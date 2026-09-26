const std = @import("std");
const linux = std.os.linux;
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;
pub const RunSource = *const fn (*Shell, []const u8) u8;

const Payload = struct {
    sh: *Shell,
    src: []const u8,
    run_source: RunSource,
};

fn child(ctx_ptr: *anyopaque) noreturn {
    const payload: *Payload = @ptrCast(@alignCast(ctx_ptr));
    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    linux.exit(payload.run_source(sh, payload.src));
}

pub fn run(
    sh: *Shell,
    src: []const u8,
    arena: std.mem.Allocator,
    run_source: RunSource,
) anyerror![]const u8 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;

    const payload = try arena.create(Payload);
    payload.* = .{ .sh = sh, .src = src, .run_source = run_source };

    const stage = proc.Stage{
        .child_fn = child,
        .child_ctx = payload,
        .stdio = .{ .in = sh.default_in, .out = fds[1], .err = sh.default_err },
    };

    const launched = proc.launch(arena, &.{stage}, .{ .new_group = false }) catch |err| {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return err;
    };
    _ = linux.close(fds[1]);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.readSome(fds[0], &buf) orelse break;
        if (n == 0) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    _ = linux.close(fds[0]);

    if (proc.waitPid(launched.pids[0], 0)) |st| sh.last_status = st.exitCode();
    return try out.toOwnedSlice(arena);
}
