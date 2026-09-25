//! Word expansion: quote removal, escapes, `$` interpolation, `~`, command
//! substitution, field splitting and globbing.
//!
//! The scanner walks the raw word text (quotes included, as the lexer left it)
//! and builds fields directly. Text that came from a *quoted* context is written
//! out backslash-escaped, so the later splitting and globbing stages treat it as
//! literal without needing a second quoting pass: `\*` reaches the glob matcher
//! as "a literal star", and `"$x"` never splits.

const std = @import("std");
const shell = @import("shell.zig");
const glob = @import("glob.zig");
const value = @import("value.zig");

pub const Error = error{
    UnterminatedSubstitution,
    SubstitutionFailed,
    UnsupportedArithmetic,
} || std.mem.Allocator.Error;

const Mode = enum {
    /// A word in a command position: split on whitespace, then glob.
    command_word,
    /// A single value: no splitting, no globbing.
    literal,
};

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Expands a command word into zero or more fields.
pub fn expandWord(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    word: []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    var ex = Expander{ .sh = sh, .arena = arena, .out = out, .mode = .command_word };
    try ex.scan(word);
    try ex.flush();
}

/// Expands a word to exactly one value: no splitting, no globbing, no escape
/// markers left behind.
pub fn expandLiteral(sh: *shell.Shell, arena: std.mem.Allocator, word: []const u8) Error![]const u8 {
    var ex = Expander{ .sh = sh, .arena = arena, .mode = .literal };
    try ex.scan(word);
    return arena.dupe(u8, ex.buf.items);
}

/// Expands a whole command's words into a flat argument list.
///
/// Arguments differ from the command name in one way: a bare identifier that
/// names a shell variable is a reference to it, so `for f in *.rs { print f }`
/// prints the file. Quote it (`print "f"`) to get the literal text instead.
pub fn expandCommand(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    words: []const []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    for (words, 0..) |word, index| {
        if (index == 0) {
            try expandWord(sh, arena, word, out);
        } else {
            try expandArgument(sh, arena, word, out);
        }
    }
}

fn expandArgument(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    word: []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    var ex = Expander{ .sh = sh, .arena = arena, .out = out, .mode = .command_word, .bare_vars = true };
    try ex.scan(word);
    try ex.flush();
}

/// True when the word is exactly one unquoted identifier.
fn bareIdentifier(word: []const u8) ?[]const u8 {
    if (word.len == 0) return null;
    if (!isIdentStart(word[0])) return null;
    for (word[1..]) |c| {
        if (!isIdentChar(c)) return null;
    }
    return word;
}

pub const Expander = struct {
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    out: ?*std.ArrayList([]const u8) = null,
    buf: std.ArrayList(u8) = .empty,
    active: bool = false,
    mode: Mode,
    /// Set only for arguments in command position, where `print file` means
    /// "print the value of `file`".
    bare_vars: bool = false,
    scratch: [256]u8 = undefined,

    // --- field handling -----------------------------------------------------

    fn appendRaw(self: *Expander, bytes: []const u8) Error!void {
        if (bytes.len == 0) return;
        try self.buf.appendSlice(self.arena, bytes);
        self.active = true;
    }

    /// Appends text from a quoted context, protecting it from splitting and
    /// globbing.
    fn appendQuoted(self: *Expander, bytes: []const u8) Error!void {
        self.active = true;
        if (bytes.len == 0) return;
        if (self.mode == .literal) {
            try self.buf.appendSlice(self.arena, bytes);
            return;
        }
        for (bytes) |b| {
            switch (b) {
                ' ', '\t', '\n', '\r', '*', '?', '[', ']', '\\' => {
                    try self.buf.append(self.arena, '\\');
                    try self.buf.append(self.arena, b);
                },
                else => try self.buf.append(self.arena, b),
            }
        }
    }

    /// Appends an unquoted value, splitting it into fields on whitespace.
    fn appendSplitRaw(self: *Expander, bytes: []const u8) Error!void {
        if (self.mode == .literal) return self.appendRaw(bytes);
        var i: usize = 0;
        while (i < bytes.len) {
            if (isSpaceByte(bytes[i])) {
                try self.flush();
                while (i < bytes.len and isSpaceByte(bytes[i])) i += 1;
                continue;
            }
            const start = i;
            while (i < bytes.len and !isSpaceByte(bytes[i])) i += 1;
            try self.appendRaw(bytes[start..i]);
        }
    }

    /// Emits the pending field, globbing it when it still has live
    /// metacharacters. Does nothing in literal mode.
    fn flush(self: *Expander) Error!void {
        if (self.mode == .literal) return;
        if (!self.active) {
            self.buf.clearRetainingCapacity();
            return;
        }
        self.active = false;
        const field = self.buf.items;

        if (glob.hasMeta(field)) {
            var matches: std.ArrayList([]const u8) = .empty;
            if (try glob.glob(self.arena, field, &matches)) {
                const out = self.out orelse unreachable;
                for (matches.items) |m| try out.append(self.arena, m);
                self.buf.clearRetainingCapacity();
                return;
            }
        }

        const text = try glob.unescape(self.arena, field);
        self.buf.clearRetainingCapacity();
        const out = self.out orelse unreachable;
        try out.append(self.arena, text);
    }

    // --- scanning -----------------------------------------------------------

    fn scan(self: *Expander, word: []const u8) Error!void {
        // A bare name that names a shell variable is a reference to it. The
        // value becomes a single field: a language-level reference should not
        // be split on whitespace or globbed.
        if (self.bare_vars) {
            if (bareIdentifier(word)) |name| {
                if (self.sh.getVar(name)) |v| {
                    try self.appendQuoted(self.renderValue(v));
                    try self.flush();
                    return;
                }
            }
        }

        var i: usize = 0;

        // A leading unquoted `~` expands to `$HOME`.
        if (word.len > 0 and word[0] == '~') {
            var j: usize = 1;
            while (j < word.len and word[j] != '/' and word[j] != ':') j += 1;
            if (j == 1) {
                if (self.sh.getEnv("HOME")) |home| {
                    try self.appendRaw(home);
                    i = 1;
                }
            }
        }

        while (i < word.len) {
            const c = word[i];
            switch (c) {
                '\\' => {
                    if (i + 1 < word.len) {
                        if (word[i + 1] == '\n') {
                            i += 2;
                            continue;
                        }
                        try self.appendQuoted(word[i + 1 .. i + 2]);
                        i += 2;
                    } else {
                        try self.appendQuoted("\\");
                        i += 1;
                    }
                },
                '\'' => {
                    const end = std.mem.indexOfScalarPos(u8, word, i + 1, '\'') orelse word.len;
                    try self.appendQuoted(word[i + 1 .. end]);
                    i = if (end < word.len) end + 1 else word.len;
                },
                '"' => {
                    const end = findClosingDouble(word, i + 1);
                    // `""` is a real (empty) field, so mark it before scanning.
                    self.active = true;
                    try self.scanDouble(word[i + 1 .. end]);
                    i = if (end < word.len) end + 1 else word.len;
                },
                '$' => try self.scanDollar(word, &i, false),
                '`' => {
                    const end = std.mem.indexOfScalarPos(u8, word, i + 1, '`') orelse word.len;
                    try self.substitute(word[i + 1 .. end], false);
                    i = if (end < word.len) end + 1 else word.len;
                },
                else => {
                    // Bare whitespace cannot reach here from the lexer, but if
                    // it does it separates fields.
                    if (isSpaceByte(c)) {
                        try self.flush();
                    } else {
                        try self.appendRaw(word[i .. i + 1]);
                    }
                    i += 1;
                },
            }
        }
    }

    fn scanDouble(self: *Expander, content: []const u8) Error!void {
        var i: usize = 0;
        while (i < content.len) {
            const c = content[i];
            if (c == '\\' and i + 1 < content.len) {
                switch (content[i + 1]) {
                    '$', '"', '\\', '`' => {
                        try self.appendQuoted(content[i + 1 .. i + 2]);
                        i += 2;
                    },
                    '\n' => i += 2,
                    else => {
                        try self.appendQuoted("\\");
                        i += 1;
                    },
                }
                continue;
            }
            if (c == '$') {
                try self.scanDollar(content, &i, true);
                continue;
            }
            if (c == '`') {
                const end = std.mem.indexOfScalarPos(u8, content, i + 1, '`') orelse content.len;
                try self.substitute(content[i + 1 .. end], true);
                i = if (end < content.len) end + 1 else content.len;
                continue;
            }
            try self.appendQuoted(content[i .. i + 1]);
            i += 1;
        }
    }

    fn emit(self: *Expander, text: []const u8, quoted: bool) Error!void {
        if (quoted) {
            try self.appendQuoted(text);
        } else {
            try self.appendSplitRaw(text);
        }
    }

    fn scanDollar(self: *Expander, s: []const u8, i: *usize, quoted: bool) Error!void {
        const start = i.*;
        if (start + 1 >= s.len) {
            try self.appendRaw("$");
            i.* = start + 1;
            return;
        }

        const next = s[start + 1];
        switch (next) {
            '{' => {
                const close = findMatching(s, start + 1, '{', '}') orelse {
                    i.* = s.len;
                    return Error.UnterminatedSubstitution;
                };
                try self.expandBraced(s[start + 2 .. close], quoted);
                i.* = close + 1;
            },
            '(' => {
                if (start + 2 < s.len and s[start + 2] == '(') {
                    i.* = s.len;
                    return Error.UnsupportedArithmetic;
                }
                const close = findMatching(s, start + 1, '(', ')') orelse {
                    i.* = s.len;
                    return Error.UnterminatedSubstitution;
                };
                try self.substitute(s[start + 2 .. close], quoted);
                i.* = close + 1;
            },
            '?' => {
                try self.emit(self.intText(self.sh.last_status), quoted);
                i.* = start + 2;
            },
            '$' => {
                try self.emit(self.intText(self.sh.pid), quoted);
                i.* = start + 2;
            },
            '!' => {
                try self.emit(self.intText(self.sh.last_bg_pid), quoted);
                i.* = start + 2;
            },
            '#' => {
                try self.emit(self.intText(self.sh.positional.len), quoted);
                i.* = start + 2;
            },
            '0'...'9' => {
                var j = start + 1;
                while (j < s.len and std.ascii.isDigit(s[j])) j += 1;
                const idx = std.fmt.parseInt(usize, s[start + 1 .. j], 10) catch 0;
                const text = if (idx == 0)
                    self.sh.script_name
                else if (idx <= self.sh.positional.len)
                    self.sh.positional[idx - 1]
                else
                    "";
                try self.emit(text, quoted);
                i.* = j;
            },
            else => {
                if (isIdentStart(next)) {
                    var j = start + 1;
                    while (j < s.len and isIdentChar(s[j])) j += 1;
                    try self.emit(self.lookup(s[start + 1 .. j]), quoted);
                    i.* = j;
                } else {
                    try self.appendRaw("$");
                    i.* = start + 1;
                }
            },
        }
    }

    fn intText(self: *Expander, n: anytype) []const u8 {
        return std.fmt.bufPrint(&self.scratch, "{d}", .{n}) catch "0";
    }

    /// `${name}`, `${#name}`, `${name:-fallback}` and `${name:+alternate}`.
    fn expandBraced(self: *Expander, inner: []const u8, quoted: bool) Error!void {
        if (inner.len == 0) {
            try self.appendRaw("$");
            return;
        }
        if (inner[0] == '#') {
            const name_len = self.lookup(inner[1..]).len;
            var buf: [24]u8 = undefined;
            const text = std.fmt.bufPrint(&buf, "{d}", .{name_len}) catch "0";
            try self.emit(text, quoted);
            return;
        }
        if (std.mem.indexOf(u8, inner, ":-")) |at| {
            const val = self.lookup(inner[0..at]);
            try self.emit(if (val.len == 0) inner[at + 2 ..] else val, quoted);
            return;
        }
        if (std.mem.indexOf(u8, inner, ":+")) |at| {
            const val = self.lookup(inner[0..at]);
            try self.emit(if (val.len != 0) inner[at + 2 ..] else "", quoted);
            return;
        }
        try self.emit(self.lookup(inner), quoted);
    }

    /// Resolves a name to text: shell variables first, then the environment.
    fn lookup(self: *Expander, name: []const u8) []const u8 {
        if (self.sh.getVar(name)) |v| return self.renderValue(v);
        return self.sh.getEnv(name) orelse "";
    }

    fn renderValue(self: *Expander, v: value.Value) []const u8 {
        switch (v) {
            .string => |s| return s,
            .none => return "",
            .boolean => |b| return if (b) "true" else "false",
            .int => |n| return std.fmt.bufPrint(&self.scratch, "{d}", .{n}) catch "",
            .float => |f| return std.fmt.bufPrint(&self.scratch, "{d}", .{f}) catch "",
            .list => |items| {
                var w = std.Io.Writer.fixed(&self.scratch);
                for (items, 0..) |item, idx| {
                    if (idx != 0) w.writeByte(' ') catch break;
                    item.render(&w) catch break;
                }
                return w.buffered();
            },
        }
    }

    fn substitute(self: *Expander, src: []const u8, quoted: bool) Error!void {
        const runner = self.sh.subst_runner orelse return;
        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (trimmed.len == 0) return;
        const result = runner(self.sh, trimmed, self.arena) catch return Error.SubstitutionFailed;
        // Only trailing newlines are stripped, like every other shell.
        try self.emit(std.mem.trimEnd(u8, result, "\n"), quoted);
    }
};

fn findClosingDouble(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            i += 2;
            continue;
        }
        if (c == '"') return i;
        // A substitution opens its own quoting scope, so quotes inside it do
        // not close this string: "$(echo "hi")" is one word.
        if (c == '$' and i + 1 < s.len and (s[i + 1] == '(' or s[i + 1] == '{')) {
            const close: u8 = if (s[i + 1] == '(') ')' else '}';
            const end = findMatching(s, i + 1, s[i + 1], close) orelse return s.len;
            i = end + 1;
            continue;
        }
        i += 1;
    }
    return s.len;
}

/// Finds the delimiter matching the opener at `open_index`, skipping quoted
/// regions and nested openers.
fn findMatching(s: []const u8, open_index: usize, open: u8, close: u8) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (c == '\'') {
            i += 1;
            while (i < s.len and s[i] != '\'') i += 1;
            continue;
        }
        if (c == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') {
                if (s[i] == '\\' and i + 1 < s.len) i += 1;
                i += 1;
            }
            continue;
        }
        if (c == open) depth += 1;
        if (c == close) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

fn testShell() !shell.Shell {
    return shell.Shell.initBare(testing.allocator);
}

test "quotes, escapes and single quotes" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try testing.expectEqualStrings("a b", try expandLiteral(&sh, arena, "\"a b\""));
    try testing.expectEqualStrings("a b", try expandLiteral(&sh, arena, "a\\ b"));
    try testing.expectEqualStrings("*.rs", try expandLiteral(&sh, arena, "'*.rs'"));
    try testing.expectEqualStrings("$HOME", try expandLiteral(&sh, arena, "'$HOME'"));
    try testing.expectEqualStrings("a'b", try expandLiteral(&sh, arena, "a\\'b"));
}

test "variable lookup and field splitting" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("x", .{ .string = "one two" });
    try sh.setVar("n", .{ .int = 42 });
    try sh.setEnv("GREETING", "hi");

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$x", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("one", fields.items[0]);
    try testing.expectEqualStrings("two", fields.items[1]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$x\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("one two", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "v$n", &fields);
    try testing.expectEqualStrings("v42", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$GREETING", &fields);
    try testing.expectEqualStrings("hi", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "${missing:-fallback}", &fields);
    try testing.expectEqualStrings("fallback", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "${#x}", &fields);
    try testing.expectEqualStrings("7", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$?", &fields);
    try testing.expectEqualStrings("0", fields.items[0]);
}

test "prefix and suffix around an unquoted expansion" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("x", .{ .string = "1 2" });

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "a$x", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("a1", fields.items[0]);
    try testing.expectEqualStrings("2", fields.items[1]);
}

test "quoted words keep their glob characters literal" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "\"*.zig\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("*.zig", fields.items[0]);
}

test "unquoted glob expands against the filesystem" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "src/*.zig", &fields);
    try testing.expect(fields.items.len >= 5);
}

test "empty quotes still produce a field" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "\"\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("", fields.items[0]);
}
