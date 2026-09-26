const std = @import("std");
const sys = @import("../sys.zig");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const shellmod = @import("../shell.zig");
const value = @import("../value.zig");
const expression_functions = @import("expression_functions.zig");
const operations = @import("operations.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };
pub const CallExecutor = *const fn (*Shell, std.mem.Allocator, []const u8, []const *ast.Expr) Error!Value;

const EvalContext = struct {
    execute_call: CallExecutor,
};

pub fn evaluate(
    sh: *Shell,
    arena: std.mem.Allocator,
    expr: *const ast.Expr,
    execute_call: CallExecutor,
) Error!Value {
    var context = EvalContext{ .execute_call = execute_call };
    return evaluateInner(&context, sh, arena, expr);
}

fn evaluateCallback(context_ptr: *anyopaque, sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    const context: *EvalContext = @ptrCast(@alignCast(context_ptr));
    return evaluateInner(context, sh, arena, expr);
}

fn evaluateInner(context: *EvalContext, sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    switch (expr.*) {
        .null_lit => return .none,
        .boolean => |boolean| return Value{ .boolean = boolean },
        .int => |integer| return Value{ .int = integer },
        .float => |float| return Value{ .float = float },
        .string => |word| return Value{ .string = try expand_mod.expandLiteral(sh, arena, word) },
        .ident => |name| return evalIdent(sh, arena, name),
        .list => |items| {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |item, index| out[index] = try evaluateInner(context, sh, arena, item);
            return Value{ .list = out };
        },
        .logic => |logic| {
            const lhs = try evaluateInner(context, sh, arena, logic.lhs);
            const take_rhs = switch (logic.op) {
                .and_ => lhs.truthy(),
                .or_ => !lhs.truthy(),
            };
            if (!take_rhs) return Value{ .boolean = lhs.truthy() };
            const rhs = try evaluateInner(context, sh, arena, logic.rhs);
            return Value{ .boolean = rhs.truthy() };
        },
        .un => |unary| {
            const operand = try evaluateInner(context, sh, arena, unary.operand);
            return switch (unary.op) {
                .not => Value{ .boolean = !operand.truthy() },
                .neg => switch (operand) {
                    .int => |integer| Value{ .int = -integer },
                    .float => |float| Value{ .float = -float },
                    else => Value{ .int = -(operand.asInt() orelse 0) },
                },
            };
        },
        .bin => |binary| {
            const lhs = try evaluateInner(context, sh, arena, binary.lhs);
            const rhs = try evaluateInner(context, sh, arena, binary.rhs);
            return try operations.binary(arena, binary.op, lhs, rhs);
        },
        .call => |call| {
            if (try expression_functions.evaluate(sh, arena, call.callee, call.args, context, &evaluateCallback)) |result| {
                return result;
            }
            return context.execute_call(sh, arena, call.callee, call.args);
        },
    }
}

fn evalIdent(sh: *Shell, arena: std.mem.Allocator, name: []const u8) Error!Value {
    if (std.mem.eql(u8, name, "status")) return Value{ .int = sh.last_status };
    if (std.mem.eql(u8, name, "pid")) return Value{ .int = sh.pid };
    if (std.mem.eql(u8, name, "cwd")) return Value{ .string = try arena.dupe(u8, sh.cwd) };
    if (std.mem.eql(u8, name, "host")) return Value{ .string = try arena.dupe(u8, sh.hostname) };
    if (std.mem.eql(u8, name, "argv")) {
        const out = try arena.alloc(Value, sh.positional.len);
        for (sh.positional, 0..) |argument, index| out[index] = Value{ .string = try arena.dupe(u8, argument) };
        return Value{ .list = out };
    }
    if (std.mem.eql(u8, name, "env")) {
        var out: std.ArrayList(Value) = .empty;
        var iterator = sh.env.iterator();
        while (iterator.next()) |entry| {
            const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try out.append(arena, Value{ .string = pair });
        }
        return Value{ .list = try out.toOwnedSlice(arena) };
    }

    if (sh.getVar(name)) |result| return result;
    if (sh.getEnv(name)) |environment| return Value{ .string = try arena.dupe(u8, environment) };
    return .none;
}

pub fn isFunction(name: []const u8) bool {
    return expression_functions.isFunction(name);
}

pub fn misuse(words: []const []const u8) ?[]const u8 {
    for (words, 0..) |word, index| {
        if (index == 0) continue;
        const open = std.mem.indexOfScalar(u8, word, '(') orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, word, ')') orelse continue;
        if (close <= open) continue;
        const name = word[0..open];
        if (!isFunction(name)) continue;
        for (word[close + 1 ..]) |character| {
            if (character != ' ' and character != 0x09) return null;
        }
        return name;
    }
    return null;
}

pub fn reportMisuse(sh: *Shell, name: []const u8) void {
    var buf: [320]u8 = undefined;
    const message = std.fmt.bufPrint(&buf,
        \\wsh: '{s}' is an expression function, not a command.
        \\     try: let result = {s}(...)
        \\
    , .{ name, name }) catch return;
    sys.writeStr(sh.default_err, message);
}
