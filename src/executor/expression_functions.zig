const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const fs = @import("../fs.zig");
const shellmod = @import("../shell.zig");
const value = @import("../value.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };
pub const Evaluator = *const fn (*anyopaque, *Shell, std.mem.Allocator, *const ast.Expr) Error!Value;

const names = [_][]const u8{
    "exists",      "is_dir",    "is_file",  "is_link", "len", "empty",
    "int",         "str",       "abs",      "min",     "max", "upper",
    "lower",       "trim",      "basename", "dirname", "env", "contains",
    "starts_with", "ends_with", "split",    "join",
};

pub fn isFunction(name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

pub fn evaluate(
    sh: *Shell,
    arena: std.mem.Allocator,
    callee: []const u8,
    args: []const *ast.Expr,
    eval_context: *anyopaque,
    eval: Evaluator,
) Error!?Value {
    if (std.mem.eql(u8, callee, "exists")) return Value{ .boolean = try pathArg(sh, arena, args, &fs.exists, eval_context, eval) };
    if (std.mem.eql(u8, callee, "is_dir")) return Value{ .boolean = try pathArg(sh, arena, args, &fs.isDir, eval_context, eval) };
    if (std.mem.eql(u8, callee, "is_file")) return Value{ .boolean = try pathArg(sh, arena, args, &isRegularFile, eval_context, eval) };
    if (std.mem.eql(u8, callee, "is_link")) return Value{ .boolean = try pathArg(sh, arena, args, &isSymlink, eval_context, eval) };
    if (std.mem.eql(u8, callee, "len")) {
        const result = try eval(eval_context, sh, arena, argAt(args, 0));
        return Value{ .int = switch (result) {
            .string => |text| @intCast(text.len),
            .list => |items| @intCast(items.len),
            else => 0,
        } };
    }
    if (std.mem.eql(u8, callee, "empty")) return Value{ .boolean = (try eval(eval_context, sh, arena, argAt(args, 0))).isNull() };
    if (std.mem.eql(u8, callee, "int")) return Value{ .int = (try eval(eval_context, sh, arena, argAt(args, 0))).asInt() orelse 0 };
    if (std.mem.eql(u8, callee, "str")) {
        const result = try eval(eval_context, sh, arena, argAt(args, 0));
        return Value{ .string = try result.renderAlloc(arena) };
    }
    if (std.mem.eql(u8, callee, "abs")) {
        const number = (try eval(eval_context, sh, arena, argAt(args, 0))).asInt() orelse 0;
        return Value{ .int = if (number < 0) -number else number };
    }
    if (std.mem.eql(u8, callee, "min") or std.mem.eql(u8, callee, "max")) {
        const want_min = std.mem.eql(u8, callee, "min");
        if (args.len == 0) return Value{ .int = 0 };
        var best = (try eval(eval_context, sh, arena, args[0])).asInt() orelse 0;
        for (args[1..]) |arg| {
            const number = (try eval(eval_context, sh, arena, arg)).asInt() orelse 0;
            if (want_min) {
                if (number < best) best = number;
            } else if (number > best) best = number;
        }
        return Value{ .int = best };
    }
    if (std.mem.eql(u8, callee, "upper") or std.mem.eql(u8, callee, "lower")) {
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        const out = try arena.dupe(u8, text);
        const want_upper = std.mem.eql(u8, callee, "upper");
        for (out) |*c| c.* = if (want_upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
        return Value{ .string = out };
    }
    if (std.mem.eql(u8, callee, "trim")) {
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        return Value{ .string = std.mem.trim(u8, text, " \t\r\n") };
    }
    if (std.mem.eql(u8, callee, "basename")) {
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        return Value{ .string = std.fs.path.basename(text) };
    }
    if (std.mem.eql(u8, callee, "dirname")) {
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        return Value{ .string = try arena.dupe(u8, std.fs.path.dirname(text) orelse ".") };
    }
    if (std.mem.eql(u8, callee, "env")) {
        const name = try stringArg(sh, arena, args, 0, eval_context, eval);
        if (sh.getEnv(name)) |entry| return Value{ .string = try arena.dupe(u8, entry) };
        if (args.len >= 2) return Value{ .string = try stringArg(sh, arena, args, 1, eval_context, eval) };
        return Value{ .string = "" };
    }
    if (std.mem.eql(u8, callee, "contains") or
        std.mem.eql(u8, callee, "starts_with") or
        std.mem.eql(u8, callee, "ends_with"))
    {
        if (args.len < 2) return Value{ .boolean = false };
        const haystack = try stringArg(sh, arena, args, 0, eval_context, eval);
        const needle = try stringArg(sh, arena, args, 1, eval_context, eval);
        if (std.mem.eql(u8, callee, "contains")) {
            return Value{ .boolean = std.mem.indexOf(u8, haystack, needle) != null };
        }
        if (std.mem.eql(u8, callee, "starts_with")) {
            return Value{ .boolean = std.mem.startsWith(u8, haystack, needle) };
        }
        return Value{ .boolean = std.mem.endsWith(u8, haystack, needle) };
    }
    if (std.mem.eql(u8, callee, "split")) {
        if (args.len < 2) return Value{ .list = &.{} };
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        const sep = try stringArg(sh, arena, args, 1, eval_context, eval);
        var out: std.ArrayList(Value) = .empty;
        if (sep.len == 0) {
            for (text) |c| try out.append(arena, Value{ .string = try arena.dupe(u8, &[_]u8{c}) });
        } else {
            var it = std.mem.splitSequence(u8, text, sep);
            while (it.next()) |part| try out.append(arena, Value{ .string = try arena.dupe(u8, part) });
        }
        return Value{ .list = try out.toOwnedSlice(arena) };
    }
    if (std.mem.eql(u8, callee, "join")) {
        if (args.len < 2) return Value{ .string = "" };
        const list = try eval(eval_context, sh, arena, args[0]);
        const sep = try stringArg(sh, arena, args, 1, eval_context, eval);
        if (std.meta.activeTag(list) != .list) return Value{ .string = "" };
        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        for (list.list, 0..) |item, i| {
            if (i != 0) try out.writer.writeAll(sep);
            try item.render(&out.writer);
        }
        return Value{ .string = try out.toOwnedSlice() };
    }
    return null;
}

fn argAt(args: []const *ast.Expr, index: usize) *const ast.Expr {
    if (index < args.len) return args[index];
    return &null_expr;
}

const null_expr: ast.Expr = .null_lit;

fn stringArg(
    sh: *Shell,
    arena: std.mem.Allocator,
    args: []const *ast.Expr,
    index: usize,
    eval_context: *anyopaque,
    eval: Evaluator,
) Error![]const u8 {
    if (index >= args.len) return "";
    const result = try eval(eval_context, sh, arena, args[index]);
    return result.renderAlloc(arena);
}

fn pathArg(
    sh: *Shell,
    arena: std.mem.Allocator,
    args: []const *ast.Expr,
    predicate: *const fn ([:0]const u8) bool,
    eval_context: *anyopaque,
    eval: Evaluator,
) Error!bool {
    const text = try stringArg(sh, arena, args, 0, eval_context, eval);
    if (text.len + 1 > linux.PATH_MAX) return false;
    const z = try arena.dupeZ(u8, text);
    return predicate(z);
}

fn isRegularFile(z: [:0]const u8) bool {
    return fs.kind(z) == .file;
}

fn isSymlink(z: [:0]const u8) bool {
    return fs.kind(z) == .symlink;
}

fn evalNone(_: *anyopaque, _: *Shell, _: std.mem.Allocator, _: *const ast.Expr) Error!Value {
    return .none;
}

test "expression function registry has implementations" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    for (names) |name| {
        var context: u8 = 0;
        const result = try evaluate(&sh, arena_state.allocator(), name, &.{}, &context, &evalNone);
        try std.testing.expect(result != null);
    }
    try std.testing.expect(!isFunction("unknown"));
}
