//! The string operations behind `${...}`: pattern removal and replacement,
//! case conversion, character-based substrings, and the quoting used by
//! `${name@Q}` and `declare -p`.
//!
//! Patterns arrive escape-marked: a backslash makes the next byte literal,
//! which is how a quoted `"*"` in `${x#"*"}` matches only a star.

const std = @import("std");
const glob = @import("glob.zig");

/// A compiled pattern. `glob.matchSegment` keeps `*` and `?` from crossing a
/// `/`, which parameter patterns must do, so `/` is mapped to NUL in both the
/// pattern and the text (NUL never occurs in a shell string).
const Matcher = struct {
    pattern: []const u8,
    /// The unescaped text when the pattern has no metacharacters.
    literal: ?[]const u8,

    fn init(arena: std.mem.Allocator, pattern: []const u8) !Matcher {
        if (!glob.hasMeta(pattern)) return .{ .pattern = pattern, .literal = try glob.unescape(arena, pattern) };
        return .{ .pattern = try mapSlashes(arena, pattern), .literal = null };
    }

    /// The text to match against: mapped like the pattern unless it is a
    /// literal.
    fn subject(self: Matcher, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        return if (self.literal != null) text else mapSlashes(arena, text);
    }

    /// `text` must come from `subject`.
    fn matches(self: Matcher, text: []const u8) bool {
        if (self.literal) |lit| return std.mem.eql(u8, lit, text);
        return glob.matchSegment(self.pattern, text);
    }
};

fn mapSlashes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '/') == null) return text;
    const out = try arena.dupe(u8, text);
    for (out) |*c| {
        if (c.* == '/') c.* = 0;
    }
    return out;
}

/// True at byte offsets that start a UTF-8 character (or end the text).
fn boundary(text: []const u8, i: usize) bool {
    return i >= text.len or (text[i] & 0xC0) != 0x80;
}

/// `${x#pat}` (shortest) and `${x##pat}` (longest).
pub fn removePrefix(arena: std.mem.Allocator, text: []const u8, pattern: []const u8, longest: bool) ![]const u8 {
    const m = try Matcher.init(arena, pattern);
    if (m.literal) |lit| return if (std.mem.startsWith(u8, text, lit)) text[lit.len..] else text;
    const t = try mapSlashes(arena, text);
    var n: usize = 0;
    while (n <= t.len) : (n += 1) {
        const i = if (longest) t.len - n else n;
        if (boundary(t, i) and m.matches(t[0..i])) return text[i..];
    }
    return text;
}

/// `${x%pat}` (shortest) and `${x%%pat}` (longest).
pub fn removeSuffix(arena: std.mem.Allocator, text: []const u8, pattern: []const u8, longest: bool) ![]const u8 {
    const m = try Matcher.init(arena, pattern);
    if (m.literal) |lit| return if (std.mem.endsWith(u8, text, lit)) text[0 .. text.len - lit.len] else text;
    const t = try mapSlashes(arena, text);
    var n: usize = 0;
    while (n <= t.len) : (n += 1) {
        const i = if (longest) n else t.len - n;
        if (boundary(t, i) and m.matches(t[i..])) return text[0..i];
    }
    return text;
}

pub const ReplaceMode = enum { first, all, prefix, suffix };

/// `${x/pat/rep}` and its `//`, `/#` and `/%` forms. `replacement` is
/// escape-marked like a pattern: an unescaped `&` stands for the matched text
/// (bash's `patsub_replacement`).
pub fn replace(
    arena: std.mem.Allocator,
    text: []const u8,
    pattern: []const u8,
    replacement: []const u8,
    mode: ReplaceMode,
) ![]const u8 {
    const m = try Matcher.init(arena, pattern);
    const t = try m.subject(arena, text);
    var out: std.ArrayList(u8) = .empty;
    switch (mode) {
        .prefix => {
            var end = t.len + 1;
            while (end > 0) {
                end -= 1;
                if (boundary(t, end) and m.matches(t[0..end])) {
                    try appendReplacement(arena, &out, replacement, text[0..end]);
                    try out.appendSlice(arena, text[end..]);
                    return out.toOwnedSlice(arena);
                }
            }
            return text;
        },
        .suffix => {
            var start: usize = 0;
            while (start <= t.len) : (start += 1) {
                if (boundary(t, start) and m.matches(t[start..])) {
                    try out.appendSlice(arena, text[0..start]);
                    try appendReplacement(arena, &out, replacement, text[start..]);
                    return out.toOwnedSlice(arena);
                }
            }
            return text;
        },
        .first, .all => {
            if (pattern.len == 0) return text;
            var last: usize = 0;
            var i: usize = 0;
            while (i < t.len) {
                if (!boundary(t, i)) {
                    i += 1;
                    continue;
                }
                const end = longestMatch(m, t, i) orelse {
                    i += 1;
                    continue;
                };
                try out.appendSlice(arena, text[last..i]);
                try appendReplacement(arena, &out, replacement, text[i..end]);
                last = end;
                i = end;
                if (mode == .first) break;
            }
            if (last == 0 and out.items.len == 0) return text;
            try out.appendSlice(arena, text[last..]);
            return out.toOwnedSlice(arena);
        },
    }
}

/// The end of the longest non-empty match starting at `start`.
fn longestMatch(m: Matcher, t: []const u8, start: usize) ?usize {
    if (m.literal) |lit| {
        if (lit.len == 0) return null;
        return if (std.mem.startsWith(u8, t[start..], lit)) start + lit.len else null;
    }
    var end = t.len;
    while (end > start) : (end -= 1) {
        if (boundary(t, end) and m.matches(t[start..end])) return end;
    }
    return null;
}

fn appendReplacement(arena: std.mem.Allocator, out: *std.ArrayList(u8), replacement: []const u8, matched: []const u8) !void {
    var i: usize = 0;
    while (i < replacement.len) : (i += 1) {
        const c = replacement[i];
        if (c == '\\' and i + 1 < replacement.len) {
            i += 1;
            try out.append(arena, replacement[i]);
        } else if (c == '&') {
            try out.appendSlice(arena, matched);
        } else {
            try out.append(arena, c);
        }
    }
}

/// `${x^}`, `${x^^}`, `${x,}` and `${x,,}`. With a pattern, only characters
/// that match it change; `first` limits the change to the first character.
pub fn convertCase(arena: std.mem.Allocator, text: []const u8, pattern: []const u8, upper: bool, first: bool) ![]const u8 {
    const m: ?Matcher = if (pattern.len == 0) null else try Matcher.init(arena, pattern);
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const char = text[i..end];
        var convert = !first or i == 0;
        if (convert) {
            if (m) |matcher| convert = matcher.matches(try matcher.subject(arena, char));
        }
        if (convert) try appendConverted(arena, &out, char, upper) else try out.appendSlice(arena, char);
        i = end;
    }
    return out.toOwnedSlice(arena);
}

/// Upper- or lower-cases every character.
pub fn caseAll(arena: std.mem.Allocator, text: []const u8, upper: bool) ![]const u8 {
    return convertCase(arena, text, "", upper, false);
}

/// `${x@u}`: the first character upper-cased.
pub fn capitalize(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    return convertCase(arena, text, "", true, true);
}

fn appendConverted(arena: std.mem.Allocator, out: *std.ArrayList(u8), char: []const u8, upper: bool) !void {
    const cp = std.unicode.utf8Decode(char) catch return out.appendSlice(arena, char);
    const mapped = if (upper) toUpper(cp) else toLower(cp);
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(mapped, &buf) catch return out.appendSlice(arena, char);
    try out.appendSlice(arena, buf[0..n]);
}

/// Case mapping for ASCII, Latin-1, Latin Extended-A, Greek and Cyrillic;
/// other scripts are left unchanged.
fn toUpper(cp: u21) u21 {
    return switch (cp) {
        'a'...'z' => cp - 32,
        0xE0...0xF6, 0xF8...0xFE => cp - 0x20,
        0xFF => 0x178,
        0x131 => 'I',
        0x17F => 'S',
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp % 2 == 1) cp - 1 else cp,
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 0) cp - 1 else cp,
        0x3C2 => 0x3A3,
        0x3B1...0x3C1, 0x3C3...0x3C9 => cp - 0x20,
        0x430...0x44F => cp - 0x20,
        0x450...0x45F => cp - 0x50,
        else => cp,
    };
}

fn toLower(cp: u21) u21 {
    return switch (cp) {
        'A'...'Z' => cp + 32,
        0xC0...0xD6, 0xD8...0xDE => cp + 0x20,
        0x178 => 0xFF,
        0x130 => 'i',
        0x100...0x12F, 0x132...0x137, 0x14A...0x177 => if (cp % 2 == 0) cp + 1 else cp,
        0x139...0x148, 0x179...0x17E => if (cp % 2 == 1) cp + 1 else cp,
        0x391...0x3A1, 0x3A3...0x3A9 => cp + 0x20,
        0x410...0x42F => cp + 0x20,
        0x400...0x40F => cp + 0x50,
        else => cp,
    };
}

/// Number of characters, counting each byte of invalid UTF-8 as one.
pub fn charCount(text: []const u8) usize {
    var n: usize = 0;
    for (text, 0..) |_, i| {
        if (boundary(text, i)) n += 1;
    }
    return n;
}

/// Byte offset of character number `index` (clamped to the end).
pub fn charOffset(text: []const u8, index: usize) usize {
    var seen: usize = 0;
    for (text, 0..) |_, i| {
        if (!boundary(text, i)) continue;
        if (seen == index) return i;
        seen += 1;
    }
    return text.len;
}

// --- quoting ----------------------------------------------------------------

/// True when the text needs `$'...'` quoting to survive a round trip: it has
/// control characters or bytes that are not valid UTF-8.
pub fn needsAnsiC(text: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(text)) return true;
    for (text) |c| {
        if (c < 0x20 or c == 0x7F) return true;
    }
    return false;
}

/// `$'...'` quoting with C escapes, the way bash prints such values.
pub fn quoteAnsiC(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "$'");
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c >= 0x80) {
            const len = std.unicode.utf8ByteSequenceLength(c) catch 0;
            if (len > 0 and i + len <= text.len and std.unicode.utf8ValidateSlice(text[i .. i + len])) {
                try out.appendSlice(arena, text[i .. i + len]);
                i += len;
                continue;
            }
        }
        switch (c) {
            0x07 => try out.appendSlice(arena, "\\a"),
            0x08 => try out.appendSlice(arena, "\\b"),
            0x1B => try out.appendSlice(arena, "\\E"),
            0x0C => try out.appendSlice(arena, "\\f"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            0x0B => try out.appendSlice(arena, "\\v"),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\'' => try out.appendSlice(arena, "\\'"),
            else => {
                if (c < 0x20 or c >= 0x7F) {
                    var buf: [4]u8 = undefined;
                    try out.appendSlice(arena, std.fmt.bufPrint(&buf, "\\{o:0>3}", .{c}) catch unreachable);
                } else {
                    try out.append(arena, c);
                }
            },
        }
        i += 1;
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// `${x@Q}`: single quotes, or `$'...'` when the text has control bytes.
pub fn quoteSingle(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (needsAnsiC(text)) return quoteAnsiC(arena, text);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |c| {
        if (c == '\'') try out.appendSlice(arena, "'\\''") else try out.append(arena, c);
    }
    try out.append(arena, '\'');
    return out.toOwnedSlice(arena);
}

/// Double quotes with `"`, `\`, `$` and backquote escaped, as `declare -p`
/// prints values; `$'...'` when the text has control bytes.
pub fn quoteDouble(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (needsAnsiC(text)) return quoteAnsiC(arena, text);
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '"');
    for (text) |c| {
        if (c == '"' or c == '\\' or c == '$' or c == '`') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
    return out.toOwnedSlice(arena);
}

/// An associative-array key as `declare -p` prints it: bare when it holds no
/// shell metacharacters, double-quoted otherwise.
pub fn quoteKey(arena: std.mem.Allocator, key: []const u8) ![]const u8 {
    if (needsAnsiC(key)) return quoteAnsiC(arena, key);
    var plain = key.len != 0 and key[0] != '~' and key[0] != '#';
    for (key) |c| {
        if (std.mem.indexOfScalar(u8, " \t'\"\\|&;()<>!{}*[?]^$`@", c) != null) plain = false;
    }
    return if (plain) key else quoteDouble(arena, key);
}

/// `${x@E}`: the backslash escapes of `$'...'` expanded.
pub fn expandEscapes(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c != '\\' or i + 1 >= text.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const e = text[i + 1];
        i += 2;
        switch (e) {
            'a' => try out.append(arena, 0x07),
            'b' => try out.append(arena, 0x08),
            'e', 'E' => try out.append(arena, 0x1B),
            'f' => try out.append(arena, 0x0C),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            't' => try out.append(arena, '\t'),
            'v' => try out.append(arena, 0x0B),
            '\\', '\'', '"', '?' => try out.append(arena, e),
            '0'...'7' => {
                var n: u32 = e - '0';
                var digits: usize = 1;
                while (digits < 3 and i < text.len and text[i] >= '0' and text[i] <= '7') : (digits += 1) {
                    n = n * 8 + (text[i] - '0');
                    i += 1;
                }
                try out.append(arena, @truncate(n));
            },
            'x', 'u', 'U' => {
                const max: usize = switch (e) {
                    'x' => 2,
                    'u' => 4,
                    else => 8,
                };
                var n: u32 = 0;
                var digits: usize = 0;
                while (digits < max and i < text.len) : (digits += 1) {
                    const d = std.fmt.charToDigit(text[i], 16) catch break;
                    n = n * 16 + d;
                    i += 1;
                }
                if (digits == 0) {
                    try out.append(arena, '\\');
                    try out.append(arena, e);
                } else if (e == 'x') {
                    try out.append(arena, @truncate(n));
                } else {
                    var buf: [4]u8 = undefined;
                    const cp: u21 = if (n > 0x10FFFF) 0xFFFD else @intCast(n);
                    const len = std.unicode.utf8Encode(cp, &buf) catch std.unicode.utf8Encode(0xFFFD, &buf) catch unreachable;
                    try out.appendSlice(arena, buf[0..len]);
                }
            },
            'c' => {
                if (i < text.len) {
                    try out.append(arena, text[i] & 0x1F);
                    i += 1;
                } else {
                    try out.appendSlice(arena, "\\c");
                }
            },
            else => {
                try out.append(arena, '\\');
                try out.append(arena, e);
            },
        }
    }
    return out.toOwnedSlice(arena);
}

const testing = std.testing;

test "prefix and suffix removal" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    const path = "/a/b/c.tar.gz";
    try testing.expectEqualStrings("/a/b", try removeSuffix(a, path, "/*", false));
    try testing.expectEqualStrings("/a/b/c", try removeSuffix(a, path, ".*", true));
    try testing.expectEqualStrings("a/b/c.tar.gz", try removePrefix(a, path, "*/", false));
    try testing.expectEqualStrings("c.tar.gz", try removePrefix(a, path, "*/", true));
    try testing.expectEqualStrings(path, try removePrefix(a, path, "\\*", false));
    try testing.expectEqualStrings("llo", try removePrefix(a, "hello", "h?", false));
    try testing.expectEqualStrings("héllo", try removePrefix(a, "héllo", "x*", true));
}

test "replacement" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("aXXbXc", try replace(a, "aXbXc", "X", "&&", .first));
    try testing.expectEqualStrings("a-b-c", try replace(a, "aXbXc", "X", "-", .all));
    try testing.expectEqualStrings("a&b&c", try replace(a, "aXbXc", "X", "\\&", .all));
    try testing.expectEqualStrings("Pabc", try replace(a, "abc", "", "P", .prefix));
    try testing.expectEqualStrings("abcS", try replace(a, "abc", "", "S", .suffix));
    try testing.expectEqualStrings("Z", try replace(a, "aaa", "a*", "Z", .first));
    try testing.expectEqualStrings("-b-", try replace(a, "abc", "[ac]", "-", .all));
    try testing.expectEqualStrings("a_b_c", try replace(a, "a/b/c", "\\/", "_", .all));
}

test "case conversion and characters" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("HÉLLO", try caseAll(a, "héllo", true));
    try testing.expectEqualStrings("heLLO", try convertCase(a, "hello", "[lo]", true, false));
    try testing.expectEqualStrings("Hello", try capitalize(a, "hello"));
    try testing.expectEqual(@as(usize, 5), charCount("héllo"));
    try testing.expectEqual(@as(usize, 3), charOffset("héllo", 2));
}

test "quoting" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const a = state.allocator();
    try testing.expectEqualStrings("'it'\\''s'", try quoteSingle(a, "it's"));
    try testing.expectEqualStrings("''", try quoteSingle(a, ""));
    try testing.expectEqualStrings("\"q\\\"r \\$z\"", try quoteDouble(a, "q\"r $z"));
    try testing.expectEqualStrings("$'a\\nb\\001\\E'", try quoteAnsiC(a, "a\nb\x01\x1b"));
    try testing.expectEqualStrings("a.b", try quoteKey(a, "a.b"));
    try testing.expectEqualStrings("\"a b\"", try quoteKey(a, "a b"));
    try testing.expectEqualStrings("a\nbA\xc3\xa9A\x01", try expandEscapes(a, "a\\nb\\x41\\u00e9\\101\\cA"));
}
