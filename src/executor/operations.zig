const std = @import("std");
const ast = @import("../ast.zig");
const value = @import("../value.zig");

const Value = value.Value;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error;

var compare_buf_a: [64]u8 = undefined;
var compare_buf_b: [64]u8 = undefined;

inline fn isString(v: Value) bool {
    return std.meta.activeTag(v) == .string;
}

pub fn isList(v: Value) bool {
    return std.meta.activeTag(v) == .list;
}

inline fn isBool(v: Value) bool {
    return std.meta.activeTag(v) == .boolean;
}

inline fn isFloat(v: Value) bool {
    return std.meta.activeTag(v) == .float;
}

pub fn binary(arena: std.mem.Allocator, op: ast.BinOp, lhs: Value, rhs: Value) Error!Value {
    switch (op) {
        .eq, .ne => {
            const equal = valueEquals(lhs, rhs);
            return Value{ .boolean = if (op == .eq) equal else !equal };
        },
        .lt, .le, .gt, .ge => {
            const order = compare(lhs, rhs);
            return Value{ .boolean = switch (op) {
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                else => order >= 0,
            } };
        },
        .add => {
            if (toNumber(lhs)) |a| {
                if (toNumber(rhs)) |b| return try numeric(.add, a, b);
            }
            var out: std.Io.Writer.Allocating = .init(arena);
            errdefer out.deinit();
            try lhs.render(&out.writer);
            try rhs.render(&out.writer);
            return Value{ .string = try out.toOwnedSlice() };
        },
        .sub, .mul, .div, .mod => return try numeric(op, lhs, rhs),
    }
}

fn numeric(op: ast.BinOp, lhs: Value, rhs: Value) Error!Value {
    if (isFloat(lhs) or isFloat(rhs)) {
        const a = lhs.asFloat() orelse 0;
        const b = rhs.asFloat() orelse 0;
        return Value{ .float = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) 0 else a / b,
            .mod => if (b == 0) 0 else @mod(a, b),
            else => 0,
        } };
    }
    const a = lhs.asInt() orelse 0;
    const b = rhs.asInt() orelse 0;
    return Value{ .int = switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div => if (b == 0) 0 else @divTrunc(a, b),
        .mod => if (b == 0) 0 else @rem(a, b),
        else => 0,
    } };
}

fn toNumber(v: Value) ?Value {
    return switch (v) {
        .int, .float => v,
        .string => |s| blk: {
            const text = std.mem.trim(u8, s, " \t");
            if (std.fmt.parseInt(i64, text, 10)) |n| {
                break :blk Value{ .int = n };
            } else |_| {}
            if (std.fmt.parseFloat(f64, text)) |f| {
                break :blk Value{ .float = f };
            } else |_| {}
            break :blk null;
        },
        else => null,
    };
}

fn numericOf(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null,
        else => null,
    };
}

fn renderInto(v: Value, buf: []u8) []const u8 {
    if (isString(v)) return v.string[0..@min(v.string.len, buf.len)];
    var writer = std.Io.Writer.fixed(buf);
    v.render(&writer) catch return buf[0..0];
    return writer.buffered();
}

fn valueEquals(lhs: Value, rhs: Value) bool {
    if (isList(lhs) or isList(rhs)) {
        if (!isList(lhs) or !isList(rhs)) return false;
        if (lhs.list.len != rhs.list.len) return false;
        for (lhs.list, rhs.list) |left, right| {
            if (!valueEquals(left, right)) return false;
        }
        return true;
    }
    if (numericOf(lhs)) |a| {
        if (numericOf(rhs)) |b| return a == b;
    }
    if (isBool(lhs) or isBool(rhs)) return lhs.truthy() == rhs.truthy();
    const a = renderInto(lhs, &compare_buf_a);
    const b = renderInto(rhs, &compare_buf_b);
    return std.mem.eql(u8, a, b);
}

fn compare(lhs: Value, rhs: Value) i8 {
    if (numericOf(lhs)) |a| {
        if (numericOf(rhs)) |b| {
            if (a < b) return -1;
            if (a > b) return 1;
            return 0;
        }
    }
    const a = renderInto(lhs, &compare_buf_a);
    const b = renderInto(rhs, &compare_buf_b);
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .gt => 1,
        .eq => 0,
    };
}
