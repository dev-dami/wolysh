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

/// Installs a disposition for one signal. Used by `trap`; `null` restores the
/// default action, which in the interactive shell is its own handling, so
/// `trap - INT` does not let Ctrl-C kill the shell.
pub fn installHandler(sig: linux.SIG, handler: ?linux.Sigaction.handler_fn) void {
    if (sig == .KILL or sig == .STOP) return;
    if (handler == null and interrupt_flag != null) {
        if (interactiveDisposition(sig)) |own| return setHandler(sig, own);
    }
    setHandler(sig, handler);
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
/// and caught ones would run the shell's handler in a forked builtin.
pub fn resetSignals() void {
    interrupt_flag = null;
    setHandler(.INT, linux.SIG.DFL);
    setHandler(.HUP, linux.SIG.DFL);
    setHandler(.TERM, linux.SIG.DFL);
    setHandler(.QUIT, linux.SIG.DFL);
    setHandler(.TSTP, linux.SIG.DFL);
    setHandler(.TTIN, linux.SIG.DFL);
    setHandler(.TTOU, linux.SIG.DFL);
    setHandler(.PIPE, linux.SIG.DFL);
    setHandler(.CHLD, linux.SIG.DFL);
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
        if (err == .INTR) continue;
        if (err != .SUCCESS or rc == 0) return null;
        return .{ .pid = @intCast(rc), .status = decode(wstatus) };
    }
}

fn childRun(stage: Stage, fd_in: i32, fd_out: i32, pipes: []const [2]i32, pgid: i32) noreturn {
    // Both parent and child call setpgid so neither has to win the race.
    if (pgid != 0) _ = linux.setpgid(0, pgid);
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

    if (stage.exec) |e| {
        const rc = linux.execve(e.path, e.argv, e.envp);
        if (linux.errno(rc) == .NOEXEC) {
            if (e.shell_path) |sh| {
                if (e.shell_argv) |argv| {
                    _ = linux.execve(sh, argv, e.envp);
                }
            }
        }
    }

    const msg = "wsh: could not execute command\n";
    _ = linux.write(2, msg.ptr, msg.len);
    linux.exit(127);
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
        if (options.new_group) {
            if (pid == 0) childRun(stage, fd_in, fd_out, pipes.items, pgid);
        } else if (pid == 0) {
            childRun(stage, fd_in, fd_out, pipes.items, 0);
        }

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
