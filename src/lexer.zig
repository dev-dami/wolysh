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
//! In both modes `|`, `&`, `;`, `<`, `>` and `{`/`}` stay structural, except
//! that in word mode `<(` and `>(` start a process-substitution word.

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
    /// `|&`: a pipe that also carries standard error (`2>&1 |`).
    pipe_amp,
    amp,
    ampamp,
    semi,
    /// `;;`, `;&` and `;;&` end a `case` item.
    dsemi,
    semi_amp,
    dsemi_amp,
    out,
    out_append,
    /// `>|`: truncating output that ignores `noclobber`.
    out_clobber,
    in,
    /// `<>`: open for reading and writing without truncating.
    in_out,
    here_doc,
    /// `<<-`: body lines and the delimiter have leading tabs stripped.
    here_doc_strip,
    /// `<<<`: the target word is expanded and fed as standard input.
    here_string,
    /// `&>` / `&>>`: stdout and stderr to the same file.
    out_both,
    out_both_append,
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
    case_pattern: bool,
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

fn isSpecialParam(c: u8) bool {
    return isDigit(c) or switch (c) {
        '?', '#', '$', '!', '@', '*', '-' => true,
        else => false,
    };
}

fn isIdentifierText(s: []const u8) bool {
    if (s.len == 0 or !isIdentStart(s[0])) return false;
    for (s[1..]) |c| {
        if (!isIdentChar(c)) return false;
    }
    return true;
}

/// Follows `case` statements inside `$(...)`, where the `)` ending each
/// pattern list must not count as closing the substitution.
const CaseParens = struct {
    open_cases: u16 = 0,
    awaiting_in: bool = false,
    in_patterns: bool = false,
    /// Extglob groups such as `@(a|b)` open in the current pattern.
    pattern_parens: u16 = 0,
    /// The next word starts a command, where `case` and `esac` are reserved.
    command_start: bool = true,

    fn boundary(c: u8) bool {
        return isSpace(c) or c == '\n' or c == ';' or c == '&' or c == '|' or c == '(' or c == ')';
    }

    /// Consumes what case tracking needs at `pos` (a word, `;;`, or a
    /// pattern paren) and returns its length; 0 leaves `pos` to the caller.
    fn scan(self: *CaseParens, src: []const u8, start: usize, pos: usize) usize {
        const c = src[pos];
        if (self.in_patterns and (c == '(' or c == ')')) {
            if (c == '(') {
                // An extglob group or a nested `$(`/`$((`; otherwise the
                // optional `(` before a pattern.
                if (pos > start and std.mem.indexOfScalar(u8, "?*+@!$(", src[pos - 1]) != null) self.pattern_parens += 1;
            } else if (self.pattern_parens > 0) {
                self.pattern_parens -= 1;
            } else {
                self.in_patterns = false;
                self.command_start = true;
            }
            return 1;
        }
        if (c == ';' and self.open_cases > 0 and pos + 1 < src.len and (src[pos + 1] == ';' or src[pos + 1] == '&')) {
            self.in_patterns = true;
            self.pattern_parens = 0;
            self.command_start = true;
            return 2;
        }
        if (isIdentStart(c) and (pos == start or boundary(src[pos - 1]))) {
            var end = pos;
            while (end < src.len and isIdentChar(src[end])) end += 1;
            const at_command = self.command_start;
            if (end < src.len and !boundary(src[end])) {
                self.command_start = false;
                return end - pos;
            }
            const word = src[pos..end];
            self.command_start = std.mem.eql(u8, word, "then") or std.mem.eql(u8, word, "do") or
                std.mem.eql(u8, word, "else") or std.mem.eql(u8, word, "elif") or
                std.mem.eql(u8, word, "if") or std.mem.eql(u8, word, "while") or std.mem.eql(u8, word, "until");
            if (at_command and std.mem.eql(u8, word, "case")) {
                self.open_cases += 1;
                self.awaiting_in = true;
            } else if (self.awaiting_in and std.mem.eql(u8, word, "in")) {
                self.awaiting_in = false;
                self.in_patterns = true;
                self.pattern_parens = 0;
                self.command_start = true;
            } else if (at_command and self.open_cases > 0 and std.mem.eql(u8, word, "esac")) {
                self.open_cases -= 1;
                self.in_patterns = false;
            }
            return end - pos;
        }
        switch (c) {
            ';', '&', '|', '(', '{', '}', '\n' => self.command_start = true,
            ' ', '\t', '\r' => {},
            else => self.command_start = false,
        }
        return 0;
    }
};

/// Index of the `)` closing the `$(` whose `(` is at `open_index`, honouring
/// quotes and `case` patterns; null when it is never closed.
pub fn closingParen(src: []const u8, open_index: usize) ?usize {
    if (open_index == 0 or src[open_index] != '(') return null;
    var lx = Lexer.init(src);
    lx.pos = open_index - 1;
    return if (lx.skipExpansion()) lx.pos - 1 else null;
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
    /// Set while the parser reads `case` patterns: `(`, `)` and `|` delimit
    /// patterns there, except inside an extglob group such as `@(a|b)`.
    case_pattern: bool = false,

    pub fn init(src: []const u8) Lexer {
        return .{ .src = src };
    }

    pub fn save(self: *const Lexer) State {
        return .{
            .pos = self.pos,
            .line = self.line,
            .mode = self.mode,
            .depth = self.depth,
            .group_depth = self.group_depth,
            .case_pattern = self.case_pattern,
        };
    }

    pub fn restore(self: *Lexer, s: State) void {
        self.pos = s.pos;
        self.line = s.line;
        self.mode = s.mode;
        self.depth = s.depth;
        self.group_depth = s.group_depth;
        self.case_pattern = s.case_pattern;
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
                if (self.mode == .word and self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return self.tok(.pipe_amp, start, depth_before);
                }
                return self.tok(.pipe, start, depth_before);
            },
            '&' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return self.tok(.ampamp, start, depth_before);
                }
                if (self.mode == .word and self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '>') {
                        self.pos += 1;
                        return self.tok(.out_both_append, start, depth_before);
                    }
                    return self.tok(.out_both, start, depth_before);
                }
                return self.tok(.amp, start, depth_before);
            },
            ';' => {
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == ';') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '&') {
                        self.pos += 1;
                        return self.tok(.dsemi_amp, start, depth_before);
                    }
                    return self.tok(.dsemi, start, depth_before);
                }
                if (self.pos < self.src.len and self.src[self.pos] == '&') {
                    self.pos += 1;
                    return self.tok(.semi_amp, start, depth_before);
                }
                return self.tok(.semi, start, depth_before);
            },
            '>' => {
                // `>(list)` is a process substitution, which is a word.
                if (self.mode == .word and self.startsProcessSubstitution(self.pos)) return self.scanWord(start, depth_before);
                self.pos += 1;
                if (self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return self.tok(.out_append, start, depth_before);
                }
                if (self.mode == .expr) return self.tok(.gt, start, depth_before);
                if (self.pos < self.src.len and self.src[self.pos] == '|') {
                    self.pos += 1;
                    return self.tok(.out_clobber, start, depth_before);
                }
                return self.tok(.out, start, depth_before);
            },
            '<' => {
                if (self.mode == .word and self.startsProcessSubstitution(self.pos)) return self.scanWord(start, depth_before);
                self.pos += 1;
                if (self.mode == .word and self.pos < self.src.len and self.src[self.pos] == '>') {
                    self.pos += 1;
                    return self.tok(.in_out, start, depth_before);
                }
                if (self.mode == .word and self.pos < self.src.len and self.src[self.pos] == '<') {
                    self.pos += 1;
                    if (self.pos < self.src.len and self.src[self.pos] == '<') {
                        self.pos += 1;
                        return self.tok(.here_string, start, depth_before);
                    }
                    if (self.pos < self.src.len and self.src[self.pos] == '-') {
                        self.pos += 1;
                        return self.tok(.here_doc_strip, start, depth_before);
                    }
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
                if (!self.case_pattern) self.group_depth += 1;
                return token;
            },
            ')' => if (self.mode == .expr) {
                self.pos += 1;
                return self.tok(.rparen, start, depth_before);
            } else {
                self.pos += 1;
                const token = self.tok(.rparen, start, depth_before);
                if (!self.case_pattern and self.group_depth > 0) self.group_depth -= 1;
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
                    _ = self.skipExpansion();
                    return self.tok(.word, start, depth_before);
                }
                if (self.pos + 1 < self.src.len and self.src[self.pos + 1] == '{') {
                    _ = self.skipExpansion();
                    // `${name}` is a variable reference; anything else
                    // (`${#name}`, `${name:-x}`, `${1}`) is expanded as a word.
                    const closed = self.pos > start + 2 and self.src[self.pos - 1] == '}';
                    if (closed and isIdentifierText(self.src[start + 2 .. self.pos - 1])) {
                        var t = self.tok(.ident, start, depth_before);
                        t.text = self.src[start + 2 .. self.pos - 1];
                        return t;
                    }
                    return self.tok(.word, start, depth_before);
                }
                if (self.pos + 1 < self.src.len and isIdentStart(self.src[self.pos + 1])) {
                    self.pos += 1;
                    const name_start = self.pos;
                    while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
                    var t = self.tok(.ident, start, depth_before);
                    t.text = self.src[name_start..self.pos];
                    return t;
                }
                // `$?`, `$#`, `$1`, `$@` and friends become words, which the
                // expression parser turns into expanded strings.
                if (self.pos + 1 < self.src.len and isSpecialParam(self.src[self.pos + 1])) {
                    self.pos += 2;
                    return self.tok(.word, start, depth_before);
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
                _ = self.skipExpansion();
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
    /// Returns whether the group was closed.
    fn skipExpansion(self: *Lexer) bool {
        const open = self.src[self.pos + 1];
        const close: u8 = if (open == '{') '}' else ')';
        self.pos += 2;
        const body_start = self.pos;
        var depth: usize = 1;
        var cases = CaseParens{};
        while (self.pos < self.src.len and depth > 0) {
            if (open == '(') {
                const used = cases.scan(self.src, body_start, self.pos);
                if (used > 0) {
                    self.pos += used;
                    continue;
                }
            }
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            if (c == '$' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                self.skipAnsiC();
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
        return depth == 0;
    }

    /// Skips a `` `...` `` command substitution, whose spaces and operators
    /// belong to the word around it.
    fn skipBackticks(self: *Lexer) void {
        self.pos += 1;
        while (self.pos < self.src.len and self.src[self.pos] != '`') {
            if (self.src[self.pos] == '\\' and self.pos + 1 < self.src.len) self.pos += 1;
            if (self.src[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
        if (self.pos < self.src.len) self.pos += 1;
    }

    /// Skips a `$'...'` string, where a backslash escapes the closing quote.
    fn skipAnsiC(self: *Lexer) void {
        self.pos += 2;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.pos += 2;
                continue;
            }
            self.pos += 1;
            if (c == '\'') return;
            if (c == '\n') self.line += 1;
        }
    }

    fn startsProcessSubstitution(self: *const Lexer, p: usize) bool {
        const c = self.src[p];
        return (c == '<' or c == '>') and p + 1 < self.src.len and self.src[p + 1] == '(';
    }

    /// The `)` closing the group opened at `open`, skipping quoted text and
    /// nested groups; null when the group does not close on this line.
    fn groupClose(self: *const Lexer, open: usize) ?usize {
        var depth: usize = 0;
        var i = open;
        while (i < self.src.len) : (i += 1) {
            switch (self.src[i]) {
                '\\' => i += 1,
                '\'' => i = std.mem.indexOfScalarPos(u8, self.src, i + 1, '\'') orelse return null,
                '"' => {
                    i += 1;
                    while (i < self.src.len and self.src[i] != '"') : (i += 1) {
                        if (self.src[i] == '\\') i += 1;
                    }
                    if (i >= self.src.len) return null;
                },
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if (depth == 0) return i;
                },
                '\n' => return null,
                else => {},
            }
        }
        return null;
    }

    /// Scans a bare command word, keeping quotes and escapes in the text.
    fn scanWord(self: *Lexer, start: usize, depth_before: u16) Token {
        var embedded_parens: usize = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            // `<(list)` / `>(list)` belong to the word, as does an extended
            // glob group such as `@(a|b)`, whose `|` is not a pipe.
            if (self.startsProcessSubstitution(self.pos)) {
                _ = self.skipExpansion();
                continue;
            }
            if ((c == '?' or c == '*' or c == '+' or c == '@' or c == '!') and
                self.pos + 1 < self.src.len and self.src[self.pos + 1] == '(')
            {
                if (self.groupClose(self.pos + 1)) |close| {
                    self.pos = close + 1;
                    continue;
                }
            }
            if (self.case_pattern) {
                if (c == '(') {
                    embedded_parens += 1;
                    self.pos += 1;
                    continue;
                }
                if (c == ')') {
                    if (embedded_parens == 0) break;
                    embedded_parens -= 1;
                    self.pos += 1;
                    continue;
                }
                if (c == '|' and embedded_parens > 0) {
                    self.pos += 1;
                    continue;
                }
            }
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
            if (c == '`') {
                self.skipBackticks();
                continue;
            }
            if (c == '$' and self.pos + 1 < self.src.len and
                (self.src[self.pos + 1] == '{' or self.src[self.pos + 1] == '('))
            {
                _ = self.skipExpansion();
                continue;
            }
            if (c == '$' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '\'') {
                self.skipAnsiC();
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

test "merged, here-string and tab-stripping redirect tokens" {
    var lx = Lexer.init("a &> f &>> g <<-EOF <<<s");
    try std.testing.expectEqualStrings("a", lx.next().text);
    try std.testing.expectEqual(Tag.out_both, lx.next().tag);
    try std.testing.expectEqualStrings("f", lx.next().text);
    try std.testing.expectEqual(Tag.out_both_append, lx.next().tag);
    try std.testing.expectEqualStrings("g", lx.next().text);
    try std.testing.expectEqual(Tag.here_doc_strip, lx.next().tag);
    try std.testing.expectEqualStrings("EOF", lx.next().text);
    try std.testing.expectEqual(Tag.here_string, lx.next().tag);
    try std.testing.expectEqualStrings("s", lx.next().text);
    try std.testing.expectEqual(Tag.eof, lx.next().tag);
}

test "a spaced ampersand still backgrounds" {
    var lx = Lexer.init("sleep 1 & > out.txt");
    try std.testing.expectEqualStrings("sleep", lx.next().text);
    try std.testing.expectEqualStrings("1", lx.next().text);
    try std.testing.expectEqual(Tag.amp, lx.next().tag);
    try std.testing.expectEqual(Tag.out, lx.next().tag);
    try std.testing.expectEqualStrings("out.txt", lx.next().text);
}

test "case item terminators" {
    var lx = Lexer.init("a;; b;& c;;& d;");
    _ = lx.next();
    try std.testing.expectEqual(Tag.dsemi, lx.next().tag);
    _ = lx.next();
    try std.testing.expectEqual(Tag.semi_amp, lx.next().tag);
    _ = lx.next();
    try std.testing.expectEqual(Tag.dsemi_amp, lx.next().tag);
    _ = lx.next();
    try std.testing.expectEqual(Tag.semi, lx.next().tag);
}

test "case patterns split on parens and bars outside extglob groups" {
    var lx = Lexer.init("(a|b*) @(x|y)) z");
    lx.case_pattern = true;
    try std.testing.expectEqual(Tag.lparen, lx.next().tag);
    try std.testing.expectEqualStrings("a", lx.next().text);
    try std.testing.expectEqual(Tag.pipe, lx.next().tag);
    try std.testing.expectEqualStrings("b*", lx.next().text);
    try std.testing.expectEqual(Tag.rparen, lx.next().tag);
    try std.testing.expectEqualStrings("@(x|y)", lx.next().text);
    try std.testing.expectEqual(Tag.rparen, lx.next().tag);
    try std.testing.expectEqual(@as(u16, 0), lx.group_depth);
}

test "backquoted substitutions stay inside the word" {
    var lx = Lexer.init("for f in `ls -a | sort` x`echo a b`y; do");
    _ = lx.next();
    _ = lx.next();
    _ = lx.next();
    try std.testing.expectEqualStrings("`ls -a | sort`", lx.next().text);
    try std.testing.expectEqualStrings("x`echo a b`y", lx.next().text);
    try std.testing.expectEqual(Tag.semi, lx.next().tag);
}

test "a case statement inside $(...) does not close it early" {
    var lx = Lexer.init("x=$(case $y in a) echo 1;; (b|c) echo 2;; @(d|e)) echo 3;; esac) next");
    try std.testing.expectEqualStrings("x=$(case $y in a) echo 1;; (b|c) echo 2;; @(d|e)) echo 3;; esac)", lx.next().text);
    try std.testing.expectEqualStrings("next", lx.next().text);

    var plain = Lexer.init("$(echo case in a) b");
    try std.testing.expectEqualStrings("$(echo case in a)", plain.next().text);

    var nested = Lexer.init("$(case $(echo b) in $(echo b)) echo B;; $((1+1))) echo 2;; esac) c");
    try std.testing.expectEqualStrings("$(case $(echo b) in $(echo b)) echo B;; $((1+1))) echo 2;; esac)", nested.next().text);
}

test "special parameters in expression mode" {
    var lx = Lexer.init("$? == 0 and ${#x} > $1 or ${name}");
    lx.mode = .expr;
    const status = lx.next();
    try std.testing.expectEqual(Tag.word, status.tag);
    try std.testing.expectEqualStrings("$?", status.text);
    try std.testing.expectEqual(Tag.eq, lx.next().tag);
    try std.testing.expectEqual(Tag.number, lx.next().tag);
    try std.testing.expectEqual(Tag.ident, lx.next().tag);
    try std.testing.expectEqualStrings("${#x}", lx.next().text);
    try std.testing.expectEqual(Tag.gt, lx.next().tag);
    try std.testing.expectEqualStrings("$1", lx.next().text);
    try std.testing.expectEqual(Tag.ident, lx.next().tag);
    const name = lx.next();
    try std.testing.expectEqual(Tag.ident, name.tag);
    try std.testing.expectEqualStrings("name", name.text);
}

test "comments" {
    var lx = Lexer.init("echo a#b # trailing\necho c");
    try std.testing.expectEqualStrings("echo", lx.next().text);
    try std.testing.expectEqualStrings("a#b", lx.next().text);
    try std.testing.expectEqual(Tag.newline, lx.next().tag);
    try std.testing.expectEqualStrings("echo", lx.next().text);
    try std.testing.expectEqualStrings("c", lx.next().text);
}

test "pipe-amp, clobber and read-write redirect tokens" {
    var lx = Lexer.init("a |& b >| f <> g 10>h");
    try std.testing.expectEqualStrings("a", lx.next().text);
    try std.testing.expectEqual(Tag.pipe_amp, lx.next().tag);
    try std.testing.expectEqualStrings("b", lx.next().text);
    try std.testing.expectEqual(Tag.out_clobber, lx.next().tag);
    try std.testing.expectEqualStrings("f", lx.next().text);
    try std.testing.expectEqual(Tag.in_out, lx.next().tag);
    try std.testing.expectEqualStrings("g", lx.next().text);
    try std.testing.expectEqualStrings("10", lx.next().text);
    try std.testing.expectEqual(Tag.out, lx.next().tag);
    try std.testing.expectEqualStrings("h", lx.next().text);
    try std.testing.expectEqual(Tag.eof, lx.next().tag);
}

test "process substitutions are words" {
    var lx = Lexer.init("diff <(sort a | uniq) >(cat) < <(ls) x=<(y)");
    try std.testing.expectEqualStrings("diff", lx.next().text);
    try std.testing.expectEqualStrings("<(sort a | uniq)", lx.next().text);
    try std.testing.expectEqualStrings(">(cat)", lx.next().text);
    try std.testing.expectEqual(Tag.in, lx.next().tag);
    try std.testing.expectEqualStrings("<(ls)", lx.next().text);
    try std.testing.expectEqualStrings("x=<(y)", lx.next().text);
    try std.testing.expectEqual(Tag.eof, lx.next().tag);
}

test "ANSI-C quoted words keep escaped quotes inside" {
    var lx = Lexer.init("echo $'it\\'s' $'a\\tb'x done");
    _ = lx.next();
    try std.testing.expectEqualStrings("$'it\\'s'", lx.next().text);
    try std.testing.expectEqualStrings("$'a\\tb'x", lx.next().text);
    try std.testing.expectEqualStrings("done", lx.next().text);
}

test "extended glob groups stay in one word" {
    var lx = Lexer.init("ls @(a|b).c !(x) | wc");
    _ = lx.next();
    try std.testing.expectEqualStrings("@(a|b).c", lx.next().text);
    try std.testing.expectEqualStrings("!(x)", lx.next().text);
    try std.testing.expectEqual(Tag.pipe, lx.next().tag);
}
