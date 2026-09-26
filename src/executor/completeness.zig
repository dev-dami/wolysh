const std = @import("std");
const lexer = @import("../lexer.zig");

pub fn isComplete(src: []const u8) bool {
    if (!quotesBalanced(src)) return false;

    var lx = lexer.Lexer.init(src);
    var braces: i32 = 0;
    var parens: i32 = 0;
    var brackets: i32 = 0;
    var last: lexer.Tag = .eof;
    var last_text: []const u8 = "";
    var heredoc_delimiters: [64][]const u8 = undefined;
    var heredoc_count: usize = 0;
    var needs_heredoc_delimiter = false;

    while (true) {
        const tok = lx.next();
        if (tok.tag == .eof) {
            if (heredoc_count != 0 or needs_heredoc_delimiter) return false;
            break;
        }
        if (needs_heredoc_delimiter) {
            if (tok.tag != .word or heredoc_count == heredoc_delimiters.len) return false;
            heredoc_delimiters[heredoc_count] = tok.text;
            heredoc_count += 1;
            needs_heredoc_delimiter = false;
        } else if (tok.tag == .here_doc) {
            needs_heredoc_delimiter = true;
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

    if (braces > 0 or parens > 0 or brackets > 0) return false;
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
        .pipe, .pipepipe, .ampamp, .lbrace, .lparen, .lbracket, .in, .here_doc, .out, .out_append => true,
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
    var line_start: usize = 0;
    var heredoc_delimiters: [64][]const u8 = undefined;
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
        if (c == '<' and !in_single and !in_double and i + 1 < src.len and src[i + 1] == '<') {
            if (heredoc_count == heredoc_delimiters.len) return false;
            const marker = rawHereDocDelimiter(src, i + 2) orelse return false;
            heredoc_delimiters[heredoc_count] = marker.raw;
            heredoc_count += 1;
            i = marker.end;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        } else if (c == '\n') {
            if (heredoc_count > 0 and !continuedLine(src[line_start..i])) {
                const skipped = skipHereDocBodies(src, i + 1, heredoc_delimiters[0..heredoc_count]) orelse return false;
                i = skipped.pos;
                heredoc_count = 0;
                line_start = i;
                in_single = false;
                in_double = false;
                continue;
            }
            line_start = i + 1;
        }
        i += 1;
    }
    return !in_single and !in_double and heredoc_count == 0;
}

const RawDelimiter = struct { raw: []const u8, end: usize };

fn rawHereDocDelimiter(src: []const u8, from: usize) ?RawDelimiter {
    var start = from;
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
    return .{ .raw = src[start..i], .end = i };
}

fn hereDocDelimiterMatches(raw: []const u8, line: []const u8) bool {
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
                if (line_index >= line.len or raw[raw_index] != line[line_index]) return false;
                raw_index += 1;
                line_index += 1;
                continue;
            }
        }
        if (quote != 0) {
            if (c == quote) {
                quote = 0;
            } else {
                if (line_index >= line.len or c != line[line_index]) return false;
                line_index += 1;
            }
            raw_index += 1;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else {
            if (line_index >= line.len or c != line[line_index]) return false;
            line_index += 1;
        }
        raw_index += 1;
    }
    return quote == 0 and line_index == line.len;
}

const SkippedHereDocs = struct { pos: usize, lines: usize };

fn skipHereDocBodies(src: []const u8, start: usize, delimiters: []const []const u8) ?SkippedHereDocs {
    var cursor = start;
    var lines: usize = 0;
    for (delimiters) |delimiter| {
        var found = false;
        while (cursor <= src.len) {
            const line_start = cursor;
            const line_end = std.mem.indexOfScalarPos(u8, src, cursor, '\n') orelse src.len;
            var line = src[line_start..line_end];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (hereDocDelimiterMatches(delimiter, line)) {
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
        .pipe, .pipepipe, .ampamp => return true,
        else => {},
    }

    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    if (token.start + token.text.len != trimmed.len) return false;
    var slashes: usize = 0;
    var i = trimmed.len;
    while (i > 0 and trimmed[i - 1] == '\\') : (i -= 1) slashes += 1;
    return slashes % 2 == 1;
}
