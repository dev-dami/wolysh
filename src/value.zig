//! Runtime values for the wolysh scripting language.

const std = @import("std");

/// One key/value pair of an associative array.
pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    none,
    boolean: bool,
    int: i64,
    float: f64,
    /// Owned by the value arena that produced it.
    string: []const u8,
    /// An indexed array. A `none` item is an unset element, which is how
    /// `a=([0]=x [3]=y)` keeps bash's element count.
    list: []const Value,
    /// An associative array, in insertion order.
    map: []const Entry,

    pub fn isNull(self: Value) bool {
        return switch (self) {
            .none => true,
            .string => |s| s.len == 0,
            else => false,
        };
    }

    /// Truthiness: bool as-is, numbers non-zero, strings non-empty,
    /// lists and maps non-empty, null always false.
    pub fn truthy(self: Value) bool {
        return switch (self) {
            .none => false,
            .boolean => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0,
            .string => |s| s.len != 0,
            .list => |l| l.len != 0,
            .map => |m| m.len != 0,
        };
    }

    pub fn typeName(self: Value) []const u8 {
        return switch (self) {
            .none => "null",
            .boolean => "bool",
            .int => "int",
            .float => "float",
            .string => "string",
            .list => "list",
            .map => "map",
        };
    }

    /// Renders the value the way a shell would print it.
    pub fn render(self: Value, w: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .none => {},
            .boolean => |b| try w.writeAll(if (b) "true" else "false"),
            .int => |i| try w.print("{d}", .{i}),
            .float => |f| try w.print("{d}", .{f}),
            .string => |s| try w.writeAll(s),
            .list => |items| {
                var first = true;
                for (items) |item| {
                    if (item == .none) continue;
                    if (!first) try w.writeByte(' ');
                    first = false;
                    try item.render(w);
                }
            },
            .map => |entries| {
                for (entries, 0..) |entry, i| {
                    if (i != 0) try w.writeByte(' ');
                    try entry.value.render(w);
                }
            },
        }
    }

    /// Renders into a freshly allocated string in `allocator`.
    pub fn renderAlloc(self: Value, allocator: std.mem.Allocator) ![]u8 {
        var allocating = std.Io.Writer.Allocating.init(allocator);
        errdefer allocating.deinit();
        try self.render(&allocating.writer);
        return allocating.toOwnedSlice();
    }

    /// The number this value stands for in arithmetic and comparisons: ints
    /// and floats as they are, strings only when they are canonical decimal
    /// numerals (see `isCanonicalNumber`). The result is `.int` or `.float`.
    pub fn asNumber(self: Value) ?Value {
        return switch (self) {
            .int, .float => self,
            .string => |s| numberFromText(s),
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .float => |f| floatToInt(f),
            .boolean => |b| if (b) 1 else 0,
            .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
            else => null,
        };
    }
};

/// `-?(0|[1-9][0-9]*)(\.[0-9]+)?`: the only spelling of a number a string can
/// have. `007`, `1e3`, `inf` and ` 5` stay strings.
pub fn isCanonicalNumber(text: []const u8) bool {
    return canonicalLength(text) == text.len and text.len != 0;
}

/// A canonical numeral without a fractional part.
pub fn isCanonicalInteger(text: []const u8) bool {
    return isCanonicalNumber(text) and std.mem.indexOfScalar(u8, text, '.') == null;
}

fn canonicalLength(text: []const u8) usize {
    var i: usize = 0;
    if (i < text.len and text[i] == '-') i += 1;
    if (i >= text.len or !std.ascii.isDigit(text[i])) return 0;
    if (text[i] == '0') {
        i += 1;
    } else {
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    }
    if (i < text.len and text[i] == '.') {
        const fraction = i + 1;
        i = fraction;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        if (i == fraction) return 0;
    }
    return i;
}

fn numberFromText(text: []const u8) ?Value {
    if (!isCanonicalNumber(text)) return null;
    if (std.mem.indexOfScalar(u8, text, '.') == null) {
        if (std.fmt.parseInt(i64, text, 10)) |n| return Value{ .int = n } else |_| {}
    }
    const f = std.fmt.parseFloat(f64, text) catch return null;
    return Value{ .float = f };
}

/// Truncates toward zero; null when `f` has no `i64` counterpart (NaN or out
/// of range), where a plain `@intFromFloat` would be illegal behaviour.
fn floatToInt(f: f64) ?i64 {
    if (std.math.isNan(f)) return null;
    const limit: f64 = 9223372036854775808.0; // 2^63
    if (f >= limit or f < -limit) return null;
    return @intFromFloat(f);
}

test "truthiness" {
    try std.testing.expect(!(@as(Value, .none)).truthy());
    try std.testing.expect((Value{ .int = 1 }).truthy());
    try std.testing.expect(!(Value{ .int = 0 }).truthy());
    try std.testing.expect((Value{ .string = "x" }).truthy());
    try std.testing.expect(!(Value{ .string = "" }).truthy());
}

test "only canonical decimal numerals are numbers" {
    for ([_][]const u8{ "0", "-0", "7", "-12", "1.5", "1.10", "-0.25", "9223372036854775807" }) |text| {
        try std.testing.expect(isCanonicalNumber(text));
    }
    for ([_][]const u8{ "", "-", "007", "+1", ".5", "5.", "1e3", "inf", "nan", " 5", "5 ", "1_000", "0x10", "--1" }) |text| {
        try std.testing.expect(!isCanonicalNumber(text));
    }
    try std.testing.expect(isCanonicalInteger("-42"));
    try std.testing.expect(!isCanonicalInteger("4.2"));

    try std.testing.expectEqual(@as(i64, 42), (Value{ .string = "42" }).asNumber().?.int);
    try std.testing.expectEqual(@as(f64, 1.5), (Value{ .string = "1.5" }).asNumber().?.float);
    // Past the `i64` range a canonical integer is still a number.
    try std.testing.expect((Value{ .string = "99999999999999999999" }).asNumber().? == .float);
    try std.testing.expect((Value{ .string = "abc" }).asNumber() == null);
    try std.testing.expect((Value{ .boolean = true }).asNumber() == null);
    try std.testing.expect((@as(Value, .none)).asNumber() == null);
}

test "asInt refuses floats without an integer counterpart" {
    try std.testing.expectEqual(@as(?i64, 3), (Value{ .float = 3.9 }).asInt());
    try std.testing.expectEqual(@as(?i64, null), (Value{ .float = 1e300 }).asInt());
    try std.testing.expectEqual(@as(?i64, null), (Value{ .float = std.math.nan(f64) }).asInt());
}

test "render" {
    const a = std.testing.allocator;
    const v = Value{ .list = &.{ Value{ .int = 1 }, Value{ .string = "two" } } };
    const s = try v.renderAlloc(a);
    defer a.free(s);
    try std.testing.expectEqualStrings("1 two", s);

    const sparse = Value{ .list = &.{ Value{ .string = "x" }, .none, Value{ .string = "y" } } };
    const t = try sparse.renderAlloc(a);
    defer a.free(t);
    try std.testing.expectEqualStrings("x y", t);

    const m = Value{ .map = &.{ .{ .key = "k", .value = .{ .string = "v" } }, .{ .key = "j", .value = .{ .int = 2 } } } };
    const u = try m.renderAlloc(a);
    defer a.free(u);
    try std.testing.expectEqualStrings("v 2", u);
    try std.testing.expect(m.truthy());
}
