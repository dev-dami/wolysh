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

pub const Error = error{
    UnterminatedSubstitution,
    SubstitutionFailed,
    UnsupportedArithmetic,
    InvalidArithmetic,
    DivisionByZero,
    /// Already reported to the user (`failglob`, a failed `<(...)`); the
    /// command does not run and the status is 1.
    ExecutionFailed,
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

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
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
    /// The whole word is an assignment value: `~` expands after each `:`.
    assignment: bool = false,
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
        if (self.mode == .literal) return self.appendRaw(bytes);
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
            try self.appendRaw(bytes[start..i]);
        }
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
        if (self.mode == .literal) return;
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
                if (self.sh.getVar(name)) |v| {
                    try self.appendQuoted(self.renderValue(v));
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
                        if (try self.expandTilde(word, i, value_start != null)) |next| {
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

    /// Expands the tilde-prefix starting at `word[i]` and returns the index
    /// after it, or null to keep the `~` literal: an unknown user, an unset
    /// variable, or a quoted or expanded character inside the prefix.
    fn expandTilde(self: *Expander, word: []const u8, i: usize, in_assignment: bool) Error!?usize {
        var end = i + 1;
        while (end < word.len) : (end += 1) {
            const c = word[end];
            if (c == '/' or (in_assignment and c == ':')) break;
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
            '!' => {
                try self.emit(self.intText(self.sh.last_bg_pid), quoted);
                i.* = start + 2;
            },
            '#' => {
                try self.emit(self.intText(self.sh.positional.len), quoted);
                i.* = start + 2;
            },
            '@' => {
                try self.emitPositionals(quoted);
                i.* = start + 2;
            },
            '*' => {
                try self.emitStar(quoted);
                i.* = start + 2;
            },
            '-' => {
                try self.emit(self.optionLetters(), quoted);
                i.* = start + 2;
            },
            '0'...'9' => {
                const idx = s[start + 1] - '0';
                const text = if (idx == 0)
                    self.sh.script_name
                else if (idx <= self.sh.positional.len)
                    self.sh.positional[idx - 1]
                else
                    "";
                try self.emit(text, quoted);
                i.* = start + 2;
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

    /// `$@`: quoted, one field per positional parameter (so `"$@"` with no
    /// parameters yields no field); unquoted, each parameter is split.
    fn emitPositionals(self: *Expander, quoted: bool) Error!void {
        const params = self.sh.positional;
        for (params, 0..) |p, idx| {
            if (idx != 0) try self.flush();
            if (quoted) try self.appendQuoted(p) else try self.appendSplitRaw(p);
        }
        if (quoted and params.len == 0 and self.buf.items.len == 0) self.active = false;
    }

    /// `$*`: quoted, the parameters joined by the first character of `IFS` in
    /// one field (empty when there are none); unquoted, the same joined text is
    /// field-split.
    fn emitStar(self: *Expander, quoted: bool) Error!void {
        var seps: [64]u8 = undefined;
        const ifs = self.ifsSpec(&seps);
        const sep: []const u8 = if (!ifs.user_set) " " else if (ifs.seps.len > 0) ifs.seps[0..1] else "";
        const params = self.sh.positional;
        for (params, 0..) |p, idx| {
            if (idx != 0) {
                if (quoted) try self.appendQuoted(sep) else try self.appendSplitRaw(sep);
            }
            if (quoted) try self.appendQuoted(p) else try self.appendSplitRaw(p);
        }
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

    /// `${name}`, `${#name}`, `${name:-fallback}` and `${name:+alternate}`.
    /// `name` may also be a positional parameter (`${1}`, `${10}`) or one of
    /// the special parameters.
    fn expandBraced(self: *Expander, inner: []const u8, quoted: bool) Error!void {
        if (inner.len == 0) {
            try self.appendRaw("$");
            return;
        }

        // `${@}` and `${*}` keep their field semantics.
        if (std.mem.eql(u8, inner, "@")) return self.emitPositionals(quoted);
        if (std.mem.eql(u8, inner, "*")) return self.emitStar(quoted);

        if (inner[0] == '#') {
            // `${#}` is the positional count; `${#name}` is the length of name.
            const text = if (inner.len == 1 or inner[1] == '@' or inner[1] == '*')
                self.intText(self.sh.positional.len)
            else
                self.intText(self.lookup(inner[1..]).len);
            try self.emit(text, quoted);
            return;
        }
        if (std.mem.indexOf(u8, inner, ":-")) |at| {
            const val = self.paramText(inner[0..at]);
            try self.emit(if (val.len == 0) inner[at + 2 ..] else val, quoted);
            return;
        }
        if (std.mem.indexOf(u8, inner, ":+")) |at| {
            const val = self.paramText(inner[0..at]);
            try self.emit(if (val.len != 0) inner[at + 2 ..] else "", quoted);
            return;
        }
        try self.emit(self.paramText(inner), quoted);
    }

    /// Resolves one parameter name (the text inside `${...}` or after `$`) to a
    /// single value: positional parameters, the special parameters, then shell
    /// variables and the environment.
    fn paramText(self: *Expander, name: []const u8) []const u8 {
        if (name.len == 1) {
            switch (name[0]) {
                '?' => return self.intText(self.sh.last_status),
                '$' => return self.intText(self.sh.pid),
                '!' => return self.intText(self.sh.last_bg_pid),
                '-' => return self.optionLetters(),
                '@', '*' => {
                    var out: std.ArrayList(u8) = .empty;
                    const sep: []const u8 = if (name[0] == '@') " " else self.starSeparator();
                    for (self.sh.positional, 0..) |p, idx| {
                        if (idx != 0) out.appendSlice(self.arena, sep) catch return "";
                        out.appendSlice(self.arena, p) catch return "";
                    }
                    return out.items;
                },
                else => {},
            }
        }
        if (allDigits(name)) {
            const idx = std.fmt.parseInt(usize, name, 10) catch return "";
            if (idx == 0) return self.sh.script_name;
            return if (idx <= self.sh.positional.len) self.sh.positional[idx - 1] else "";
        }
        return self.lookup(name);
    }

    fn starSeparator(self: *Expander) []const u8 {
        var seps: [64]u8 = undefined;
        const ifs = self.ifsSpec(&seps);
        if (!ifs.user_set) return " ";
        return if (ifs.seps.len > 0) ifs.seps[0..1] else "";
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
