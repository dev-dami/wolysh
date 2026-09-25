//! Lexer for wolysh.
//!
//! wolysh has two lexing modes and the parser switches between them, because
//! the same characters mean different things in the two positions:
//!
//! * `.word` mode — used for command words. A token runs from the start of a
//!   word to the next unquoted whitespace or metacharacter, and quotes stay in
//!   the token text because the expander interprets them later. `=`, `[`, `]`,
//!   embedded parentheses, `+`, `-`, `*` and `/` are ordinary word characters
//!   here, so
//!   `cargo build --target=x`, `*.rs` and `ls -la` all lex as single words.
//!
//! * `.expr` mode — used inside language constructs. Quotes become string
//!   literals, identifiers and numbers become their own tokens, and the
//!   arithmetic/comparison operators turn into operators.
//!
//! In both modes `|`, `&`, `;`, `<`, `>` and `{`/`}` stay structural.

const std = @import("std");

pub const Mode = enum { word, expr };

pub const Tag = enum {
    eof,
    newline,
    /// A complete command word, quotes included.
    word,
    /// `"..."` in expression position; `text` is the content without quotes.
    dquote,
    /// `'...'` in expression position; `text` is the content without quotes.
    squote,
    ident,
    /// `text` is the literal, parsed by the parser.
    number,

    // structural, both modes
    pipe,
    pipepipe,
    amp,
    ampamp,
    semi,
    out,
    out_append,
    in,
    here_doc,
    lbrace,
    rbrace,

    // expression operators
    lparen,
    rparen,
    lbracket,
    rbracket,
    assign,
    plus_assign,
    minus_assign,
    plus,
    minus,
    star,
    slash,
    percent,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    bang,
    comma,
    dot,

    invalid,

    pub fn isOperator(self: Tag) bool {
        return switch (self) {
            .lparen, .rparen, .lbracket, .rbracket, .assign, .plus_assign, .minus_assign, .plus, .minus, .star, .slash, .percent, .eq, .ne, .lt, .le, .gt, .ge, .bang, .comma, .dot, .here_doc, .pipepipe, .ampamp, .amp, .pipe => true,
            else => false,
        };
    }
};

pub const Token = struct {
    tag: Tag,
    text: []const u8,
    /// Offset of the first byte of the token in the source.
    start: usize,
    line: usize,
    /// Brace depth *before* this token was lexed, so the parser can rewind a
    /// token in a different mode without double-counting braces.
    depth_before: u16,
    group_depth_before: u16,
};

pub const State = struct {
    pos: usize,
    line: usize,
    mode: Mode,
    depth: u16,
    group_depth: u16,
};

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\x0b' or c == '\x0c';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Characters that always end a command word, in both modes.
fn isStructural(c: u8) bool {
    return switch (c) {
        '|', '&', ';', '<', '>', '\n' => true,
        else => false,
    };
}

pub const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    line: usize = 1,
    mode: Mode = .word,
    depth: u16 = 0,
    group_depth: u16 = 0,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn save(self: *const Lexer) State {
        return .{ .pos = self.pos, .line = self.line, .mode = self.mode, .depth = self.depth, .group_depth = self.group_depth };
    }

    pub fn restore(self: *Lexer, s: State) void {
        self.pos = s.pos;
        self.line = s.line;
        self.mode = s.mode;
        self.depth = s.depth;
        self.group_depth = s.group_depth;
    }

    fn tok(self: *Lexer, tag: Tag, start: usize, depth_before: u16) Token {
        return .{
            .tag = tag,
            .text = self.src[start..self.pos],
            .start = start,
            .line = self.line,
            .depth_before = depth_before,
            .group_depth_before = self.group_depth,
        };
    }

    fn atComment(self: *const Lexer, p: usize) bool {
        // `#` opens a comment only at the start of a token: either the very
        // first byte, or preceded by whitespace/newline.
        if (p == 0) return true;
        return isSpace(self.src[p - 1]) or self.src[p - 1] == '\n';
    }

    /// Skips whitespace, line continuations and comments. Returns whether any
    /// whitespace was crossed.
    fn skipTrivia(self: *Lexer) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (isSpace(c)) {
                self.pos += 1;
                continue;
            }
            if (c == '\\' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\n') {
                self.pos += 2;
                self.line += 1;
                continue;
            }
            if (c == '#' and self.atComment(self.pos)) {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
                continue;
            }
            return;
        }
    }

    pub fn next(self: *Lexer) Token {
        self.skipTrivia();
        const start = self.pos;
        const depth_before = self.depth;
        if (self.pos >= self.src.len) return self.tok(.eof, start, depth_before);

        const c = self.src[self.pos];

        if (c == '\n') {
            self.pos += 1;
            const t = self.tok(.newline, start, depth_before);
            self.line += 1;
            return t;
        }

        switch (c) {
            '|' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '|') {
                    self.pos += 1;
                    return self.tok(.pipepipe, start, depth_before);
                }
                return self.tok(.pipe, start, depth_before);
            },
            '&' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return self.tok(.ampamp, start, depth_before);
                }
                return self.tok(.amp, start, depth_before);
            },
            ';' => {
                self.pos += 1;
                return self.tok(.semi, start, depth_before);
            },
            '>' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return self.tok(.out_append, start, depth_before);
                }
                if (self.mode == .expr) return self.tok(.gt, start, depth_before);
                return self.tok(.out, start, depth_before);
            },
            '<' => {
                self.pos += 1;
                if (self.mode == .word and self.pos < self.src.len and self.src[self.pos] == '<') {
                    self.pos += 1;
                    return self.tok(.here_doc, start, depth_before);
                }
                if (self.pos < self.src.len and self.src[self.pos] == '=' and self.mode == .expr) {
                    self.pos += 1;
                    return self.tok(.le, start, depth_before);
                }
                if (self.mode == .expr) return self.tok(.lt, start, depth_before);
                return self.tok(.in, start, depth_before);
            },
            '{' => {
                // A brace opens a block only when it stands alone, which keeps
                // `find . -exec ls {} \;` and `${var}` working.
                const standalone = self.pos + 1 >= self.src.len or
                    isSpace(self.src[self.pos + 1]) or
                    self.src[self.pos + 1] == '\n';
                if (standalone) {
                    self.pos += 1;
                    self.depth += 1;
                    return self.tok(.lbrace, start, depth_before);
                }
            },
            '}' => {
                if (self.depth > 0) {
                    self.pos += 1;
                    self.depth -= 1;
                    return self.tok(.rbrace, start, depth_before);
                }
            },
            '=' => if (self.mode == .expr) {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return self.tok(.eq, start, depth_before);
                }
                return self.tok(.assign, start, depth_before);
            },
            '+' => if (self.mode == .expr) {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return self.tok(.plus_assign, start, depth_before);
                }
                return self.tok(.plus, start, depth_before);
            },
            '-' => if (self.mode == .expr) {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return self.tok(.minus_assign, start, depth_before);
                }
                return self.tok(.minus, start, depth_before);
            },
            '*' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.star, start, depth_before);
            },
            '/' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.slash, start, depth_before);
            },
            '%' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.percent, start, depth_before);
            },
            '!' => if (self.mode == .expr) {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '=') {
                    self.pos += 1;
                    return self.tok(.ne, start, depth_before);
                }
                return self.tok(.bang, start, depth_before);
            },
            '(' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.lparen, start, depth_before);
            } else {
                self.pos += 1;
                const token = self.tok(.lparen, start, depth_before);
                self.group_depth += 1;
                return token;
            },
            ')' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.rparen, start, depth_before);
            } else {
                self.pos += 1;
                const token = self.tok(.rparen, start, depth_before);
                if (self.group_depth > 0) self.group_depth -= 1;
                return token;
            },
            '[' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.lbracket, start, depth_before);
            },
            ']' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.rbracket, start, depth_before);
            },
            ',' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.comma, start, depth_before);
            },
            '.' => if (self.mode == .expr and !(self.pos + 1 < self.src.len and isDigit(self.src[self.pos + 1]))) {
                self.pos += 1;
                return self.tok(.dot, start, depth_before);
            },
            else => {},
        }

        if (self.mode == .expr) {
            if (isDigit(c)) return self.scanNumber(start, depth_before);
            if (c == '$') {
                // `$(...)` is a command substitution wherever it appears; the
                // expression parser turns the resulting word into a string.
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '(') {
                    self.skipExpansion();
                    return self.tok(.word, start, depth_before);
                }
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '{') {
                    self.pos += 2;
                    const inner_start = self.pos;
                    while (self.pos < self.src.len and self.src[self.pos] != '}') self.pos += 1;
                    const inner = self.src[inner_start..self.pos];
                    if (self.pos < self.src.len) self.pos += 1;
                    var t = self.tok(.ident, start, depth_before);
                    t.text = inner;
                    return t;
                }
                if (self.pos + 1 < self.src.len and isIdentStart(self.src[self.pos + 1])) {
                    self.pos += 1;
                    const name_start = self.pos;
                    while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
                    var t = self.tok(.ident, start, depth_before);
                    t.text = self.src[name_start..self.pos];
                    return t;
                }
            }
            if (isIdentStart(c)) return self.scanIdent(start, depth_before);
            if (c == '"') return self.scanQuoted(start, depth_before, .dquote);
            if (c == '\'') return self.scanQuoted(start, depth_before, .squote);
            self.pos += 1;
            return self.tok(.invalid, start, depth_before);
        }

        // A bare command word. Quotes stay inside the token text so the expander
        // can tell quoted text from unquoted text, and text adjacent to a quoted
        // run joins the same word (`a"b c"d` is one word).
        return self.scanWord(start, depth_before);
    }

    fn scanNumber(self: *Lexer, start: usize, depth_before: u16) Token {
        while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        if (self.pos + 1 < self.src.len and self.src[self.pos] == '.' and isDigit(self.src[self.pos + 1])) {
            self.pos += 1;
            while (self.pos < self.src.len and isDigit(self.src[self.pos])) self.pos += 1;
        }
        return self.tok(.number, start, depth_before);
    }

    fn scanIdent(self: *Lexer, start: usize, depth_before: u16) Token {
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        return self.tok(.ident, start, depth_before);
    }

    /// Scans a quoted run. `text` covers the content only (quotes stripped).
    fn scanQuoted(self: *Lexer, start: usize, depth_before: u16, tag: Tag) Token {
        const quote = self.src[self.pos];
        self.pos += 1;
        const content_start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and quote == '"' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == quote) break;
            if (c == '\n') self.line += 1;
            // `${...}` and `$(...)` are their own nesting level: quotes inside
            // them belong to the inner construct, not to this string.
            if (c == '$' and self.pos + 1 < self.src.len and
                (self.src[self.pos + 1] == '(' or self.src[self.pos + 1] == '{'))
            {
                self.skipExpansion();
                continue;
            }
            self.pos += 1;
        }
        const content = self.src[content_start..self.pos];
        if (self.pos < self.src.len) self.pos += 1; // closing quote
        return .{
            .tag = tag,
            .text = content,
            .start = start,
            .line = self.line,
            .depth_before = depth_before,
            .group_depth_before = self.group_depth,
        };
    }

    /// Skips a `${...}` or `$(...)` group, honouring nesting and quotes.
    fn skipExpansion(self: *Lexer) void {
        const open = self.src[self.pos + 1];
        const close: u8 = if (open == '{') '}' else ')';
        self.pos += 2;
        var depth: usize = 1;
        while (self.pos < self.src.len and depth > 0) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == '\'') {
                self.pos += 1;
                while (self.pos < self.src.len and self.src[self.pos] != '\'') self.pos += 1;
                if (self.pos < self.src.len) self.pos += 1;
                continue;
            }
            if (c == '"') {
                self.pos += 1;
                while (self.pos < self.src.len and self.src[self.pos] != '"') {
                    if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) self.pos += 1;
                    self.pos += 1;
                }
                if (self.pos < self.src.len) self.pos += 1;
                continue;
            }
            if (c == '\n') self.line += 1;
            if (c == open) depth += 1;
            if (c == close) depth -= 1;
            self.pos += 1;
        }
    }

    /// Scans a bare command word, keeping quotes and escapes in the text.
    fn scanWord(self: *Lexer, start: usize, depth_before: u16) Token {
        var embedded_parens: usize = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (self.group_depth > 0 and c == '(') {
                embedded_parens += 1;
                self.pos += 1;
                continue;
            }
            if (c == ')' and self.group_depth > 0) {
                if (embedded_parens == 0) break;
                embedded_parens -= 1;
                self.pos += 1;
                continue;
            }
            if (isSpace(c) or isStructural(c)) break;
            if (c == '\\') {
                if (self.pos + 1 < self.src.len) {
                    if (self.src[self.pos + 1] == '\n') self.line += 1;
                    self.pos += 2;
                } else {
                    self.pos += 1;
                }
                continue;
            }
            if (c == '\'' or c == '"') {
                _ = self.scanQuoted(self.pos, depth_before, if (c == '"') .dquote else .squote);
                continue;
            }
            if (c == '$' and self.pos + 1 < self.src.len and
                (self.src[self.pos + 1] == '{' or self.src[self.pos + 1] == '('))
            {
                self.skipExpansion();
                continue;
            }
            self.pos += 1;
        }
        // An unquoted `{`/`}` that is not standalone still belongs to the word.
        return self.tok(.word, start, depth_before);
    }
};

test "word mode keeps operators inside words" {
    var lx = Lexer.init("cargo build --target=x86 *.rs");
    try std.testing.expectEqualStrings("cargo", lx.next().text);
    try std.testing.expectEqualStrings("build", lx.next().text);
    try std.testing.expectEqualStrings("--target=x86", lx.next().text);
    try std.testing.expectEqualStrings("*.rs", lx.next().text);
    try std.testing.expectEqual(Tag.eof, lx.next().tag);
}

test "structural operators" {
    var lx = Lexer.init("a | b && c > out >> more < in; d &");
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.pipe, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.ampamp, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.out, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.out_append, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.in, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.semi, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.amp, lx.next().tag);
}

test "embedded parentheses do not close a command group" {
    var lx = Lexer.init("(echo foo(bar))");
    try std.testing.expectEqual(Tag.lparen, lx.next().tag);
    try std.testing.expectEqualStrings("echo", lx.next().text);
    try std.testing.expectEqualStrings("foo(bar)", lx.next().text);
    try std.testing.expectEqual(Tag.rparen, lx.next().tag);
    try std.testing.expectEqual(Tag.eof, lx.next().tag);
}

test "expression mode" {
    var lx = Lexer.init("4 * (10 + 2)");
    lx.mode = .expr;
    try std.testing.expectEqual(Tag.number, lx.next().tag);
    try std.testing.expectEqual(Tag.star, lx.next().tag);
    try std.testing.expectEqual(Tag.lparen, lx.next().tag);
    try std.testing.expectEqual(Tag.number, lx.next().tag);
    try std.testing.expectEqual(Tag.plus, lx.next().tag);
    try std.testing.expectEqual(Tag.number, lx.next().tag);
    try std.testing.expectEqual(Tag.rparen, lx.next().tag);
}

test "quotes survive as words with quote characters" {
    var lx = Lexer.init("echo \"a b\" 'c d'");
    _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqual(Tag.word, t.tag);
    try std.testing.expectEqualStrings("\"a b\"", t.text);
    const t2 = lx.next();
    try std.testing.expectEqualStrings("'c d'", t2.text);
}

test "text adjacent to a quoted run stays in one word" {
    var lx = Lexer.init("echo a\"b c\"d \"x$(echo \"y\")z\"");
    _ = lx.next();
    try std.testing.expectEqualStrings("a\"b c\"d", lx.next().text);
    try std.testing.expectEqualStrings("\"x$(echo \"y\")z\"", lx.next().text);
}

test "command substitution stays inside the word" {
    var lx = Lexer.init("echo $(basename /a/b) done");
    _ = lx.next();
    const t = lx.next();
    try std.testing.expectEqualStrings("$(basename /a/b)", t.text);
    try std.testing.expectEqualStrings("done", lx.next().text);
}

test "braces are structural only when standalone" {
    var lx = Lexer.init("if x { y }");
    _ = lx.next();
    _ = lx.next();
    try std.testing.expectEqual(Tag.lbrace, lx.next().tag);
    try std.testing.expectEqual(Tag.word, lx.next().tag);
    try std.testing.expectEqual(Tag.rbrace, lx.next().tag);

    var lx2 = Lexer.init("find . -exec ls {} \\;");
    _ = lx2.next();
    _ = lx2.next();
    _ = lx2.next();
    _ = lx2.next();
    try std.testing.expectEqualStrings("{}", lx2.next().text);
}

test "comments" {
    var lx = Lexer.init("echo a#b # trailing\necho c");
    try std.testing.expectEqualStrings("echo", lx.next().text);
    try std.testing.expectEqualStrings("a#b", lx.next().text);
    try std.testing.expectEqual(Tag.newline, lx.next().tag);
    try std.testing.expectEqualStrings("echo", lx.next().text);
    try std.testing.expectEqualStrings("c", lx.next().text);
}
