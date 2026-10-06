const std = @import("std");
const lexer = @import("../lexer.zig");

/// A here-document opener: the raw delimiter text plus whether `<<-` asks for
/// leading tabs to be stripped.
const Delimiter = struct { raw: []const u8, strip: bool };

/// Reserved-word bookkeeping. A header (`if`, `while`, `function`, ...) is
/// open until its body starts: `then`/`do` open a POSIX block that `fi`,
/// `done` or `esac` close, while a `{` after a word starts a native body,
/// which the brace count tracks.
const Blocks = struct {
    const Header = enum { if_, elif, loop, function };

    headers: [64]Header = undefined,
    header_count: usize = 0,
    /// Open `then`/`do`/`case` blocks.
    depth: i32 = 0,
    /// The next word starts a command, so a reserved word is recognised.
    command_start: bool = true,
    /// Also inside a `case`, where `pattern)` is followed by a command.
    case_depth: i32 = 0,
    /// The input ends right after `name()`, whose body has not started.
    open_definition: bool = false,

    fn push(self: *Blocks, header: Header) void {
        if (self.header_count < self.headers.len) {
            self.headers[self.header_count] = header;
            self.header_count += 1;
        }
    }

    fn top(self: *const Blocks) ?Header {
        return if (self.header_count == 0) null else self.headers[self.header_count - 1];
    }

    fn see(self: *Blocks, tok: lexer.Token) void {
        const at_start = self.command_start;
        self.open_definition = false;
        switch (tok.tag) {
            .word => {
                self.command_start = false;
                if (!at_start) {
                    if (self.case_depth > 0 and tok.text.len > 1 and tok.text[tok.text.len - 1] == ')') self.command_start = true;
                    return;
                }
                const text = tok.text;
                if (eql(text, "if")) {
                    self.push(.if_);
                } else if (eql(text, "elif")) {
                    self.push(.elif);
                } else if (eql(text, "while") or eql(text, "until") or eql(text, "for") or eql(text, "select")) {
                    self.push(.loop);
                } else if (eql(text, "function")) {
                    self.push(.function);
                } else if (eql(text, "then")) {
                    if (self.top()) |header| {
                        if (header == .if_ or header == .elif) self.header_count -= 1;
                        if (header == .if_) self.depth += 1;
                    }
                } else if (eql(text, "do")) {
                    if (self.top() == .loop) {
                        self.header_count -= 1;
                        self.depth += 1;
                    }
                } else if (eql(text, "case")) {
                    self.depth += 1;
                    self.case_depth += 1;
                } else if (eql(text, "esac")) {
                    self.depth -= 1;
                    self.case_depth -= 1;
                } else if (eql(text, "fi") or eql(text, "done")) {
                    self.depth -= 1;
                } else if (std.mem.endsWith(u8, text, "()")) {
                    self.open_definition = true;
                }
                // These keep the next word in command position.
                self.command_start = eql(text, "if") or eql(text, "elif") or eql(text, "then") or
                    eql(text, "else") or eql(text, "while") or eql(text, "until") or eql(text, "do") or
                    eql(text, "!") or eql(text, "time");
            },
            .lbrace => {
                // A `{` after a word opens a native body.
                if (!at_start and self.top() != null) self.header_count -= 1;
                self.command_start = true;
            },
            .lparen => {
                if (self.top() == .function) self.header_count -= 1;
                self.command_start = true;
            },
            .rparen => self.command_start = self.case_depth > 0,
            .newline, .semi, .dsemi, .semi_amp, .dsemi_amp, .pipe, .pipepipe, .amp, .ampamp, .rbrace => self.command_start = true,
            else => self.command_start = false,
        }
    }

    fn open(self: *const Blocks) bool {
        return self.depth > 0 or self.header_count > 0 or self.open_definition;
    }
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isComplete(src: []const u8) bool {
    if (!quotesBalanced(src)) return false;

    var lx = lexer.Lexer.init(src);
    var braces: i32 = 0;
    var parens: i32 = 0;
    var brackets: i32 = 0;
    // Open `[[ ... ]]` tests, whose `]]` may come on a later line.
    var conds: i32 = 0;
    var last: lexer.Tag = .eof;
    var last_text: []const u8 = "";
    var heredoc_delimiters: [64]Delimiter = undefined;
    var heredoc_count: usize = 0;
    var needs_heredoc_delimiter = false;
    var heredoc_strip = false;
    var blocks = Blocks{};

    while (true) {
        const tok = lx.next();
        if (tok.tag == .eof) {
            if (heredoc_count != 0 or needs_heredoc_delimiter) return false;
            break;
        }
        if (tok.tag == .word) {
            if (blocks.command_start and eql(tok.text, "[[")) conds += 1;
            if (conds > 0 and eql(tok.text, "]]")) conds -= 1;
        }
        blocks.see(tok);
        if (needs_heredoc_delimiter) {
            if (tok.tag != .word or heredoc_count == heredoc_delimiters.len) return false;
            heredoc_delimiters[heredoc_count] = .{ .raw = tok.text, .strip = heredoc_strip };
            heredoc_count += 1;
            needs_heredoc_delimiter = false;
        } else if (tok.tag == .here_doc or tok.tag == .here_doc_strip) {
            needs_heredoc_delimiter = true;
            heredoc_strip = tok.tag == .here_doc_strip;
        }
        switch (tok.tag) {
            .lbrace => braces += 1,
            .rbrace => braces -= 1,
            .lparen => parens += 1,
            .rparen => parens -= 1,
            .lbracket => brackets += 1,
            .rbracket => brackets -= 1,
            else => {},
        }
        const previous = last;
        last = tok.tag;
        last_text = tok.text;
        if (tok.tag == .newline and heredoc_count > 0 and !expectsMore(previous)) {
            const skipped = skipHereDocBodies(src, lx.pos, heredoc_delimiters[0..heredoc_count]) orelse return false;
            lx.pos = skipped.pos;
            lx.line += skipped.lines;
            heredoc_count = 0;
        }
    }

    if (braces > 0 or parens > 0 or brackets > 0 or conds > 0) return false;
    if (blocks.open()) return false;
    if (expectsMore(last)) return false;
    if (last == .word and wordExpectsMore(last_text)) return false;

    return true;
}

fn wordExpectsMore(text: []const u8) bool {
    const openers = [_][]const u8{ "=", "+=", "else", "and", "or", "not" };
    for (openers) |opener| {
        if (std.mem.eql(u8, text, opener)) return true;
    }
    return false;
}

fn expectsMore(tag: lexer.Tag) bool {
    return switch (tag) {
        .pipe, .pipepipe, .pipe_amp, .ampamp, .lbrace, .lparen, .lbracket, .in, .here_doc, .here_doc_strip, .here_string => true,
        .out, .out_append, .out_both, .out_both_append, .out_clobber, .in_out => true,
        .assign, .plus_assign, .minus_assign => true,
        .plus, .minus, .star, .slash, .percent => true,
        .eq, .ne, .lt, .le, .gt, .ge => true,
        .comma, .dot => true,
        else => false,
    };
}

fn quotesBalanced(src: []const u8) bool {
    var i: usize = 0;
    var in_single = false;
    var in_double = false;
    var in_backtick = false;
    var line_start: usize = 0;
    var heredoc_delimiters: [64]Delimiter = undefined;
    var heredoc_count: usize = 0;
    while (i < src.len) {
        const c = src[i];
        if (c == '#' and !in_single and !in_double and
            (i == 0 or std.ascii.isWhitespace(src[i - 1])))
        {
            while (i < src.len and src[i] != '\n') i += 1;
            continue;
        }
        if (c == '\\' and !in_single and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '$' and !in_single and !in_double and i + 1 < src.len and src[i + 1] == '\'') {
            // `$'...'`: a backslash escapes the closing quote.
            i += 2;
            while (i < src.len and src[i] != '\'') : (i += 1) {
                if (src[i] == '\\') i += 1;
            }
            if (i >= src.len) return false;
            i += 1;
            continue;
        }
        if (c == '<' and !in_single and !in_double and i + 1 < src.len and src[i + 1] == '<') {
            // A here-string (`<<<word`) carries no body.
            if (i + 2 < src.len and src[i + 2] == '<') {
                i += 3;
                continue;
            }
            if (heredoc_count == heredoc_delimiters.len) return false;
            const marker = rawHereDocDelimiter(src, i + 2) orelse return false;
            heredoc_delimiters[heredoc_count] = .{ .raw = marker.raw, .strip = marker.strip };
            heredoc_count += 1;
            i = marker.end;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (c == '`' and !in_single) {
            in_backtick = !in_backtick;
        } else if (c == '\n') {
            if (heredoc_count > 0 and !continuedLine(src[line_start..i])) {
                const skipped = skipHereDocBodies(src, i + 1, heredoc_delimiters[0..heredoc_count]) orelse return false;
                i = skipped.pos;
                heredoc_count = 0;
                line_start = i;
                in_single = false;
                in_double = false;
                in_backtick = false;
                continue;
            }
            line_start = i + 1;
        }
        i += 1;
    }
    return !in_single and !in_double and !in_backtick and heredoc_count == 0;
}

const RawDelimiter = struct { raw: []const u8, end: usize, strip: bool };

fn rawHereDocDelimiter(src: []const u8, from: usize) ?RawDelimiter {
    var start = from;
    // Only `<<-` written without a space strips tabs, exactly like the lexer.
    const strip = start < src.len and src[start] == '-';
    if (strip) start += 1;
    while (start < src.len and (src[start] == ' ' or src[start] == '\t')) start += 1;
    if (start == src.len or src[start] == '\n') return null;
    var i = start;
    var quote: u8 = 0;
    while (i < src.len) : (i += 1) {
        const c = src[i];
        if (c == '\\' and quote != '\'' and i + 1 < src.len) {
            i += 1;
            continue;
        }
        if (quote != 0) {
            if (c == quote) quote = 0;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (std.ascii.isWhitespace(c) or c == '<' or c == '>' or c == '|' or c == '&' or c == ';') {
            break;
        }
    }
    if (quote != 0 or i == start) return null;
    return .{ .raw = src[start..i], .end = i, .strip = strip };
}

fn hereDocDelimiterMatches(raw: []const u8, line: []const u8, strip: bool) bool {
    const candidate = if (strip) std.mem.trimStart(u8, line, "\t") else line;
    var raw_index: usize = 0;
    var line_index: usize = 0;
    var quote: u8 = 0;
    while (raw_index < raw.len) {
        const c = raw[raw_index];
        if (c == '\\' and quote != '\'' and raw_index + 1 < raw.len) {
            const next = raw[raw_index + 1];
            if (next == '\n') {
                raw_index += 2;
                continue;
            }
            if (quote != '"' or next == '$' or next == '`' or next == '"' or next == '\\') {
                raw_index += 1;
                if (line_index >= candidate.len or raw[raw_index] != candidate[line_index]) return false;
                raw_index += 1;
                line_index += 1;
                continue;
            }
        }
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else {
                if (line_index >= candidate.len or c != candidate[line_index]) return false;
                line_index += 1;
            }
            raw_index += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else {
            if (line_index >= candidate.len or c != candidate[line_index]) return false;
            line_index += 1;
        }
        raw_index += 1;
    }
    return quote == 0 and line_index == candidate.len;
}

const SkippedHereDocs = struct { pos: usize, lines: usize };

fn skipHereDocBodies(src: []const u8, start: usize, delimiters: []const Delimiter) ?SkippedHereDocs {
    var cursor = start;
    var lines: usize = 0;
    for (delimiters) |delimiter| {
        var found = false;
        while (cursor <= src.len) {
            const line_start = cursor;
            const line_end = std.mem.indexOfScalarPos(u8, src, cursor, '\n') orelse src.len;
            var line = src[line_start..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (hereDocDelimiterMatches(delimiter.raw, line, delimiter.strip)) {
                cursor = if (line_end < src.len) line_end + 1 else line_end;
                if (line_end < src.len) lines += 1;
                found = true;
                break;
            }
            if (line_end == src.len) break;
            cursor = line_end + 1;
            lines += 1;
        }
        if (!found) return null;
    }
    return .{ .pos = cursor, .lines = lines };
}

fn continuedLine(line: []const u8) bool {
    var lx = lexer.Lexer.init(line);
    var last: ?lexer.Token = null;
    while (true) {
        const tok = lx.next();
        if (tok.tag == .eof) break;
        last = tok;
    }
    const token = last orelse return false;
    switch (token.tag) {
        .pipe, .pipepipe, .pipe_amp, .ampamp => return true,
        else => {},
    }

    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    if (token.start + token.text.len != trimmed.len) return false;
    var slashes: usize = 0;
    var i = trimmed.len;
    while (i > 0 and trimmed[i - 1] == '\\') : (i -= 1) slashes += 1;
    return slashes % 2 == 1;
}
