//! Shell quoting for output that must read back as the same words: `set -x`
//! traces, the `set` variable listing and `trap -p`. The rules follow bash so
//! the output matches what bash users expect to see and paste.

const std = @import("std");

/// A word as `set -x` and `set` print it: bare when nothing in it is special,
/// `$'...'` when it holds control characters, otherwise single-quoted.
pub fn appendWord(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    if (text.len == 0) return out.appendSlice(gpa, "''");
    if (needsAnsi(text)) return appendAnsi(out, gpa, text);
    if (hasMetas(text)) return appendSingle(out, gpa, text);
    try out.appendSlice(gpa, text);
}

/// `'text'`, with each embedded `'` written as `'\''`.
pub fn appendSingle(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    if (std.mem.eql(u8, text, "'")) return out.appendSlice(gpa, "\\'");
    try out.append(gpa, '\'');
    for (text) |c| {
        if (c == '\'') {
            try out.appendSlice(gpa, "'\\''");
        } else {
            try out.append(gpa, c);
        }
    }
    try out.append(gpa, '\'');
}

/// `"text"` with `"`, `\`, `$` and `` ` `` escaped; control characters use
/// `$'...'` instead. Used for list elements in the `set` listing.
pub fn appendDouble(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    if (needsAnsi(text)) return appendAnsi(out, gpa, text);
    try out.append(gpa, '"');
    for (text) |c| {
        if (c == '"' or c == '\\' or c == '$' or c == '`') try out.append(gpa, '\\');
        try out.append(gpa, c);
    }
    try out.append(gpa, '"');
}

fn appendAnsi(out: *std.ArrayList(u8), gpa: std.mem.Allocator, text: []const u8) !void {
    try out.appendSlice(gpa, "$'");
    for (text) |c| {
        const escape: ?[]const u8 = switch (c) {
            0x1b => "\\E",
            0x07 => "\\a",
            0x0b => "\\v",
            0x08 => "\\b",
            0x0c => "\\f",
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            '\\' => "\\\\",
            '\'' => "\\'",
            else => null,
        };
        if (escape) |text_escape| {
            try out.appendSlice(gpa, text_escape);
        } else if (isControl(c)) {
            var buf: [4]u8 = undefined;
            try out.appendSlice(gpa, std.fmt.bufPrint(&buf, "\\{o:0>3}", .{c}) catch unreachable);
        } else {
            try out.append(gpa, c);
        }
    }
    try out.append(gpa, '\'');
}

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

fn needsAnsi(text: []const u8) bool {
    for (text) |c| {
        if (isControl(c)) return true;
    }
    return false;
}

/// Characters the shell would treat specially if the word were re-read.
fn hasMetas(text: []const u8) bool {
    for (text, 0..) |c, i| {
        switch (c) {
            ' ', '\t', '\n', '\'', '"', '\\', '|', '&', ';', '(', ')', '<', '>' => return true,
            '!', '{', '}', '*', '[', '?', ']', '^', '$', '`' => return true,
            '~' => if (i == 0 or text[i - 1] == '=' or text[i - 1] == ':') return true,
            '#' => if (i == 0) return true,
            else => {},
        }
    }
    return false;
}

test "words are quoted only when they need it" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    const cases = [_][2][]const u8{
        .{ "plain", "plain" },
        .{ "", "''" },
        .{ "a b", "'a b'" },
        .{ "it's", "'it'\\''s'" },
        .{ "$x", "'$x'" },
        .{ "~", "'~'" },
        .{ "a~", "a~" },
        .{ "#x", "'#x'" },
        .{ "a#", "a#" },
        .{ "x=y", "x=y" },
        .{ "a\nb", "$'a\\nb'" },
        .{ "\x01", "$'\\001'" },
        .{ "é", "é" },
    };
    for (cases) |case| {
        out.clearRetainingCapacity();
        try appendWord(&out, a, case[0]);
        try std.testing.expectEqualStrings(case[1], out.items);
    }
}

test "single and double quoting" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);

    try appendSingle(&out, a, "echo it's");
    try std.testing.expectEqualStrings("'echo it'\\''s'", out.items);
    out.clearRetainingCapacity();
    try appendSingle(&out, a, "");
    try std.testing.expectEqualStrings("''", out.items);
    out.clearRetainingCapacity();
    try appendDouble(&out, a, "say \"$hi\"");
    try std.testing.expectEqualStrings("\"say \\\"\\$hi\\\"\"", out.items);
}
