const std = @import("std");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const parser_mod = @import("../parser.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");
const value = @import("../value.zig");
const strict = @import("../strict.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };

pub const Runtime = struct {
    evaluate: *const fn (*Shell, std.mem.Allocator, *const ast.Expr) Error!Value,
    expression_error: *const fn (*Shell, anyerror) u8,
    run_statements: *const fn (*Shell, []const ast.Stmt) u8,
};

pub fn run(
    sh: *Shell,
    _: []const u8,
    source: []const u8,
    argv: []const []const u8,
    runtime: Runtime,
) u8 {
    if (sh.call_depth >= Shell.max_call_depth) {
        sys.writeStr(sh.default_err, "wsh: maximum function call depth reached\n");
        return 1;
    }

    const arena = sh.scratch();
    var parser = parser_mod.Parser.init(arena, source);
    const program = parser.parseProgram() catch {
        reportSyntaxError(sh, &parser);
        return 2;
    };
    if (program.stmts.len == 0) return 0;

    const declaration = switch (program.stmts[0]) {
        .fn_decl => |decl| decl,
        else => return 0,
    };

    // `$0` keeps naming the shell/script; only the positional parameters are
    // the function's.
    const saved_return = sh.return_pending;
    const saved_code = sh.return_code;
    sh.beginScope() catch return 1;
    const saved_positional = sh.pushPositional(if (argv.len > 1) argv[1..] else &.{});
    sh.return_pending = false;
    sh.call_depth += 1;
    defer {
        sh.call_depth -= 1;
        sh.endScope();
        sh.popPositional(saved_positional);
        sh.return_pending = saved_return;
        sh.return_code = saved_code;
    }
    // Declared after the block above so it runs first: the RETURN trap still
    // sees the function's parameters.
    const saved_traps = strict.enterFunction(sh);
    defer strict.leaveFunction(sh, saved_traps);

    for (declaration.params, 0..) |param, index| {
        const arg_index = index + 1;
        if (arg_index < argv.len) {
            sh.setLocal(param.name, .{ .string = argv[arg_index] }) catch return 1;
        } else if (param.default) |default| {
            const result = runtime.evaluate(sh, arena, default) catch |err| return runtime.expression_error(sh, err);
            sh.setLocal(param.name, result) catch return 1;
        } else {
            sh.setLocal(param.name, .{ .string = "" }) catch return 1;
        }
    }

    const status = runtime.run_statements(sh, declaration.body.stmts);
    if (sh.return_pending) {
        sh.last_status = sh.return_code;
        return sh.return_code;
    }
    return status;
}

fn reportSyntaxError(sh: *Shell, parser: *const parser_mod.Parser) void {
    var message_buffer: [512]u8 = undefined;
    const message = parser.message(&message_buffer);
    var line: [640]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "wsh: {s}\n", .{message}) catch message;
    sys.writeStr(sh.default_err, text);
}
