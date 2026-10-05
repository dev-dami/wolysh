//! Text scanning for bash compound assignments, `name=(one "two three")`.
//! The parser uses it to find where the list ends; the executor uses it to
//! split the list into element words, which keep their quotes for the
//! expander.

const std = @import("std");

/// Prefixes an unexpanded `NAME=(...)` argument handed to `declare`, which a
/// quoted `"NAME=(...)"` (a plain string in bash) can never start with.
pub const marker: u8 = 0;

/// Index of the `(` when `word` starts a compound assignment: an identifier,
/// `=` or `+=`, then `(`.
pub fn openParen(word: []const u8) ?usize {
    if (word.len == 0 or !(std.ascii.isAlphabetic(word[0]) or word[0] == '_')) return null;
    var i: usize = 1;
    while (i < word.len and (std.ascii.isAlphanumeric(word[i]) or word[i] == '_')) i += 1;
    if (i < word.len and word[i] == '+') i += 1;
    if (i + 1 >= word.len or word[i] != '=' or word[i + 1] != '(') return null;
    return i + 1;
}

/// Index of the `)` matching the `(` at `open`. Quotes, escapes, comments and
/// nested `$(...)`, `${...}` and backquotes are skipped.
pub fn findClose(src: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '\\' => i += 2,
            '\'' => i = skipPast(src, i + 1, '\'') orelse return null,
            '"' => i = skipDouble(src, i + 1) orelse return null,
            '`' => i = skipBackquote(src, i + 1) orelse return null,
            '$' => {
                if (i + 1 < src.len and (src[i + 1] == '(' or src[i + 1] == '{')) {
                    i = skipGroup(src, i + 1) orelse return null;
                } else {
                    i += 1;
                }
            },
            '#' => {
                if (i > open and !isBreak(src[i - 1])) {
                    i += 1;
                    continue;
                }
                i = std.mem.indexOfScalarPos(u8, src, i, '\n') orelse src.len;
            },
            '(' => {
                depth += 1;
                i += 1;
            },
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

/// Splits the text between the parentheses into element words.
pub fn splitElements(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (isSpace(c)) {
            i += 1;
            continue;
        }
        if (c == '#') {
            i = std.mem.indexOfScalarPos(u8, body, i, '\n') orelse body.len;
            continue;
        }
        const start = i;
        while (i < body.len and !isSpace(body[i])) {
            switch (body[i]) {
                '\\' => i = @min(i + 2, body.len),
                '\'' => i = skipPast(body, i + 1, '\'') orelse body.len,
                '"' => i = skipDouble(body, i + 1) orelse body.len,
                '`' => i = skipBackquote(body, i + 1) orelse body.len,
                '$' => {
                    if (i + 1 < body.len and (body[i + 1] == '(' or body[i + 1] == '{')) {
                        i = skipGroup(body, i + 1) orelse body.len;
                    } else {
                        i += 1;
                    }
                },
                '[' => i = if (i == start) (closeBracket(body, i) orelse i) + 1 else i + 1,
                else => i += 1,
            }
        }
        try out.append(arena, body[start..i]);
    }
    return out.toOwnedSlice(arena);
}

pub const Keyed = struct {
    key: []const u8,
    value: []const u8,
    append: bool,
};

/// `[key]=value` or `[key]+=value`: an element with an explicit subscript.
pub fn keyed(word: []const u8) ?Keyed {
    if (word.len == 0 or word[0] != '[') return null;
    const close = closeBracket(word, 0) orelse return null;
    var i = close + 1;
    var append = false;
    if (i < word.len and word[i] == '+') {
        append = true;
        i += 1;
    }
    if (i >= word.len or word[i] != '=') return null;
    return .{ .key = word[1..close], .value = word[i + 1 ..], .append = append };
}

/// Index of the `]` closing the `[` at `open`, skipping quotes and nested
/// brackets.
pub fn closeBracket(text: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < text.len) {
        switch (text[i]) {
            '\\' => i += 2,
            '\'' => i = skipPast(text, i + 1, '\'') orelse return null,
            '"' => i = skipDouble(text, i + 1) orelse return null,
            '$' => {
                if (i + 1 < text.len and (text[i + 1] == '(' or text[i + 1] == '{')) {
                    i = skipGroup(text, i + 1) orelse return null;
                } else {
                    i += 1;
                }
            },
            '[' => {
                depth += 1;
                i += 1;
            },
            ']' => {
                depth -= 1;
                if (depth == 0) return i;
                i += 1;
            },
            else => i += 1,
        }
    }
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

/// A `#` starts a comment only at the start of a word.
fn isBreak(c: u8) bool {
    return isSpace(c) or c == '(';
}

/// The index just past the next `quote` at or after `from`.
fn skipPast(s: []const u8, from: usize, quote: u8) ?usize {
    const end = std.mem.indexOfScalarPos(u8, s, from, quote) orelse return null;
    return end + 1;
}

fn skipDouble(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) {
        switch (s[i]) {
            '\\' => i += 2,
            '"' => return i + 1,
            '`' => i = skipBackquote(s, i + 1) orelse return null,
            '$' => {
                if (i + 1 < s.len and (s[i + 1] == '(' or s[i + 1] == '{')) {
                    i = skipGroup(s, i + 1) orelse return null;
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
    return null;
}

fn skipBackquote(s: []const u8, from: usize) ?usize {
    var i = from;
    while (i < s.len) {
        if (s[i] == '\\') {
            i += 2;
            continue;
        }
        if (s[i] == '`') return i + 1;
        i += 1;
    }
    return null;
}

/// The index past the `)` or `}` closing the group opened at `open`.
fn skipGroup(s: []const u8, open: usize) ?usize {
    const open_char = s[open];
    const close_char: u8 = if (open_char == '(') ')' else '}';
    var depth: usize = 0;
    var i = open;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\'') {
            i = skipPast(s, i + 1, '\'') orelse return null;
            continue;
        }
        if (c == '"') {
            i = skipDouble(s, i + 1) orelse return null;
            continue;
        }
        if (c == open_char) depth += 1;
        if (c == close_char) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
        i += 1;
    }
    return null;
}

const testing = std.testing;

test "compound assignment openers" {
    try testing.expectEqual(@as(?usize, 2), openParen("a=(x)"));
    try testing.expectEqual(@as(?usize, 4), openParen("ab+=(x"));
    try testing.expectEqual(@as(?usize, null), openParen("a=x"));
    try testing.expectEqual(@as(?usize, null), openParen("=(x)"));
    try testing.expectEqual(@as(?usize, null), openParen("a[1]=(x)"));
}

test "find the closing parenthesis of a compound assignment" {
    const src = "a=(x \"y)\" 'z)' $(echo ')') # note )\n w) tail";
    const close = findClose(src, 2).?;
    try testing.expectEqualStrings(" tail", src[close + 1 ..]);
    try testing.expectEqual(@as(?usize, null), findClose("a=(x y", 2));
}

test "split compound elements" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const words = try splitElements(state.allocator(), " x \"y z\" [3]=w\n# skip me\n['a b']=c $(echo 1 2) ");
    try testing.expectEqual(@as(usize, 5), words.len);
    try testing.expectEqualStrings("\"y z\"", words[1]);
    try testing.expectEqualStrings("['a b']=c", words[3]);
    try testing.expectEqualStrings("$(echo 1 2)", words[4]);

    const k = keyed("['a b']+=c").?;
    try testing.expectEqualStrings("'a b'", k.key);
    try testing.expectEqualStrings("c", k.value);
    try testing.expect(k.append);
    try testing.expect(keyed("[x]") == null);
}
