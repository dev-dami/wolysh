//! Word expansion: quote removal, escapes, `$` interpolation, `~`, command
//! substitution, field splitting and globbing.
//!
//! The scanner walks the raw word text (quotes included, as the lexer left it)
//! and builds fields directly. Text that came from a *quoted* context is written
//! out backslash-escaped, so the later splitting and globbing stages treat it as
//! literal without needing a second quoting pass: `\*` reaches the glob matcher
//! as "a literal star", and `"$x"` never splits.

const std = @import("std");
const linux = std.os.linux;
const shell = @import("shell.zig");
const glob = @import("glob.zig");
const arith = @import("arith.zig");
const value = @import("value.zig");
const fs = @import("fs.zig");
const lexer = @import("lexer.zig");
const sys = @import("sys.zig");
const procsub = @import("executor/procsub.zig");
const redirect = @import("executor/redirect.zig");
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
    BraceExpansionTooLarge,
    /// Already reported to the user (`failglob`, a failed `<(...)`); the
    /// command does not run and the status is 1.
    ExecutionFailed,
    /// A malformed or failed `${...}`; the message has been printed.
    BadSubstitution,
    /// `set -u` met an unset parameter, or `${name?word}` fired; the message
    /// has been printed.
    UnboundVariable,
} || std.mem.Allocator.Error;

/// Writes an expansion error to the shell's stderr.
pub fn printError(sh: *const shell.Shell, comptime fmt: []const u8, args: anytype) void {
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
    /// A single pattern (a `case` item or a `${name#pattern}` operand): no
    /// splitting, and quoted characters stay backslash-escaped so they match
    /// literally.
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

/// Expands a word to one glob pattern for `glob.matchSegment`: quoted parts
/// are escaped, unquoted expansions keep their metacharacters live.
pub fn expandPattern(sh: *shell.Shell, arena: std.mem.Allocator, word: []const u8) Error![]const u8 {
    var ex = Expander{ .sh = sh, .arena = arena, .mode = .pattern };
    try ex.scan(word);
    return arena.dupe(u8, ex.buf.items);
}

/// Expands the value of a `NAME=value` assignment to one value. Like
/// `expandLiteral`, but `~` also expands after every unquoted `:`, so
/// `PATH=~/bin:~/.local/bin` works.
pub fn expandAssignment(sh: *shell.Shell, arena: std.mem.Allocator, word: []const u8) Error![]const u8 {
    var ex = Expander{ .sh = sh, .arena = arena, .mode = .literal, .assignment = true };
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
/// The `print` builtin's arguments differ in one way: a bare identifier that
/// names a shell variable is a reference to it, so `for f in *.rs { print f }`
/// prints the file. Quote it (`print "f"`) to get the literal text instead.
/// Every other command receives its words literally.
pub fn expandCommand(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    words: []const []const u8,
    out: *std.ArrayList([]const u8),
) Error!void {
    if (words.len == 0) return;
    const start = out.items.len;
    try expandWord(sh, arena, words[0], out);
    const name = if (out.items.len > start) out.items[start] else "";
    const bare_vars = std.mem.eql(u8, name, "print");
    const declaration = declarationKind(name);
    for (words[1..]) |word| {
        if (declaration != .none) {
            try expandDeclarationArgument(sh, arena, word, out, declaration == .arrays);
        } else if (bare_vars) {
            try expandArgument(sh, arena, word, out);
        } else {
            try expandWord(sh, arena, word, out);
        }
    }
}

const Declaration = enum { none, scalars, arrays };

/// Builtins whose `NAME=value` arguments are assignments; `declare`, `typeset`
/// and `local` also take `NAME=(...)` lists.
fn declarationKind(name: []const u8) Declaration {
    const eql = std.mem.eql;
    if (eql(u8, name, "declare") or eql(u8, name, "typeset") or eql(u8, name, "local")) return .arrays;
    if (eql(u8, name, "export") or eql(u8, name, "readonly")) return .scalars;
    return .none;
}

/// An argument of a declaration builtin. An unquoted `NAME=(...)` reaches
/// `declare` unexpanded behind `compound.marker`, because only the builtin
/// knows whether it builds an indexed or an associative array. `NAME=value`
/// expands like an assignment: no splitting, no globbing.
fn expandDeclarationArgument(
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    word: []const u8,
    out: *std.ArrayList([]const u8),
    lists: bool,
) Error!void {
    if (lists and compound.openParen(word) != null and word[word.len - 1] == ')') {
        try out.append(arena, try std.mem.concat(arena, u8, &.{ &.{compound.marker}, word }));
        return;
    }
    if (assignmentEquals(word)) |eq| {
        const assigned = try expandAssignment(sh, arena, word[eq + 1 ..]);
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
    /// Set only for the `print` builtin's arguments, where `print file` means
    /// "print the value of `file`".
    bare_vars: bool = false,
    /// Words generated by brace expansion so far, against `max_brace_values`.
    brace_words: usize = 0,
    /// The whole word is an assignment value: `~` expands after each `:`.
    assignment: bool = false,
    /// Holds integers and option letters, which have a small fixed bound.
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
                ' ', '\t', '\n', '\r', '*', '?', '[', ']', '\\', '(', ')', '|' => {
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
        if (self.sh.getVar("IFS")) |v| {
            // Separators past the buffer are dropped, as for an environment IFS.
            var w = std.Io.Writer.fixed(buf);
            v.render(&w) catch {};
            return .{ .seps = w.buffered(), .user_set = true };
        }
        if (self.sh.getEnv("IFS")) |s| {
            const n = @min(s.len, buf.len);
            @memcpy(buf[0..n], s[0..n]);
            return .{ .seps = buf[0..n], .user_set = true };
        }
        return .{ .seps = " \t\n\r", .user_set = false };
    }

    /// Emits the pending field, globbing it when it still has live
    /// metacharacters. Does nothing outside command words.
    fn flush(self: *Expander) Error!void {
        if (self.mode != .command_word) return;
        if (!self.active) {
            self.buf.clearRetainingCapacity();
            return;
        }
        self.active = false;
        const field = self.buf.items;
        const options = self.sh.options;

        if (!options.noglob and glob.hasMetaOpts(field, options.extglob)) {
            var matches: std.ArrayList([]const u8) = .empty;
            const found = try glob.globWith(self.arena, field, &matches, .{
                .dotglob = options.dotglob,
                .nocase = options.nocaseglob,
                .globstar = options.globstar,
                .extglob = options.extglob,
            });
            if (found) {
                const out = self.out orelse unreachable;
                for (matches.items) |m| try out.append(self.arena, m);
                self.buf.clearRetainingCapacity();
                return;
            }
            if (options.failglob) {
                const pattern = try glob.unescape(self.arena, field);
                self.buf.clearRetainingCapacity();
                self.report("no match", pattern);
                return error.ExecutionFailed;
            }
            if (options.nullglob) {
                self.buf.clearRetainingCapacity();
                return;
            }
        }

        const text = try glob.unescape(self.arena, field);
        self.buf.clearRetainingCapacity();
        const out = self.out orelse unreachable;
        try out.append(self.arena, text);
    }

    /// Prints `wsh: <what>: <subject>` to the shell's standard error.
    fn report(self: *Expander, what: []const u8, subject: []const u8) void {
        var buf: [640]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "wsh: {s}: {s}\n", .{ what, subject }) catch "wsh: expansion error\n";
        sys.writeStr(self.sh.default_err, message);
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
                // Stored variables only: `print UID` stays a word.
                if (self.sh.vars.get(name)) |v| {
                    try self.appendQuoted(try self.renderValue(v));
                    try self.flush();
                    return;
                }
            }
        }

        var i: usize = 0;
        // Where an assignment value starts (`NAME=value`, including the
        // arguments of `export` and friends): `~` expands there and after each
        // `:` in it, as well as at the start of every word.
        const value_start: ?usize = if (self.assignment)
            0
        else if (self.mode == .command_word) assignmentValueStart(word) else null;

        while (i < word.len) {
            const c = word[i];
            switch (c) {
                '~' => {
                    const at_prefix = i == 0 or if (value_start) |start|
                        i == start or (i > start and word[i - 1] == ':')
                    else
                        false;
                    if (at_prefix) {
                        if (try self.expandTilde(word, i)) |next| {
                            i = next;
                            continue;
                        }
                    }
                    try self.appendRaw("~");
                    i += 1;
                },
                '<', '>' => {
                    if (i + 1 < word.len and word[i + 1] == '(') {
                        const close = findMatching(word, i + 1, '(', ')') orelse return Error.UnterminatedSubstitution;
                        const direction: procsub.Direction = if (c == '<') .read else .write;
                        const path = procsub.open(self.sh, self.arena, word[i + 2 .. close], direction) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.ProcessSubstitutionFailed => {
                                self.report("cannot start process substitution", word[i .. close + 1]);
                                return error.ExecutionFailed;
                            },
                        };
                        try self.appendQuoted(path);
                        i = close + 1;
                    } else {
                        try self.appendRaw(word[i .. i + 1]);
                        i += 1;
                    }
                },
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

    /// Expands the tilde-prefix starting at `word[i]`, which runs to the next
    /// `/` or `:`, and returns the index after it; null keeps the `~` literal
    /// (an unknown user, an unset variable, or a quoted or expanded character
    /// inside the prefix).
    fn expandTilde(self: *Expander, word: []const u8, i: usize) Error!?usize {
        var end = i + 1;
        while (end < word.len) : (end += 1) {
            const c = word[end];
            if (c == '/' or c == ':') break;
            switch (c) {
                '\'', '"', '\\', '$', '`' => return null,
                else => {},
            }
        }
        const name = word[i + 1 .. end];
        const dir = if (name.len == 0)
            self.sh.getEnv("HOME") orelse try passwdHome(self.arena, .{ .uid = linux.getuid() })
        else if (std.mem.eql(u8, name, "+"))
            self.sh.getEnv("PWD")
        else if (std.mem.eql(u8, name, "-"))
            self.sh.getEnv("OLDPWD")
        else
            try passwdHome(self.arena, .{ .name = name });
        try self.appendQuoted(dir orelse return null);
        return end;
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
            '\'' => {
                // `$'...'` is ANSI-C quoting, but only outside double quotes.
                if (quoted) {
                    try self.appendRaw("$");
                    i.* = start + 1;
                    return;
                }
                const end = ansiCEnd(s, start + 2);
                try self.appendQuoted(try decodeAnsiC(self.arena, s[start + 2 .. end]));
                i.* = if (end < s.len) end + 1 else s.len;
            },
            '"' => {
                // `$"..."` would be translated by bash; here it is plain "...".
                if (quoted) try self.appendRaw("$");
                i.* = start + 1;
            },
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
                    const result = try arith.evaluate(self.sh, self.arena, s[start + 3 .. close - 1]);
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
        const o = self.sh.options;
        const flags = [_]struct { u8, bool }{
            .{ 'a', o.allexport },
            .{ 'e', o.errexit },
            .{ 'f', o.noglob },
            .{ 'i', self.sh.interactive },
            .{ 'l', self.sh.login },
            .{ 'm', self.sh.job_control },
            .{ 'u', o.nounset },
            .{ 'x', o.xtrace },
            .{ 'C', o.noclobber },
            .{ 'E', o.errtrace },
            // History expansion only ever applies to interactive input.
            .{ 'H', o.histexpand and self.sh.interactive },
        };
        var n: usize = 0;
        for (flags) |flag| {
            if (!flag[1]) continue;
            self.scratch[n] = flag[0];
            n += 1;
        }
        return self.scratch[0..n];
    }

    /// Expands one brace group into the words it stands for and scans each.
    /// Returns false when the group is left literal instead.
    fn expandBrace(self: *Expander, word: []const u8, group: BraceGroup, depth: u32) Error!bool {
        const prefix = word[0..group.open];
        const suffix = word[group.close + 1 ..];
        const content = word[group.open + 1 .. group.close];

        if (parseRange(content)) |range| {
            const count = range.count();
            if (count > max_brace_values) return error.BraceExpansionTooLarge;
            var text: std.ArrayList(u8) = .empty;
            var index: u64 = 0;
            while (index < count) : (index += 1) {
                text.clearRetainingCapacity();
                try range.render(self.arena, &text, index);
                try self.emitBraceWord(prefix, text.items, suffix, depth);
            }
            return true;
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
        // Nested groups multiply, so the total is capped as well as each range.
        self.brace_words += 1;
        if (self.brace_words > max_brace_values) return error.BraceExpansionTooLarge;
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
            printError(self.sh, "wsh: ${{{s}}}: bad substitution\n", .{inner});
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
                    printError(self.sh, "wsh: {f}: cannot assign in this way\n", .{ref});
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
                printError(self.sh, "wsh: {f}: {s}\n", .{ ref, message });
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
        printError(self.sh, "wsh: {f}: unbound variable\n", .{ref});
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
            printError(self.sh, "wsh: {s}: bad array subscript\n", .{name});
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
            printError(self.sh, "wsh: {f}: invalid indirect expansion\n", .{Label{ .name = name, .subscript = subscript }});
            return error.BadSubstitution;
        }
        const target = ref.text;
        if ((paramLength(target) orelse 0) != target.len or target.len == 0) {
            printError(self.sh, "wsh: {s}: invalid variable name\n", .{target});
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
        printError(self.sh, "wsh: {d}: substring expression < 0\n", .{length});
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
                printError(self.sh, "wsh: {s}: readonly variable\n", .{name});
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

    /// An arithmetic operand: a subscript, offset or length.
    fn arithOperand(self: *Expander, text: []const u8) Error!i64 {
        return arith.evaluate(self.sh, self.arena, text);
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

    /// Lists and floats have no length bound, so values render into the arena.
    fn renderValue(self: *Expander, v: value.Value) Error![]const u8 {
        return switch (v) {
            .string => |s| s,
            .none => "",
            .boolean => |b| if (b) "true" else "false",
            // The allocating writer fails only when allocation does.
            .int, .float, .list, .map => v.renderAlloc(self.arena) catch error.OutOfMemory,
        };
    }

    fn substitute(self: *Expander, src: []const u8, quoted: bool) Error!void {
        const trimmed = std.mem.trim(u8, src, " \t\r\n");
        if (trimmed.len == 0) return;
        if (inputRedirectOnly(trimmed)) |target| return self.substituteFile(target, quoted);
        const runner = self.sh.subst_runner orelse return;
        const result = runner(self.sh, trimmed, self.arena) catch return Error.SubstitutionFailed;
        // Only trailing newlines are stripped, like every other shell.
        try self.emit(std.mem.trimEnd(u8, result, "\n"), quoted);
    }

    /// `$(< file)`: the file's contents, read without starting a process.
    fn substituteFile(self: *Expander, target: []const u8, quoted: bool) Error!void {
        const path = try expandLiteral(self.sh, self.arena, target);
        const z = try self.arena.dupeZ(u8, path);
        const rc = linux.openat(linux.AT.FDCWD, z.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            self.report(path, redirect.errnoText(err));
            self.sh.last_status = 1;
            return;
        }
        const fd: i32 = @intCast(rc);
        defer _ = linux.close(fd);
        var data: std.ArrayList(u8) = .empty;
        var buf: [8192]u8 = undefined;
        while (true) {
            const n = sys.readSome(fd, &buf) orelse {
                self.report(path, "read error");
                self.sh.last_status = 1;
                return;
            };
            if (n == 0) break;
            try data.appendSlice(self.arena, buf[0..n]);
        }
        self.sh.last_status = 0;
        try self.emit(std.mem.trimEnd(u8, data.items, "\n"), quoted);
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

/// The file word of a substitution that is only an input redirection,
/// `$(< file)` or `$(0< file)`.
fn inputRedirectOnly(src: []const u8) ?[]const u8 {
    var rest = src;
    if (rest.len > 0 and rest[0] == '0') rest = rest[1..];
    if (rest.len < 2 or rest[0] != '<' or rest[1] == '<' or rest[1] == '(' or rest[1] == '>') return null;
    var lx = lexer.Lexer.init(rest[1..]);
    const word = lx.next();
    if (word.tag != .word or lx.next().tag != .eof) return null;
    return word.text;
}

/// Where the value of an assignment-shaped word (`NAME=value`) starts.
fn assignmentValueStart(word: []const u8) ?usize {
    if (word.len == 0 or !isIdentStart(word[0])) return null;
    var i: usize = 1;
    while (i < word.len and isIdentChar(word[i])) i += 1;
    if (i < word.len and word[i] == '=') return i + 1;
    return null;
}

const PasswdKey = union(enum) { name: []const u8, uid: linux.uid_t };

/// A home directory from /etc/passwd. wsh has no libc, so there is no NSS:
/// only users listed in that file are found.
fn passwdHome(arena: std.mem.Allocator, key: PasswdKey) Error!?[]const u8 {
    const data = (fs.readFileAlloc(arena, "/etc/passwd", 16 << 20) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    }) orelse return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const user = fields.next() orelse continue;
        _ = fields.next() orelse continue; // password
        const uid = fields.next() orelse continue;
        _ = fields.next() orelse continue; // group
        _ = fields.next() orelse continue; // comment
        const home = fields.next() orelse continue;
        const matched = switch (key) {
            .name => |name| std.mem.eql(u8, user, name),
            .uid => |id| if (std.fmt.parseInt(linux.uid_t, uid, 10)) |parsed| parsed == id else |_| false,
        };
        if (matched) return home;
    }
    return null;
}

/// The quote closing a `$'...'` string whose body starts at `from`.
fn ansiCEnd(s: []const u8, from: usize) usize {
    var i = from;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == '\'') return i;
    }
    return s.len;
}

/// Decodes the body of `$'...'`. Unknown escapes keep their backslash, and a
/// NUL byte ends the string, as in bash.
fn decodeAnsiC(arena: std.mem.Allocator, body: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (c != '\\' or i + 1 >= body.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        const escape = body[i + 1];
        const start = i;
        i += 2;
        const byte: u8 = switch (escape) {
            'a' => 0x07,
            'b' => 0x08,
            'e', 'E' => 0x1b,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'v' => 0x0b,
            '\\', '\'', '"', '?' => escape,
            '0'...'7' => blk: {
                var code: u32 = escape - '0';
                var digits: usize = 1;
                while (digits < 3 and i < body.len and body[i] >= '0' and body[i] <= '7') : (digits += 1) {
                    code = code * 8 + (body[i] - '0');
                    i += 1;
                }
                break :blk @truncate(code);
            },
            'x' => blk: {
                const code = hexValue(body, &i, 2) orelse {
                    try out.appendSlice(arena, body[start..i]);
                    continue;
                };
                break :blk @truncate(code);
            },
            'u', 'U' => {
                const code = hexValue(body, &i, if (escape == 'u') 4 else 8) orelse {
                    try out.appendSlice(arena, body[start..i]);
                    continue;
                };
                if (code == 0) break;
                var utf8: [4]u8 = undefined;
                const point = std.math.cast(u21, code) orelse {
                    try out.appendSlice(arena, body[start..i]);
                    continue;
                };
                const n = std.unicode.utf8Encode(point, &utf8) catch {
                    try out.appendSlice(arena, body[start..i]);
                    continue;
                };
                try out.appendSlice(arena, utf8[0..n]);
                continue;
            },
            'c' => blk: {
                if (i >= body.len) {
                    try out.appendSlice(arena, body[start..i]);
                    continue;
                }
                const control = body[i];
                i += 1;
                break :blk if (control == '?') 0x7f else std.ascii.toUpper(control) & 0x1f;
            },
            else => {
                try out.appendSlice(arena, body[start..i]);
                continue;
            },
        };
        if (byte == 0) break;
        try out.append(arena, byte);
    }
    return out.toOwnedSlice(arena);
}

/// Up to `max` hex digits at `i.*`, advancing past them; null when there are
/// none.
fn hexValue(s: []const u8, i: *usize, max: usize) ?u32 {
    var code: u32 = 0;
    var digits: usize = 0;
    while (digits < max and i.* < s.len) : (digits += 1) {
        const d = std.fmt.charToDigit(s[i.*], 16) catch break;
        code = code * 16 + d;
        i.* += 1;
    }
    return if (digits == 0) null else code;
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
    // `$(...)` may hold a `case`, whose patterns end in an unmatched `)`.
    if (open == '(' and open_index > 0 and s[open_index - 1] == '$') return lexer.closingParen(s, open_index);
    var depth: usize = 0;
    var i = open_index;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\' and i + 1 < s.len) {
            i += 1;
            continue;
        }
        if (c == '$' and i + 1 < s.len and s[i + 1] == '\'') {
            // The loop's increment steps past the closing quote.
            i = ansiCEnd(s, i + 2);
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
/// Words one brace expansion may generate. bash has no limit short of memory;
/// this covers `{1..1000000}` with room to spare and fails loudly past it.
const max_brace_values = 1 << 22;

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
        if ((c == '<' or c == '>') and i + 1 < word.len and word[i + 1] == '(') {
            // The list of a process substitution is expanded when it runs.
            i = (findMatching(word, i + 1, '(', ')') orelse return null) + 1;
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

/// A `{lo..hi}` or `{lo..hi..step}` sequence. Letter ranges keep the
/// endpoints' byte values in `lo`/`hi`.
const Range = struct {
    lo: i64,
    hi: i64,
    /// Always at least 1; the direction comes from the endpoints.
    step: u64 = 1,
    /// Zero-padded width of every number, or 0 for none.
    width: usize = 0,
    letters: bool = false,

    fn count(self: Range) u64 {
        return rangeLength(self.lo, self.hi) / self.step +| 1;
    }

    /// Appends the `index`th element, counting from `lo` toward `hi`.
    fn render(self: Range, arena: std.mem.Allocator, out: *std.ArrayList(u8), index: u64) !void {
        const offset = @as(i128, index) * @as(i128, self.step);
        const n: i128 = if (self.lo <= self.hi) self.lo + offset else self.lo - offset;
        if (self.letters) return out.append(arena, @intCast(n));
        // printf's `%0*d`: the sign counts toward the width.
        var buf: [24]u8 = undefined;
        const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(n)}) catch unreachable;
        const used = digits.len + @intFromBool(n < 0);
        if (n < 0) try out.append(arena, '-');
        if (self.width > used) @memset(try out.addManyAsSlice(arena, self.width - used), '0');
        try out.appendSlice(arena, digits);
    }
};

fn rangeLength(lo: i64, hi: i64) u64 {
    const a: u64 = @bitCast(lo);
    const b: u64 = @bitCast(hi);
    return if (lo <= hi) b -% a else a -% b;
}

/// Parses a brace body as a sequence the way bash does: integer endpoints
/// (zero-padded when either has a leading zero, as in `{01..10}`) or single
/// letters, and an optional step whose sign is ignored.
fn parseRange(content: []const u8) ?Range {
    var parts: [3][]const u8 = undefined;
    var len: usize = 0;
    var it = std.mem.splitSequence(u8, content, "..");
    while (it.next()) |part| {
        if (len == parts.len) return null;
        parts[len] = part;
        len += 1;
    }
    if (len < 2) return null;

    var step: u64 = 1;
    if (len == 3) {
        const raw = braceInteger(parts[2]) orelse return null;
        if (raw == std.math.minInt(i64)) return null;
        step = @max(@abs(raw), 1);
    }

    if (braceInteger(parts[0])) |lo| {
        const hi = braceInteger(parts[1]) orelse return null;
        const padded = zeroPadded(parts[0]) or zeroPadded(parts[1]);
        return .{ .lo = lo, .hi = hi, .step = step, .width = if (padded) @max(parts[0].len, parts[1].len) else 0 };
    }
    const a = parts[0];
    const b = parts[1];
    if (a.len == 1 and b.len == 1 and std.ascii.isAlphabetic(a[0]) and std.ascii.isAlphabetic(b[0])) {
        return .{ .lo = a[0], .hi = b[0], .step = step, .letters = true };
    }
    return null;
}

/// An optional sign and decimal digits, within `i64`.
fn braceInteger(text: []const u8) ?i64 {
    const digits = if (text.len > 0 and (text[0] == '-' or text[0] == '+')) text[1..] else text;
    if (digits.len == 0) return null;
    for (digits) |c| {
        if (!std.ascii.isDigit(c)) return null;
    }
    return std.fmt.parseInt(i64, text, 10) catch null;
}

/// `01` and `-01` ask for padding; `0`, `-0` and `+01` do not.
fn zeroPadded(text: []const u8) bool {
    if (text.len > 1 and text[0] == '0') return true;
    return text.len > 2 and text[0] == '-' and text[1] == '0';
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
    try testing.expectEqualStrings("iH", try expandLiteral(&sh, arena, "$-"));

    sh.login = true;
    try testing.expectEqualStrings("ilH", try expandLiteral(&sh, arena, "$-"));

    sh.interactive = false;
    sh.login = false;
    sh.options.errexit = true;
    sh.options.nounset = true;
    sh.options.xtrace = true;
    try testing.expectEqualStrings("eux", try expandLiteral(&sh, arena, "$-"));
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

    // An oversized range is an error instead of generating forever.
    fields.clearRetainingCapacity();
    try testing.expectError(error.BraceExpansionTooLarge, expandWord(&sh, arena, "{-9223372036854775808..9223372036854775807}", &fields));

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

fn expectFields(sh: *shell.Shell, arena: std.mem.Allocator, word: []const u8, expected: []const []const u8) !void {
    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(sh, arena, word, &fields);
    try testing.expectEqual(expected.len, fields.items.len);
    for (expected, fields.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "brace ranges take steps and zero padding like bash" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try expectFields(&sh, arena, "{01..10..3}", &.{ "01", "04", "07", "10" });
    try expectFields(&sh, arena, "{1..010..4}", &.{ "001", "005", "009" });
    try expectFields(&sh, arena, "{-05..1..2}", &.{ "-05", "-03", "-01", "001" });
    try expectFields(&sh, arena, "{1..10..2}", &.{ "1", "3", "5", "7", "9" });
    try expectFields(&sh, arena, "{10..1..3}", &.{ "10", "7", "4", "1" });
    try expectFields(&sh, arena, "{1..5..-2}", &.{ "1", "3", "5" });
    try expectFields(&sh, arena, "{3..1..0}", &.{ "3", "2", "1" });
    try expectFields(&sh, arena, "{a..k..5}", &.{ "a", "f", "k" });
    try expectFields(&sh, arena, "{+01..2}", &.{ "1", "2" });
    try expectFields(&sh, arena, "{-0..1}", &.{ "0", "1" });
    try expectFields(&sh, arena, "f{9223372036854775806..9223372036854775807}", &.{ "f9223372036854775806", "f9223372036854775807" });
    // Not sequences: bash leaves these alone.
    try expectFields(&sh, arena, "{1..3..x}", &.{"{1..3..x}"});
    try expectFields(&sh, arena, "{1..2..3..4}", &.{"{1..2..3..4}"});
    try expectFields(&sh, arena, "{1_0..12}", &.{"{1_0..12}"});
    try expectFields(&sh, arena, "{0x1..0x3}", &.{"{0x1..0x3}"});
    try expectFields(&sh, arena, "{-..a}", &.{"{-..a}"});
    try expectFields(&sh, arena, "{1..a}", &.{"{1..a}"});
}

test "large brace ranges expand in full" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "{1..10001}", &fields);
    try testing.expectEqual(@as(usize, 10001), fields.items.len);
    try testing.expectEqualStrings("10001", fields.items[10000]);

    fields.clearRetainingCapacity();
    try testing.expectError(error.BraceExpansionTooLarge, expandWord(&sh, arena, "{0..4194304}", &fields));
}

test "list values render in full" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const items = try arena.alloc(value.Value, 1000);
    for (items, 0..) |*item, index| item.* = .{ .string = try std.fmt.allocPrint(arena, "item{d}", .{index}) };
    try sh.setVar("parts", .{ .list = items });

    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$parts", &fields);
    try testing.expectEqual(@as(usize, 1000), fields.items.len);
    try testing.expectEqualStrings("item999", fields.items[999]);

    try sh.setVar("big", .{ .float = 1e300 });
    try testing.expectEqual(@as(usize, 301), (try expandLiteral(&sh, arena, "$big")).len);
}

test "only print reads bare names as variables" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("status", .{ .string = "dirty" });
    var argv: std.ArrayList([]const u8) = .empty;
    try expandCommand(&sh, arena, &.{ "echo", "git", "status" }, &argv);
    try testing.expectEqualStrings("status", argv.items[2]);

    argv.clearRetainingCapacity();
    try expandCommand(&sh, arena, &.{ "print", "status", "\"status\"" }, &argv);
    try testing.expectEqualStrings("dirty", argv.items[1]);
    try testing.expectEqualStrings("status", argv.items[2]);
}

test "ANSI-C quoting" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try testing.expectEqualStrings("a\tb", try expandLiteral(&sh, arena, "$'a\\tb'"));
    try testing.expectEqualStrings("it's", try expandLiteral(&sh, arena, "$'it\\'s'"));
    try testing.expectEqualStrings("\x07\x08\x1b\x1b\x0c\n\r\x0b\\\"?", try expandLiteral(&sh, arena, "$'\\a\\b\\e\\E\\f\\n\\r\\v\\\\\\\"\\?'"));
    try testing.expectEqualStrings("AA\xc3\xa9\x01\x7f", try expandLiteral(&sh, arena, "$'\\x41\\101\\u00e9\\cA\\c?'"));
    try testing.expectEqualStrings("\xf0\x9f\x98\x80", try expandLiteral(&sh, arena, "$'\\U0001F600'"));
    try testing.expectEqualStrings("\xff", try expandLiteral(&sh, arena, "$'\\777'"));
    try testing.expectEqualStrings("\\xZ\\q", try expandLiteral(&sh, arena, "$'\\xZ\\q'"));
    try testing.expectEqualStrings("a", try expandLiteral(&sh, arena, "$'a\\0b'"));
    // Inside double quotes `$'` is literal, and `$"..."` is a plain string.
    try testing.expectEqualStrings("$'x'", try expandLiteral(&sh, arena, "\"$'x'\""));
    try testing.expectEqualStrings("dq", try expandLiteral(&sh, arena, "$\"dq\""));

    // The decoded text is quoted: no splitting, no globbing.
    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "$'a *\\n'", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("a *\n", fields.items[0]);
}

test "tilde prefixes" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setEnv("HOME", "/home/me");
    try sh.setEnv("PWD", "/work");
    try sh.setEnv("OLDPWD", "/before");

    try testing.expectEqualStrings("/home/me", try expandLiteral(&sh, arena, "~"));
    try testing.expectEqualStrings("/home/me/x", try expandLiteral(&sh, arena, "~/x"));
    try testing.expectEqualStrings("/work/a", try expandLiteral(&sh, arena, "~+/a"));
    try testing.expectEqualStrings("/before", try expandLiteral(&sh, arena, "~-"));
    try testing.expectEqualStrings("/root", try expandLiteral(&sh, arena, "~root"));
    try testing.expectEqualStrings("~no-such-user-xyz/a", try expandLiteral(&sh, arena, "~no-such-user-xyz/a"));
    try testing.expectEqualStrings("~/x", try expandLiteral(&sh, arena, "\"~\"/x"));
    try testing.expectEqualStrings("~/x", try expandLiteral(&sh, arena, "~\"/x\""));
    try testing.expectEqualStrings("a~", try expandLiteral(&sh, arena, "a~"));
    try testing.expectEqualStrings("/home/me:x", try expandLiteral(&sh, arena, "~:x"));

    // Assignment values expand after `=` and every `:`.
    try testing.expectEqualStrings("/home/me/bin:/home/me/lib", try expandAssignment(&sh, arena, "~/bin:~/lib"));
    var fields: std.ArrayList([]const u8) = .empty;
    try expandWord(&sh, arena, "PATH=~/bin:~", &fields);
    try testing.expectEqualStrings("PATH=/home/me/bin:/home/me", fields.items[0]);
    // Outside an assignment `:` is an ordinary character.
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "x:~", &fields);
    try testing.expectEqualStrings("x:~", fields.items[0]);

    // HOME with spaces stays one field.
    try sh.setEnv("HOME", "/home/a b");
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "~", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
}

test "glob options: noglob, nullglob, failglob" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var fields: std.ArrayList([]const u8) = .empty;
    sh.options.noglob = true;
    try expandWord(&sh, arena, "src/*.zig", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    try testing.expectEqualStrings("src/*.zig", fields.items[0]);
    sh.options.noglob = false;

    fields.clearRetainingCapacity();
    sh.options.nullglob = true;
    try expandWord(&sh, arena, "src/*.no-such-extension", &fields);
    try testing.expectEqual(@as(usize, 0), fields.items.len);
    // `[` alone is not a pattern, so the test command survives nullglob.
    try expandWord(&sh, arena, "[", &fields);
    try testing.expectEqual(@as(usize, 1), fields.items.len);
    sh.options.nullglob = false;

    fields.clearRetainingCapacity();
    sh.options.failglob = true;
    sh.default_err = -1;
    try testing.expectError(error.ExecutionFailed, expandWord(&sh, arena, "src/*.no-such-extension", &fields));
    sh.options.failglob = false;

    // A quoted group is literal, not an extended pattern.
    fields.clearRetainingCapacity();
    try expandWord(&sh, arena, "\"@(a|b)\"", &fields);
    try testing.expectEqualStrings("@(a|b)", fields.items[0]);
}

test "$(< file) reads the file without a command" {
    var sh = try testShell();
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const text = try expandLiteral(&sh, arena, "$(< src/tests.zig)");
    try testing.expect(std.mem.startsWith(u8, text, "//! Aggregates the unit tests."));
    try testing.expect(!std.mem.endsWith(u8, text, "\n"));

    sh.default_err = -1;
    try testing.expectEqualStrings("", try expandLiteral(&sh, arena, "$(< no-such-file-here)"));
    try testing.expectEqual(@as(u8, 1), sh.last_status);
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
