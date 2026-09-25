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

/// Signals the shell itself ignores while it waits for children.
pub fn shellSignals() void {
    setHandler(.INT, linux.SIG.IGN);
    setHandler(.QUIT, linux.SIG.IGN);
    setHandler(.TSTP, linux.SIG.IGN);
    setHandler(.TTIN, linux.SIG.IGN);
    setHandler(.TTOU, linux.SIG.IGN);
    setHandler(.PIPE, linux.SIG.IGN);
}

/// Children must get the default dispositions back, otherwise Ctrl-C would be
/// ignored by everything the shell starts.
pub fn resetSignals() void {
    setHandler(.INT, linux.SIG.DFL);
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

fn childRun(stage: Stage, fd_in: i32, fd_out: i32, pipes: []const [2]i32, pgid: i32) noreturn {
    // Both parent and child call setpgid so neither has to win the race.
    if (pgid != 0) _ = linux.setpgid(0, pgid);
    resetSignals();

    const saved_in = sys.duplicate(fd_in) orelse linux.exit(126);
    const saved_out = sys.duplicate(fd_out) orelse linux.exit(126);
    const saved_err = sys.duplicate(stage.stdio.err) orelse linux.exit(126);
    sys.dup2(saved_in, 0);
    sys.dup2(saved_out, 1);
    sys.dup2(saved_err, 2);
    sys.closeFd(saved_in);
    sys.closeFd(saved_out);
    sys.closeFd(saved_err);

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

test "resolve finds real binaries and rejects missing ones" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try resolve(arena, "sh", "/usr/bin:/bin");
    try std.testing.expect(found != null);
    const missing = try resolve(arena, "definitely-not-a-real-binary-xyz", "/usr/bin:/bin");
    try std.testing.expect(missing == null);
}
