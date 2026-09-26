const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");

const Shell = shellmod.Shell;

pub const RunStatements = *const fn (*Shell, []const ast.Stmt) u8;

const Payload = struct {
    sh: *Shell,
    statements: []ast.Stmt,
    run_statements: RunStatements,
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
    sh.return_pending = false;
    sh.break_pending = false;
    sh.continue_pending = false;
    linux.exit(payload.run_statements(sh, payload.statements));
}

pub fn makeStage(
    sh: *Shell,
    arena: std.mem.Allocator,
    statements: []ast.Stmt,
    redirects: []const proc.Redirection,
    run_statements: RunStatements,
) !proc.Stage {
    const payload = try arena.create(Payload);
    payload.* = .{ .sh = sh, .statements = statements, .run_statements = run_statements };
    return .{
        .child_fn = child,
        .child_ctx = payload,
        .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
        .redirects = redirects,
    };
}
