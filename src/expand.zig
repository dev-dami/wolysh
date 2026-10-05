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
const arith = @import("arith.zig");
const value = @import("value.zig");
const sys = @import("sys.zig");
const arrays = @import("arrays.zig");
const compound = @import("compound.zig");
const param_ops = @import("param_ops.zig");
const special_vars = @import("special_vars.zig");

pub const Error = error{
    UnterminatedSubstitution,
    SubstitutionFailed,
    UnsupportedArithmetic,
    InvalidArithmetic,
    DivisionByZero,
    /// A malformed or failed `${...}`; the message has been printed.
    BadSubstitution,
    /// `set -u` met an unset parameter, or `${name?word}` fired; the message
    /// has been printed.
    UnboundVariable,
} || std.mem.Allocator.Error;

/// Writes an expansion error to the shell's stderr.
pub fn report(sh: *const shell.Shell, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    w.print(fmt, args) catch {};
    sys.writeStr(sh.default_err, w.buffered());
}

const Mode = enum {
    /// A word in a command position: split on whitespace, then glob.
    command_word,
    /// A single value: no splitting, no globbing.
    literal,
    /// A `${name#pattern}` operand: one value in which quoted characters are
    /// backslash-escaped, so they match literally.
    pattern,
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

/// The field-splitting separators in force. `seps` borrows from the caller's
/// buffer; `user_set` distinguishes an explicit `IFS` from the default set, so
/// `\r` stays whitespace only in the default.
const Ifs = struct {
    seps: []const u8,
    user_set: bool,
};

fn isIfsSep(c: u8, ifs: Ifs) bool {
    return std.mem.indexOfScalar(u8, ifs.seps, c) != null;
}

fn isIfsWhite(c: u8, ifs: Ifs) bool {
    if (!isIfsSep(c, ifs)) return false;
    return c == ' ' or c == '\t' or c == '\n' or (!ifs.user_set and c == '\r');
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

pub fn expandHereDoc(sh: *shell.Shell, arena: std.mem.Allocator, body: []const u8) Error![]const u8 {
    var ex = Expander{ .sh = sh, .arena = arena, .mode = .literal };
    try ex.scanHereDoc(body);
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
        } else if (out.items.len > 0 and isDeclaration(out.items[0])) {
            try expandDeclarationArgument(sh, arena, word, out);
        } else {
            try expandArgument(sh, arena, word, out);
        }
    }
}

fn isDeclaration(name: []const u8) bool {
    return std.mem.eql(u8, name, "declare") or std.mem.eql(u8, name, "typeset") or std.mem.eql(u8, name, "local");
}

/// An argument of `declare`, `typeset` or `local`. An unquoted `NAME=(...)`
/// reaches the builtin unexpanded behind `compound.marker`, because only the
/// builtin knows whether it builds an indexed or an associative array.
/// `NAME=value` expands like an assignment: no splitting, no globbing. Names
/// are never replaced by a variable's value.
fn expandDeclarationArgument(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    word: []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    if (compound.openParen(word) != null and word[word.len - 1] == ')') {
        try out.append(arena, try std.mem.concat(arena, u8, &.{ &.{compound.marker}, word }));
        return;
    }
    if (assignmentEquals(word)) |eq| {
        const assigned = try expandLiteral(sh, arena, word[eq + 1 ..]);
        try out.append(arena, try std.mem.concat(arena, u8, &.{ word[0 .. eq + 1], assigned }));
        return;
    }
    try expandWord(sh, arena, word, out);
}

/// The `=` of an unquoted `NAME=`, `NAME+=` or `NAME[subscript]=` prefix.
fn assignmentEquals(word: []const u8) ?usize {
    if (word.len == 0 or !isIdentStart(word[0])) return null;
    var i: usize = 1;
    while (i < word.len and isIdentChar(word[i])) i += 1;
    if (i < word.len and word[i] == '[') i = (compound.closeBracket(word, i) orelse return null) + 1;
    if (i < word.len and word[i] == '+') i += 1;
    if (i < word.len and word[i] == '=') return i;
    return null;
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
    flag_buf: [8]u8 = undefined,

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
        if (self.mode == .pattern) {
            // Every byte, so `&` in a replacement and extglob operators stay
            // literal too.
            for (bytes) |b| try self.buf.appendSlice(self.arena, &.{ '\\', b });
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

    /// Appends an unquoted value, splitting it into fields on `IFS`.
    fn appendSplitRaw(self: *Expander, bytes: []const u8) Error!void {
        if (self.mode != .command_word) return self.appendRaw(bytes);
        if (bytes.len == 0) return;
        var seps: [64]u8 = undefined;
        const ifs = self.ifsSpec(&seps);
        var i: usize = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            if (isIfsWhite(c, ifs)) {
                while (i < bytes.len and isIfsWhite(bytes[i], ifs)) i += 1;
                // Whitespace touching a non-whitespace delimiter is part of
                // the same delimiter, which can be a field of its own.
                if (i < bytes.len and isIfsSep(bytes[i], ifs)) {
                    i += 1;
                    while (i < bytes.len and isIfsWhite(bytes[i], ifs)) i += 1;
                    try self.closeField();
                } else if (self.active) {
                    try self.flush();
                }
                continue;
            }
            if (isIfsSep(c, ifs)) {
                try self.closeField();
                i += 1;
                while (i < bytes.len and isIfsWhite(bytes[i], ifs)) i += 1;
                continue;
            }
            const start = i;
            while (i < bytes.len and !isIfsSep(bytes[i], ifs)) i += 1;
            try self.appendExpanded(bytes[start..i]);
        }
    }

    /// Expansion output keeps its glob characters live, but a backslash in it
    /// is data, not an escape: `x='a\b'; echo $x` prints `a\b`.
    fn appendExpanded(self: *Expander, bytes: []const u8) Error!void {
        var start: usize = 0;
        for (bytes, 0..) |b, i| {
            if (b != '\\') continue;
            try self.appendRaw(bytes[start..i]);
            try self.appendRaw("\\\\");
            start = i + 1;
        }
        try self.appendRaw(bytes[start..]);
    }

    /// Ends the current field. A delimiter with nothing before it still yields
    /// an (empty) field when the delimiter is not IFS whitespace.
    fn closeField(self: *Expander) Error!void {
        if (self.active) return self.flush();
        const out = self.out orelse return;
        try out.append(self.arena, "");
    }

    /// Reads `IFS` into `buf`, falling back to the default separator set.
    fn ifsSpec(self: *Expander, buf: *[64]u8) Ifs {
        const explicit: ?[]const u8 = if (self.sh.getVar("IFS")) |v| self.renderValue(v) else self.sh.getEnv("IFS");
        if (explicit) |s| {
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return .{ .seps = buf[0..n], .user_set = true };
        }
        return .{ .seps = " \t\n\r", .user_set = false };
    }

    /// Emits the pending field, globbing it when it still has live
    /// metacharacters. Does nothing in literal mode.
    fn flush(self: *Expander) Error!void {
        if (self.mode != .command_word) return;
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

    /// Brace expansion runs first, at the word level, over the raw text.
    fn scan(self: *Expander, word: []const u8) Error!void {
        if (self.mode != .command_word) return self.scanText(word);
        try self.scanBraceWord(word, 0);
    }

    fn scanBraceWord(self: *Expander, word: []const u8, depth: u32) Error!void {
        if (depth < max_brace_depth) {
            if (findBrace(word)) |group| {
                if (try self.expandBrace(word, group, depth)) return;
            }
        }
        try self.scanText(word);
    }

    fn scanText(self: *Expander, word: []const u8) Error!void {
        // A bare name that names a shell variable is a reference to it. The
        // value becomes a single field: a language-level reference should not
        // be split on whitespace or globbed.
        if (self.bare_vars) {
            if (bareIdentifier(word)) |name| {
                // Stored variables only: `echo UID` stays a word.
                if (self.sh.vars.get(name)) |v| {
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
                    const end = findClosingBacktick(word, i + 1);
                    try self.substitute(word[i + 1 .. end], false);
                    i = if (end < word.len) end + 1 else word.len;
                },
                else => {
                    // Bare whitespace reaches here only from a `${x:-a b}`
                    // operand, where it separates fields.
                    if (isSpaceByte(c) and self.mode == .command_word) {
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
                const end = findClosingBacktick(content, i + 1);
                try self.substitute(content[i + 1 .. end], true);
                i = if (end < content.len) end + 1 else content.len;
                continue;
            }
            try self.appendQuoted(content[i .. i + 1]);
            i += 1;
        }
    }

    fn scanHereDoc(self: *Expander, content: []const u8) Error!void {
        var i: usize = 0;
        while (i < content.len) {
            const c = content[i];
            if (c == '\\' and i + 1 < content.len) {
                switch (content[i + 1]) {
                    '$', '`', '\\' => {
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
                const end = findClosingBacktick(content, i + 1);
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
                const close = findMatching(s, start + 1, '(', ')') orelse {
                    i.* = s.len;
                    return Error.UnterminatedSubstitution;
                };
                if (start + 2 < s.len and s[start + 2] == '(') {
                    // As in bash, `${a[i]}` and `${#a[@]}` expand before the
                    // arithmetic is evaluated.
                    const expr = try expandLiteral(self.sh, self.arena, s[start + 3 .. close - 1]);
                    const result = try arith.evaluate(self.sh, self.arena, expr);
                    try self.emit(self.intText(result), quoted);
                } else {
                    try self.substitute(s[start + 2 .. close], quoted);
                }
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
            '#' => {
                try self.emit(self.intText(self.sh.positional.len), quoted);
                i.* = start + 2;
            },
            '-' => {
                try self.emit(self.optionLetters(), quoted);
                i.* = start + 2;
            },
            '!', '@', '*', '0'...'9' => {
                try self.expandSimple(s[start + 1 .. start + 2], quoted);
                i.* = start + 2;
            },
            else => {
                if (isIdentStart(next)) {
                    var j = start + 1;
                    while (j < s.len and isIdentChar(s[j])) j += 1;
                    try self.expandSimple(s[start + 1 .. j], quoted);
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

    /// The fields of `$@`, `${name[@]}` and similar. `@`, quoted: one field
    /// per item, so `"$@"` with no parameters yields no field. `*`, quoted:
    /// the items joined by the first character of `IFS` in one field (empty
    /// when there are none). Unquoted, each item is split. A single-value
    /// context such as an assignment joins `@` with spaces and `*` with `IFS`.
    fn emitList(self: *Expander, items: []const []const u8, star: bool, quoted: bool) Error!void {
        if (star or self.mode != .command_word) {
            const sep = if (star) self.starSeparator() else " ";
            if (self.mode != .command_word) self.active = true;
            for (items, 0..) |item, idx| {
                if (idx != 0) try self.emit(sep, quoted);
                try self.emit(item, quoted);
            }
            return;
        }
        for (items, 0..) |item, idx| {
            if (idx != 0) try self.flush();
            if (quoted) try self.appendQuoted(item) else try self.appendSplitRaw(item);
        }
        if (quoted and items.len == 0 and self.buf.items.len == 0) self.active = false;
    }

    /// `$-`: the option letters the shell is running with.
    fn optionLetters(self: *Expander) []const u8 {
        var n: usize = 0;
        if (self.sh.interactive) {
            self.scratch[n] = 'i';
            n += 1;
        }
        if (self.sh.login) {
            self.scratch[n] = 'l';
            n += 1;
        }
        if (self.sh.job_control) {
            self.scratch[n] = 'm';
            n += 1;
        }
        return self.scratch[0..n];
    }

    /// Expands one brace group into the words it stands for and scans each.
    /// Returns false when the group is left literal instead (oversized range).
    fn expandBrace(self: *Expander, word: []const u8, group: BraceGroup, depth: u32) Error!bool {
        const prefix = word[0..group.open];
        const suffix = word[group.close + 1 ..];
        const content = word[group.open + 1 .. group.close];

        if (parseRange(content)) |range| {
            switch (range) {
                .ints => |iv| {
                    if (rangeLength(iv.lo, iv.hi) > max_brace_values) return false;
                    const step: i64 = if (iv.lo <= iv.hi) 1 else -1;
                    var n = iv.lo;
                    while (true) {
                        var buf: [24]u8 = undefined;
                        const text = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return false;
                        try self.emitBraceWord(prefix, text, suffix, depth);
                        if (n == iv.hi) break;
                        n += step;
                    }
                    return true;
                },
                .chars => |cv| {
                    if (rangeLength(cv.lo, cv.hi) > max_brace_values) return false;
                    const step: i16 = if (cv.lo <= cv.hi) 1 else -1;
                    var c: i16 = cv.lo;
                    while (true) {
                        const one = [1]u8{@intCast(c)};
                        try self.emitBraceWord(prefix, &one, suffix, depth);
                        if (c == cv.hi) break;
                        c += step;
                    }
                    return true;
                },
            }
        }

        if (!hasTopLevelComma(content)) return false;
        var pieces: std.ArrayList([]const u8) = .empty;
        try splitTopLevel(self.arena, content, &pieces);
        for (pieces.items) |piece| {
            try self.emitBraceWord(prefix, piece, suffix, depth);
        }
        return true;
    }

    /// Scans one generated word and closes it as its own field.
    fn emitBraceWord(self: *Expander, prefix: []const u8, mid: []const u8, suffix: []const u8, depth: u32) Error!void {
        self.active = true;
        try self.scanBraceWord(try self.joinWord(prefix, mid, suffix), depth + 1);
        try self.flush();
    }

    fn joinWord(self: *Expander, prefix: []const u8, mid: []const u8, suffix: []const u8) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}{s}", .{ prefix, mid, suffix });
    }

    // --- parameters ---------------------------------------------------------

    /// The value of one parameter: a single string, or the fields of `$@`,
    /// `${name[@]}` and the other multi-field forms.
    const Param = struct {
        set: bool,
        list: bool = false,
        /// `*` rather than `@`: quoted, the fields join into one.
        star: bool = false,
        text: []const u8 = "",
        items: []const []const u8 = &.{},
        /// Each item's array index, for `${name[@]:offset}` on a sparse array;
        /// null means the items are numbered from 0.
        indices: ?[]const usize = null,
        /// `$@` and `$*`, where offset 0 of `${@:offset}` is `$0`.
        positional: bool = false,
        /// `${scalar[@]}`, whose `${x[@]:offset}` slices the string.
        scalar: bool = false,
        /// `${name[@]}` of a variable that does not exist, as opposed to an
        /// empty array; `set -u` rejects only the former's length.
        undeclared: bool = false,
    };

    /// `$name`, `$1`, `$!` and the other unbraced forms.
    fn expandSimple(self: *Expander, name: []const u8, quoted: bool) Error!void {
        const p = try self.resolve(name, null);
        try self.requireSet(p, .{ .name = name, .subscript = null });
        try self.emitParam(p, quoted);
    }

    /// `${...}`; `Braced` lists the forms.
    fn expandBraced(self: *Expander, inner: []const u8, quoted: bool) Error!void {
        const b = parseBraced(inner) orelse {
            report(self.sh, "wsh: ${{{s}}}: bad substitution\n", .{inner});
            return error.BadSubstitution;
        };
        switch (b.op) {
            .names => return self.emitList(try self.namesWithPrefix(b.name), b.star, quoted),
            .keys => return self.emitList(try self.keysOf(b.name), b.star, quoted),
            else => {},
        }
        const ref = Label{ .name = b.name, .subscript = b.subscript };
        const p = if (b.indirect) try self.resolveIndirect(b.name, b.subscript) else try self.resolve(b.name, b.subscript);
        switch (b.op) {
            .names, .keys => unreachable,
            .none => {
                try self.requireSet(p, ref);
                return self.emitParam(p, quoted);
            },
            .length => {
                if (p.list) {
                    if (p.undeclared) try self.requireSet(.{ .set = false }, .{ .name = b.name, .subscript = null });
                    return self.emit(try self.number(p.items.len), quoted);
                }
                try self.requireSet(p, ref);
                return self.emit(try self.number(param_ops.charCount(p.text)), quoted);
            },
            .use_default => {
                if (isMissing(p, b.colon)) return self.emitOperand(b.word, quoted);
                return self.emitParam(p, quoted);
            },
            .use_alternate => {
                if (!isMissing(p, b.colon)) return self.emitOperand(b.word, quoted);
            },
            .assign_default => {
                if (!isMissing(p, b.colon)) return self.emitParam(p, quoted);
                if (b.indirect or !isIdentStart(b.name[0])) {
                    report(self.sh, "wsh: {f}: cannot assign in this way\n", .{ref});
                    return error.BadSubstitution;
                }
                try self.assignParam(b.name, b.subscript, try self.operandText(b.word));
                return self.emitParam(try self.resolve(b.name, b.subscript), quoted);
            },
            .fail_unset => {
                if (!isMissing(p, b.colon)) return self.emitParam(p, quoted);
                const message = if (b.word.len != 0)
                    try self.operandText(b.word)
                else if (b.colon) "parameter null or not set" else "parameter not set";
                report(self.sh, "wsh: {f}: {s}\n", .{ ref, message });
                return error.UnboundVariable;
            },
            .substring => {
                try self.requireSet(p, ref);
                return self.emitParam(try self.substring(p, b.word, b.word2), quoted);
            },
            .transform => {
                try self.requireSet(p, ref);
                switch (b.word[0]) {
                    'A' => return self.emit(try self.assignmentText(b.name, p), quoted),
                    'K' => return self.emit(try self.keyValueText(b.name, p), quoted),
                    else => return self.emitParam(try self.applyOperator(p, b), quoted),
                }
            },
            .remove_prefix, .remove_suffix, .replace, .upper, .lower => {
                try self.requireSet(p, ref);
                return self.emitParam(try self.applyOperator(p, b), quoted);
            },
        }
    }

    fn emitParam(self: *Expander, p: Param, quoted: bool) Error!void {
        if (p.list) return self.emitList(p.items, p.star, quoted);
        return self.emit(p.text, quoted);
    }

    /// `set -u`: an unset parameter is an error, except the multi-field forms.
    fn requireSet(self: *Expander, p: Param, ref: Label) Error!void {
        if (p.set or p.list or !self.sh.options.nounset) return;
        report(self.sh, "wsh: {f}: unbound variable\n", .{ref});
        return error.UnboundVariable;
    }

    fn resolve(self: *Expander, name: []const u8, subscript: ?[]const u8) Error!Param {
        const sh = self.sh;
        if (std.ascii.isDigit(name[0])) {
            const idx = std.fmt.parseInt(usize, name, 10) catch return .{ .set = false };
            if (idx == 0) return .{ .set = true, .text = sh.script_name };
            if (idx <= sh.positional.len) return .{ .set = true, .text = sh.positional[idx - 1] };
            return .{ .set = false };
        }
        if (!isIdentStart(name[0])) {
            return switch (name[0]) {
                '@', '*' => .{
                    .set = sh.positional.len != 0,
                    .list = true,
                    .star = name[0] == '*',
                    .items = sh.positional,
                    .positional = true,
                },
                '#' => .{ .set = true, .text = try self.number(sh.positional.len) },
                '?' => .{ .set = true, .text = try self.number(sh.last_status) },
                '$' => .{ .set = true, .text = try self.number(sh.pid) },
                '!' => if (sh.last_bg_pid == 0) .{ .set = false } else .{ .set = true, .text = try self.number(sh.last_bg_pid) },
                '-' => .{ .set = true, .text = try self.arena.dupe(u8, self.optionLetters()) },
                else => .{ .set = false },
            };
        }
        const v = variable(sh, name);
        const sub = subscript orelse {
            // wsh rule: `$list` without a subscript is every element.
            const val = v orelse return .{ .set = false };
            return .{ .set = true, .text = try self.textOf(val) };
        };
        if (isAllSubscript(sub)) return self.allItems(v, sub[0] == '*');
        return self.element(name, v, sub);
    }

    /// `${name[@]}`: the set elements in index order. A scalar is a
    /// one-element array.
    fn allItems(self: *Expander, v: ?value.Value, star: bool) Error!Param {
        const val = v orelse return .{ .set = false, .list = true, .star = star, .undeclared = true };
        var items: std.ArrayList([]const u8) = .empty;
        var indices: std.ArrayList(usize) = .empty;
        switch (val) {
            .list => |list| for (list, 0..) |item, i| {
                if (item == .none) continue;
                try items.append(self.arena, try self.textOf(item));
                try indices.append(self.arena, i);
            },
            .map => |entries| for (entries, 0..) |entry, i| {
                if (entry.value == .none) continue;
                try items.append(self.arena, try self.textOf(entry.value));
                try indices.append(self.arena, i);
            },
            else => {
                try items.append(self.arena, try self.textOf(val));
                try indices.append(self.arena, 0);
            },
        }
        return .{
            .set = items.items.len != 0,
            .list = true,
            .star = star,
            .items = items.items,
            .indices = indices.items,
            .scalar = val != .list and val != .map,
        };
    }

    /// `${name[subscript]}`: an arithmetic index for an indexed array (negative
    /// counts from the end), a key for an associative one.
    fn element(self: *Expander, name: []const u8, v: ?value.Value, subscript: []const u8) Error!Param {
        const val = v orelse return .{ .set = false };
        if (val == .map) {
            const key = try expandLiteral(self.sh, self.arena, subscript);
            for (val.map) |entry| {
                if (!std.mem.eql(u8, entry.key, key)) continue;
                if (entry.value == .none) break;
                return .{ .set = true, .text = try self.textOf(entry.value) };
            }
            return .{ .set = false };
        }
        const n = try self.arithOperand(subscript);
        const len: usize = if (val == .list) val.list.len else 1;
        const index: i64 = if (n < 0) n + @as(i64, @intCast(len)) else n;
        if (index < 0) {
            report(self.sh, "wsh: {s}: bad array subscript\n", .{name});
            return .{ .set = false };
        }
        if (index >= len) return .{ .set = false };
        const item = if (val == .list) val.list[@intCast(index)] else val;
        if (item == .none) return .{ .set = false };
        return .{ .set = true, .text = try self.textOf(item) };
    }

    /// `${!name}`: the parameter that `name`'s value names.
    fn resolveIndirect(self: *Expander, name: []const u8, subscript: ?[]const u8) Error!Param {
        const ref = try self.resolve(name, subscript);
        if (!ref.set or ref.list) {
            report(self.sh, "wsh: {f}: invalid indirect expansion\n", .{Label{ .name = name, .subscript = subscript }});
            return error.BadSubstitution;
        }
        const target = ref.text;
        if ((paramLength(target) orelse 0) != target.len or target.len == 0) {
            report(self.sh, "wsh: {s}: invalid variable name\n", .{target});
            return error.BadSubstitution;
        }
        const t = splitParam(target);
        return self.resolve(t.name, t.subscript);
    }

    /// `${!prefix*}`: the names of set variables starting with `prefix`.
    fn namesWithPrefix(self: *Expander, prefix: []const u8) Error![]const []const u8 {
        const sh = self.sh;
        var names: std.ArrayList([]const u8) = .empty;
        var vars = sh.vars.iterator();
        while (vars.next()) |entry| {
            if (entry.value_ptr.* == .none or !std.mem.startsWith(u8, entry.key_ptr.*, prefix)) continue;
            try names.append(self.arena, entry.key_ptr.*);
        }
        var env = sh.env.iterator();
        while (env.next()) |entry| {
            const name = entry.key_ptr.*;
            if (std.mem.startsWith(u8, name, prefix) and !sh.vars.contains(name)) try names.append(self.arena, name);
        }
        for (special_vars.names) |name| {
            if (std.mem.startsWith(u8, name, prefix) and !sh.vars.contains(name) and sh.env.get(name) == null) {
                try names.append(self.arena, name);
            }
        }
        std.mem.sort([]const u8, names.items, {}, lessThan);
        return names.items;
    }

    /// `${!name[@]}`: the indices of the set elements, or the keys.
    fn keysOf(self: *Expander, name: []const u8) Error![]const []const u8 {
        const val = variable(self.sh, name) orelse return &.{};
        var keys: std.ArrayList([]const u8) = .empty;
        switch (val) {
            .list => |list| for (list, 0..) |item, i| {
                if (item != .none) try keys.append(self.arena, try self.number(i));
            },
            .map => |entries| for (entries) |entry| try keys.append(self.arena, entry.key),
            else => try keys.append(self.arena, "0"),
        }
        return keys.items;
    }

    /// `${name:offset}` and `${name:offset:length}`: characters of a string,
    /// or elements of a list (`$@` counts `$0` as offset 0).
    fn substring(self: *Expander, p: Param, offset_text: []const u8, length_text: ?[]const u8) Error!Param {
        const offset = try self.arithOperand(offset_text);
        const length: ?i64 = if (length_text) |text| try self.arithOperand(text) else null;
        if (!p.list) return .{ .set = true, .text = try self.substringText(p.text, offset, length) };
        if (p.scalar) {
            const text = try self.substringText(p.items[0], offset, length);
            return .{ .set = true, .list = true, .star = p.star, .items = try self.arena.dupe([]const u8, &.{text}) };
        }
        if (length) |l| {
            if (l < 0) return self.negativeLength(l);
        }
        var items: std.ArrayList([]const u8) = .empty;
        if (p.positional) {
            const count: i64 = @intCast(p.items.len);
            const start = if (offset < 0) offset + count + 1 else offset;
            if (start == 0) try items.append(self.arena, self.sh.script_name);
            if (start >= 0 and start <= count) try items.appendSlice(self.arena, p.items[@intCast(@max(start, 1) - 1)..]);
        } else if (p.items.len != 0) {
            const last_index: i64 = @intCast(if (p.indices) |ix| ix[ix.len - 1] else p.items.len - 1);
            const start = if (offset < 0) offset + last_index + 1 else offset;
            if (start >= 0) {
                for (p.items, 0..) |item, i| {
                    const index: i64 = @intCast(if (p.indices) |ix| ix[i] else i);
                    if (index >= start) try items.append(self.arena, item);
                }
            }
        }
        if (length) |l| items.items.len = @min(items.items.len, @as(usize, @intCast(l)));
        return .{ .set = true, .list = true, .star = p.star, .items = items.items };
    }

    /// Characters `offset` onwards; a negative offset counts from the end and
    /// a negative length stops that many characters before it.
    fn substringText(self: *Expander, text: []const u8, offset: i64, length: ?i64) Error![]const u8 {
        const count: i64 = @intCast(param_ops.charCount(text));
        const start = if (offset < 0) offset + count else offset;
        if (start < 0 or start > count) return "";
        var end = count;
        if (length) |l| {
            end = if (l < 0) count + l else start + @min(l, count - start);
            if (end < start) return self.negativeLength(l);
        }
        return text[param_ops.charOffset(text, @intCast(start))..param_ops.charOffset(text, @intCast(end))];
    }

    fn negativeLength(self: *Expander, length: i64) Error {
        report(self.sh, "wsh: {d}: substring expression < 0\n", .{length});
        return error.BadSubstitution;
    }

    /// The pattern and case operators and `@` transforms, applied to the value
    /// or to each element.
    fn applyOperator(self: *Expander, p: Param, b: Braced) Error!Param {
        const pattern = if (b.op == .transform) "" else try self.patternText(b.word);
        const replacement = if (b.word2) |w| try self.patternText(w) else "";
        var out = p;
        if (p.list) {
            const items = try self.arena.alloc([]const u8, p.items.len);
            for (p.items, 0..) |item, i| items[i] = try self.applyText(item, b, pattern, replacement);
            out.items = items;
        } else {
            out.text = try self.applyText(p.text, b, pattern, replacement);
        }
        return out;
    }

    fn applyText(self: *Expander, text: []const u8, b: Braced, pattern: []const u8, replacement: []const u8) Error![]const u8 {
        const a = self.arena;
        return switch (b.op) {
            .remove_prefix => param_ops.removePrefix(a, text, pattern, b.twice),
            .remove_suffix => param_ops.removeSuffix(a, text, pattern, b.twice),
            .replace => param_ops.replace(a, text, pattern, replacement, b.mode),
            .upper => param_ops.convertCase(a, text, pattern, true, !b.twice),
            .lower => param_ops.convertCase(a, text, pattern, false, !b.twice),
            .transform => switch (b.word[0]) {
                'Q' => param_ops.quoteSingle(a, text),
                'E' => param_ops.expandEscapes(a, text),
                'U' => param_ops.caseAll(a, text, true),
                'L' => param_ops.caseAll(a, text, false),
                'u' => param_ops.capitalize(a, text),
                'a' => a.dupe(u8, arrays.flagLetters(self.sh, b.name, &self.flag_buf)),
                else => unreachable,
            },
            else => unreachable,
        };
    }

    /// `${name@A}`: an assignment that recreates the variable.
    fn assignmentText(self: *Expander, name: []const u8, p: Param) Error![]const u8 {
        if (variable(self.sh, name)) |v| {
            if (v == .list or v == .map) return (try arrays.describe(self.sh, self.arena, name)) orelse "";
        }
        const quoted = try param_ops.quoteSingle(self.arena, p.text);
        const flags = arrays.flagLetters(self.sh, name, &self.flag_buf);
        if (flags.len == 0) return std.fmt.allocPrint(self.arena, "{s}={s}", .{ name, quoted });
        return std.fmt.allocPrint(self.arena, "declare -{s} {s}={s}", .{ flags, name, quoted });
    }

    /// `${name@K}`: the value quoted, or an array's keys and quoted values.
    fn keyValueText(self: *Expander, name: []const u8, p: Param) Error![]const u8 {
        const v = variable(self.sh, name) orelse return param_ops.quoteSingle(self.arena, p.text);
        var out: std.ArrayList(u8) = .empty;
        switch (v) {
            .list => |list| for (list, 0..) |item, i| {
                if (item == .none) continue;
                if (out.items.len != 0) try out.append(self.arena, ' ');
                try out.print(self.arena, "{d} {s}", .{ i, try param_ops.quoteDouble(self.arena, try self.textOf(item)) });
            },
            .map => |entries| for (entries) |entry| {
                if (out.items.len != 0) try out.append(self.arena, ' ');
                try out.print(self.arena, "{s} {s}", .{
                    try param_ops.quoteKey(self.arena, entry.key),
                    try param_ops.quoteDouble(self.arena, try self.textOf(entry.value)),
                });
            },
            else => return param_ops.quoteSingle(self.arena, p.text),
        }
        return out.items;
    }

    /// `${name:=word}`.
    fn assignParam(self: *Expander, name: []const u8, subscript: ?[]const u8, text: []const u8) Error!void {
        const result = if (subscript) |sub|
            arrays.assignElement(self.sh, self.arena, name, sub, text, false)
        else if (self.sh.isReadonly(name))
            error.ReadonlyVariable
        else
            self.sh.setVar(name, .{ .string = text });
        result catch |err| switch (err) {
            error.ReadonlyVariable => {
                report(self.sh, "wsh: {s}: readonly variable\n", .{name});
                return error.BadSubstitution;
            },
            else => |e| return e,
        };
    }

    /// A `${name:-word}` operand, expanded in place: inside double quotes it
    /// stays one field, unquoted it splits like any other expansion.
    fn emitOperand(self: *Expander, word: []const u8, quoted: bool) Error!void {
        const saved = self.bare_vars;
        self.bare_vars = false;
        defer self.bare_vars = saved;
        if (quoted) try self.scanOperandQuoted(word) else try self.scanText(word);
    }

    /// An operand inside double quotes: single quotes are literal and inner
    /// double quotes only group, as in bash.
    fn scanOperandQuoted(self: *Expander, word: []const u8) Error!void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < word.len) {
            switch (word[i]) {
                '\\' => i += 2,
                '`' => i = skipBacktick(word, i + 1),
                '$' => i = skipExpansion(word, i) orelse i + 1,
                '"' => {
                    try self.scanDouble(word[start..i]);
                    const end = findClosingDouble(word, i + 1);
                    try self.scanDouble(word[i + 1 .. end]);
                    i = if (end < word.len) end + 1 else word.len;
                    start = i;
                },
                else => i += 1,
            }
        }
        try self.scanDouble(word[start..]);
    }

    /// An operand as one string, quotes removed.
    fn operandText(self: *Expander, word: []const u8) Error![]const u8 {
        var sub = Expander{ .sh = self.sh, .arena = self.arena, .mode = .literal };
        try sub.scanText(word);
        return sub.buf.items;
    }

    /// An operand as a pattern, with quoted characters escaped.
    fn patternText(self: *Expander, word: []const u8) Error![]const u8 {
        var sub = Expander{ .sh = self.sh, .arena = self.arena, .mode = .pattern };
        try sub.scanText(word);
        return sub.buf.items;
    }

    /// An arithmetic operand (a subscript, offset or length), expanded first.
    fn arithOperand(self: *Expander, text: []const u8) Error!i64 {
        const expanded = try expandLiteral(self.sh, self.arena, text);
        return arith.evaluate(self.sh, self.arena, expanded);
    }

    fn number(self: *Expander, n: anytype) Error![]const u8 {
        return std.fmt.allocPrint(self.arena, "{d}", .{n});
    }

    fn textOf(self: *Expander, v: value.Value) Error![]const u8 {
        return switch (v) {
            .string => |s| s,
            else => v.renderAlloc(self.arena) catch return error.OutOfMemory,
        };
    }

    /// The first character of `IFS` that `"$*"` joins with.
    fn starSeparator(self: *Expander) []const u8 {
        var seps: [64]u8 = undefined;
        const ifs = self.ifsSpec(&seps);
        if (!ifs.user_set) return " ";
        if (ifs.seps.len == 0) return "";
        const c = ifs.seps[0];
        return all_bytes[c .. @as(usize, c) + 1];
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
            .map => {
                var w = std.Io.Writer.fixed(&self.scratch);
                v.render(&w) catch {};
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

/// Every byte value once, so a one-byte separator can be returned by slice.
const all_bytes = blk: {
    var bytes: [256]u8 = undefined;
    for (&bytes, 0..) |*b, i| b.* = @intCast(i);
    break :blk bytes;
};

/// A variable's value, falling back to the environment. A declared but unset
/// variable (`local x`) holds `none` and counts as unset.
fn variable(sh: *shell.Shell, name: []const u8) ?value.Value {
    if (sh.getVar(name)) |v| return if (v == .none) null else v;
    if (sh.getEnv(name)) |text| return .{ .string = text };
    return null;
}

/// Whether `${name-word}` (or, with `colon`, `${name:-word}`) uses its word.
fn isMissing(p: Expander.Param, colon: bool) bool {
    if (!p.set) return true;
    if (!colon) return false;
    if (p.list) return p.items.len == 0 or (p.items.len == 1 and p.items[0].len == 0);
    return p.text.len == 0;
}

fn isAllSubscript(subscript: []const u8) bool {
    return std.mem.eql(u8, subscript, "@") or std.mem.eql(u8, subscript, "*");
}

fn isName(text: []const u8) bool {
    if (text.len == 0 or !isIdentStart(text[0])) return false;
    for (text[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// How an error message names a parameter: `name`, `name[sub]` or `$1`.
const Label = struct {
    name: []const u8,
    subscript: ?[]const u8,

    pub fn format(self: Label, w: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!isIdentStart(self.name[0])) try w.writeByte('$');
        try w.writeAll(self.name);
        if (self.subscript) |sub| try w.print("[{s}]", .{sub});
    }
};

/// Length of the parameter at the start of `s`: a name with an optional
/// `[subscript]`, a run of digits, or one special character.
fn paramLength(s: []const u8) ?usize {
    if (s.len == 0) return null;
    if (isIdentStart(s[0])) {
        var i: usize = 1;
        while (i < s.len and isIdentChar(s[i])) i += 1;
        if (i < s.len and s[i] == '[') return (compound.closeBracket(s, i) orelse return null) + 1;
        return i;
    }
    if (std.ascii.isDigit(s[0])) {
        var i: usize = 1;
        while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        return i;
    }
    if (std.mem.indexOfScalar(u8, "@*#?-$!", s[0]) != null) return 1;
    return null;
}

const ParamRef = struct { name: []const u8, subscript: ?[]const u8 };

/// Splits a parameter that `paramLength` accepted into name and subscript.
fn splitParam(s: []const u8) ParamRef {
    if (s.len > 0 and s[s.len - 1] == ']') {
        if (std.mem.indexOfScalar(u8, s, '[')) |open| return .{ .name = s[0..open], .subscript = s[open + 1 .. s.len - 1] };
    }
    return .{ .name = s, .subscript = null };
}

const Op = enum {
    none,
    length,
    names,
    keys,
    use_default,
    assign_default,
    fail_unset,
    use_alternate,
    remove_prefix,
    remove_suffix,
    replace,
    substring,
    upper,
    lower,
    transform,
};

/// A parsed `${...}`:
///
///     ${p} ${#p} ${!p} ${!prefix*} ${!a[@]}
///     ${p-w} ${p=w} ${p?w} ${p+w}, each also with `:`
///     ${p#pat} ${p##pat} ${p%pat} ${p%%pat}
///     ${p/pat/rep} ${p//pat/rep} ${p/#pat/rep} ${p/%pat/rep}
///     ${p:off} ${p:off:len} ${p^} ${p^^} ${p,} ${p,,} ${p@X}
const Braced = struct {
    name: []const u8 = "",
    subscript: ?[]const u8 = null,
    /// `${!name}`: the parameter that `name`'s value names.
    indirect: bool = false,
    op: Op = .none,
    /// `${p:-w}` rather than `${p-w}`: an empty value counts as unset.
    colon: bool = false,
    /// The doubled operators `##`, `%%`, `^^` and `,,`.
    twice: bool = false,
    /// `${!prefix*}` and `${!a[*]}` rather than their `@` forms.
    star: bool = false,
    mode: param_ops.ReplaceMode = .first,
    /// The word, pattern, transform letter or substring offset.
    word: []const u8 = "",
    /// The replacement or substring length, when present.
    word2: ?[]const u8 = null,
};

fn parseBraced(inner: []const u8) ?Braced {
    var b = Braced{};
    var rest = inner;
    if (rest.len > 1 and rest[0] == '#') {
        if (paramLength(rest[1..])) |n| {
            if (n == rest.len - 1) {
                const ref = splitParam(rest[1..]);
                return .{ .name = ref.name, .subscript = ref.subscript, .op = .length };
            }
        }
    }
    if (rest.len > 1 and rest[0] == '!') {
        rest = rest[1..];
        const last = rest[rest.len - 1];
        if ((last == '*' or last == '@') and isName(rest[0 .. rest.len - 1])) {
            return .{ .name = rest[0 .. rest.len - 1], .op = .names, .star = last == '*' };
        }
        b.indirect = true;
    }
    const n = paramLength(rest) orelse return null;
    const ref = splitParam(rest[0..n]);
    b.name = ref.name;
    b.subscript = ref.subscript;
    rest = rest[n..];
    if (rest.len == 0) {
        if (b.indirect) {
            if (ref.subscript) |sub| {
                if (isAllSubscript(sub)) return .{ .name = ref.name, .op = .keys, .star = sub[0] == '*' };
            }
        }
        return b;
    }
    switch (rest[0]) {
        ':' => {
            if (rest.len > 1 and std.mem.indexOfScalar(u8, "-=?+", rest[1]) != null) {
                b.colon = true;
                b.op = wordOp(rest[1]);
                b.word = rest[2..];
                return b;
            }
            b.op = .substring;
            const body = rest[1..];
            if (findTopLevel(body, ':')) |at| {
                b.word = body[0..at];
                b.word2 = body[at + 1 ..];
            } else {
                if (std.mem.trim(u8, body, " \t").len == 0) return null;
                b.word = body;
            }
        },
        '-', '=', '?', '+' => {
            b.op = wordOp(rest[0]);
            b.word = rest[1..];
        },
        '#', '%', '^', ',' => {
            b.op = switch (rest[0]) {
                '#' => .remove_prefix,
                '%' => .remove_suffix,
                '^' => .upper,
                else => .lower,
            };
            b.twice = rest.len > 1 and rest[1] == rest[0];
            b.word = rest[if (b.twice) 2 else 1..];
        },
        '/' => {
            b.op = .replace;
            var body = rest[1..];
            if (body.len > 0) {
                b.mode = switch (body[0]) {
                    '/' => .all,
                    '#' => .prefix,
                    '%' => .suffix,
                    else => .first,
                };
                if (b.mode != .first) body = body[1..];
            }
            if (findTopLevel(body, '/')) |at| {
                b.word = body[0..at];
                b.word2 = body[at + 1 ..];
            } else {
                b.word = body;
            }
        },
        '@' => {
            if (rest.len != 2 or std.mem.indexOfScalar(u8, "QEULuaAK", rest[1]) == null) return null;
            b.op = .transform;
            b.word = rest[1..2];
        },
        else => return null,
    }
    return b;
}

fn wordOp(c: u8) Op {
    return switch (c) {
        '-' => .use_default,
        '=' => .assign_default,
        '?' => .fail_unset,
        else => .use_alternate,
    };
}

/// The first `target` outside quotes, escapes, substitutions and parentheses.
fn findTopLevel(s: []const u8, target: u8) ?usize {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        switch (c) {
            '\\' => i += 2,
            '\'' => i = skipSingle(s, i + 1),
            '"' => i = skipDouble(s, i + 1),
            '`' => i = skipBacktick(s, i + 1),
            '$' => i = skipExpansion(s, i) orelse i + 1,
            else => {
                if (c == target and depth == 0) return i;
                if (c == '(') depth += 1;
                if (c == ')') depth -|= 1;
                i += 1;
            },
        }
    }
    return null;
}

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

/// The backtick closing a command substitution, skipping escaped backticks.
fn findClosingBacktick(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (s[i] == '`') return i;
    }
    return s.len;
}

fn skipSingle(s: []const u8, from: usize) usize {
    const end = std.mem.indexOfScalarPos(u8, s, from, '\'') orelse return s.len;
    return end + 1;
}

fn skipDouble(s: []const u8, from: usize) usize {
    const end = findClosingDouble(s, from);
    return if (end < s.len) end + 1 else s.len;
}

fn skipBacktick(s: []const u8, from: usize) usize {
    const end = findClosingBacktick(s, from);
    return if (end < s.len) end + 1 else s.len;
}

/// Steps past a `${...}` or `$(...)` group, or null at anything else.
fn skipExpansion(s: []const u8, i: usize) ?usize {
    if (i + 1 >= s.len or (s[i + 1] != '{' and s[i + 1] != '(')) return null;
    const close: u8 = if (s[i + 1] == '{') '}' else ')';
    const end = findMatching(s, i + 1, s[i + 1], close) orelse return s.len;
    return if (end < s.len) end + 1 else s.len;
}

const max_brace_depth = 32;
const max_brace_values = 4096;

const BraceGroup = struct {
    open: usize,
    close: usize,
};

/// The first brace group in `word` that stands for more than one word: a
/// top-level comma list or a `..` range. Quoted, escaped and `$`-substitution
/// braces are skipped.
fn findBrace(word: []const u8) ?BraceGroup {
    var i: usize = 0;
    while (i < word.len) {
        const c = word[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\'') {
            i = skipSingle(word, i + 1);
            continue;
        }
        if (c == '"') {
            i = skipDouble(word, i + 1);
            continue;
        }
        if (c == '`') {
            i = skipBacktick(word, i + 1);
            continue;
        }
        if (c == '$') {
            i = skipExpansion(word, i) orelse i + 1;
            continue;
        }
        if (c == '{') {
            if (findMatching(word, i, '{', '}')) |close| {
                const content = word[i + 1 .. close];
                if (hasTopLevelComma(content) or parseRange(content) != null) {
                    return .{ .open = i, .close = close };
                }
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    return null;
}

/// True when a brace body carries a comma that separates alternatives.
fn hasTopLevelComma(content: []const u8) bool {
    var depth: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\'') {
            i = skipSingle(content, i + 1);
            continue;
        }
        if (c == '"') {
            i = skipDouble(content, i + 1);
            continue;
        }
        if (c == '$') {
            i = skipExpansion(content, i) orelse i + 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
        } else if (c == ',' and depth == 0) {
            return true;
        }
        i += 1;
    }
    return false;
}

fn splitTopLevel(arena: std.mem.Allocator, content: []const u8, out: *std.ArrayList([]const u8)) !void {
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\'') {
            i = skipSingle(content, i + 1);
            continue;
        }
        if (c == '"') {
            i = skipDouble(content, i + 1);
            continue;
        }
        if (c == '$') {
            i = skipExpansion(content, i) orelse i + 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
        } else if (c == '}') {
            if (depth > 0) depth -= 1;
        } else if (c == ',' and depth == 0) {
            try out.append(arena, content[start..i]);
            start = i + 1;
        }
        i += 1;
    }
    try out.append(arena, content[start..]);
}

const Range = union(enum) {
    ints: struct { lo: i64, hi: i64 },
    chars: struct { lo: u8, hi: u8 },
};

fn rangeLength(lo: i64, hi: i64) u64 {
    const a: u64 = @bitCast(lo);
    const b: u64 = @bitCast(hi);
    return if (lo <= hi) b -% a else a -% b;
}

/// A `{lo..hi}` range: numeric when both ends are integers, otherwise single
/// characters.
fn parseRange(content: []const u8) ?Range {
    const at = topLevelRangeSplit(content) orelse return null;
    const a = content[0..at];
    const b = content[at + 2 ..];
    if (a.len == 0 or b.len == 0) return null;
    const lo: ?i64 = std.fmt.parseInt(i64, a, 0) catch null;
    const hi: ?i64 = std.fmt.parseInt(i64, b, 0) catch null;
    if (lo != null and hi != null) return .{ .ints = .{ .lo = lo.?, .hi = hi.? } };
    if (a.len == 1 and b.len == 1) return .{ .chars = .{ .lo = a[0], .hi = b[0] } };
    return null;
}

/// The offset of the single top-level `..`, or null if there is none or more
/// than one.
fn topLevelRangeSplit(content: []const u8) ?usize {
    var depth: usize = 0;
    var found: ?usize = null;
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (c == '\\') {
            i += 2;
            continue;
        }
        if (c == '\'') {
            i = skipSingle(content, i + 1);
            continue;
        }
        if (c == '"') {
            i = skipDouble(content, i + 1);
            continue;
        }
        if (c == '$') {
            i = skipExpansion(content, i) orelse i + 1;
            continue;
        }
        if (c == '{') {
            depth += 1;
            i += 1;
            continue;
        }
        if (c == '}') {
            if (depth > 0) depth -= 1;
            i += 1;
            continue;
        }
        if (c == '.' and depth == 0 and i + 1 < content.len and content[i + 1] == '.') {
            if (found != null) return null;
            found = i;
            i += 2;
            continue;
        }
        i += 1;
    }
    return found;
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

fn identitySubst(_: *shell.Shell, src: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    return arena.dupe(u8, src);
}

test "$@ and $* expand the positional parameters" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    sh.positional = &.{ "a b", "c" };

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$@", &fields);
    try testing.expectEqual(@as(usize, 3), fields.items.len);
    try testing.expectEqualStrings("a", fields.items[0]);
    try testing.expectEqualStrings("b", fields.items[1]);
    try testing.expectEqualStrings("c", fields.items[2]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "x$@y", &fields);
    try testing.expectEqual(@as(usize, 3), fields.items.len);
    try testing.expectEqualStrings("xa", fields.items[0]);
    try testing.expectEqualStrings("b", fields.items[1]);
    try testing.expectEqualStrings("cy", fields.items[2]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$@\"", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("a b", fields.items[0]);
    try testing.expectEqualStrings("c", fields.items[1]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$*\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("a b c", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$*", &fields);
    try testing.expectEqual(@as(usize, 3), fields.items.len);

    fields.clearRetainingCapacity();
    sh.positional = &.{};
    try expandWord(&sh, arena, "\"$@\"", &fields);
    try testing.expectEqual(@as(usize, 0), fields.items.len);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$*\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$#", &fields);
    try testing.expectEqualStrings("0", fields.items[0]);
}

test "$- reports option letters, never its literal text" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try testing.expectEqualStrings("", try expandLiteral(&sh, arena, "$-"));

    sh.interactive = true;
    try testing.expectEqualStrings("i", try expandLiteral(&sh, arena, "$-"));

    sh.login = true;
    try testing.expectEqualStrings("il", try expandLiteral(&sh, arena, "$-"));
}

test "$10 is one digit followed by a literal zero" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    sh.script_name = "wsh";
    sh.positional = &.{ "one", "two" };

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$10", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("one0", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$2", &fields);
    try testing.expectEqualStrings("two", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$0", &fields);
    try testing.expectEqualStrings("wsh", fields.items[0]);
}

test "an escaped backtick does not close a substitution" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    sh.subst_runner = identitySubst;

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "`hi`", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("hi", fields.items[0]);

    try testing.expectEqualStrings("a\\`b", try expandLiteral(&sh, arena, "`a\\`b`"));
}

test "IFS drives field splitting" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("x", .{ .string = "a:b::c" });
    try sh.setVar("IFS", .{ .string = ":" });

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$x", &fields);
    try testing.expectEqual(@as(usize, 4), fields.items.len);
    try testing.expectEqualStrings("a", fields.items[0]);
    try testing.expectEqualStrings("b", fields.items[1]);
    try testing.expectEqualStrings("", fields.items[2]);
    try testing.expectEqualStrings("c", fields.items[3]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$x\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("a:b::c", fields.items[0]);

    // IFS whitespace collapses and is swallowed around a real delimiter.
    try sh.setVar("y", .{ .string = "a : b" });
    try sh.setVar("IFS", .{ .string = " :" });
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$y", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("a", fields.items[0]);
    try testing.expectEqualStrings("b", fields.items[1]);

    // `"$*"` joins with the first character of IFS.
    try sh.setVar("IFS", .{ .string = ":" });
    sh.positional = &.{ "a", "b" };
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"$*\"", &fields);
    try testing.expectEqualStrings("a:b", fields.items[0]);

    // Without IFS the default separators apply.
    _ = sh.unsetVar("IFS");
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "$x", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("a:b::c", fields.items[0]);
}

test "arithmetic expansion" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("n", .{ .int = 10 });
    try sh.setVar("s", .{ .string = "2" });

    try testing.expectEqualStrings("5", try expandLiteral(&sh, arena, "$((1 + 2 * 2))"));
    try testing.expectEqualStrings("1", try expandLiteral(&sh, arena, "$((10 % 3))"));
    try testing.expectEqualStrings("2", try expandLiteral(&sh, arena, "$((7 / 3))"));
    try testing.expectEqualStrings("-1", try expandLiteral(&sh, arena, "$((-1))"));
    try testing.expectEqualStrings("3", try expandLiteral(&sh, arena, "$(((1 + 2)))"));
    try testing.expectEqualStrings("10", try expandLiteral(&sh, arena, "$((n))"));
    try testing.expectEqualStrings("12", try expandLiteral(&sh, arena, "$(( ${n} + s ))"));
    try testing.expectEqualStrings("16", try expandLiteral(&sh, arena, "$((2 * $((n - 2))))"));
    try testing.expectEqualStrings("255", try expandLiteral(&sh, arena, "$((0xff))"));
    try testing.expectEqualStrings("0", try expandLiteral(&sh, arena, "$(( ))"));
    try testing.expectEqualStrings("42", try expandLiteral(&sh, arena, "$((missing + 42))"));

    try testing.expectError(error.DivisionByZero, expandLiteral(&sh, arena, "$((1 / 0))"));
}

test "brace expansion lists, ranges and nesting" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "a{b,c}d", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("abd", fields.items[0]);
    try testing.expectEqualStrings("acd", fields.items[1]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "a{b,c}d{e,f}", &fields);
    try testing.expectEqual(@as(usize, 4), fields.items.len);
    try testing.expectEqualStrings("abde", fields.items[0]);
    try testing.expectEqualStrings("abdf", fields.items[1]);
    try testing.expectEqualStrings("acde", fields.items[2]);
    try testing.expectEqualStrings("acdf", fields.items[3]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{1..3}", &fields);
    try testing.expectEqual(@as(usize, 3), fields.items.len);
    try testing.expectEqualStrings("1", fields.items[0]);
    try testing.expectEqualStrings("2", fields.items[1]);
    try testing.expectEqualStrings("3", fields.items[2]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{5..1}", &fields);
    try testing.expectEqual(@as(usize, 5), fields.items.len);
    try testing.expectEqualStrings("5", fields.items[0]);
    try testing.expectEqualStrings("1", fields.items[4]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{a..c}", &fields);
    try testing.expectEqual(@as(usize, 3), fields.items.len);
    try testing.expectEqualStrings("a", fields.items[0]);
    try testing.expectEqualStrings("b", fields.items[1]);
    try testing.expectEqualStrings("c", fields.items[2]);

    // A group with neither a comma nor a range stays literal.
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{x}", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("{x}", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{}", &fields);
    try testing.expectEqualStrings("{}", fields.items[0]);

    // An oversized range is left literal instead of generating forever.
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "{-9223372036854775808..9223372036854775807}", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("{-9223372036854775808..9223372036854775807}", fields.items[0]);

    // Quoted braces stay literal and `${...}` is not a brace group.
    try sh.setVar("v", .{ .string = "value" });
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"{1..3}\"", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("{1..3}", fields.items[0]);

    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "${v}", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("value", fields.items[0]);

    // A later expansion still attaches to each generated word.
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "x{1..2}$v", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("x1value", fields.items[0]);
    try testing.expectEqualStrings("x2value", fields.items[1]);
}

test "parameter operators" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    sh.scratch_override = arena;
    try sh.setVar("p", .{ .string = "/a/b/c.tar.gz" });
    try sh.setEnv("HOME", "/home/me");

    const cases = [_][2][]const u8{
        .{ "${p%/*}", "/a/b" },
        .{ "${p%%.*}", "/a/b/c" },
        .{ "${p#*/}", "a/b/c.tar.gz" },
        .{ "${p##*/}", "c.tar.gz" },
        .{ "${p#\"*\"}", "/a/b/c.tar.gz" },
        .{ "${p/b/B}", "/a/B/c.tar.gz" },
        .{ "${p//\\//_}", "_a_b_c.tar.gz" },
        .{ "${p:3:3}", "b/c" },
        .{ "${p: -2}", "gz" },
        .{ "${unset:-$HOME}", "/home/me" },
        .{ "${unset-~}", "/home/me" },
        .{ "${p:+set}", "set" },
        .{ "${#p}", "13" },
        .{ "${p^^}", "/A/B/C.TAR.GZ" },
        .{ "${p@Q}", "'/a/b/c.tar.gz'" },
        .{ "${!p*}", "p" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], try expandLiteral(&sh, arena, case[0]));
    }

    try testing.expectEqualStrings("abc", try expandLiteral(&sh, arena, "${fresh:=abc}"));
    try testing.expectEqualStrings("abc", sh.getVar("fresh").?.string);

    sh.default_err = -1;
    try testing.expectError(error.BadSubstitution, expandLiteral(&sh, arena, "${p;x}"));
    try testing.expectError(error.BadSubstitution, expandLiteral(&sh, arena, "${p:}"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${unset:?}"));
    try testing.expectError(error.BadSubstitution, expandLiteral(&sh, arena, "${p:1:-20}"));
}

test "set -u rejects unset parameters outside the default forms" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    sh.default_err = -1;
    sh.options.nounset = true;

    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "$nope"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${nope}"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${#nope}"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${nope#x}"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "$1"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "$!"));
    try testing.expectEqualStrings("d", try expandLiteral(&sh, arena, "${nope-d}"));
    try testing.expectEqualStrings("e", try expandLiteral(&sh, arena, "${nope:-e}"));
    try testing.expectEqualStrings("", try expandLiteral(&sh, arena, "${nope+f}"));
    try testing.expectEqualStrings("", try expandLiteral(&sh, arena, "$@$*"));
    try testing.expectEqualStrings("", try expandLiteral(&sh, arena, "${nope[@]}"));

    try sh.setVar("a", .{ .list = &.{.{ .string = "x" }} });
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${a[3]}"));
    try testing.expectEqualStrings("x", try expandLiteral(&sh, arena, "${a[0]}"));
    try sh.setVar("empty", .{ .list = &.{} });
    try testing.expectEqualStrings("0", try expandLiteral(&sh, arena, "${#empty[@]}"));
    try testing.expectError(error.UnboundVariable, expandLiteral(&sh, arena, "${#nope[@]}"));
}

test "arrays expand by element" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    try sh.setVar("a", .{ .list = &.{ .{ .string = "x y" }, .none, .{ .string = "z" } } });
    try sh.setVar("m", .{ .map = &.{ .{ .key = "k", .value = .{ .string = "v" } }, .{ .key = "j", .value = .{ .string = "w" } } } });

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "\"${a[@]}\"", &fields);
    try testing.expectEqual(@as(usize, 2), fields.items.len);
    try testing.expectEqualStrings("x y", fields.items[0]);

    try testing.expectEqualStrings("2", try expandLiteral(&sh, arena, "${#a[@]}"));
    try testing.expectEqualStrings("0 2", try expandLiteral(&sh, arena, "${!a[@]}"));
    try testing.expectEqualStrings("z", try expandLiteral(&sh, arena, "${a[-1]}"));
    try testing.expectEqualStrings("x y z", try expandLiteral(&sh, arena, "$a"));
    try testing.expectEqualStrings("v", try expandLiteral(&sh, arena, "${m[k]}"));
    try testing.expectEqualStrings("k j", try expandLiteral(&sh, arena, "${!m[@]}"));
    try testing.expectEqualStrings("x z", try expandLiteral(&sh, arena, "${a[@]% *}"));
    try testing.expectEqualStrings("3", try expandLiteral(&sh, arena, "$(( ${#a[@]} + 1 ))"));

    sh.current_line = 12;
    try testing.expectEqualStrings("12", try expandLiteral(&sh, arena, "$LINENO"));
}
