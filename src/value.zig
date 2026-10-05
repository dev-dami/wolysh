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

    /// Numeric view of the value, if it has one.
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .int => |i| @floatFromInt(i),
            .float => |f| f,
            .boolean => |b| if (b) 1 else 0,
            .string => |s| std.fmt.parseFloat(f64, s) catch null,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .int => |i| i,
            .float => |f| @intFromFloat(f),
            .boolean => |b| if (b) 1 else 0,
            .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch null,
            else => null,
        };
    }
};

test "truthiness" {
    try std.testing.expect(!(@as(Value, .none)).truthy());
    try std.testing.expect((Value{ .int = 1 }).truthy());
    try std.testing.expect(!(Value{ .int = 0 }).truthy());
    try std.testing.expect((Value{ .string = "x" }).truthy());
    try std.testing.expect(!(Value{ .string = "" }).truthy());
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
