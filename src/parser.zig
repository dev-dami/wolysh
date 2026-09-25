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
        self.tok = self.lex.next();
    }

    fn skipSeparators(self: *Parser) void {
        while (self.tok.tag == .newline or self.tok.tag == .semi) self.advance();
    }

    fn parseStmtList(self: *Parser, out: *std.ArrayList(ast.Stmt)) Error!void {
        while (true) {
            self.setMode(.word);
            self.skipSeparators();
            if (self.tok.tag == .eof or self.tok.tag == .rbrace) break;
            try out.append(self.arena, try self.parseStmt());
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
                if (eql(kw, "break")) {
                    self.advance();
                    return .{ .break_ = {} };
                }
                if (eql(kw, "continue")) {
                    self.advance();
                    return .{ .continue_ = {} };
                }
                if (eql(kw, "env")) {
                    if (try self.tryParseEnv()) |stmt| return stmt;
                }
            }
        }
        return .{ .pipeline = try self.parseChain() };
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
            return .{ .pipeline = try self.parseChain() };
        }
        const name = self.tok.text;
        self.advance();
        if (!isKeyword(self.tok, "=")) {
            self.restore(saved);
            return .{ .pipeline = try self.parseChain() };
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
        return .{ .commands = try cmds.toOwnedSlice(self.arena), .background = background };
    }

    fn parseCommand(self: *Parser) Error!ast.Command {
        self.setMode(.word);
        var words: std.ArrayList(ast.Word) = .empty;
        var redirects: std.ArrayList(ast.Redirect) = .empty;

        while (true) {
            switch (self.tok.tag) {
                .word => {
                    try words.append(self.arena, self.tok.text);
                    self.advance();
                },
                .out, .out_append => {
                    var kind: ast.RedirectKind = if (self.tok.tag == .out) .out else .out_append;
                    if (words.items.len > 0 and eql(words.items[words.items.len - 1], "2")) {
                        words.items.len -= 1;
                        kind = if (self.tok.tag == .out) .err_out else .err_append;
                    }
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a file name after the redirect");
                    try redirects.append(self.arena, .{ .kind = kind, .target = self.tok.text });
                    self.advance();
                },
                .in => {
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a file name after '<'");
                    try redirects.append(self.arena, .{ .kind = .in, .target = self.tok.text });
                    self.advance();
                },
                else => break,
            }
        }

        if (words.items.len == 0 and redirects.items.len == 0) {
            return self.fail("expected a command");
        }
        return .{
            .words = try words.toOwnedSlice(self.arena),
            .redirects = try redirects.toOwnedSlice(self.arena),
        };
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

test "syntax errors are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "if { }");
    try std.testing.expectError(error.SyntaxError, p.parseProgram());
    try std.testing.expect(p.err_msg.len != 0);
}
