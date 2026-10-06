//! Syntax highlighting for the interactive line editor.
//!
//! Highlighting runs over the lexer's word-mode tokens. Whitespace is not part
//! of any token, so the gaps between tokens are copied through verbatim, which
//! keeps the rendered line byte-identical to what the user typed.

const std = @import("std");
const lexer = @import("../lexer.zig");
const shellmod = @import("../shell.zig");
const builtins = @import("../builtins.zig");
const proc = @import("../proc.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const red = "\x1b[31m";
pub const green = "\x1b[32m";
pub const yellow = "\x1b[33m";
pub const blue = "\x1b[34m";
pub const magenta = "\x1b[35m";
pub const cyan = "\x1b[36m";
pub const gray = "\x1b[90m";

pub const keyword = bold ++ magenta;

/// False when `NO_COLOR` is set to a non-empty value (https://no-color.org).
pub fn colorEnabled(sh: *const Shell) bool {
    const value = sh.getEnv("NO_COLOR") orelse return true;
    return value.len == 0;
}

const KeywordKind = enum {
    /// A command follows: `then`, `else`, `do`, `time`, `!`.
    command,
    /// An expression or arguments follow: wsh `if`/`while`, `fi`, `return`.
    argument,
    /// A name follows, then possibly `in`: `for`, `select`, `case`.
    name_then_in,
};

fn keywordKind(word: []const u8) ?KeywordKind {
    const table = [_]struct { []const u8, KeywordKind }{
        .{ "then", .command },      .{ "else", .command },        .{ "do", .command },
        .{ "time", .command },      .{ "!", .command },           .{ "if", .argument },
        .{ "elif", .argument },     .{ "while", .argument },      .{ "until", .argument },
        .{ "fi", .argument },       .{ "done", .argument },       .{ "esac", .argument },
        .{ "function", .argument }, .{ "fn", .argument },         .{ "let", .argument },
        .{ "return", .argument },   .{ "break", .argument },      .{ "continue", .argument },
        .{ "for", .name_then_in },  .{ "select", .name_then_in }, .{ "case", .name_then_in },
    };
    for (table) |entry| {
        if (std.mem.eql(u8, entry[0], word)) return entry[1];
    }
    return null;
}

/// Appends `src` with ANSI colours to `out`.
pub fn render(out: *std.Io.Writer, sh: *Shell, src: []const u8) !void {
    if (!colorEnabled(sh)) return out.writeAll(src);

    var lx = lexer.Lexer.init(src);
    var prev_end: usize = 0;
    var expect_command = true;
    var expect_filename = false;
    // Counts down the words of `for NAME in`, `case WORD in`.
    var in_countdown: u8 = 0;

    while (true) {
        const tok = lx.next();
        if (tok.tag == .eof) break;

        // Copy the whitespace the lexer skipped.
        if (tok.start > prev_end) try out.writeAll(src[prev_end..tok.start]);
        prev_end = @min(tok.start + tok.text.len, src.len);

        switch (tok.tag) {
            .word => {
                if (expect_filename) {
                    try out.writeAll(yellow);
                    try out.writeAll(tok.text);
                    try out.writeAll(reset);
                    expect_filename = false;
                    continue;
                }
                if (expect_command) {
                    if (keywordKind(tok.text)) |kind| {
                        try out.writeAll(keyword);
                        try out.writeAll(tok.text);
                        try out.writeAll(reset);
                        expect_command = kind == .command;
                        in_countdown = if (kind == .name_then_in) 2 else 0;
                        continue;
                    }
                    try writeCommandWord(out, sh, tok.text);
                    expect_command = false;
                } else if (in_countdown == 1 and std.mem.eql(u8, tok.text, "in")) {
                    try out.writeAll(keyword);
                    try out.writeAll(tok.text);
                    try out.writeAll(reset);
                    in_countdown = 0;
                } else {
                    try writeArgument(out, sh, tok.text);
                    if (in_countdown > 0) in_countdown -= 1;
                }
            },
            .out, .out_append, .in => {
                try out.writeAll(magenta);
                try out.writeAll(tok.text);
                try out.writeAll(reset);
                expect_filename = true;
            },
            .pipe, .pipepipe, .semi, .amp, .ampamp => {
                try out.writeAll(magenta);
                try out.writeAll(tok.text);
                try out.writeAll(reset);
                expect_command = true;
                in_countdown = 0;
            },
            .lbrace, .rbrace => {
                try out.writeAll(magenta);
                try out.writeAll(tok.text);
                try out.writeAll(reset);
                expect_command = true;
                in_countdown = 0;
            },
            .newline => {
                try out.writeAll("\n");
                expect_command = true;
                in_countdown = 0;
            },
            .invalid => {
                try out.writeAll(red);
                try out.writeAll(tok.text);
                try out.writeAll(reset);
            },
            else => try out.writeAll(tok.text),
        }
    }

    if (prev_end < src.len) try out.writeAll(src[prev_end..]);
}

/// Colours a word in command position by how it would actually resolve.
fn writeCommandWord(out: *std.Io.Writer, sh: *Shell, word: []const u8) !void {
    if (!isPlainName(word)) {
        try writeArgument(out, sh, word);
        return;
    }

    const colour: []const u8 = if (builtins.isBuiltin(word) or
        sh.getFunc(word) != null or
        sh.getAlias(word) != null or
        isExecBuiltin(word))
        bold ++ cyan
    else if (resolves(sh, word))
        bold ++ green
    else
        bold ++ red;

    try out.writeAll(colour);
    try out.writeAll(word);
    try out.writeAll(reset);
}

fn isExecBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "source") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, ".");
}

fn resolves(sh: *Shell, name: []const u8) bool {
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        // An explicit path: no need to allocate, just test it.
        var buf: [std.os.linux.PATH_MAX]u8 = undefined;
        if (name.len + 1 > buf.len) return false;
        @memcpy(buf[0..name.len], name);
        buf[name.len] = 0;
        const fs = @import("../fs.zig");
        return fs.isExecutable(buf[0..name.len :0]);
    }

    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const resolved = proc.resolve(arena_state.allocator(), name, sh.pathEnv()) catch return false;
    return resolved != null;
}

fn isPlainName(word: []const u8) bool {
    if (word.len == 0) return false;
    for (word) |c| {
        switch (c) {
            '\'', '"', '$', '*', '?', '[', ']', '\\', '~', '=' => return false,
            else => {},
        }
    }
    return true;
}

/// Colours the quoted spans and variable references inside an argument.
fn writeArgument(out: *std.Io.Writer, sh: *Shell, word: []const u8) !void {
    _ = sh;
    var i: usize = 0;
    while (i < word.len) {
        const c = word[i];
        if (c == '\'' or c == '"') {
            const end = quoteEnd(word, i);
            try out.writeAll(yellow);
            try out.writeAll(word[i..end]);
            try out.writeAll(reset);
            i = end;
            continue;
        }
        if (c == '$') {
            const end = variableEnd(word, i);
            try out.writeAll(blue);
            try out.writeAll(word[i..end]);
            try out.writeAll(reset);
            i = end;
            continue;
        }
        if (c == '\\' and i + 1 < word.len) {
            try out.writeAll(gray);
            try out.writeAll(word[i .. i + 2]);
            try out.writeAll(reset);
            i += 2;
            continue;
        }
        try out.writeAll(word[i .. i + 1]);
        i += 1;
    }
}

fn quoteEnd(word: []const u8, start: usize) usize {
    const quote = word[start];
    var i = start + 1;
    while (i < word.len) : (i += 1) {
        if (quote == '"' and word[i] == '\\' and i + 1 < word.len) {
            i += 1;
            continue;
        }
        if (word[i] == quote) return i + 1;
    }
    return word.len;
}

fn variableEnd(word: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= word.len) return i;
    if (word[i] == '{') {
        while (i < word.len and word[i] != '}') i += 1;
        return if (i < word.len) i + 1 else i;
    }
    while (i < word.len and (std.ascii.isAlphanumeric(word[i]) or word[i] == '_' or word[i] == '?' or word[i] == '$' or word[i] == '!' or word[i] == '#')) i += 1;
    return i;
}

test "highlighting preserves the source text" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    const src = "ls -la | grep 'x y' > out.txt && echo $HOME";
    try render(&allocating.writer, &sh, src);

    // Strip ANSI sequences and compare with the original.
    const rendered = allocating.writer.buffered();
    var plain: std.ArrayList(u8) = .empty;
    defer plain.deinit(std.testing.allocator);
    var i: usize = 0;
    while (i < rendered.len) {
        if (rendered[i] == 0x1b) {
            while (i < rendered.len and rendered[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        try plain.append(std.testing.allocator, rendered[i]);
        i += 1;
    }
    try std.testing.expectEqualStrings(src, plain.items);
}

test "keywords are highlighted and NO_COLOR disables colour" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();

    try render(&allocating.writer, &sh, "for x in a b; do echo $x; done");
    const rendered = allocating.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, rendered, keyword ++ "for" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, keyword ++ "in" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, keyword ++ "do" ++ reset) != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, keyword ++ "done" ++ reset) != null);
    // `a` after `in` is an ordinary argument, not a keyword.
    try std.testing.expect(std.mem.indexOf(u8, rendered, keyword ++ "a") == null);

    allocating.writer.end = 0;
    try render(&allocating.writer, &sh, "case $x in a) echo;; esac");
    try std.testing.expect(std.mem.indexOf(u8, allocating.writer.buffered(), keyword ++ "in" ++ reset) != null);

    try sh.setEnv("NO_COLOR", "1");
    allocating.writer.end = 0;
    try render(&allocating.writer, &sh, "if true; then echo hi; fi");
    try std.testing.expectEqualStrings("if true; then echo hi; fi", allocating.writer.buffered());
}
