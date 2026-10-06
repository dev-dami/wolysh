//! Process engine: fork/exec, pipelines, process groups and waiting.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const fs = @import("fs.zig");

pub const Error = error{
    ForkFailed,
    PipeFailed,
    NotFound,
    NotExecutable,
} || std.mem.Allocator.Error;

/// Which descriptors a stage reads from and writes to. `0`/`1`/`2` mean
/// "inherit the shell's own".
pub const Stdio = struct {
    in: i32 = 0,
    out: i32 = 1,
    err: i32 = 2,
};

/// A prepared `execve` call. Everything is built in the parent so the child
/// never allocates.
pub const Exec = struct {
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    /// Fallback used when `execve` reports `ENOEXEC`: run the file through
    /// `/bin/sh`, the way a real shell does.
    shell_path: ?[*:0]const u8 = null,
    shell_argv: ?[*:null]const ?[*:0]const u8 = null,
};

/// One process in a pipeline. Either exec a program or run shell code in the
/// forked child (used for builtins that appear inside a pipeline).
pub const Stage = struct {
    exec: ?*const Exec = null,
    child_fn: ?*const fn (*anyopaque) noreturn = null,
    child_ctx: ?*anyopaque = null,
    stdio: Stdio = .{},
    redirects: []const Redirection = &.{},
};

pub const Redirection = struct {
    target: i32,
    source: i32,
    close_source: bool = false,
};

pub const LaunchOptions = struct {
    /// Put the job in its own process group. Real job control needs this;
    /// command substitution does not, and staying in the shell's group means
    /// it still receives terminal signals.
    new_group: bool = true,
};

pub const Launched = struct {
    /// Process group shared by every stage.
    pgid: i32,
    /// Pids in pipeline order.
    pids: []i32,
};

fn setHandler(sig: linux.SIG, handler: ?linux.Sigaction.handler_fn) void {
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = handler };
    _ = linux.sigaction(sig, &act, null);
}

/// Dispositions in force before `trap` first changed each signal, so `trap -
/// SIG` puts back what the shell itself had (an interactive shell ignores
/// SIGINT, for instance).
var original_actions: [linux.NSIG]?linux.Sigaction = [_]?linux.Sigaction{null} ** linux.NSIG;
/// Signals a `trap '' SIG` ignores. Children keep ignoring them.
var trap_ignored: u64 = 0;

fn signalBit(sig: linux.SIG) u64 {
    return @as(u64, 1) << @intCast(@intFromEnum(sig) - 1);
}

/// Installs a disposition for one signal. Used by `trap`.
pub fn installHandler(sig: linux.SIG, handler: ?linux.Sigaction.handler_fn) void {
    if (sig == .KILL or sig == .STOP) return;
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = handler };
    var old: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(sig, &act, &old)) != .SUCCESS) return;
    const index = @intFromEnum(sig);
    if (original_actions[index] == null) original_actions[index] = old;
    const ignoring = if (handler) |h| @intFromPtr(h) == @intFromPtr(linux.SIG.IGN.?) else false;
    if (ignoring) trap_ignored |= signalBit(sig) else trap_ignored &= ~signalBit(sig);
}

/// `trap - SIG`: puts back the disposition the shell had before any trap. In
/// the interactive shell that is its own handling, so `trap - INT` does not
/// let Ctrl-C kill the shell.
pub fn restoreHandler(sig: linux.SIG) void {
    if (sig == .KILL or sig == .STOP) return;
    trap_ignored &= ~signalBit(sig);
    if (interrupt_flag != null) {
        if (interactiveDisposition(sig)) |own| return setHandler(sig, own);
    }
    const original = original_actions[@intFromEnum(sig)] orelse return setHandler(sig, linux.SIG.DFL);
    _ = linux.sigaction(sig, &original, null);
}

/// True when the shell started with `sig` at its default action, so catching
/// it changes nothing but the chance to run cleanup first.
pub fn startedDefault(sig: linux.SIG) bool {
    // SIG_DFL is the null handler.
    if (original_actions[@intFromEnum(sig)]) |original| return original.handler.handler == null;
    var current: linux.Sigaction = undefined;
    if (linux.errno(linux.sigaction(sig, null, &current)) != .SUCCESS) return false;
    return current.handler.handler == null;
}

/// Signals that can never be caught or ignored.
pub fn isUncatchable(sig: linux.SIG) bool {
    return sig == .KILL or sig == .STOP;
}

/// Resolves `INT`, `SIGINT`, `int` or `2` to a signal number.
pub fn signalFromName(text: []const u8) ?linux.SIG {
    var buf: [16]u8 = undefined;
    var name = text;
    if (std.mem.startsWith(u8, name, "SIG") or std.mem.startsWith(u8, name, "sig")) name = name[3..];
    if (name.len == 0 or name.len > buf.len) return null;
    for (name, 0..) |c, i| buf[i] = std.ascii.toUpper(c);
    name = buf[0..name.len];

    if (std.fmt.parseInt(u32, name, 10)) |n| {
        if (n == 0 or n > 64) return null;
        return @enumFromInt(n);
    } else |_| {}

    const known = [_]struct { []const u8, linux.SIG }{
        .{ "HUP", .HUP },       .{ "INT", .INT },   .{ "QUIT", .QUIT },
        .{ "ILL", .ILL },       .{ "TRAP", .TRAP }, .{ "ABRT", .ABRT },
        .{ "BUS", .BUS },       .{ "FPE", .FPE },   .{ "KILL", .KILL },
        .{ "USR1", .USR1 },     .{ "SEGV", .SEGV }, .{ "USR2", .USR2 },
        .{ "PIPE", .PIPE },     .{ "ALRM", .ALRM }, .{ "TERM", .TERM },
        .{ "CHLD", .CHLD },     .{ "CONT", .CONT }, .{ "STOP", .STOP },
        .{ "TSTP", .TSTP },     .{ "TTIN", .TTIN }, .{ "TTOU", .TTOU },
        .{ "URG", .URG },       .{ "XCPU", .XCPU }, .{ "XFSZ", .XFSZ },
        .{ "VTALRM", .VTALRM }, .{ "PROF", .PROF }, .{ "WINCH", .WINCH },
        .{ "IO", .IO },         .{ "SYS", .SYS },
    };
    for (known) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Canonical short name of a signal number, without the `SIG` prefix.
pub fn signalName(sig: u32) []const u8 {
    if (sig == 0 or sig > 64) return "0";
    const named: linux.SIG = @enumFromInt(sig);
    return switch (named) {
        .HUP => "HUP",
        .INT => "INT",
        .QUIT => "QUIT",
        .ILL => "ILL",
        .TRAP => "TRAP",
        .ABRT => "ABRT",
        .BUS => "BUS",
        .FPE => "FPE",
        .KILL => "KILL",
        .USR1 => "USR1",
        .SEGV => "SEGV",
        .USR2 => "USR2",
        .PIPE => "PIPE",
        .ALRM => "ALRM",
        .TERM => "TERM",
        .CHLD => "CHLD",
        .CONT => "CONT",
        .STOP => "STOP",
        .TSTP => "TSTP",
        .TTIN => "TTIN",
        .TTOU => "TTOU",
        .URG => "URG",
        .XCPU => "XCPU",
        .XFSZ => "XFSZ",
        .VTALRM => "VTALRM",
        .PROF => "PROF",
        .WINCH => "WINCH",
        .IO => "IO",
        .SYS => "SYS",
        else => "SIG",
    };
}

/// The interactive shell's `Shell.interrupted`, raised by the SIGINT and SIGHUP
/// handlers. Volatile because a handler writes it behind the compiler's back.
var interrupt_flag: ?*volatile bool = null;
var hangup_received: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);

fn onInterrupt(_: linux.SIG) callconv(.c) void {
    if (interrupt_flag) |flag| flag.* = true;
}

fn onHangup(_: linux.SIG) callconv(.c) void {
    hangup_received.store(true, .monotonic);
    if (interrupt_flag) |flag| flag.* = true;
    // The shell may be blocked waiting for a foreground job; hang that up too,
    // as a real terminal hangup does, so the shell gets to act on it.
    var foreground: linux.pid_t = 0;
    if (linux.errno(linux.tcgetpgrp(0, &foreground)) != .SUCCESS or foreground <= 0) return;
    if (foreground != @as(linux.pid_t, @intCast(linux.getpgid(0)))) _ = linux.kill(-foreground, .HUP);
}

/// What the interactive shell does with `sig` when no trap is set.
fn interactiveDisposition(sig: linux.SIG) ?linux.Sigaction.handler_fn {
    return switch (sig) {
        .INT => onInterrupt,
        .HUP => onHangup,
        .TERM, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE => linux.SIG.IGN,
        else => null,
    };
}

/// True once SIGHUP reached the interactive shell; the REPL then hangs up.
pub fn hangupPending() bool {
    return hangup_received.load(.monotonic);
}

/// Dispositions for the interactive shell. SIGINT and SIGHUP are caught
/// without `SA_RESTART`, so a blocking read or wait returns EINTR instead of
/// resuming and the command line can stop; SIGTERM is ignored, as in bash.
pub fn shellSignals(interrupted: *bool) void {
    interrupt_flag = interrupted;
    setHandler(.INT, onInterrupt);
    setHandler(.HUP, onHangup);
    setHandler(.TERM, linux.SIG.IGN);
    setHandler(.QUIT, linux.SIG.IGN);
    setHandler(.TSTP, linux.SIG.IGN);
    setHandler(.TTIN, linux.SIG.IGN);
    setHandler(.TTOU, linux.SIG.IGN);
    setHandler(.PIPE, linux.SIG.IGN);
}

/// Children must get the default dispositions back, otherwise Ctrl-C would be
/// ignored by everything the shell starts. Ignored signals survive `execve`,
/// and caught ones would run the shell's handler in a forked builtin. Signals
/// `trap ''` ignores stay ignored, as in other shells.
pub fn resetSignals() void {
    interrupt_flag = null;
    for ([_]linux.SIG{ .INT, .HUP, .TERM, .QUIT, .TSTP, .TTIN, .TTOU, .PIPE, .CHLD }) |sig| {
        if (trap_ignored & signalBit(sig) == 0) setHandler(sig, linux.SIG.DFL);
    }
}

/// Builds a null-terminated argument vector in `arena`.
pub fn buildArgv(arena: std.mem.Allocator, items: []const []const u8) ![*:null]const ?[*:0]const u8 {
    const arr = try arena.alloc(?[*:0]const u8, items.len + 1);
    for (items, 0..) |item, i| {
        arr[i] = (try arena.dupeZ(u8, item)).ptr;
    }
    arr[items.len] = null;
    return @ptrCast(arr.ptr);
}

/// Finds the file to `execve` for `name`. A name with a `/` is used as it is,
/// so `execve` reports why it cannot run. Otherwise the first executable on
/// `PATH` wins; failing that, the first other non-directory match, which
/// `execve` then refuses with `Permission denied`, as in bash. Null when
/// nothing on `PATH` matches.
pub fn locate(arena: std.mem.Allocator, name: []const u8, path_env: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var fallback: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        const z = try arena.dupeZ(u8, full);
        const found = fs.kind(z) orelse continue;
        if (found == .dir) continue;
        if (fs.isExecutable(z)) return full;
        if (fallback == null) fallback = full;
    }
    return fallback;
}

/// The C library's message for the errors the shell reports.
pub fn errorText(err: linux.E) []const u8 {
    return switch (err) {
        .PERM => "Operation not permitted",
        .NOENT => "No such file or directory",
        .SRCH => "No such process",
        .@"2BIG" => "Argument list too long",
        .NOEXEC => "Exec format error",
        .NOMEM => "Cannot allocate memory",
        .ACCES => "Permission denied",
        .NOTDIR => "Not a directory",
        .ISDIR => "Is a directory",
        .INVAL => "Invalid argument",
        .TXTBSY => "Text file busy",
        .NAMETOOLONG => "File name too long",
        .LOOP => "Too many levels of symbolic links",
        .IO => "Input/output error",
        else => std.enums.tagName(linux.E, err) orelse "Unknown error",
    };
}

/// Locates `name` on `PATH`. Returns null when it is not an executable file.
pub fn resolve(arena: std.mem.Allocator, name: []const u8, path_env: []const u8) !?[]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        const z = try arena.dupeZ(u8, name);
        if (fs.isExecutable(z)) return name;
        return null;
    }
    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        const z = try arena.dupeZ(u8, full);
        if (fs.isExecutable(z)) return full;
    }
    return null;
}

pub const StatusKind = enum { exited, signaled, stopped, continued };

pub const Status = struct {
    kind: StatusKind,
    code: u8 = 0,
    sig: u32 = 0,

    pub fn exitCode(self: Status) u8 {
        return switch (self.kind) {
            .exited => self.code,
            .signaled => 128 +% @as(u8, @intCast(@min(self.sig, 127))),
            .stopped => 128 +% @as(u8, @intCast(@min(self.sig, 127))),
            .continued => 0,
        };
    }
};

pub fn decode(wstatus: u32) Status {
    if (linux.W.IFEXITED(wstatus)) return .{ .kind = .exited, .code = linux.W.EXITSTATUS(wstatus) };
    if (linux.W.IFSIGNALED(wstatus)) return .{ .kind = .signaled, .sig = @intFromEnum(linux.W.TERMSIG(wstatus)) };
    if (linux.W.IFSTOPPED(wstatus)) return .{ .kind = .stopped, .sig = @intFromEnum(linux.W.STOPSIG(wstatus)) };
    return .{ .kind = .continued };
}

/// Waits for one pid. Returns null with `WNOHANG` when nothing is ready.
pub fn waitPid(pid: i32, flags: u32) ?Status {
    var wstatus: u32 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &wstatus, flags);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return null;
        const p: i32 = @intCast(rc);
        if (p == 0) return null;
        return decode(wstatus);
    }
}

pub const ChildEvent = struct { pid: i32, status: Status };

pub fn waitAny(flags: u32) ?ChildEvent {
    var wstatus: u32 = 0;
    while (true) {
        const rc = linux.waitpid(-1, &wstatus, flags);
        const err = linux.errno(rc);
        if (err == .INTR) {
            // Ctrl-C in an interactive shell ends `wait -n` instead of resuming it.
            if (interrupt_flag) |flag| {
                if (flag.*) return null;
            }
            continue;
        }
        if (err != .SUCCESS or rc == 0) return null;
        return .{ .pid = @intCast(rc), .status = decode(wstatus) };
    }
}

/// `group` is the process group to join: 0 makes this child the leader of a
/// new one, null keeps the shell's.
fn childRun(stage: Stage, fd_in: i32, fd_out: i32, pipes: []const [2]i32, group: ?i32) noreturn {
    // Both parent and child call setpgid so neither has to win the race.
    if (group) |pgid| _ = linux.setpgid(0, pgid);
    resetSignals();

    const sources = [3]i32{ fd_in, fd_out, stage.stdio.err };
    var cross_standard = false;
    for (sources, 0..) |source, target| {
        if (source >= 0 and source < 3 and source != @as(i32, @intCast(target))) cross_standard = true;
    }
    if (cross_standard) {
        // Preserve standard descriptors before a remapping can overwrite them.
        var saved: [3]i32 = undefined;
        for (sources, 0..) |source, index| saved[index] = sys.duplicate(source) orelse linux.exit(126);
        for (saved, 0..) |source, target| {
            if (linux.errno(linux.dup3(source, @intCast(target), 0)) != .SUCCESS) linux.exit(126);
            sys.closeFd(source);
        }
    } else {
        for (sources, 0..) |source, target| {
            if (source == @as(i32, @intCast(target))) continue;
            if (linux.errno(linux.dup3(source, @intCast(target), 0)) != .SUCCESS) linux.exit(126);
        }
    }

    for (pipes) |fds| {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }

    for (stage.redirects) |redirect| {
        sys.dup2(redirect.source, redirect.target);
        if (redirect.close_source) sys.closeFd(redirect.source);
    }

    if (stage.child_fn) |f| f(stage.child_ctx.?);

    const e = stage.exec orelse {
        const msg = "wsh: internal error: a stage has nothing to run\n";
        _ = linux.write(2, msg.ptr, msg.len);
        linux.exit(127);
    };
    const err = linux.errno(linux.execve(e.path, e.argv, e.envp));
    if (err == .NOEXEC) {
        if (e.shell_path) |sh| {
            if (e.shell_argv) |argv| _ = linux.execve(sh, argv, e.envp);
        }
    }
    var buf: [linux.PATH_MAX + 512]u8 = undefined;
    const failure = describeExecFailure(&buf, std.mem.span(e.path), err);
    _ = linux.write(2, failure.text.ptr, failure.text.len);
    linux.exit(failure.status);
}

pub const ExecFailure = struct {
    /// A whole `wsh: ...` line.
    text: []const u8,
    status: u8,
};

/// Explains a failed `execve` of `path` the way bash does: status 127 when
/// the command does not exist, 126 when it exists but cannot run. Uses only
/// `buf` and the stack, so a forked child can call it.
pub fn describeExecFailure(buf: []u8, path: [:0]const u8, err: linux.E) ExecFailure {
    var head: [256]u8 = undefined;
    var status: u8 = 126;
    const text = switch (err) {
        .NOENT => if (interpreterOf(path, &head)) |interpreter|
            std.fmt.bufPrint(buf, "wsh: {s}: {s}: bad interpreter: No such file or directory\n", .{ path, interpreter })
        else blk: {
            status = 127;
            break :blk std.fmt.bufPrint(buf, "wsh: {s}: No such file or directory\n", .{path});
        },
        .ACCES => std.fmt.bufPrint(buf, "wsh: {s}: {s}\n", .{ path, if (fs.isDir(path)) "Is a directory" else "Permission denied" }),
        else => std.fmt.bufPrint(buf, "wsh: {s}: {s}\n", .{ path, errorText(err) }),
    } catch "wsh: cannot execute command: name too long\n";
    return .{ .text = text, .status = status };
}

/// The interpreter named by a `#!` line, or null when `path` cannot be read
/// or does not start with one.
fn interpreterOf(path: [:0]const u8, buf: []u8) ?[]const u8 {
    const fd = sys.openRead(path.ptr) orelse return null;
    defer sys.closeFd(fd);
    const n = sys.readAll(fd, buf);
    const head = buf[0..n];
    if (!std.mem.startsWith(u8, head, "#!")) return null;
    const line = head[2 .. std.mem.indexOfScalar(u8, head, '\n') orelse head.len];
    const trimmed = std.mem.trimStart(u8, line, " \t");
    const end = std.mem.indexOfAny(u8, trimmed, " \t\r") orelse trimmed.len;
    if (end == 0) return null;
    return trimmed[0..end];
}

/// Forks every stage, wiring the pipes between them, and returns the pids.
/// The caller waits for the job or registers it as a background job.
pub fn launch(arena: std.mem.Allocator, stages: []const Stage, options: LaunchOptions) Error!Launched {
    std.debug.assert(stages.len > 0);

    var pipes: std.ArrayList([2]i32) = .empty;
    var i: usize = 0;
    while (i + 1 < stages.len) : (i += 1) {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) {
            for (pipes.items) |p| {
                _ = linux.close(p[0]);
                _ = linux.close(p[1]);
            }
            return error.PipeFailed;
        }
        try pipes.append(arena, fds);
    }

    const pids = try arena.alloc(i32, stages.len);
    var pgid: i32 = 0;

    for (stages, 0..) |stage, idx| {
        const fd_in = if (idx == 0) stage.stdio.in else pipes.items[idx - 1][0];
        const fd_out = if (idx + 1 == stages.len) stage.stdio.out else pipes.items[idx][1];

        const rc = linux.fork();
        if (linux.errno(rc) != .SUCCESS) {
            for (pipes.items) |p| {
                _ = linux.close(p[0]);
                _ = linux.close(p[1]);
            }
            return error.ForkFailed;
        }
        const pid: i32 = @intCast(rc);
        if (pid == 0) childRun(stage, fd_in, fd_out, pipes.items, if (options.new_group) pgid else null);

        pids[idx] = pid;
        if (options.new_group) {
            if (idx == 0) {
                pgid = pid;
                _ = linux.setpgid(pid, pid);
            } else {
                _ = linux.setpgid(pid, pgid);
            }
        }
    }

    for (pipes.items) |p| {
        _ = linux.close(p[0]);
        _ = linux.close(p[1]);
    }

    const process_group = if (pgid != 0)
        pgid
    else if (options.new_group)
        pids[0]
    else
        (sys.getpgid(0) orelse pids[0]);
    return .{ .pgid = process_group, .pids = pids };
}

pub fn signalProcess(pid: i32, sig: linux.SIG) void {
    _ = linux.kill(pid, sig);
}

/// `kill(2)` with any signal number, real-time ones included, returning the
/// errno so the caller can say why it failed. A negative `pid` names a group.
pub fn sendSignal(pid: i32, sig: u32) linux.E {
    return linux.errno(linux.syscall2(.kill, @bitCast(@as(isize, pid)), sig));
}

pub fn signalGroup(pgid: i32, sig: linux.SIG) void {
    _ = linux.kill(-pgid, sig);
}

/// Signal 0 (`kill -0`): reports whether the process exists and is ours to
/// signal. Sent as a raw syscall because `linux.kill` takes a `SIG` enum, which
/// has no zero member.
pub fn probeProcess(pid: i32) bool {
    const rc = linux.syscall2(.kill, @bitCast(@as(isize, pid)), 0);
    return linux.errno(rc) == .SUCCESS;
}

test "create a pipe and read from a child" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fds: [2]i32 = undefined;
    try std.testing.expectEqual(
        linux.E.SUCCESS,
        linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })),
    );

    const argv = try buildArgv(arena, &.{ "echo", "hello" });
    const envp = try buildArgv(arena, &.{"PATH=/usr/bin:/bin"});
    const exec = Exec{
        .path = "/bin/echo",
        .argv = argv,
        .envp = envp,
    };

    const launched = try launch(arena, &.{.{ .exec = &exec, .stdio = .{ .out = fds[1] } }}, .{});
    _ = linux.close(fds[1]);

    var buf: [64]u8 = undefined;
    const n = sys.readAll(fds[0], &buf);
    _ = linux.close(fds[0]);
    try std.testing.expectEqualStrings("hello\n", buf[0..n]);

    const st = waitPid(launched.pids[0], 0).?;
    try std.testing.expectEqual(@as(u8, 0), st.exitCode());
}

test "signal names round-trip" {
    try std.testing.expectEqual(linux.SIG.INT, signalFromName("INT").?);
    try std.testing.expectEqual(linux.SIG.TERM, signalFromName("SIGTERM").?);
    try std.testing.expectEqual(linux.SIG.TERM, signalFromName("term").?);
    try std.testing.expectEqual(linux.SIG.USR1, signalFromName("10").?);
    try std.testing.expect(signalFromName("NOPE") == null);
    try std.testing.expect(signalFromName("0") == null);
    try std.testing.expectEqualStrings("INT", signalName(2));
    try std.testing.expectEqualStrings("TERM", signalName(15));
    try std.testing.expect(isUncatchable(linux.SIG.KILL));
    try std.testing.expect(!isUncatchable(linux.SIG.INT));
}

test "resolve finds real binaries and rejects missing ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try resolve(arena, "sh", "/usr/bin:/bin");
    try std.testing.expect(found != null);
    const missing = try resolve(arena, "definitely-not-a-real-binary-xyz", "/usr/bin:/bin");
    try std.testing.expect(missing == null);
}
