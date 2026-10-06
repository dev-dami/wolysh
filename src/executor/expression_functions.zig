const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const fs = @import("../fs.zig");
const shellmod = @import("../shell.zig");
const value = @import("../value.zig");
const sys = @import("../sys.zig");
const param_ops = @import("../param_ops.zig");
const operations = @import("operations.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };
pub const Evaluator = *const fn (*anyopaque, *Shell, std.mem.Allocator, *const ast.Expr) Error!Value;

const names = [_][]const u8{
    "exists",      "is_dir",    "is_file",  "is_link", "len",    "empty",
    "int",         "str",       "abs",      "min",     "max",    "upper",
    "lower",       "trim",      "basename", "dirname", "env",    "contains",
    "starts_with", "ends_with", "split",    "join",    "append", "slice",
    "replace",     "index",     "keys",     "values",
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
            .string => |text| @intCast(param_ops.charCount(text)),
            .list => |items| @intCast(items.len),
            .map => |entries| @intCast(entries.len),
            else => 0,
        } };
    }
    if (std.mem.eql(u8, callee, "append")) {
        const target = try eval(eval_context, sh, arena, argAt(args, 0));
        const item = try eval(eval_context, sh, arena, argAt(args, 1));
        const items: []const Value = switch (target) {
            .list => |list| list,
            .none => &.{},
            else => return fail(sh, "append: expected a list, got {s}\n", .{target.typeName()}),
        };
        const out = try arena.alloc(Value, items.len + 1);
        @memcpy(out[0..items.len], items);
        out[items.len] = item;
        return Value{ .list = out };
    }
    if (std.mem.eql(u8, callee, "slice")) {
        const target = try eval(eval_context, sh, arena, argAt(args, 0));
        const start = try intArg(sh, arena, args, 1, 0, eval_context, eval);
        switch (target) {
            .none => return .none,
            .list => |items| {
                const end = try intArg(sh, arena, args, 2, @intCast(items.len), eval_context, eval);
                const range = clampRange(items.len, start, end);
                return Value{ .list = items[range.from..range.to] };
            },
            else => {
                const text = try renderValue(arena, target);
                const count = param_ops.charCount(text);
                const end = try intArg(sh, arena, args, 2, @intCast(count), eval_context, eval);
                const range = clampRange(count, start, end);
                return Value{ .string = text[param_ops.charOffset(text, range.from)..param_ops.charOffset(text, range.to)] };
            },
        }
    }
    if (std.mem.eql(u8, callee, "replace")) {
        const text = try stringArg(sh, arena, args, 0, eval_context, eval);
        const old = try stringArg(sh, arena, args, 1, eval_context, eval);
        const new = try stringArg(sh, arena, args, 2, eval_context, eval);
        if (old.len == 0) return Value{ .string = text };
        return Value{ .string = try std.mem.replaceOwned(u8, arena, text, old, new) };
    }
    if (std.mem.eql(u8, callee, "index")) {
        const target = try eval(eval_context, sh, arena, argAt(args, 0));
        const needle = try eval(eval_context, sh, arena, argAt(args, 1));
        if (target == .list) {
            for (target.list, 0..) |item, i| {
                // Equality never needs numbers, so only allocation can fail.
                const same = operations.binary(arena, .eq, item, needle) catch return error.OutOfMemory;
                if (same.boolean) return Value{ .int = @intCast(i) };
            }
            return Value{ .int = -1 };
        }
        const text = try renderValue(arena, target);
        const sub = try renderValue(arena, needle);
        const at = std.mem.indexOf(u8, text, sub) orelse return Value{ .int = -1 };
        return Value{ .int = @intCast(param_ops.charCount(text[0..at])) };
    }
    if (std.mem.eql(u8, callee, "keys") or std.mem.eql(u8, callee, "values")) {
        const want_keys = std.mem.eql(u8, callee, "keys");
        const target = try eval(eval_context, sh, arena, argAt(args, 0));
        var out: std.ArrayList(Value) = .empty;
        switch (target) {
            .map => |entries| for (entries) |entry| {
                try out.append(arena, if (want_keys) Value{ .string = entry.key } else entry.value);
            },
            .list => |items| for (items, 0..) |item, i| {
                if (item == .none) continue;
                try out.append(arena, if (want_keys) Value{ .int = @intCast(i) } else item);
            },
            .none => {},
            else => return fail(sh, "{s}: expected a map or a list, got {s}\n", .{ callee, target.typeName() }),
        }
        return Value{ .list = try out.toOwnedSlice(arena) };
    }
    if (std.mem.eql(u8, callee, "empty")) return Value{ .boolean = (try eval(eval_context, sh, arena, argAt(args, 0))).isNull() };
    if (std.mem.eql(u8, callee, "int")) return Value{ .int = (try eval(eval_context, sh, arena, argAt(args, 0))).asInt() orelse 0 };
    if (std.mem.eql(u8, callee, "str")) {
        const result = try eval(eval_context, sh, arena, argAt(args, 0));
        return Value{ .string = try result.renderAlloc(arena) };
    }
    if (std.mem.eql(u8, callee, "abs")) {
        const number = (try eval(eval_context, sh, arena, argAt(args, 0))).asInt() orelse 0;
        // Wraps like bash: the minimum integer has no positive counterpart.
        return Value{ .int = if (number < 0) 0 -% number else number };
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

/// `list[i]` (negative counts from the end), `map["key"]` and `text[i]` (by
/// character). A missing element is null.
pub fn indexValue(sh: *Shell, arena: std.mem.Allocator, target: Value, key: Value) Error!Value {
    switch (target) {
        .none => return .none,
        .map => |entries| {
            const name = try renderValue(arena, key);
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.key, name)) return entry.value;
            }
            return .none;
        },
        .list => |items| {
            const index = position(key, items.len) orelse return fail(sh, "a list index must be an integer, got '{s}'\n", .{try renderValue(arena, key)});
            return if (index) |i| items[i] else .none;
        },
        .string => |text| {
            const count = param_ops.charCount(text);
            const index = position(key, count) orelse return fail(sh, "a string index must be an integer, got '{s}'\n", .{try renderValue(arena, key)});
            const i = index orelse return .none;
            return Value{ .string = text[param_ops.charOffset(text, i)..param_ops.charOffset(text, i + 1)] };
        },
        else => return fail(sh, "cannot index a value of type {s}\n", .{target.typeName()}),
    }
}

/// An integer index into `len` items: null when `key` is not an integer, and
/// an inner null when the index is out of range.
fn position(key: Value, len: usize) ??usize {
    const n = key.asInt() orelse return null;
    const index = if (n < 0) n + @as(i64, @intCast(len)) else n;
    if (index < 0 or index >= len) return @as(?usize, null);
    return @as(?usize, @intCast(index));
}

/// `slice` bounds: negatives count from the end, and both clamp to `len`.
fn clampRange(len: usize, start: i64, end: i64) struct { from: usize, to: usize } {
    const n: i64 = @intCast(len);
    const from = std.math.clamp(if (start < 0) start + n else start, 0, n);
    const to = std.math.clamp(if (end < 0) end + n else end, from, n);
    return .{ .from = @intCast(from), .to = @intCast(to) };
}

fn intArg(
    sh: *Shell,
    arena: std.mem.Allocator,
    args: []const *ast.Expr,
    index: usize,
    default: i64,
    eval_context: *anyopaque,
    eval: Evaluator,
) Error!i64 {
    if (index >= args.len) return default;
    const result = try eval(eval_context, sh, arena, args[index]);
    return result.asInt() orelse fail(sh, "expected an integer, got '{s}'\n", .{try renderValue(arena, result)});
}

fn renderValue(arena: std.mem.Allocator, v: Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => try v.renderAlloc(arena),
    };
}

fn fail(sh: *Shell, comptime fmt: []const u8, args: anytype) Error {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print("wsh: " ++ fmt, args) catch {};
    sys.writeStr(sh.default_err, w.buffered());
    return error.ExecutionFailed;
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
