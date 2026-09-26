const std = @import("std");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const parser_mod = @import("../parser.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");
const value = @import("../value.zig");

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
    name: []const u8,
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

    for (declaration.params, 0..) |param, index| {
        const arg_index = index + 1;
        if (arg_index < argv.len) {
            sh.setVar(param.name, .{ .string = argv[arg_index] }) catch return 1;
        } else if (param.default) |default| {
            const result = runtime.evaluate(sh, arena, default) catch |err| return runtime.expression_error(sh, err);
            sh.setVar(param.name, result) catch return 1;
        } else {
            sh.setVar(param.name, .{ .string = "" }) catch return 1;
        }
    }

    const saved_positional = sh.positional;
    const saved_name = sh.script_name;
    const saved_return = sh.return_pending;
    const saved_code = sh.return_code;
    sh.positional = if (argv.len > 1) argv[1..] else &.{};
    sh.script_name = name;
    sh.return_pending = false;
    sh.call_depth += 1;
    defer {
        sh.call_depth -= 1;
        sh.positional = saved_positional;
        sh.script_name = saved_name;
        sh.return_pending = saved_return;
        sh.return_code = saved_code;
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
