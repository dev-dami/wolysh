const std = @import("std");
const ast = @import("../ast.zig");
const value = @import("../value.zig");

const Value = value.Value;

pub const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{ DivisionByZero, NotANumber };

inline fn isString(v: Value) bool {
    return std.meta.activeTag(v) == .string;
}

pub fn isList(v: Value) bool {
    return std.meta.activeTag(v) == .list;
}

inline fn isBool(v: Value) bool {
    return std.meta.activeTag(v) == .boolean;
}

/// Numbers are typed ints and floats plus canonical numeral strings (see
/// `value.isCanonicalNumber`). `+` adds two numbers and otherwise
/// concatenates; `- * / %` refuse anything that is not a number.
pub fn binary(arena: std.mem.Allocator, op: ast.BinOp, lhs: Value, rhs: Value) Error!Value {
    switch (op) {
        .eq, .ne => {
            const equal = try valueEquals(arena, lhs, rhs);
            return Value{ .boolean = if (op == .eq) equal else !equal };
        },
        .lt, .le, .gt, .ge => {
            // An unordered pair (a NaN) satisfies none of the orderings.
            const order = try compare(arena, lhs, rhs) orelse return Value{ .boolean = false };
            return Value{ .boolean = switch (op) {
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                else => order >= 0,
            } };
        },
        .add => {
            if (lhs.asNumber()) |a| {
                if (rhs.asNumber()) |b| return try numeric(.add, a, b);
            }
            var out: std.Io.Writer.Allocating = .init(arena);
            errdefer out.deinit();
            try lhs.render(&out.writer);
            try rhs.render(&out.writer);
            return Value{ .string = try out.toOwnedSlice() };
        },
        .sub, .mul, .div, .mod => {
            const a = lhs.asNumber() orelse return error.NotANumber;
            const b = rhs.asNumber() orelse return error.NotANumber;
            return try numeric(op, a, b);
        },
    }
}

/// The operand `binary` rejected with `NotANumber`.
pub fn nonNumber(lhs: Value, rhs: Value) Value {
    return if (lhs.asNumber() == null) lhs else rhs;
}

/// Unary minus. Integers wrap like bash, so negating the minimum stays there.
pub fn negate(operand: Value) Error!Value {
    const number = operand.asNumber() orelse return error.NotANumber;
    return switch (number) {
        .int => |n| Value{ .int = 0 -% n },
        .float => |f| Value{ .float = -f },
        else => unreachable,
    };
}

fn toFloat(number: Value) f64 {
    return switch (number) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        else => unreachable,
    };
}

/// `a` and `b` are `.int` or `.float` (from `asNumber`).
fn numeric(op: ast.BinOp, a: Value, b: Value) Error!Value {
    if (a == .float or b == .float) {
        const x = toFloat(a);
        const y = toFloat(b);
        return Value{ .float = switch (op) {
            .add => x + y,
            .sub => x - y,
            .mul => x * y,
            .div => if (y == 0) return error.DivisionByZero else x / y,
            .mod => if (y == 0) return error.DivisionByZero else @mod(x, y),
            else => unreachable,
        } };
    }
    const x = a.int;
    const y = b.int;
    return Value{
        .int = switch (op) {
            .add => x +% y,
            .sub => x -% y,
            .mul => x *% y,
            // `minInt / -1` overflows (and traps on x86); bash wraps it.
            .div => if (y == 0) return error.DivisionByZero else if (y == -1) 0 -% x else @divTrunc(x, y),
            .mod => if (y == 0) return error.DivisionByZero else if (y == -1) 0 else @rem(x, y),
            else => unreachable,
        },
    };
}

/// Numeric order of two numbers; null when unordered (a NaN is involved).
fn numericOrder(a: Value, b: Value) ?i8 {
    if (a == .int and b == .int) return orderOf(std.math.order(a.int, b.int));
    const x = toFloat(a);
    const y = toFloat(b);
    if (std.math.isNan(x) or std.math.isNan(y)) return null;
    if (x < y) return -1;
    if (x > y) return 1;
    return 0;
}

fn orderOf(order: std.math.Order) i8 {
    return switch (order) {
        .lt => -1,
        .gt => 1,
        .eq => 0,
    };
}

fn rendered(arena: std.mem.Allocator, v: Value) Error![]const u8 {
    if (isString(v)) return v.string;
    return v.renderAlloc(arena);
}

/// Canonical integers have one spelling each, except that `-0` is `0`.
fn sameInteger(a: []const u8, b: []const u8) bool {
    const left = if (std.mem.eql(u8, a, "-0")) "0" else a;
    const right = if (std.mem.eql(u8, b, "-0")) "0" else b;
    return std.mem.eql(u8, left, right);
}

fn valueEquals(arena: std.mem.Allocator, lhs: Value, rhs: Value) Error!bool {
    if (isList(lhs) or isList(rhs)) {
        if (!isList(lhs) or !isList(rhs)) return false;
        if (lhs.list.len != rhs.list.len) return false;
        for (lhs.list, rhs.list) |left, right| {
            if (!try valueEquals(arena, left, right)) return false;
        }
        return true;
    }
    // Two strings are text: `"1.10" != "1.1"`. Only two canonical integers
    // compare as numbers, which differs from text equality just for `-0`.
    if (isString(lhs) and isString(rhs)) {
        if (value.isCanonicalInteger(lhs.string) and value.isCanonicalInteger(rhs.string)) {
            return sameInteger(lhs.string, rhs.string);
        }
        return std.mem.eql(u8, lhs.string, rhs.string);
    }
    if (lhs.asNumber()) |a| {
        if (rhs.asNumber()) |b| return (numericOrder(a, b) orelse return false) == 0;
    }
    if (isBool(lhs) or isBool(rhs)) return lhs.truthy() == rhs.truthy();
    return std.mem.eql(u8, try rendered(arena, lhs), try rendered(arena, rhs));
}

/// Numeric when both sides are numbers, otherwise byte-wise on the rendered
/// text.
fn compare(arena: std.mem.Allocator, lhs: Value, rhs: Value) Error!?i8 {
    if (lhs.asNumber()) |a| {
        if (rhs.asNumber()) |b| return numericOrder(a, b);
    }
    return orderOf(std.mem.order(u8, try rendered(arena, lhs), try rendered(arena, rhs)));
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

fn str(text: []const u8) Value {
    return .{ .string = text };
}

fn expectBool(expected: bool, op: ast.BinOp, lhs: Value, rhs: Value) !void {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const result = try binary(state.allocator(), op, lhs, rhs);
    try testing.expectEqual(expected, result.boolean);
}

test "strings compare as text unless both are canonical integers" {
    try expectBool(false, .eq, str("1.10"), str("1.1"));
    try expectBool(false, .eq, str("007"), str("7"));
    try expectBool(false, .eq, str("inf"), str("infinity"));
    try expectBool(true, .eq, str("nan"), str("nan"));
    try expectBool(true, .eq, str("-0"), str("0"));
    try expectBool(true, .ne, str("1.0"), str("1"));
    // A typed number against a numeric string compares numerically.
    try expectBool(true, .eq, Value{ .int = 1 }, str("1.0"));
    try expectBool(true, .eq, Value{ .float = 2.5 }, str("2.50"));
    try expectBool(false, .eq, Value{ .int = 7 }, str("007"));
    // Strings longer than any fixed buffer still compare in full.
    const long_a = "x" ** 100 ++ "a";
    const long_b = "x" ** 100 ++ "b";
    try expectBool(false, .eq, str(long_a), str(long_b));
    try expectBool(true, .lt, str(long_a), str(long_b));
}

test "ordering is numeric for numbers and byte-wise otherwise" {
    try expectBool(true, .lt, str("9"), str("10"));
    try expectBool(true, .lt, str("-1.5"), Value{ .int = 0 });
    // `09` is not a number, so it sorts as text before `1`.
    try expectBool(false, .gt, str("09"), str("1"));
    try expectBool(true, .gt, str("b"), str("a"));
    try expectBool(true, .ge, Value{ .int = 3 }, Value{ .float = 3.0 });
}

test "plus adds numbers and concatenates everything else" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try testing.expectEqual(@as(i64, 3), (try binary(arena, .add, str("1"), str("2"))).int);
    try testing.expectEqualStrings("1.0", (try binary(arena, .add, str("1"), str(".0"))).string);
    try testing.expectEqualStrings("0071", (try binary(arena, .add, str("007"), str("1"))).string);
    try testing.expectEqual(@as(f64, 1.5), (try binary(arena, .add, Value{ .int = 1 }, str("0.5"))).float);
}

test "arithmetic refuses non-numbers and division by zero" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try testing.expectError(error.NotANumber, binary(arena, .sub, str("abc"), Value{ .int = 1 }));
    try testing.expectError(error.NotANumber, binary(arena, .mul, Value{ .int = 2 }, str("007")));
    try testing.expectError(error.NotANumber, binary(arena, .div, .none, Value{ .int = 2 }));
    try testing.expectEqualStrings("abc", nonNumber(str("abc"), Value{ .int = 1 }).string);
    try testing.expectError(error.DivisionByZero, binary(arena, .div, Value{ .int = 10 }, Value{ .int = 0 }));
    try testing.expectError(error.DivisionByZero, binary(arena, .mod, Value{ .int = 5 }, Value{ .int = 0 }));
    try testing.expectError(error.DivisionByZero, binary(arena, .div, Value{ .float = 1.5 }, Value{ .int = 0 }));
    try testing.expectError(error.NotANumber, negate(str("x")));
}

test "integer overflow wraps like bash" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const min = Value{ .int = std.math.minInt(i64) };
    const minus_one = Value{ .int = -1 };
    try testing.expectEqual(std.math.minInt(i64), (try binary(arena, .div, min, minus_one)).int);
    try testing.expectEqual(@as(i64, 0), (try binary(arena, .mod, min, minus_one)).int);
    try testing.expectEqual(std.math.minInt(i64), (try negate(min)).int);
    try testing.expectEqual(@as(i64, -2), (try binary(arena, .mod, Value{ .int = -7 }, Value{ .int = 5 })).int);
    try testing.expectEqual(@as(i64, -1), (try binary(arena, .div, Value{ .int = -7 }, Value{ .int = 5 })).int);
}
