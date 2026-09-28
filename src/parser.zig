//! Recursive-descent parser for wolysh.
//!
//! Statement dispatch is by leading keyword, which is what keeps commands and
//! language constructs from colliding:
//!
//!     let name = "dami"            language
//!     if name == "dami" { ... }    language
//!     for f in *.rs { ... }        language, but the `in` list is shell words
//!     cargo build --profile $mode  command
//!
//! The parser drives the lexer's mode, so the same text lexes the way the
//! surrounding construct needs it to.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");

pub const Error = error{ SyntaxError, OutOfMemory } || std.mem.Allocator.Error;

const keywords = [_][]const u8{ "let", "if", "for", "while", "fn", "return", "alias", "env", "break", "continue" };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub fn isIdentifier(s: []const u8) bool {
    if (s.len == 0) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// True when the word is a bare, unquoted keyword (quoted words keep their
/// quote characters, so they never compare equal to a keyword).
fn isKeyword(t: lexer.Token, kw: []const u8) bool {
    return t.tag == .word and eql(t.text, kw);
}

/// A descriptor number small enough to track, e.g. `3` in `3>file`.
fn parseSmallFd(text: []const u8) ?i32 {
    if (text.len == 0) return null;
    var value: i32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    if (value > 31) return null;
    return value;
}

/// The descriptor written after `>&`/`<&`: a small number, or `-` to close.
fn isDupTarget(text: []const u8) bool {
    if (text.len == 1 and text[0] == '-') return true;
    return parseSmallFd(text) != null;
}

/// Splits `NAME=value` when NAME is a plain identifier. A quoted or otherwise
/// non-identifier left-hand side is an ordinary word.
fn parseAssignment(word: []const u8) ?ast.PrefixAssign {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return null;
    if (eq == 0) return null;
    const name = word[0..eq];
    if (!isIdentifier(name)) return null;
    return .{ .name = name, .value = word[eq + 1 ..] };
}

const Save = struct {
    lex: lexer.State,
    tok: lexer.Token,
};

pub const Parser = struct {
    lex: lexer.Lexer,
    arena: std.mem.Allocator,
    tok: lexer.Token,
    err_msg: []const u8 = "",
    err_tok: lexer.Token = undefined,
    pending_heredocs: std.ArrayList(*ast.Redirect) = .empty,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Parser {
        var lex = lexer.Lexer.init(src);
        const first = lex.next();
        return .{ .lex = lex, .arena = arena, .tok = first };
    }

    pub fn parseProgram(self: *Parser) Error!ast.Program {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        try self.parseStmtList(&stmts);
        if (self.tok.tag != .eof) return self.fail("unexpected input after the end of the statement");
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }

    /// Parses the statements of `src` only; used by `eval` and the REPL.
    pub fn parseBlockSource(self: *Parser) Error!ast.Block {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        try self.parseStmtList(&stmts);
        if (self.tok.tag != .eof) return self.fail("unexpected input after the end of the statement");
        return .{ .stmts = try stmts.toOwnedSlice(self.arena) };
    }

    fn fail(self: *Parser, msg: []const u8) Error {
        if (self.err_msg.len == 0) {
            self.err_msg = msg;
            self.err_tok = self.tok;
        }
        return error.SyntaxError;
    }

    /// Human-readable description of the last syntax error.
    pub fn message(self: *const Parser, buf: []u8) []const u8 {
        const t = self.err_tok;
        const shown = if (t.tag == .eof) "end of input" else t.text;
        if (t.tag == .eof) {
            return std.fmt.bufPrint(buf, "{s}", .{self.err_msg}) catch self.err_msg;
        }
        return std.fmt.bufPrint(buf, "{s} (got '{s}' on line {d})", .{ self.err_msg, shown, t.line }) catch self.err_msg;
    }

    fn save(self: *const Parser) Save {
        return .{ .lex = self.lex.save(), .tok = self.tok };
    }

    fn restore(self: *Parser, s: Save) void {
        self.lex.restore(s.lex);
        self.tok = s.tok;
    }

    fn advance(self: *Parser) void {
        self.tok = self.lex.next();
    }

    /// Re-lexes the current token in `m`. Used when the parser learns that the
    /// text it just read belongs to the other mode.
    fn setMode(self: *Parser, m: lexer.Mode) void {
        if (self.lex.mode == m) return;
        self.lex.mode = m;
        self.lex.pos = self.tok.start;
        self.lex.line = self.tok.line;
        self.lex.depth = self.tok.depth_before;
        self.lex.group_depth = self.tok.group_depth_before;
        self.tok = self.lex.next();
    }

    fn skipSeparators(self: *Parser) void {
        while (self.tok.tag == .newline or self.tok.tag == .semi) self.advance();
    }

    fn parseStmtList(self: *Parser, out: *std.ArrayList(ast.Stmt)) Error!void {
        const heredoc_baseline = self.pending_heredocs.items.len;
        while (true) {
            self.setMode(.word);
            self.skipSeparators();
            if (self.tok.tag == .eof or self.tok.tag == .rbrace or self.tok.tag == .rparen) break;
            try out.append(self.arena, try self.parseStmt());
            if (self.tok.tag == .newline and self.pending_heredocs.items.len > heredoc_baseline) {
                try self.consumePendingHereDocs(heredoc_baseline);
            } else if (self.tok.tag == .eof and self.pending_heredocs.items.len > heredoc_baseline) {
                return self.fail("expected a newline before the here-document body");
            }
        }
    }

    fn parseStmt(self: *Parser) Error!ast.Stmt {
        if (self.tok.tag == .invalid) return self.fail("unexpected character");
        for (keywords) |kw| {
            if (isKeyword(self.tok, kw)) {
                if (eql(kw, "let")) return self.parseLet();
                if (eql(kw, "if")) return self.parseIf();
                if (eql(kw, "for")) return self.parseFor();
                if (eql(kw, "while")) return self.parseWhile();
                if (eql(kw, "fn")) return self.parseFn();
                if (eql(kw, "return")) return self.parseReturn();
                if (eql(kw, "alias")) return self.parseAlias();
                if (eql(kw, "break")) return self.parseLoopControl(true);
                if (eql(kw, "continue")) return self.parseLoopControl(false);
                if (eql(kw, "env")) {
                    if (try self.tryParseEnv()) |stmt| return stmt;
                }
            }
        }
        return .{ .pipeline = try self.parseCommandChain() };
    }

    fn parseCommandChain(self: *Parser) Error!ast.Pipeline {
        return self.parseChain();
    }

    /// `break [n]` / `continue [n]`. The optional count must be a positive
    /// integer; anything else is a syntax error.
    fn parseLoopControl(self: *Parser, is_break: bool) Error!ast.Stmt {
        self.advance(); // `break` / `continue`
        var count: u32 = 1;
        if (self.tok.tag == .word) {
            const value = std.fmt.parseInt(u32, self.tok.text, 10) catch
                return self.fail(if (is_break) "break expects a positive number" else "continue expects a positive number");
            if (value == 0) return self.fail(if (is_break) "break expects a positive number" else "continue expects a positive number");
            count = value;
            self.advance();
        }
        return if (is_break) .{ .break_ = count } else .{ .continue_ = count };
    }

    // --- language constructs -------------------------------------------------

    fn parseLet(self: *Parser) Error!ast.Stmt {
        self.advance(); // `let`
        if (self.tok.tag != .word or !isIdentifier(self.tok.text)) {
            return self.fail("expected a variable name after 'let'");
        }
        const name = self.tok.text;
        self.advance();
        if (!isKeyword(self.tok, "=")) return self.fail("expected '=' after the variable name");
        self.advance();
        self.setMode(.expr);
        const value = try self.parseExpr();
        return .{ .var_decl = .{ .name = name, .value = value } };
    }

    /// `env` is also a real command, so this backtracks when what follows is
    /// not an `NAME = value` pair.
    fn tryParseEnv(self: *Parser) Error!?ast.Stmt {
        const saved = self.save();
        self.advance(); // `env`
        self.setMode(.word);
        if (self.tok.tag != .word or !isIdentifier(self.tok.text)) {
            self.restore(saved);
            return null;
        }
        const name = self.tok.text;
        self.advance();
        const op: ast.EnvOp = if (isKeyword(self.tok, "="))
            .set
        else if (isKeyword(self.tok, "+="))
            .append
        else {
            self.restore(saved);
            return null;
        };
        self.advance();
        self.setMode(.expr);
        const value = try self.parseExpr();
        return .{ .env_assign = .{ .name = name, .op = op, .value = value } };
    }

    fn parseIf(self: *Parser) Error!ast.Stmt {
        self.advance(); // `if`
        self.setMode(.expr);
        const cond = try self.parseExpr();
        const then = try self.parseBlock();
        var else_: ?*ast.Block = null;
        self.setMode(.word);
        // Allow the `else` on its own line, which is a common layout.
        self.skipSeparators();
        if (isKeyword(self.tok, "else")) {
            self.advance();
            self.setMode(.word);
            if (isKeyword(self.tok, "if")) {
                const nested = try self.parseIf();
                const stmts = try self.arena.alloc(ast.Stmt, 1);
                stmts[0] = nested;
                const block = try self.arena.create(ast.Block);
                block.* = .{ .stmts = stmts };
                else_ = block;
            } else {
                else_ = try self.parseBlock();
            }
        }
        return .{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } };
    }

    fn parseWhile(self: *Parser) Error!ast.Stmt {
        self.advance(); // `while`
        self.setMode(.expr);
        const cond = try self.parseExpr();
        const body = try self.parseBlock();
        return .{ .while_ = .{ .cond = cond, .body = body } };
    }

    fn parseFor(self: *Parser) Error!ast.Stmt {
        self.advance(); // `for`
        self.setMode(.word);
        if (self.tok.tag != .word or !isIdentifier(self.tok.text)) {
            return self.fail("expected a loop variable after 'for'");
        }
        const name = self.tok.text;
        self.advance();
        if (!isKeyword(self.tok, "in")) return self.fail("expected 'in' after the loop variable");
        self.advance();
        var items: std.ArrayList(ast.Word) = .empty;
        while (self.tok.tag == .word) {
            try items.append(self.arena, self.tok.text);
            self.advance();
        }
        if (items.items.len == 0) return self.fail("expected at least one value after 'in'");
        const body = try self.parseBlock();
        return .{ .for_ = .{
            .name = name,
            .items = try items.toOwnedSlice(self.arena),
            .body = body,
        } };
    }

    fn parseFn(self: *Parser) Error!ast.Stmt {
        const decl_start = self.tok.start;
        self.advance(); // `fn`
        self.setMode(.expr);
        if (self.tok.tag != .ident) return self.fail("expected a function name after 'fn'");
        const name = self.tok.text;
        self.advance();
        if (self.tok.tag != .lparen) return self.fail("expected '(' after the function name");
        self.advance();
        var params: std.ArrayList(ast.Param) = .empty;
        while (self.tok.tag != .rparen) {
            if (self.tok.tag != .ident) return self.fail("expected a parameter name");
            const pname = self.tok.text;
            self.advance();
            var default: ?*ast.Expr = null;
            if (self.tok.tag == .assign) {
                self.advance();
                default = try self.parseExpr();
            }
            try params.append(self.arena, .{ .name = pname, .default = default });
            if (self.tok.tag == .comma) {
                self.advance();
                continue;
            }
            break;
        }
        if (self.tok.tag != .rparen) return self.fail("expected ')' to close the parameter list");
        self.advance();
        const body = try self.parseBlock();
        // The next token starts after the closing brace; slicing to it keeps the
        // whole declaration, which the executor stores for later calls.
        const decl_end = self.tok.start;
        return .{ .fn_decl = .{
            .name = name,
            .params = try params.toOwnedSlice(self.arena),
            .body = body,
            .source = self.lex.src[decl_start..decl_end],
        } };
    }

    fn parseReturn(self: *Parser) Error!ast.Stmt {
        self.advance(); // `return`
        self.setMode(.expr);
        switch (self.tok.tag) {
            .newline, .semi, .eof, .rbrace => return .{ .return_ = null },
            else => return .{ .return_ = try self.parseExpr() },
        }
    }

    fn parseAlias(self: *Parser) Error!ast.Stmt {
        // `alias` is also a real command (`alias ll` prints one), so fall back
        // to a plain pipeline unless a `NAME = value` definition follows.
        const saved = self.save();
        self.advance(); // `alias`
        if (self.tok.tag != .word or !isIdentifier(self.tok.text)) {
            self.restore(saved);
            return .{ .pipeline = try self.parseCommandChain() };
        }
        const name = self.tok.text;
        self.advance();
        if (!isKeyword(self.tok, "=")) {
            self.restore(saved);
            return .{ .pipeline = try self.parseCommandChain() };
        }
        self.advance();
        const value = std.mem.trim(u8, self.restOfLine(), " \t\r");
        if (value.len == 0) return self.fail("expected a value after '='");
        return .{ .alias = .{ .name = name, .value = value } };
    }

    /// Consumes the remainder of the current line as raw text, which is what an
    /// alias body needs (`alias ll = ls -la`).
    fn restOfLine(self: *Parser) []const u8 {
        const src = self.lex.src;
        var i = if (self.tok.tag == .eof) src.len else self.tok.start;
        const from = i;
        while (i < src.len and src[i] != '\n') {
            const c = src[i];
            if (c == '\\' and i + 1 < src.len) {
                i += 2;
                continue;
            }
            if (c == '\'' or c == '"') {
                const q = c;
                i += 1;
                while (i < src.len and src[i] != q) {
                    if (src[i] == '\\' and q == '"' and i + 1 < src.len) i += 1;
                    i += 1;
                }
                if (i < src.len) i += 1;
                continue;
            }
            i += 1;
        }
        self.lex.pos = i;
        self.lex.mode = .word;
        self.tok = self.lex.next();
        return src[from..i];
    }

    fn parseBlock(self: *Parser) Error!*ast.Block {
        if (self.tok.tag != .lbrace) return self.fail("expected '{' to open a block");
        self.advance();
        self.setMode(.word);
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        try self.parseStmtList(&stmts);
        if (self.tok.tag != .rbrace) return self.fail("expected '}' to close the block");
        self.advance();
        const block = try self.arena.create(ast.Block);
        block.* = .{ .stmts = try stmts.toOwnedSlice(self.arena) };
        return block;
    }

    // --- pipelines ----------------------------------------------------------

    fn parseChain(self: *Parser) Error!ast.Pipeline {
        var first = try self.parsePipeline();
        var links: std.ArrayList(ast.ChainLink) = .empty;
        while (self.tok.tag == .ampamp or self.tok.tag == .pipepipe) {
            const op: ast.ChainOp = if (self.tok.tag == .ampamp) .and_ else .or_;
            self.advance();
            while (self.tok.tag == .newline) self.advance();
            const p = try self.parsePipeline();
            try links.append(self.arena, .{ .op = op, .pipeline = p });
        }
        first.links = try links.toOwnedSlice(self.arena);
        return first;
    }

    fn parsePipeline(self: *Parser) Error!ast.Pipeline {
        self.setMode(.word);
        // A leading standalone `!` negates the whole pipeline; `! !` cancels.
        var negate = false;
        while (isKeyword(self.tok, "!")) {
            negate = !negate;
            self.advance();
        }
        var cmds: std.ArrayList(ast.Command) = .empty;
        try cmds.append(self.arena, try self.parseCommand());
        while (self.tok.tag == .pipe) {
            self.advance();
            while (self.tok.tag == .newline) self.advance();
            try cmds.append(self.arena, try self.parseCommand());
        }
        var background = false;
        if (self.tok.tag == .amp) {
            background = true;
            self.advance();
        }
        return .{
            .commands = try cmds.toOwnedSlice(self.arena),
            .background = background,
            .negate = negate,
        };
    }

    /// The descriptor written directly before a redirect operator, when the
    /// last command word is a small number. Removes that word from `words`.
    fn takeRedirectFd(self: *Parser, last_word: ?lexer.Token, words: *std.ArrayList(ast.Word)) ?i32 {
        const word = last_word orelse return null;
        if (words.items.len == 0 or word.text.len == 0 or word.text.len > 2) return null;
        if (word.start + word.text.len != self.tok.start) return null;
        const fd = parseSmallFd(word.text) orelse return null;
        words.items.len -= 1;
        return fd;
    }

    fn parseCommand(self: *Parser) Error!ast.Command {
        self.setMode(.word);
        var words: std.ArrayList(ast.Word) = .empty;
        var redirects: std.ArrayList(ast.Redirect) = .empty;
        var assigns: std.ArrayList(ast.PrefixAssign) = .empty;
        var last_word: ?lexer.Token = null;
        var subshell: ?[]ast.Stmt = null;
        var group: ?[]ast.Stmt = null;

        while (true) {
            switch (self.tok.tag) {
                .word => {
                    if (subshell != null or group != null) {
                        // After a group or subshell the only word that may
                        // appear is a redirect's explicit descriptor number,
                        // as in `{ ...; } 2>file`.
                        const text = self.tok.text;
                        if (words.items.len == 0 and redirects.items.len == 0 and
                            text.len > 0 and text.len <= 2 and parseSmallFd(text) != null)
                        {
                            last_word = self.tok;
                            self.advance();
                            continue;
                        }
                        if (subshell != null) return self.fail("unexpected word after a subshell");
                        return self.fail("unexpected word after a command group");
                    }
                    // `NAME=value` words before the command word form the
                    // command's temporary environment.
                    if (words.items.len == 0 and redirects.items.len == 0) {
                        if (parseAssignment(self.tok.text)) |assignment| {
                            try assigns.append(self.arena, assignment);
                            self.advance();
                            last_word = null;
                            continue;
                        }
                    }
                    last_word = self.tok;
                    try words.append(self.arena, self.tok.text);
                    self.advance();
                },
                .lparen => {
                    if (subshell != null or group != null or words.items.len != 0 or
                        redirects.items.len != 0 or assigns.items.len != 0)
                    {
                        return self.fail("a subshell must start a command");
                    }
                    self.advance();
                    var stmts: std.ArrayList(ast.Stmt) = .empty;
                    try self.parseStmtList(&stmts);
                    if (self.tok.tag != .rparen) return self.fail("expected ')' to close the subshell");
                    self.advance();
                    subshell = try stmts.toOwnedSlice(self.arena);
                },
                .lbrace => {
                    if (subshell != null or group != null or words.items.len != 0 or
                        redirects.items.len != 0 or assigns.items.len != 0)
                    {
                        return self.fail("a command group must start a command");
                    }
                    self.advance();
                    self.setMode(.word);
                    var stmts: std.ArrayList(ast.Stmt) = .empty;
                    try self.parseStmtList(&stmts);
                    if (self.tok.tag != .rbrace) return self.fail("expected '}' to close the command group");
                    self.advance();
                    group = try stmts.toOwnedSlice(self.arena);
                    last_word = null;
                },
                .out, .out_append, .in => {
                    const base: ast.RedirectKind = switch (self.tok.tag) {
                        .out => .out,
                        .out_append => .out_append,
                        else => .in,
                    };
                    const explicit = self.takeRedirectFd(last_word, &words);
                    last_word = null;
                    self.advance();
                    if (self.tok.tag == .amp) {
                        self.advance();
                        if (self.tok.tag != .word or !isDupTarget(self.tok.text)) {
                            return self.fail("expected a file descriptor after '&'");
                        }
                        const target_fd = explicit orelse base.fd();
                        const kind: ast.RedirectKind = switch (target_fd) {
                            0 => .in_dup,
                            2 => .err_dup,
                            else => .out_dup,
                        };
                        try redirects.append(self.arena, .{ .kind = kind, .target = self.tok.text, .fd = explicit orelse kind.fd() });
                        self.advance();
                        continue;
                    }
                    if (self.tok.tag != .word) {
                        return self.fail(if (base == .in) "expected a file name after '<'" else "expected a file name after the redirect");
                    }
                    const kind: ast.RedirectKind = if (explicit) |n| switch (n) {
                        2 => switch (base) {
                            .out => .err_out,
                            .out_append => .err_append,
                            .in => .in,
                            else => base,
                        },
                        else => base,
                    } else base;
                    try redirects.append(self.arena, .{ .kind = kind, .target = self.tok.text, .fd = explicit orelse -1 });
                    self.advance();
                    last_word = null;
                },
                .out_both, .out_both_append => {
                    const append = self.tok.tag == .out_both_append;
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a file name after '&>'");
                    try redirects.append(self.arena, .{
                        .kind = if (append) .out_append else .out,
                        .target = self.tok.text,
                    });
                    // `&>file` is exactly `>file 2>&1`.
                    try redirects.append(self.arena, .{ .kind = .err_dup, .target = "1" });
                    self.advance();
                    last_word = null;
                },
                .here_doc, .here_doc_strip => {
                    const strip = self.tok.tag == .here_doc_strip;
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a delimiter after '<<'");
                    const delimiter = parseHereDocDelimiter(self.arena, self.tok.text) catch return self.fail("invalid here-document delimiter");
                    try redirects.append(self.arena, .{
                        .kind = .here_doc,
                        .target = delimiter.text,
                        .expand_body = delimiter.expand,
                        .strip_tabs = strip,
                    });
                    self.advance();
                    last_word = null;
                },
                .here_string => {
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a word after '<<<'");
                    try redirects.append(self.arena, .{ .kind = .here_string, .target = self.tok.text });
                    self.advance();
                    last_word = null;
                },
                else => break,
            }
        }

        if ((subshell != null or group != null) and last_word != null) {
            return self.fail("expected a redirect after the descriptor");
        }
        if (words.items.len == 0 and redirects.items.len == 0 and
            subshell == null and group == null and assigns.items.len == 0)
        {
            return self.fail("expected a command");
        }
        const command = ast.Command{
            .words = try words.toOwnedSlice(self.arena),
            .redirects = try redirects.toOwnedSlice(self.arena),
            .subshell = subshell,
            .group = group,
            .assigns = try assigns.toOwnedSlice(self.arena),
        };
        for (command.redirects) |*redirect| {
            if (redirect.kind == .here_doc) try self.pending_heredocs.append(self.arena, redirect);
        }
        return command;
    }

    const HereDocDelimiter = struct { text: []const u8, expand: bool };

    /// `<<-`: leading tabs are removed from every body line.
    fn stripLeadingTabs(arena: std.mem.Allocator, body: []const u8) Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        var lines = std.mem.splitScalar(u8, body, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) try out.append(arena, '\n');
            first = false;
            try out.appendSlice(arena, std.mem.trimStart(u8, line, "\t"));
        }
        return out.toOwnedSlice(arena);
    }

    fn parseHereDocDelimiter(arena: std.mem.Allocator, raw: []const u8) Error!HereDocDelimiter {
        var text: std.ArrayList(u8) = .empty;
        var quote: u8 = 0;
        var expand = true;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and quote != '\'' and i + 1 < raw.len) {
                const next = raw[i + 1];
                if (next == '\n') {
                    i += 2;
                    continue;
                }
                if (quote != '"' or next == '$' or next == '`' or next == '"' or next == '\\') {
                    expand = false;
                    try text.append(arena, next);
                    i += 2;
                    continue;
                }
            }
            if (quote != 0) {
                if (c == quote) {
                    quote = 0;
                } else {
                    try text.append(arena, c);
                }
                i += 1;
                continue;
            }
            if (c == '\'' or c == '"') {
                quote = c;
                expand = false;
            } else {
                try text.append(arena, c);
            }
            i += 1;
        }
        if (quote != 0) return error.SyntaxError;
        return .{ .text = try text.toOwnedSlice(arena), .expand = expand };
    }

    fn consumePendingHereDocs(self: *Parser, first_pending: usize) Error!void {
        if (self.tok.tag != .newline) return self.fail("expected a newline before the here-document body");

        var cursor = self.lex.pos;
        var line = self.lex.line;
        for (self.pending_heredocs.items[first_pending..]) |redirect| {
            const body_start = cursor;
            var found = false;
            while (cursor <= self.lex.src.len) {
                const line_start = cursor;
                const line_end = std.mem.indexOfScalarPos(u8, self.lex.src, cursor, '\n') orelse self.lex.src.len;
                var current = self.lex.src[line_start..line_end];
                if (current.len > 0 and current[current.len - 1] == '\r') current = current[0 .. current.len - 1];
                const candidate = if (redirect.strip_tabs) std.mem.trimStart(u8, current, "\t") else current;
                if (std.mem.eql(u8, candidate, redirect.target)) {
                    redirect.body = if (redirect.strip_tabs)
                        try stripLeadingTabs(self.arena, self.lex.src[body_start..line_start])
                    else
                        self.lex.src[body_start..line_start];
                    cursor = if (line_end < self.lex.src.len) line_end + 1 else line_end;
                    if (line_end < self.lex.src.len) line += 1;
                    found = true;
                    break;
                }
                if (line_end == self.lex.src.len) break;
                cursor = line_end + 1;
                line += 1;
            }
            if (!found) return self.fail("unterminated here-document");
        }

        self.lex.pos = cursor;
        self.lex.line = line;
        self.tok = self.lex.next();
        self.pending_heredocs.items.len = first_pending;
    }

    // --- expressions --------------------------------------------------------

    fn parseExpr(self: *Parser) Error!*ast.Expr {
        return self.parseBin(0);
    }

    /// Precedence of the operator at the current token, or null if it does not
    /// continue an expression.
    fn infixPrec(self: *Parser) ?u8 {
        return switch (self.tok.tag) {
            .pipepipe => 1,
            .ampamp => 2,
            .eq, .ne => 3,
            .lt, .le, .gt, .ge => 4,
            .plus, .minus => 5,
            .star, .slash, .percent => 6,
            .ident => blk: {
                if (eql(self.tok.text, "or")) break :blk 1;
                if (eql(self.tok.text, "and")) break :blk 2;
                break :blk null;
            },
            else => null,
        };
    }

    fn parseBin(self: *Parser, min_prec: u8) Error!*ast.Expr {
        var lhs = try self.parseUnary();
        while (self.infixPrec()) |p| {
            if (p < min_prec) break;
            const t = self.tok;
            self.advance();
            const rhs = try self.parseBin(p + 1);
            lhs = try self.makeBin(t, lhs, rhs);
        }
        return lhs;
    }

    fn makeBin(self: *Parser, t: lexer.Token, lhs: *ast.Expr, rhs: *ast.Expr) Error!*ast.Expr {
        const node = try self.arena.create(ast.Expr);
        if (t.tag == .pipepipe or (t.tag == .ident and eql(t.text, "or"))) {
            node.* = .{ .logic = .{ .op = .or_, .lhs = lhs, .rhs = rhs } };
            return node;
        }
        if (t.tag == .ampamp or (t.tag == .ident and eql(t.text, "and"))) {
            node.* = .{ .logic = .{ .op = .and_, .lhs = lhs, .rhs = rhs } };
            return node;
        }
        const op: ast.BinOp = switch (t.tag) {
            .plus => .add,
            .minus => .sub,
            .star => .mul,
            .slash => .div,
            .percent => .mod,
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .le => .le,
            .gt => .gt,
            .ge => .ge,
            else => return self.fail("unsupported operator"),
        };
        node.* = .{ .bin = .{ .op = op, .lhs = lhs, .rhs = rhs } };
        return node;
    }

    fn parseUnary(self: *Parser) Error!*ast.Expr {
        const node = try self.arena.create(ast.Expr);
        switch (self.tok.tag) {
            .minus => {
                self.advance();
                node.* = .{ .un = .{ .op = .neg, .operand = try self.parseUnary() } };
                return node;
            },
            .bang => {
                self.advance();
                node.* = .{ .un = .{ .op = .not, .operand = try self.parseUnary() } };
                return node;
            },
            .ident => {
                if (eql(self.tok.text, "not")) {
                    self.advance();
                    node.* = .{ .un = .{ .op = .not, .operand = try self.parseUnary() } };
                    return node;
                }
            },
            else => {},
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) Error!*ast.Expr {
        const node = try self.arena.create(ast.Expr);
        switch (self.tok.tag) {
            .number => {
                const text = self.tok.text;
                self.advance();
                if (std.mem.indexOfScalar(u8, text, '.') != null) {
                    node.* = .{ .float = std.fmt.parseFloat(f64, text) catch return self.fail("invalid number") };
                } else {
                    node.* = .{ .int = std.fmt.parseInt(i64, text, 10) catch return self.fail("invalid number") };
                }
                return node;
            },
            .dquote, .squote => {
                const word = self.quotedWord();
                self.advance();
                node.* = .{ .string = word };
                return node;
            },
            .word => {
                // Reached for `$(...)` in expression position: expanding the
                // word runs the substitution and yields its output.
                const word = self.tok.text;
                self.advance();
                node.* = .{ .string = word };
                return node;
            },
            .ident => {
                const name = self.tok.text;
                self.advance();
                // A call is checked first, so a function may be named after a
                // keyword-like literal (`true()`, `null()`).
                if (self.tok.tag == .lparen) {
                    self.advance();
                    var args: std.ArrayList(*ast.Expr) = .empty;
                    while (self.tok.tag != .rparen) {
                        try args.append(self.arena, try self.parseExpr());
                        if (self.tok.tag == .comma) {
                            self.advance();
                            continue;
                        }
                        break;
                    }
                    if (self.tok.tag != .rparen) return self.fail("expected ')' to close the argument list");
                    self.advance();
                    node.* = .{ .call = .{
                        .callee = name,
                        .args = try args.toOwnedSlice(self.arena),
                    } };
                    return node;
                }
                if (eql(name, "true")) {
                    node.* = .{ .boolean = true };
                    return node;
                }
                if (eql(name, "false")) {
                    node.* = .{ .boolean = false };
                    return node;
                }
                if (eql(name, "null")) {
                    node.* = .null_lit;
                    return node;
                }
                node.* = .{ .ident = name };
                return node;
            },
            .lparen => {
                self.advance();
                const inner = try self.parseExpr();
                if (self.tok.tag != .rparen) return self.fail("expected ')'");
                self.advance();
                return inner;
            },
            .lbracket => {
                self.advance();
                var items: std.ArrayList(*ast.Expr) = .empty;
                while (self.tok.tag != .rbracket) {
                    try items.append(self.arena, try self.parseExpr());
                    if (self.tok.tag == .comma) {
                        self.advance();
                        continue;
                    }
                    break;
                }
                if (self.tok.tag != .rbracket) return self.fail("expected ']' to close the list");
                self.advance();
                node.* = .{ .list = try items.toOwnedSlice(self.arena) };
                return node;
            },
            else => return self.fail("expected an expression"),
        }
    }

    /// Rebuilds the raw source text of a quoted literal, quotes included, so
    /// the expander can apply its usual interpolation rules.
    fn quotedWord(self: *Parser) ast.Word {
        const t = self.tok;
        const end = t.start + t.text.len + 2;
        if (end > self.lex.src.len) return self.lex.src[t.start..@min(end, self.lex.src.len)];
        return self.lex.src[t.start..end];
    }
};

test "parse a plain pipeline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "ls -la | grep zig > out.txt");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.stmts.len);
    const pipe = prog.stmts[0].pipeline;
    try std.testing.expectEqual(@as(usize, 2), pipe.commands.len);
    try std.testing.expectEqualStrings("ls", pipe.commands[0].words[0]);
    try std.testing.expectEqualStrings("-la", pipe.commands[0].words[1]);
    try std.testing.expectEqual(@as(usize, 1), pipe.commands[1].redirects.len);
    try std.testing.expectEqual(ast.RedirectKind.out, pipe.commands[1].redirects[0].kind);
}

test "parse let and env" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\let count = 4 * (10 + 2)
        \\env PATH += "/opt/bin"
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    try std.testing.expectEqualStrings("count", prog.stmts[0].var_decl.name);
    try std.testing.expectEqualStrings("PATH", prog.stmts[1].env_assign.name);
    try std.testing.expectEqual(ast.EnvOp.append, prog.stmts[1].env_assign.op);
}

test "env falls back to the env command" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "env -i /bin/sh");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), prog.stmts[0].pipeline.commands[0].words.len);
}

test "parse if for while fn" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\if name == "dami" {
        \\    print "hello"
        \\} else {
        \\    print "hi"
        \\}
        \\for file in *.rs {
        \\    print file
        \\}
        \\while count > 0 {
        \\    let count = count - 1
        \\}
        \\fn build(mode = "debug") {
        \\    cargo build --profile $mode
        \\}
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 4), prog.stmts.len);
    try std.testing.expect(prog.stmts[0].if_.else_ != null);
    try std.testing.expectEqual(@as(usize, 1), prog.stmts[1].for_.items.len);
    try std.testing.expectEqualStrings("*.rs", prog.stmts[1].for_.items[0]);
    try std.testing.expectEqual(@as(usize, 1), prog.stmts[3].fn_decl.params.len);
    try std.testing.expect(prog.stmts[3].fn_decl.params[0].default != null);
}

test "parse && and || chains" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "make && ./run || echo failed");
    const prog = try p.parseProgram();
    const pl = prog.stmts[0].pipeline;
    try std.testing.expectEqual(@as(usize, 2), pl.links.len);
    try std.testing.expectEqual(ast.ChainOp.and_, pl.links[0].op);
    try std.testing.expectEqual(ast.ChainOp.or_, pl.links[1].op);
}

test "parse background and redirects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "sleep 10 & echo hi 2> err.txt");
    const prog = try p.parseProgram();
    try std.testing.expect(prog.stmts[0].pipeline.background);
    try std.testing.expectEqual(ast.RedirectKind.err_out, prog.stmts[1].pipeline.commands[0].redirects[0].kind);
}

test "parse ordered file descriptor duplication" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "echo hi 2>&1 > out.txt");
    const prog = try p.parseProgram();
    const redirects = prog.stmts[0].pipeline.commands[0].redirects;
    try std.testing.expectEqual(@as(usize, 2), redirects.len);
    try std.testing.expectEqual(ast.RedirectKind.err_dup, redirects[0].kind);
    try std.testing.expectEqualStrings("1", redirects[0].target);
    try std.testing.expectEqual(ast.RedirectKind.out, redirects[1].kind);
    try std.testing.expectEqualStrings("out.txt", redirects[1].target);
}

test "parse here-document body and quoted delimiter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\cat <<EOF
        \\body $value
        \\EOF
        \\cat <<'LITERAL'
        \\$value
        \\LITERAL
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    const expanded = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqual(ast.RedirectKind.here_doc, expanded.kind);
    try std.testing.expect(expanded.expand_body);
    try std.testing.expectEqualStrings("body $value\n", expanded.body);
    const literal = prog.stmts[1].pipeline.commands[0].redirects[0];
    try std.testing.expect(!literal.expand_body);
    try std.testing.expectEqualStrings("$value\n", literal.body);
}

test "parse here-document delimiter quote removal preserves ordinary double-quoted backslashes" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cat <<\"\\EOF\"\nbody\n\\EOF");
    const prog = try p.parseProgram();
    const redirect = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqualStrings("\\EOF", redirect.target);
    try std.testing.expect(!redirect.expand_body);
    try std.testing.expectEqualStrings("body\n", redirect.body);
}

test "parse empty quoted here-document delimiter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cat <<''\nbody\n\n");
    const prog = try p.parseProgram();
    const redirect = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqualStrings("", redirect.target);
    try std.testing.expectEqualStrings("body\n", redirect.body);
}

test "parse multiple here-documents after a semicolon-separated command line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\cat <<FIRST <<'SECOND'; echo done
        \\first body
        \\FIRST
        \\$HOME
        \\SECOND
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    const redirects = prog.stmts[0].pipeline.commands[0].redirects;
    try std.testing.expectEqual(@as(usize, 2), redirects.len);
    try std.testing.expectEqualStrings("first body\n", redirects[0].body);
    try std.testing.expectEqualStrings("$HOME\n", redirects[1].body);
}

test "parse nested subshells and piped command groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "(echo first; (echo nested)) | cat");
    const prog = try p.parseProgram();
    const pipeline = prog.stmts[0].pipeline;
    try std.testing.expectEqual(@as(usize, 2), pipeline.commands.len);
    try std.testing.expectEqual(@as(usize, 2), pipeline.commands[0].subshell.?.len);
    const nested = pipeline.commands[0].subshell.?[1].pipeline.commands[0].subshell.?;
    try std.testing.expectEqual(@as(usize, 1), nested.len);
}

test "parse break and continue" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\while true {
        \\    break
        \\}
        \\for x in 1 {
        \\    continue
        \\}
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    try std.testing.expectEqual(@as(usize, 1), prog.stmts[0].while_.body.stmts.len);
    try std.testing.expect(prog.stmts[0].while_.body.stmts[0] == .break_);
    try std.testing.expect(prog.stmts[1].for_.body.stmts[0] == .continue_);
}

test "parse break and continue counts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\while true {
        \\    break 2
        \\}
        \\for x in 1 {
        \\    continue 3
        \\}
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(u32, 2), prog.stmts[0].while_.body.stmts[0].break_);
    try std.testing.expectEqual(@as(u32, 3), prog.stmts[1].for_.body.stmts[0].continue_);
}

test "break and continue reject a non-numeric count" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "while true {\n    break nope\n}\n");
    try std.testing.expectError(error.SyntaxError, p.parseProgram());

    var p2 = Parser.init(arena_state.allocator(), "while true {\n    continue 0\n}\n");
    try std.testing.expectError(error.SyntaxError, p2.parseProgram());
}

test "parse a brace command group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\{
        \\    echo hi
        \\    cd /tmp
        \\}
        \\{ echo one; } > out.txt
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    const group = prog.stmts[0].pipeline.commands[0].group.?;
    try std.testing.expectEqual(@as(usize, 2), group.len);
    try std.testing.expectEqualStrings("echo", group[0].pipeline.commands[0].words[0]);
    try std.testing.expectEqualStrings("hi", group[0].pipeline.commands[0].words[1]);

    const redirected = prog.stmts[1].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 1), redirected.group.?.len);
    try std.testing.expectEqual(ast.RedirectKind.out, redirected.redirects[0].kind);
    try std.testing.expectEqualStrings("out.txt", redirected.redirects[0].target);
}

test "brace characters inside words are untouched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "find . -exec ls {} \\;\necho ${HOME}-x\n");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    try std.testing.expectEqualStrings("{}", prog.stmts[0].pipeline.commands[0].words[4]);
    try std.testing.expectEqualStrings("${HOME}-x", prog.stmts[1].pipeline.commands[0].words[1]);
}

test "parse pipeline negation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "! true\n! ! false\n!a\n");
    const prog = try p.parseProgram();
    try std.testing.expect(prog.stmts[0].pipeline.negate);
    try std.testing.expect(!prog.stmts[1].pipeline.negate);
    // `!a` is a command word, not negation.
    try std.testing.expect(!prog.stmts[2].pipeline.negate);
    try std.testing.expectEqualStrings("!a", prog.stmts[2].pipeline.commands[0].words[0]);
}

test "parse command-prefix assignments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\FOO=bar BAZ="a b" cmd arg
        \\COUNT=7
        \\cmd COUNT=7
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), prog.stmts.len);

    const first = prog.stmts[0].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 2), first.assigns.len);
    try std.testing.expectEqualStrings("FOO", first.assigns[0].name);
    try std.testing.expectEqualStrings("bar", first.assigns[0].value);
    try std.testing.expectEqualStrings("BAZ", first.assigns[1].name);
    try std.testing.expectEqualStrings("\"a b\"", first.assigns[1].value);
    try std.testing.expectEqual(@as(usize, 2), first.words.len);
    try std.testing.expectEqualStrings("cmd", first.words[0]);

    // With no command word the assignment stands alone.
    const second = prog.stmts[1].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 0), second.words.len);
    try std.testing.expectEqualStrings("COUNT", second.assigns[0].name);

    // After the command word an assignment is an ordinary argument.
    const third = prog.stmts[2].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 0), third.assigns.len);
    try std.testing.expectEqualStrings("COUNT=7", third.words[1]);
}

test "parse numbered and merged redirects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cmd 3>file 2>&3 <&0 4>&- &> all.txt &>> more.txt");
    const prog = try p.parseProgram();
    const redirects = prog.stmts[0].pipeline.commands[0].redirects;
    try std.testing.expectEqual(@as(usize, 8), redirects.len);

    try std.testing.expectEqual(ast.RedirectKind.out, redirects[0].kind);
    try std.testing.expectEqual(@as(i32, 3), redirects[0].targetFd());
    try std.testing.expectEqualStrings("file", redirects[0].target);

    try std.testing.expectEqual(ast.RedirectKind.err_dup, redirects[1].kind);
    try std.testing.expectEqual(@as(i32, 2), redirects[1].targetFd());
    try std.testing.expectEqualStrings("3", redirects[1].target);

    try std.testing.expectEqual(ast.RedirectKind.in_dup, redirects[2].kind);
    try std.testing.expectEqual(@as(i32, 0), redirects[2].targetFd());

    try std.testing.expectEqual(ast.RedirectKind.out_dup, redirects[3].kind);
    try std.testing.expectEqual(@as(i32, 4), redirects[3].targetFd());
    try std.testing.expectEqualStrings("-", redirects[3].target);

    // `&>file` is `>file 2>&1`.
    try std.testing.expectEqual(ast.RedirectKind.out, redirects[4].kind);
    try std.testing.expectEqualStrings("all.txt", redirects[4].target);
    try std.testing.expectEqual(ast.RedirectKind.err_dup, redirects[5].kind);
    try std.testing.expectEqualStrings("1", redirects[5].target);

    try std.testing.expectEqual(ast.RedirectKind.out_append, redirects[6].kind);
    try std.testing.expectEqualStrings("more.txt", redirects[6].target);
    try std.testing.expectEqual(ast.RedirectKind.err_dup, redirects[7].kind);
}

test "parse a numbered input redirect" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cmd 3<input.txt");
    const prog = try p.parseProgram();
    const redirect = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqual(ast.RedirectKind.in, redirect.kind);
    try std.testing.expectEqual(@as(i32, 3), redirect.targetFd());
    try std.testing.expectEqual(@as(usize, 1), prog.stmts[0].pipeline.commands[0].words.len);
}

test "parse tab-stripping here-documents" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cat <<-EOF\n\tone\n\t\ttwo\n\tEOF\n");
    const prog = try p.parseProgram();
    const redirect = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqual(ast.RedirectKind.here_doc, redirect.kind);
    try std.testing.expect(redirect.strip_tabs);
    try std.testing.expectEqualStrings("EOF", redirect.target);
    try std.testing.expectEqualStrings("one\ntwo\n", redirect.body);
}

test "a space after << keeps a literal dash delimiter" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cat << -EOF\nbody\n-EOF\n");
    const prog = try p.parseProgram();
    const redirect = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expect(!redirect.strip_tabs);
    try std.testing.expectEqualStrings("-EOF", redirect.target);
    try std.testing.expectEqualStrings("body\n", redirect.body);
}

test "parse here-strings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cat <<<\"hi there\"\ncat <<<$word\n");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 2), prog.stmts.len);
    const first = prog.stmts[0].pipeline.commands[0].redirects[0];
    try std.testing.expectEqual(ast.RedirectKind.here_string, first.kind);
    try std.testing.expectEqual(@as(i32, 0), first.targetFd());
    try std.testing.expectEqualStrings("\"hi there\"", first.target);
    try std.testing.expectEqualStrings("$word", prog.stmts[1].pipeline.commands[0].redirects[0].target);
}

test "syntax errors are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "if { }");
    try std.testing.expectError(error.SyntaxError, p.parseProgram());
    try std.testing.expect(p.err_msg.len != 0);
}
