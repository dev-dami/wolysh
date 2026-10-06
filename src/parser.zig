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
//! Control flow is a compound command in either syntax: the native braces
//! (`if cond { }`) or POSIX (`if list; then ...; fi`, `case`, `until`, ...).
//! Reserved words are only recognised where a command may start.
//!
//! The parser drives the lexer's mode, so the same text lexes the way the
//! surrounding construct needs it to.

const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const compound_assign = @import("compound.zig");
const test_ops = @import("builtins/test.zig");

pub const Error = error{ SyntaxError, OutOfMemory } || std.mem.Allocator.Error;

const keywords = [_][]const u8{ "let", "fn", "return", "alias", "env", "break", "continue" };

/// Words that close a POSIX command list; a statement never starts with one.
const list_terminators = [_][]const u8{ "then", "elif", "else", "fi", "do", "done", "esac" };

/// Names an expression gives a meaning of its own, so a condition that uses
/// one is never read as a command.
const expression_words = [_][]const u8{ "not", "and", "or", "true", "false", "null" };

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn oneOf(text: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (eql(text, option)) return true;
    }
    return false;
}

fn lineOf(t: lexer.Token) u32 {
    return std.math.cast(u32, t.line) orelse std.math.maxInt(u32);
}

/// Like bash, a function name may be almost any plain word (`0x0`, `a-b`,
/// `x/y`), but never one with quotes, expansions or `=`, nor a reserved word.
fn validFunctionName(name: []const u8) bool {
    if (name.len == 0 or name[0] == '-') return false;
    for (name) |c| {
        switch (c) {
            '\'', '"', '`', '$', '\\', '=', '(', ')', '{', '}', '[', ']', '*', '?', '~', '#' => return false,
            else => {},
        }
    }
    return !oneOf(name, &list_terminators) and !oneOf(name, &compound_keywords) and !oneOf(name, &.{ "function", "time", "in", "!" });
}

const compound_keywords = [_][]const u8{ "if", "while", "until", "for", "select", "case" };

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

fn isCaseTerminator(tag: lexer.Tag) bool {
    return tag == .dsemi or tag == .semi_amp or tag == .dsemi_amp;
}

/// A descriptor number such as `3` in `3>file` or `10` in `10>file`.
fn parseFdNumber(text: []const u8) ?i32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: i32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// What may precede a redirect operator: a number, or `{name}` asking the
/// shell to allocate a descriptor and store it in `name`.
const RedirectFd = struct { fd: i32 = -1, name: []const u8 = "" };

fn redirectFdWord(text: []const u8) ?RedirectFd {
    if (text.len > 2 and text[0] == '{' and text[text.len - 1] == '}') {
        const name = text[1 .. text.len - 1];
        return if (isIdentifier(name)) .{ .name = name } else null;
    }
    return .{ .fd = parseFdNumber(text) orelse return null };
}

/// Splits `NAME=value`, `NAME+=value` and `NAME[subscript]=value` when NAME
/// is a plain identifier. A quoted or otherwise non-identifier left-hand side
/// is an ordinary word.
fn parseAssignment(word: []const u8) ?ast.PrefixAssign {
    var i: usize = 0;
    while (i < word.len and (std.ascii.isAlphanumeric(word[i]) or word[i] == '_')) i += 1;
    const name = word[0..i];
    if (!isIdentifier(name)) return null;
    var index: ?[]const u8 = null;
    if (i < word.len and word[i] == '[') {
        const close = compound_assign.closeBracket(word, i) orelse return null;
        index = word[i + 1 .. close];
        i = close + 1;
    }
    var append = false;
    if (i < word.len and word[i] == '+') {
        append = true;
        i += 1;
    }
    if (i >= word.len or word[i] != '=') return null;
    return .{ .name = name, .value = word[i + 1 ..], .index = index, .append = append };
}

/// Commands whose `NAME=(...)` arguments are array assignments.
fn isDeclaration(word: []const u8) bool {
    return eql(word, "declare") or eql(word, "typeset") or eql(word, "local");
}

/// Everything a speculative parse can change. Here-document redirects are
/// only ever appended, so restoring their count and the consumed mark undoes
/// any bodies read in between; they are read again, identically, later.
const Save = struct {
    lex: lexer.State,
    tok: lexer.Token,
    heredoc_len: usize,
    heredoc_next: usize,
    heredoc_failed: bool,
    err_msg: []const u8,
    err_tok: lexer.Token,
};

const ParsedCondition = struct { value: ast.Condition, native: bool };
const ConditionList = struct { stmts: []ast.Stmt, native: bool };

pub const Parser = struct {
    lex: lexer.Lexer,
    arena: std.mem.Allocator,
    tok: lexer.Token,
    err_msg: []const u8 = "",
    err_tok: lexer.Token = .{ .tag = .eof, .text = "", .start = 0, .line = 0, .depth_before = 0, .group_depth_before = 0 },
    /// Here-document redirects in source order; bodies are read when the
    /// parser moves past the newline that ends their line.
    pending_heredocs: std.ArrayList(*ast.Redirect) = .empty,
    /// Index of the first redirect whose body has not been read yet.
    heredoc_next: usize = 0,
    heredoc_failed: bool = false,
    /// Set while reading a native `if`/`while`/`until` condition, where a
    /// standalone `{` after a command opens the body instead of a group.
    cond_brace: bool = false,

    pub fn init(arena: std.mem.Allocator, src: []const u8) Parser {
        return initAt(arena, src, 1);
    }

    /// Starts line numbering at `line`, so a re-parsed function body reports
    /// the lines of its original definition.
    pub fn initAt(arena: std.mem.Allocator, src: []const u8, line: usize) Parser {
        var lex = lexer.Lexer.init(src);
        lex.line = line;
        const first = lex.next();
        return .{ .lex = lex, .arena = arena, .tok = first };
    }

    pub fn parseProgram(self: *Parser) Error!ast.Program {
        return .{ .stmts = try self.parseAll() };
    }

    /// Parses the statements of `src` only; used by `eval` and the REPL.
    pub fn parseBlockSource(self: *Parser) Error!ast.Block {
        return .{ .stmts = try self.parseAll() };
    }

    fn parseAll(self: *Parser) Error![]ast.Stmt {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        try self.parseStmtList(&stmts);
        if (self.heredoc_failed) return error.SyntaxError;
        if (self.tok.tag != .eof) {
            if (self.tok.tag == .word) return self.fail("unexpected keyword");
            if (isCaseTerminator(self.tok.tag)) return self.fail("unexpected case terminator outside 'case'");
            return self.fail("unexpected input after the end of the statement");
        }
        if (self.heredoc_next < self.pending_heredocs.items.len) {
            return self.fail("expected a newline before the here-document body");
        }
        return stmts.toOwnedSlice(self.arena);
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
        return .{
            .lex = self.lex.save(),
            .tok = self.tok,
            .heredoc_len = self.pending_heredocs.items.len,
            .heredoc_next = self.heredoc_next,
            .heredoc_failed = self.heredoc_failed,
            .err_msg = self.err_msg,
            .err_tok = self.err_tok,
        };
    }

    fn restore(self: *Parser, s: Save) void {
        self.lex.restore(s.lex);
        self.tok = s.tok;
        self.pending_heredocs.items.len = s.heredoc_len;
        self.heredoc_next = s.heredoc_next;
        self.heredoc_failed = s.heredoc_failed;
        self.err_msg = s.err_msg;
        self.err_tok = s.err_tok;
    }

    fn advance(self: *Parser) void {
        // Here-document bodies start on the line after their operator.
        if (self.tok.tag == .newline) self.readHereDocBodies();
        self.tok = self.lex.next();
    }

    /// Re-lexes the current token in `m`. Used when the parser learns that the
    /// text it just read belongs to the other mode.
    fn setMode(self: *Parser, m: lexer.Mode) void {
        if (self.lex.mode == m) return;
        self.lex.mode = m;
        self.relex();
    }

    fn setCasePattern(self: *Parser, on: bool) void {
        if (self.lex.case_pattern == on) return;
        self.lex.case_pattern = on;
        self.relex();
    }

    fn relex(self: *Parser) void {
        // A newline lexes the same in every mode, and re-reading it would
        // lose track of here-document bodies already skipped after it.
        if (self.tok.tag == .newline) return;
        self.relexFrom(self.tok.start);
    }

    fn relexFrom(self: *Parser, pos: usize) void {
        self.lex.pos = pos;
        self.lex.line = self.tok.line;
        self.lex.depth = self.tok.depth_before;
        self.lex.group_depth = self.tok.group_depth_before;
        self.tok = self.lex.next();
    }

    fn skipSeparators(self: *Parser) void {
        while (self.tok.tag == .newline or self.tok.tag == .semi) self.advance();
    }

    fn skipNewlines(self: *Parser) void {
        while (self.tok.tag == .newline) self.advance();
    }

    /// True at a token that ends a statement list: end of input, a closing
    /// brace or paren, a `case` item terminator or a closing reserved word.
    fn atListEnd(self: *const Parser) bool {
        return switch (self.tok.tag) {
            .eof, .rbrace, .rparen, .dsemi, .semi_amp, .dsemi_amp => true,
            .word => oneOf(self.tok.text, &list_terminators),
            else => false,
        };
    }

    fn parseStmtList(self: *Parser, out: *std.ArrayList(ast.Stmt)) Error!void {
        // A nested list never ends at a native condition's `{`.
        const saved_cond_brace = self.cond_brace;
        self.cond_brace = false;
        defer self.cond_brace = saved_cond_brace;
        while (true) {
            self.setMode(.word);
            self.skipSeparators();
            if (self.atListEnd()) break;
            try out.append(self.arena, try self.parseStmt());
        }
    }

    fn parseStmt(self: *Parser) Error!ast.Stmt {
        if (self.tok.tag == .invalid) return self.fail("unexpected character");
        for (keywords) |kw| {
            if (isKeyword(self.tok, kw)) {
                if (eql(kw, "let")) return self.parseLet();
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
        const start = self.tok.start;
        const definition = if (isKeyword(self.tok, "function"))
            try self.parseFunctionKeyword()
        else if (self.tok.tag == .word)
            try self.tryParsePosixFunction()
        else
            null;
        if (definition) |stmt| {
            // `_complete() { ...; } && complete -F _complete cmd`
            if (self.tok.tag != .ampamp and self.tok.tag != .pipepipe) return stmt;
            const commands = try self.arena.alloc(ast.Command, 1);
            commands[0] = .{ .words = &.{}, .redirects = &.{}, .compound = try self.newCompound(.{ .statement = stmt }, start) };
            return .{ .pipeline = try self.parseLinks(.{ .commands = commands, .line = stmt.fn_decl.line }) };
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
        const line = lineOf(self.tok);
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
        return .{ .var_decl = .{ .name = name, .value = value, .line = line } };
    }

    /// `env` is also a real command, so this backtracks when what follows is
    /// not an `NAME = value` pair.
    fn tryParseEnv(self: *Parser) Error!?ast.Stmt {
        const line = lineOf(self.tok);
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
        return .{ .env_assign = .{ .name = name, .op = op, .value = value, .line = line } };
    }

    // --- compound commands ----------------------------------------------------

    /// Parses `if`, `while`, `until`, `for`, `select` or `case` at the start of
    /// a command, and `return`/`break`/`continue` where a command is expected.
    fn parseCompound(self: *Parser) Error!?*ast.Compound {
        const start = self.tok.start;
        const t = self.tok;
        const kind: ast.Compound.Kind = if (isKeyword(t, "if"))
            .{ .if_ = try self.parseIfClause() }
        else if (isKeyword(t, "while"))
            .{ .while_ = try self.parseWhileClause(false) }
        else if (isKeyword(t, "until"))
            .{ .while_ = try self.parseWhileClause(true) }
        else if (isKeyword(t, "for"))
            (try self.parseArithFor()) orelse .{ .for_ = try self.parseForClause(false) }
        else if (isKeyword(t, "select"))
            .{ .select_ = try self.parseForClause(true) }
        else if (isKeyword(t, "case"))
            .{ .case_ = try self.parseCaseClause() }
        else if (isKeyword(t, "return"))
            .{ .statement = try self.parseReturn() }
        else if (isKeyword(t, "break"))
            .{ .statement = try self.parseLoopControl(true) }
        else if (isKeyword(t, "continue"))
            .{ .statement = try self.parseLoopControl(false) }
        else if (t.tag == .word and eql(t.text, "[["))
            .{ .cond = try self.parseCondCommand() }
        else
            return null;
        return try self.newCompound(kind, start);
    }

    /// `(( expression ))`, or null when the parentheses do not close with
    /// `))`, which makes them nested subshells.
    fn parseArithCommand(self: *Parser) Error!?*ast.Compound {
        const start = self.tok.start;
        const parens = self.doubleParen() orelse return null;
        self.skipPast(parens.close + 2);
        return try self.newCompound(.{ .arith = parens.text }, start);
    }

    const DoubleParen = struct {
        /// The text between `((` and `))`.
        text: []const u8,
        /// Index of the first `)` of the closing `))`.
        close: usize,
    };

    /// The `((` at the current token and its contents, when `))` closes it.
    fn doubleParen(self: *const Parser) ?DoubleParen {
        if (self.tok.tag != .lparen) return null;
        const src = self.lex.src;
        const open = self.tok.start;
        if (open + 1 >= src.len or src[open + 1] != '(') return null;
        const close = lexer.arithmeticClose(src, open) orelse return null;
        return .{ .text = src[open + 2 .. close], .close = close };
    }

    /// Moves on to the token at `pos`, past source the parser has read itself.
    fn skipPast(self: *Parser, pos: usize) void {
        const start_line = self.tok.line - std.mem.count(u8, self.tok.text, "\n");
        self.lex.line = start_line + std.mem.count(u8, self.lex.src[self.tok.start..pos], "\n");
        self.lex.pos = pos;
        self.lex.depth = self.tok.depth_before;
        self.lex.group_depth = self.tok.group_depth_before;
        self.tok = self.lex.next();
    }

    /// `for (( init; test; step ))` with a `do ... done` or `{ }` body, or
    /// null, consuming nothing, for a `for NAME` loop.
    fn parseArithFor(self: *Parser) Error!?ast.Compound.Kind {
        const saved = self.save();
        self.advance(); // `for`
        self.setMode(.word);
        const parens = self.doubleParen() orelse {
            self.restore(saved);
            return null;
        };
        const parts = splitArithFor(parens.text) orelse return self.fail("expected 'for (( init; test; step ))'");
        self.skipPast(parens.close + 2);
        self.skipSeparators();
        const body = if (self.tok.tag == .lbrace) try self.parseBlock() else try self.parseDoBody();
        return .{ .arith_for = .{ .init = parts[0], .cond = parts[1], .step = parts[2], .body = body } };
    }

    // --- [[ ]] ------------------------------------------------------------------

    /// `[[ expression ]]`, with bash's precedence: `!` binds tightest, then
    /// `&&`, then `||`. The current token is `[[`.
    fn parseCondCommand(self: *Parser) Error!*ast.Cond {
        self.advance();
        if (self.atCondEnd()) return self.fail("expected an expression after '[['");
        const cond = try self.parseCondOr();
        if (!self.atCondEnd()) return self.fail("expected ']]' to close the conditional expression");
        self.advance();
        return cond;
    }

    fn atCondEnd(self: *const Parser) bool {
        return self.tok.tag == .word and eql(self.tok.text, "]]");
    }

    fn newCond(self: *Parser, cond: ast.Cond) Error!*ast.Cond {
        const node = try self.arena.create(ast.Cond);
        node.* = cond;
        return node;
    }

    fn parseCondOr(self: *Parser) Error!*ast.Cond {
        var lhs = try self.parseCondAnd();
        while (self.tok.tag == .pipepipe) {
            self.advance();
            const rhs = try self.parseCondAnd();
            lhs = try self.newCond(.{ .or_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseCondAnd(self: *Parser) Error!*ast.Cond {
        var lhs = try self.parseCondTerm();
        while (self.tok.tag == .ampamp) {
            self.advance();
            const rhs = try self.parseCondTerm();
            lhs = try self.newCond(.{ .and_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    /// One operand of `&&` or `||`. Newlines may surround it, but not split
    /// a test from its operator.
    fn parseCondTerm(self: *Parser) Error!*ast.Cond {
        self.skipNewlines();
        const term = try self.parseCondPrimary();
        self.skipNewlines();
        return term;
    }

    fn parseCondPrimary(self: *Parser) Error!*ast.Cond {
        switch (self.tok.tag) {
            .lparen => {
                self.advance();
                const inner = try self.parseCondOr();
                if (self.tok.tag != .rparen) return self.fail("expected ')' in the conditional expression");
                self.advance();
                return inner;
            },
            .word => if (self.atCondEnd()) return self.fail("expected an operand in the conditional expression"),
            else => return self.fail("unexpected token in the conditional expression"),
        }
        const first = self.tok.text;
        self.advance();
        if (eql(first, "!")) return self.newCond(.{ .not = try self.parseCondTerm() });
        if (test_ops.isUnaryOp(first)) {
            if (self.tok.tag != .word or self.atCondEnd()) return self.fail("expected an argument to the conditional unary operator");
            const operand = self.tok.text;
            self.advance();
            return self.newCond(.{ .unary = .{ .op = first, .operand = operand } });
        }
        const op: []const u8 = switch (self.tok.tag) {
            .in => "<",
            .out => ">",
            .word => if (eql(self.tok.text, "=~") or test_ops.isBinaryOp(self.tok.text))
                self.tok.text
            else if (self.atCondEnd())
                return self.lone(first)
            else
                return self.fail("expected a conditional binary operator"),
            // `[[ x ]]` is `[[ -n x ]]`, as with `test`.
            .ampamp, .pipepipe, .rparen => return self.lone(first),
            else => return self.fail("expected a conditional binary operator"),
        };
        if (eql(op, "=~")) self.tok = self.lex.nextRegexWord() else self.advance();
        if (self.tok.tag != .word or self.atCondEnd()) return self.fail("expected an argument to the conditional binary operator");
        const rhs = self.tok.text;
        self.advance();
        return self.newCond(.{ .binary = .{ .op = op, .lhs = first, .rhs = rhs } });
    }

    fn lone(self: *Parser, word: ast.Word) Error!*ast.Cond {
        return self.newCond(.{ .unary = .{ .op = "-n", .operand = word } });
    }

    /// `kind` as a node whose text runs from `start` to the current token.
    fn newCompound(self: *Parser, kind: ast.Compound.Kind, start: usize) Error!*ast.Compound {
        const node = try self.arena.create(ast.Compound);
        const text = self.lex.src[start..@max(start, self.tok.start)];
        node.* = .{ .kind = kind, .text = std.mem.trimEnd(u8, text, " \t\r\n") };
        return node;
    }

    /// A one-statement block holding `compound` as a command, which is how
    /// `elif` and `else if` nest.
    fn wrapCompound(self: *Parser, kind: ast.Compound.Kind, start: usize, line: u32) Error!*ast.Block {
        const commands = try self.arena.alloc(ast.Command, 1);
        commands[0] = .{ .words = &.{}, .redirects = &.{}, .compound = try self.newCompound(kind, start) };
        const stmts = try self.arena.alloc(ast.Stmt, 1);
        stmts[0] = .{ .pipeline = .{ .commands = commands, .line = line } };
        const block = try self.arena.create(ast.Block);
        block.* = .{ .stmts = stmts };
        return block;
    }

    /// `if cond { } [else ...]` or `if list; then list; [elif ...] [else list;] fi`.
    /// The current token is `if` or `elif`.
    fn parseIfClause(self: *Parser) Error!ast.If {
        self.advance(); // `if` / `elif`
        const cond = try self.parseCondition("then");
        if (cond.native) {
            const then = try self.parseBlock();
            return .{ .cond = cond.value, .then = then, .else_ = try self.parseNativeElse() };
        }
        self.advance(); // `then`
        const then = try self.parsePosixBody(&.{ "elif", "else", "fi" }, "expected 'fi' to close the 'if'");
        var else_: ?*ast.Block = null;
        if (isKeyword(self.tok, "elif")) {
            const start = self.tok.start;
            const line = lineOf(self.tok);
            // The nested clause consumes the shared `fi`.
            const nested = try self.parseIfClause();
            else_ = try self.wrapCompound(.{ .if_ = nested }, start, line);
            return .{ .cond = cond.value, .then = then, .else_ = else_ };
        }
        if (isKeyword(self.tok, "else")) {
            self.advance();
            else_ = try self.parsePosixBody(&.{"fi"}, "expected 'fi' to close the 'if'");
        }
        self.advance(); // `fi`
        return .{ .cond = cond.value, .then = then, .else_ = else_ };
    }

    /// `else { }` or `else if ...` after a native `if` block. The `else` may
    /// sit on its own line, which is a common layout.
    fn parseNativeElse(self: *Parser) Error!?*ast.Block {
        const saved = self.save();
        self.setMode(.word);
        self.skipSeparators();
        if (!isKeyword(self.tok, "else")) {
            self.restore(saved);
            return null;
        }
        self.advance();
        self.setMode(.word);
        if (isKeyword(self.tok, "if")) {
            const start = self.tok.start;
            const line = lineOf(self.tok);
            const nested = try self.parseIfClause();
            return try self.wrapCompound(.{ .if_ = nested }, start, line);
        }
        return try self.parseBlock();
    }

    /// `while`/`until` with a native `{ }` body or a POSIX `do ... done` one.
    fn parseWhileClause(self: *Parser, until: bool) Error!ast.While {
        self.advance(); // `while` / `until`
        const cond = try self.parseCondition("do");
        const body = if (cond.native) try self.parseBlock() else try self.parseDoBody();
        return .{ .cond = cond.value, .body = body, .until = until };
    }

    /// `for NAME in WORDS { }`, or `for NAME [in WORDS]; do ...; done` where a
    /// missing `in` means `"$@"`. `select` has the same shape.
    fn parseForClause(self: *Parser, is_select: bool) Error!ast.For {
        self.advance(); // `for` / `select`
        self.setMode(.word);
        if (self.tok.tag != .word or !isIdentifier(self.tok.text)) {
            return self.fail(if (is_select) "expected a variable name after 'select'" else "expected a loop variable after 'for'");
        }
        const name = self.tok.text;
        self.advance();
        var items: []ast.Word = undefined;
        if (isKeyword(self.tok, "in")) {
            self.advance();
            var list: std.ArrayList(ast.Word) = .empty;
            while (self.tok.tag == .word) {
                try list.append(self.arena, self.tok.text);
                self.advance();
            }
            items = try list.toOwnedSlice(self.arena);
            if (self.tok.tag == .lbrace) {
                if (items.len == 0) return self.fail("expected at least one value after 'in'");
                return .{ .name = name, .items = items, .body = try self.parseBlock() };
            }
            if (self.tok.tag != .semi and self.tok.tag != .newline) {
                return self.fail("expected ';' or a newline after the word list");
            }
        } else {
            if (self.tok.tag == .lbrace) return self.fail("expected 'in' after the loop variable");
            items = try self.arena.dupe(ast.Word, &.{"\"$@\""});
        }
        self.skipSeparators();
        return .{ .name = name, .items = items, .body = try self.parseDoBody() };
    }

    fn parseDoBody(self: *Parser) Error!*ast.Block {
        if (!isKeyword(self.tok, "do")) return self.fail("expected 'do'");
        self.advance();
        const body = try self.parsePosixBody(&.{"done"}, "expected 'done' to close the loop");
        self.advance(); // `done`
        return body;
    }

    /// A non-empty statement list that must stop at one of `closers`, which
    /// is left as the current token.
    fn parsePosixBody(self: *Parser, closers: []const []const u8, missing: []const u8) Error!*ast.Block {
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        try self.parseStmtList(&stmts);
        if (self.tok.tag != .word or !oneOf(self.tok.text, closers)) return self.fail(missing);
        if (stmts.items.len == 0) return self.fail("expected a command");
        const block = try self.arena.create(ast.Block);
        block.* = .{ .stmts = try stmts.toOwnedSlice(self.arena) };
        return block;
    }

    /// `case WORD in [(]PAT[|PAT]...) LIST ;; ... esac`.
    fn parseCaseClause(self: *Parser) Error!ast.Case {
        self.advance(); // `case`
        self.setMode(.word);
        if (self.tok.tag != .word) return self.fail("expected a word after 'case'");
        const word = self.tok.text;
        self.advance();
        self.skipNewlines();
        if (!isKeyword(self.tok, "in")) return self.fail("expected 'in' after the case word");
        self.advance();

        var items: std.ArrayList(ast.CaseItem) = .empty;
        while (true) {
            self.setMode(.word);
            self.skipNewlines();
            if (isKeyword(self.tok, "esac")) {
                self.advance();
                break;
            }
            if (self.tok.tag == .eof) return self.fail("expected 'esac' to close the 'case'");

            self.setCasePattern(true);
            if (self.tok.tag == .lparen) self.advance();
            var patterns: std.ArrayList(ast.Word) = .empty;
            while (true) {
                if (self.tok.tag != .word) return self.fail("expected a case pattern");
                try patterns.append(self.arena, self.tok.text);
                self.advance();
                if (self.tok.tag != .pipe) break;
                self.advance();
            }
            if (self.tok.tag != .rparen) return self.fail("expected ')' after the case pattern");
            // The body after `)` lexes normally.
            self.lex.case_pattern = false;
            self.advance();

            var body: std.ArrayList(ast.Stmt) = .empty;
            try self.parseStmtList(&body);
            const next: ast.CaseNext = switch (self.tok.tag) {
                .dsemi => .stop,
                .semi_amp => .fallthrough,
                .dsemi_amp => .test_next,
                else => if (isKeyword(self.tok, "esac")) .stop else return self.fail("expected ';;' or 'esac'"),
            };
            if (isCaseTerminator(self.tok.tag)) self.advance();
            try items.append(self.arena, .{
                .patterns = try patterns.toOwnedSlice(self.arena),
                .body = try body.toOwnedSlice(self.arena),
                .next = next,
            });
        }
        return .{ .word = word, .items = try items.toOwnedSlice(self.arena) };
    }

    /// The test of an `if`/`while`/`until`. A native condition ends at `{`
    /// and is read as an expression when it parses as one, otherwise as a
    /// command list (`if grep -q x file {`). A POSIX condition is a command
    /// list ending at `posix_word` (`then` or `do`).
    fn parseCondition(self: *Parser, posix_word: []const u8) Error!ParsedCondition {
        const start = self.save();
        self.setMode(.expr);
        if (self.parseExpr()) |expr| {
            if (self.tok.tag == .lbrace) {
                if (!self.commandLike(start.tok.start, self.tok.start)) {
                    return .{ .value = .{ .expr = expr }, .native = true };
                }
                const after_expr = self.save();
                self.restore(start);
                if (self.parseConditionList(posix_word)) |list| {
                    if (list.native) return .{ .value = .{ .expr = expr, .list = list.stmts }, .native = true };
                } else |err| {
                    if (err != error.SyntaxError) return err;
                }
                self.restore(after_expr);
                return .{ .value = .{ .expr = expr }, .native = true };
            }
        } else |err| {
            if (err != error.SyntaxError) return err;
        }
        self.restore(start);
        const list = try self.parseConditionList(posix_word);
        return .{ .value = .{ .list = list.stmts }, .native = list.native };
    }

    fn parseConditionList(self: *Parser, posix_word: []const u8) Error!ConditionList {
        const saved_cond_brace = self.cond_brace;
        self.cond_brace = true;
        defer self.cond_brace = saved_cond_brace;
        var stmts: std.ArrayList(ast.Stmt) = .empty;
        while (true) {
            self.setMode(.word);
            self.skipSeparators();
            if (isKeyword(self.tok, posix_word)) {
                if (stmts.items.len == 0) return self.fail("expected a condition");
                return .{ .stmts = try stmts.toOwnedSlice(self.arena), .native = false };
            }
            if (self.atListEnd()) {
                return self.fail(if (eql(posix_word, "then")) "expected 'then' or '{' after the condition" else "expected 'do' or '{' after the condition");
            }
            try stmts.append(self.arena, try self.parseStmt());
            if (self.tok.tag == .lbrace) return .{ .stmts = try stmts.toOwnedSlice(self.arena), .native = true };
        }
    }

    /// True when the source between `from` and `to` is only bare names joined
    /// by `!`, `&&` and `||`, which reads as an expression and as commands.
    fn commandLike(self: *const Parser, from: usize, to: usize) bool {
        var lx = lexer.Lexer.init(self.lex.src);
        lx.pos = from;
        lx.mode = .expr;
        var names: usize = 0;
        while (true) {
            const t = lx.next();
            if (t.tag == .eof or t.start >= to) break;
            switch (t.tag) {
                .ampamp, .pipepipe => {},
                // `!name` is one word to a command, so only `! name` negates.
                .bang => if (t.start + 1 < to and !std.ascii.isWhitespace(self.lex.src[t.start + 1])) return false,
                .ident => {
                    if (self.lex.src[t.start] == '$' or oneOf(t.text, &expression_words)) return false;
                    names += 1;
                },
                else => return false,
            }
        }
        return names > 0;
    }

    // --- functions ------------------------------------------------------------

    /// `name() COMPOUND` and `name(){ ...; }`. Returns null, consuming
    /// nothing, when the statement is not a definition.
    fn tryParsePosixFunction(self: *Parser) Error!?ast.Stmt {
        const t = self.tok;
        if (std.mem.indexOf(u8, t.text, "()") != null) {
            const name = self.takeGluedParens() orelse return null;
            return try self.parseFunctionBody(name, t.start, lineOf(t));
        }
        if (!validFunctionName(t.text)) return null;
        const saved = self.save();
        self.advance();
        if (self.tok.tag == .lparen) {
            self.advance();
            if (self.tok.tag == .rparen) {
                self.advance();
                return try self.parseFunctionBody(t.text, t.start, lineOf(t));
            }
        }
        self.restore(saved);
        return null;
    }

    /// `function name [()] COMPOUND`.
    fn parseFunctionKeyword(self: *Parser) Error!ast.Stmt {
        const decl_start = self.tok.start;
        const line = lineOf(self.tok);
        self.advance(); // `function`
        self.setMode(.word);
        if (self.tok.tag != .word) return self.fail("expected a function name after 'function'");
        const t = self.tok;
        const name = if (std.mem.indexOf(u8, t.text, "()") != null)
            self.takeGluedParens() orelse return self.fail("invalid function name")
        else blk: {
            self.advance();
            if (self.tok.tag == .lparen) {
                self.advance();
                if (self.tok.tag != .rparen) return self.fail("expected ')' after '('");
                self.advance();
            }
            break :blk t.text;
        };
        if (!validFunctionName(name)) return self.fail("invalid function name");
        return self.parseFunctionBody(name, decl_start, line);
    }

    /// For a word written `name()` or `name(){`, moves past the parentheses
    /// and returns the name; null, consuming nothing, for anything else.
    fn takeGluedParens(self: *Parser) ?[]const u8 {
        const t = self.tok;
        const paren = std.mem.indexOf(u8, t.text, "()") orelse return null;
        const name = t.text[0..paren];
        if (!validFunctionName(name)) return null;
        const rest = t.text[paren + 2 ..];
        if (rest.len == 0) {
            self.advance();
        } else if (eql(rest, "{")) {
            // `name(){`: the brace still opens the body.
            self.relexFrom(t.start + paren + 2);
        } else {
            return null;
        }
        return name;
    }

    /// The compound command (with any redirections) after a function header.
    fn parseFunctionBody(self: *Parser, name: []const u8, decl_start: usize, line: u32) Error!ast.Stmt {
        self.setMode(.word);
        self.skipNewlines();
        const body_line = lineOf(self.tok);
        const cmd = try self.parseCommand();
        const is_compound = if (cmd.compound) |c| c.kind != .statement else (cmd.group != null or cmd.subshell != null);
        if (!is_compound) return self.fail("expected a compound command as the function body");

        var decl_end = self.tok.start;
        const owns_heredoc = for (cmd.redirects) |redirect| {
            if (redirect.kind == .here_doc) break true;
        } else false;
        if (owns_heredoc and self.tok.tag == .newline) {
            // The definition's own here-document bodies follow its line; keep
            // them in the stored source.
            self.readHereDocBodies();
            decl_end = self.lex.pos;
        }

        const commands = try self.arena.alloc(ast.Command, 1);
        commands[0] = cmd;
        const stmts = try self.arena.alloc(ast.Stmt, 1);
        stmts[0] = .{ .pipeline = .{ .commands = commands, .line = body_line } };
        const block = try self.arena.create(ast.Block);
        block.* = .{ .stmts = stmts };
        return .{ .fn_decl = .{
            .name = name,
            .params = &.{},
            .body = block,
            .source = self.lex.src[decl_start..decl_end],
            .line = line,
        } };
    }

    fn parseFn(self: *Parser) Error!ast.Stmt {
        const line = lineOf(self.tok);
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
            .line = line,
        } };
    }

    fn parseReturn(self: *Parser) Error!ast.Stmt {
        self.advance(); // `return`
        self.setMode(.expr);
        switch (self.tok.tag) {
            .newline, .semi, .eof, .rbrace, .rparen, .amp, .ampamp, .pipe, .pipepipe, .dsemi, .semi_amp, .dsemi_amp => return .{ .return_ = null },
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
        return self.parseLinks(try self.parsePipeline());
    }

    /// The `&&`/`||` continuation of `head`.
    fn parseLinks(self: *Parser, head: ast.Pipeline) Error!ast.Pipeline {
        var first = head;
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
        const line = lineOf(self.tok);
        var time: ast.TimeMode = .none;
        if (isKeyword(self.tok, "time")) {
            self.advance();
            time = .default;
            if (isKeyword(self.tok, "-p")) {
                time = .posix;
                self.advance();
            }
            if (isKeyword(self.tok, "--")) self.advance();
            // A bare `time` reports on nothing, like bash.
            if (self.atPipelineEnd()) return .{ .commands = &.{}, .line = line, .time = time };
        }
        // A leading standalone `!` negates the whole pipeline; `! !` cancels.
        var negate = false;
        while (isKeyword(self.tok, "!")) {
            negate = !negate;
            self.advance();
        }
        var cmds: std.ArrayList(ast.Command) = .empty;
        try cmds.append(self.arena, try self.parseCommand());
        while (self.tok.tag == .pipe or self.tok.tag == .pipe_amp) {
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
            .line = line,
            .time = time,
        };
    }

    fn atPipelineEnd(self: *const Parser) bool {
        return switch (self.tok.tag) {
            .newline, .semi, .amp, .ampamp, .pipepipe => true,
            else => self.atListEnd(),
        };
    }

    /// The descriptor written directly before a redirect operator (`10>`,
    /// `{fd}>`). Removes that word from `words`; after a group, subshell or
    /// compound command it was never added there.
    fn takeRedirectFd(self: *Parser, last_word: ?lexer.Token, words: *std.ArrayList(ast.Word)) ?RedirectFd {
        const word = last_word orelse return null;
        if (word.start + word.text.len != self.tok.start) return null;
        const spec = redirectFdWord(word.text) orelse return null;
        if (words.items.len > 0 and words.items[words.items.len - 1].ptr == word.text.ptr) {
            words.items.len -= 1;
        }
        return spec;
    }

    fn parseCommand(self: *Parser) Error!ast.Command {
        self.setMode(.word);
        if (self.tok.tag == .word and oneOf(self.tok.text, &list_terminators)) return self.fail("unexpected keyword");
        var words: std.ArrayList(ast.Word) = .empty;
        var redirects: std.ArrayList(ast.Redirect) = .empty;
        var assigns: std.ArrayList(ast.PrefixAssign) = .empty;
        var last_word: ?lexer.Token = null;
        var subshell: ?[]ast.Stmt = null;
        var group: ?[]ast.Stmt = null;
        const compound: ?*ast.Compound = switch (self.tok.tag) {
            .word => try self.parseCompound(),
            .lparen => try self.parseArithCommand(),
            else => null,
        };

        while (true) {
            const after_body = subshell != null or group != null or compound != null;
            switch (self.tok.tag) {
                .word => {
                    if (after_body) {
                        // A reserved word ends the command: `if (cmd) then`.
                        if (oneOf(self.tok.text, &list_terminators)) break;
                        // After a group, subshell or compound command the only
                        // other word that may appear is a redirect's explicit
                        // descriptor number, as in `{ ...; } 2>file`.
                        const text = self.tok.text;
                        if (last_word == null and redirectFdWord(text) != null) {
                            last_word = self.tok;
                            self.advance();
                            continue;
                        }
                        if (subshell != null) return self.fail("unexpected word after a subshell");
                        if (compound != null) return self.fail("unexpected word after a compound command");
                        return self.fail("unexpected word after a command group");
                    }
                    // `NAME=value` words before the command word form the
                    // command's temporary environment.
                    if (words.items.len == 0 and redirects.items.len == 0) {
                        if (try self.assignmentWord()) |assignment| {
                            try assigns.append(self.arena, assignment);
                            self.advance();
                            last_word = null;
                            continue;
                        }
                    }
                    last_word = self.tok;
                    try words.append(self.arena, try self.declarationWord(words.items));
                    self.advance();
                },
                .lparen => {
                    if (after_body or words.items.len != 0 or
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
                    const started = after_body or words.items.len != 0 or
                        redirects.items.len != 0 or assigns.items.len != 0;
                    // In a native condition, `{` after a command opens the body.
                    if (started and self.cond_brace) break;
                    if (started) return self.fail("a command group must start a command");
                    self.advance();
                    self.setMode(.word);
                    var stmts: std.ArrayList(ast.Stmt) = .empty;
                    try self.parseStmtList(&stmts);
                    if (self.tok.tag != .rbrace) return self.fail("expected '}' to close the command group");
                    self.advance();
                    group = try stmts.toOwnedSlice(self.arena);
                    last_word = null;
                },
                .out, .out_append, .in, .out_clobber, .in_out => {
                    const base: ast.RedirectKind = switch (self.tok.tag) {
                        .out => .out,
                        .out_append => .out_append,
                        .out_clobber => .clobber,
                        .in_out => .read_write,
                        else => .in,
                    };
                    const spec = self.takeRedirectFd(last_word, &words);
                    if (after_body and last_word != null and spec == null) {
                        return self.fail("expected a redirect after the descriptor");
                    }
                    const fd_var: []const u8 = if (spec) |s| s.name else "";
                    const explicit: ?i32 = if (spec) |s| (if (s.name.len == 0) s.fd else null) else null;
                    last_word = null;
                    self.advance();
                    if (self.tok.tag == .amp and (base == .out or base == .in)) {
                        // The target (`2`, `-`, `3-`, `$fd`) is checked once it
                        // has been expanded.
                        self.advance();
                        if (self.tok.tag != .word) return self.fail("expected a file descriptor after '&'");
                        const target_fd = explicit orelse base.fd();
                        const kind: ast.RedirectKind = switch (target_fd) {
                            0 => .in_dup,
                            2 => .err_dup,
                            else => .out_dup,
                        };
                        try redirects.append(self.arena, .{
                            .kind = kind,
                            .target = self.tok.text,
                            .fd = explicit orelse kind.fd(),
                            .fd_var = fd_var,
                        });
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
                            else => base,
                        },
                        else => base,
                    } else base;
                    try redirects.append(self.arena, .{ .kind = kind, .target = self.tok.text, .fd = explicit orelse -1, .fd_var = fd_var });
                    self.advance();
                    last_word = null;
                },
                .out_both, .out_both_append => {
                    if (after_body and last_word != null) return self.fail("expected a redirect after the descriptor");
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
                    const taken = self.takeRedirectFd(last_word, &words);
                    if (after_body and last_word != null and taken == null) return self.fail("expected a redirect after the descriptor");
                    const spec = taken orelse RedirectFd{};
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a delimiter after '<<'");
                    const delimiter = parseHereDocDelimiter(self.arena, self.tok.text) catch return self.fail("invalid here-document delimiter");
                    try redirects.append(self.arena, .{
                        .kind = .here_doc,
                        .target = delimiter.text,
                        .expand_body = delimiter.expand,
                        .strip_tabs = strip,
                        .fd = spec.fd,
                        .fd_var = spec.name,
                    });
                    self.advance();
                    last_word = null;
                },
                .here_string => {
                    const taken = self.takeRedirectFd(last_word, &words);
                    if (after_body and last_word != null and taken == null) return self.fail("expected a redirect after the descriptor");
                    const spec = taken orelse RedirectFd{};
                    self.advance();
                    if (self.tok.tag != .word) return self.fail("expected a word after '<<<'");
                    try redirects.append(self.arena, .{ .kind = .here_string, .target = self.tok.text, .fd = spec.fd, .fd_var = spec.name });
                    self.advance();
                    last_word = null;
                },
                else => break,
            }
        }

        if ((subshell != null or group != null or compound != null) and last_word != null) {
            return self.fail("expected a redirect after the descriptor");
        }
        if (words.items.len == 0 and redirects.items.len == 0 and
            subshell == null and group == null and compound == null and assigns.items.len == 0)
        {
            return self.fail("expected a command");
        }
        // `a |& b` is `a 2>&1 | b`.
        if (self.tok.tag == .pipe_amp) try redirects.append(self.arena, .{ .kind = .err_dup, .target = "1", .fd = 2 });
        const command = ast.Command{
            .words = try words.toOwnedSlice(self.arena),
            .redirects = try redirects.toOwnedSlice(self.arena),
            .subshell = subshell,
            .group = group,
            .assigns = try assigns.toOwnedSlice(self.arena),
            .compound = compound,
        };
        for (command.redirects) |*redirect| {
            if (redirect.kind == .here_doc) try self.pending_heredocs.append(self.arena, redirect);
        }
        return command;
    }

    /// A `NAME=value` word before the command word, including the array forms
    /// `NAME[i]=v`, `NAME+=v` and `NAME=(...)`. A list may span lines, so the
    /// lexer is moved past its closing parenthesis.
    fn assignmentWord(self: *Parser) Error!?ast.PrefixAssign {
        var assignment = parseAssignment(self.tok.text) orelse return null;
        if (assignment.value.len == 0 or assignment.value[0] != '(') return assignment;
        if (assignment.index != null) return self.fail("an array element cannot be assigned a list");
        const open = self.tok.start + (@intFromPtr(assignment.value.ptr) - @intFromPtr(self.tok.text.ptr));
        const close = try self.skipCompound(open);
        assignment.value = self.lex.src[open + 1 .. close];
        assignment.compound = true;
        return assignment;
    }

    /// The current word, extended to the whole `NAME=(...)` list when it is an
    /// argument of `declare`, `typeset` or `local`.
    fn declarationWord(self: *Parser, words: []const ast.Word) Error!ast.Word {
        if (words.len == 0 or !isDeclaration(words[0])) return self.tok.text;
        const offset = compound_assign.openParen(self.tok.text) orelse return self.tok.text;
        const close = try self.skipCompound(self.tok.start + offset);
        return self.lex.src[self.tok.start .. close + 1];
    }

    /// Moves the lexer past the `)` closing the list opened at `open`.
    fn skipCompound(self: *Parser, open: usize) Error!usize {
        const src = self.lex.src;
        const close = compound_assign.findClose(src, open) orelse return self.fail("unterminated array assignment");
        if (close + 1 < src.len and std.mem.indexOfScalar(u8, " \t\r\n;&|<>)", src[close + 1]) == null) {
            return self.fail("unexpected text after an array assignment");
        }
        const start_line = self.tok.line - std.mem.count(u8, self.tok.text, "\n");
        self.lex.pos = close + 1;
        self.lex.line = start_line + std.mem.count(u8, src[self.tok.start .. close + 1], "\n");
        return close;
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

    /// Reads the bodies of every pending here-document, which start right
    /// after the current newline token, and moves the lexer past them. A
    /// failure is reported when the parse finishes.
    fn readHereDocBodies(self: *Parser) void {
        if (self.heredoc_next >= self.pending_heredocs.items.len) return;
        self.consumePendingHereDocs() catch |err| {
            if (err == error.OutOfMemory) self.fail("out of memory") catch {};
            self.heredoc_failed = true;
            self.lex.pos = self.lex.src.len;
        };
    }

    fn consumePendingHereDocs(self: *Parser) Error!void {
        var cursor = self.lex.pos;
        var line = self.lex.line;
        for (self.pending_heredocs.items[self.heredoc_next..]) |redirect| {
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
        self.heredoc_next = self.pending_heredocs.items.len;
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
                return self.parseIndexing(node);
            },
            .dquote, .squote => {
                const word = self.quotedWord();
                self.advance();
                node.* = .{ .string = word };
                return self.parseIndexing(node);
            },
            .word => {
                // Reached for `$(...)` in expression position: expanding the
                // word runs the substitution and yields its output.
                const word = self.tok.text;
                self.advance();
                node.* = .{ .string = word };
                return self.parseIndexing(node);
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
                    return self.parseIndexing(node);
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
                return self.parseIndexing(node);
            },
            .lparen => {
                self.advance();
                const inner = try self.parseExpr();
                if (self.tok.tag != .rparen) return self.fail("expected ')'");
                self.advance();
                return self.parseIndexing(inner);
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
                return self.parseIndexing(node);
            },
            else => return self.fail("expected an expression"),
        }
    }

    /// `target[index]`, repeated for `grid[0][1]`.
    fn parseIndexing(self: *Parser, target: *ast.Expr) Error!*ast.Expr {
        var current = target;
        while (self.tok.tag == .lbracket) {
            self.advance();
            const index = try self.parseExpr();
            if (self.tok.tag != .rbracket) return self.fail("expected ']' to close the index");
            self.advance();
            const node = try self.arena.create(ast.Expr);
            node.* = .{ .index = .{ .target = current, .index = index } };
            current = node;
        }
        return current;
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

/// The compound command a statement consists of, for tests.
/// The init, test and step of `for (( init; test; step ))`, split at the two
/// semicolons outside parentheses; null when there are not exactly two.
fn splitArithFor(text: []const u8) ?[3][]const u8 {
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (text, 0..) |c, i| {
        switch (c) {
            '(' => depth += 1,
            ')' => depth -|= 1,
            ';' => if (depth == 0) {
                if (count == 2) return null;
                parts[count] = text[start..i];
                count += 1;
                start = i + 1;
            },
            else => {},
        }
    }
    if (count != 2) return null;
    parts[2] = text[start..];
    return parts;
}

fn compoundOf(stmt: ast.Stmt) ast.Compound.Kind {
    return stmt.pipeline.commands[0].compound.?.kind;
}

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
    try std.testing.expect(compoundOf(prog.stmts[0]).if_.else_ != null);
    try std.testing.expectEqual(@as(usize, 1), compoundOf(prog.stmts[1]).for_.items.len);
    try std.testing.expectEqualStrings("*.rs", compoundOf(prog.stmts[1]).for_.items[0]);
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
    try std.testing.expectEqual(@as(usize, 1), compoundOf(prog.stmts[0]).while_.body.stmts.len);
    try std.testing.expect(compoundOf(prog.stmts[0]).while_.body.stmts[0] == .break_);
    try std.testing.expect(compoundOf(prog.stmts[1]).for_.body.stmts[0] == .continue_);
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
    try std.testing.expectEqual(@as(u32, 2), compoundOf(prog.stmts[0]).while_.body.stmts[0].break_);
    try std.testing.expectEqual(@as(u32, 3), compoundOf(prog.stmts[1]).for_.body.stmts[0].continue_);
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

test "parse array assignments and expression indexing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\a=(one "two three"
        \\   four) ; m[k]+=v
        \\declare -A m=([x]=1 [y]=2) n
        \\let v = l[0][-1]
        \\echo $LINENO
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), prog.stmts.len);
    const list = prog.stmts[0].pipeline.commands[0].assigns[0];
    try std.testing.expect(list.compound);
    try std.testing.expectEqualStrings("one \"two three\"\n   four", list.value);
    const element = prog.stmts[1].pipeline.commands[0].assigns[0];
    try std.testing.expectEqualStrings("k", element.index.?);
    try std.testing.expect(element.append);
    const words = prog.stmts[2].pipeline.commands[0].words;
    try std.testing.expectEqual(@as(usize, 4), words.len);
    try std.testing.expectEqualStrings("m=([x]=1 [y]=2)", words[2]);
    try std.testing.expect(prog.stmts[3].var_decl.value.* == .index);

    var bad = Parser.init(arena_state.allocator(), "a=(x y");
    try std.testing.expectError(error.SyntaxError, bad.parseProgram());
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

test "parse wide, named, clobbering and read-write redirects" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "cmd 10>wide {fd}>named >|forced 3<>both 2>&$fd 7>&3- arg");
    const prog = try p.parseProgram();
    const command = prog.stmts[0].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 2), command.words.len);
    try std.testing.expectEqualStrings("arg", command.words[1]);
    const redirects = command.redirects;
    try std.testing.expectEqual(@as(usize, 6), redirects.len);
    try std.testing.expectEqual(@as(i32, 10), redirects[0].targetFd());
    try std.testing.expectEqualStrings("fd", redirects[1].fd_var);
    try std.testing.expectEqualStrings("named", redirects[1].target);
    try std.testing.expectEqual(ast.RedirectKind.clobber, redirects[2].kind);
    try std.testing.expectEqual(@as(i32, 1), redirects[2].targetFd());
    try std.testing.expectEqual(ast.RedirectKind.read_write, redirects[3].kind);
    try std.testing.expectEqual(@as(i32, 3), redirects[3].targetFd());
    try std.testing.expectEqual(ast.RedirectKind.err_dup, redirects[4].kind);
    try std.testing.expectEqualStrings("$fd", redirects[4].target);
    try std.testing.expectEqual(@as(i32, 7), redirects[5].targetFd());
    try std.testing.expectEqualStrings("3-", redirects[5].target);
}

test "parse |& and descriptors after a group" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "make |& tee log\n{ echo; } >out 2>err\n");
    const prog = try p.parseProgram();
    const piped = prog.stmts[0].pipeline;
    try std.testing.expectEqual(@as(usize, 2), piped.commands.len);
    try std.testing.expectEqual(ast.RedirectKind.err_dup, piped.commands[0].redirects[0].kind);
    try std.testing.expectEqualStrings("1", piped.commands[0].redirects[0].target);
    const group = prog.stmts[1].pipeline.commands[0];
    try std.testing.expectEqual(@as(usize, 2), group.redirects.len);
    try std.testing.expectEqual(@as(i32, 1), group.redirects[0].targetFd());
    try std.testing.expectEqual(@as(i32, 2), group.redirects[1].targetFd());
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

test "parse POSIX if, loops, case and select" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\if [ -f x ]; then echo a; elif false
        \\then echo b; else echo c; fi
        \\while read -r line; do echo "$line"; done
        \\until false; do break; done
        \\for f in *.txt; do echo $f; done
        \\for arg
        \\do echo $arg
        \\done
        \\case "$1" in start|run) echo go;; (stop) echo halt;& *) echo any;;& esac
        \\select x in a b; do break; done
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 7), prog.stmts.len);

    const branch = compoundOf(prog.stmts[0]).if_;
    try std.testing.expect(branch.cond.list != null and branch.cond.expr == null);
    const elif = compoundOf(branch.else_.?.stmts[0]).if_;
    try std.testing.expectEqualStrings("echo", elif.else_.?.stmts[0].pipeline.commands[0].words[0]);

    try std.testing.expect(!compoundOf(prog.stmts[1]).while_.until);
    try std.testing.expect(compoundOf(prog.stmts[2]).while_.until);
    try std.testing.expectEqualStrings("*.txt", compoundOf(prog.stmts[3]).for_.items[0]);
    // No `in` list means "$@".
    try std.testing.expectEqualStrings("\"$@\"", compoundOf(prog.stmts[4]).for_.items[0]);

    const case = compoundOf(prog.stmts[5]).case_;
    try std.testing.expectEqualStrings("\"$1\"", case.word);
    try std.testing.expectEqual(@as(usize, 3), case.items.len);
    try std.testing.expectEqual(@as(usize, 2), case.items[0].patterns.len);
    try std.testing.expectEqualStrings("run", case.items[0].patterns[1]);
    try std.testing.expectEqual(ast.CaseNext.stop, case.items[0].next);
    try std.testing.expectEqual(ast.CaseNext.fallthrough, case.items[1].next);
    try std.testing.expectEqual(ast.CaseNext.test_next, case.items[2].next);

    try std.testing.expectEqualStrings("x", compoundOf(prog.stmts[6]).select_.name);
}

test "reserved words are plain words outside command position" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "echo if then fi do done case esac");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 8), prog.stmts[0].pipeline.commands[0].words.len);

    var p2 = Parser.init(arena_state.allocator(), "echo a; fi");
    try std.testing.expectError(error.SyntaxError, p2.parseProgram());
}

test "compound commands take redirections, pipes and lists" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\for i in a b { echo $i } > out.txt
        \\if true; then echo x; fi 2>&1 | grep x && echo found
        \\while read -r l; do echo $l; done < in.txt &
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), prog.stmts.len);

    const looped = prog.stmts[0].pipeline.commands[0];
    try std.testing.expect(looped.compound != null);
    try std.testing.expectEqual(ast.RedirectKind.out, looped.redirects[0].kind);

    const piped = prog.stmts[1].pipeline;
    try std.testing.expectEqual(@as(usize, 2), piped.commands.len);
    try std.testing.expectEqual(ast.RedirectKind.err_dup, piped.commands[0].redirects[0].kind);
    try std.testing.expectEqual(@as(i32, 2), piped.commands[0].redirects[0].targetFd());
    try std.testing.expectEqual(@as(usize, 1), piped.links.len);

    try std.testing.expect(prog.stmts[2].pipeline.background);
    try std.testing.expectEqual(ast.RedirectKind.in, prog.stmts[2].pipeline.commands[0].redirects[0].kind);
}

test "parse [[ ]] with bash precedence and operand words" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\[[ -f $f && ! $a == "x y"* || b < c ]] > out
        \\[[ $x =~ ^(a| b)c$ ]]
        \\[[ word ]]
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), prog.stmts.len);

    const first = prog.stmts[0].pipeline.commands[0];
    try std.testing.expectEqual(ast.RedirectKind.out, first.redirects[0].kind);
    const either = first.compound.?.kind.cond.or_;
    const both = either.lhs.and_;
    try std.testing.expectEqualStrings("-f", both.lhs.unary.op);
    try std.testing.expectEqualStrings("$f", both.lhs.unary.operand);
    try std.testing.expectEqualStrings("\"x y\"*", both.rhs.not.binary.rhs);
    try std.testing.expectEqualStrings("<", either.rhs.binary.op);

    // The regular expression is one word, spaces inside its group included.
    const re = compoundOf(prog.stmts[1]).cond.binary;
    try std.testing.expectEqualStrings("=~", re.op);
    try std.testing.expectEqualStrings("^(a| b)c$", re.rhs);

    try std.testing.expectEqualStrings("-n", compoundOf(prog.stmts[2]).cond.unary.op);
}

test "parse (( )), nested subshells and for (( ))" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\(( i < (n + 1) ))
        \\((echo nested) )
        \\for ((i = 0; i < 3; i++)); do echo $i; done
        \\for (( ; ; )) { break; }
        \\echo after
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), prog.stmts.len);
    try std.testing.expectEqualStrings(" i < (n + 1) ", compoundOf(prog.stmts[0]).arith);
    try std.testing.expect(prog.stmts[1].pipeline.commands[0].subshell != null);
    const loop = compoundOf(prog.stmts[2]).arith_for;
    try std.testing.expectEqualStrings("i = 0", loop.init);
    try std.testing.expectEqualStrings(" i < 3", loop.cond);
    try std.testing.expectEqualStrings(" i++", loop.step);
    try std.testing.expectEqualStrings(" ", compoundOf(prog.stmts[3]).arith_for.cond);
    try std.testing.expectEqual(@as(u32, 5), prog.stmts[4].pipeline.line);
}

test "malformed [[ ]] and for (( )) are syntax errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for ([_][]const u8{ "[[ ]]", "[[ a == ]]", "[[ -f ]]", "[[ a\n== a ]]", "[[ a == b", "for ((i=0; i<3)); do :; done" }) |src| {
        var p = Parser.init(arena, src);
        try std.testing.expectError(error.SyntaxError, p.parseProgram());
    }
}

test "native conditions are expressions first, then commands" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\if count > 10 { echo big }
        \\if grep -q x file { echo found }
        \\if ! ready { echo waiting }
        \\while $? == 0 && $# > 1 { break }
        \\if !ready { echo waiting }
    );
    const prog = try p.parseProgram();

    const expression = compoundOf(prog.stmts[0]).if_.cond;
    try std.testing.expect(expression.expr != null and expression.list == null);

    const command = compoundOf(prog.stmts[1]).if_.cond;
    try std.testing.expect(command.expr == null and command.list != null);
    try std.testing.expectEqual(@as(usize, 4), command.list.?[0].pipeline.commands[0].words.len);

    // Bare names alone could be either: both readings are kept.
    const either = compoundOf(prog.stmts[2]).if_.cond;
    try std.testing.expect(either.expr != null and either.list != null);
    try std.testing.expect(either.list.?[0].pipeline.negate);

    const special = compoundOf(prog.stmts[3]).while_.cond;
    try std.testing.expect(special.expr != null and special.list == null);

    // `!ready` would be a single command word, so it stays an expression.
    const glued = compoundOf(prog.stmts[4]).if_.cond;
    try std.testing.expect(glued.expr != null and glued.list == null);
}

test "POSIX function definitions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\greet() { echo "hi $1"; } > log.txt
        \\usage(){ echo usage; }
        \\function build { make; }
        \\function clean() ( rm -f out )
        \\f ()
        \\{
        \\    local x=1
        \\}
    );
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), prog.stmts.len);

    const greet = prog.stmts[0].fn_decl;
    try std.testing.expectEqualStrings("greet", greet.name);
    try std.testing.expectEqualStrings("greet() { echo \"hi $1\"; } > log.txt", greet.source);
    const body = greet.body.stmts[0].pipeline.commands[0];
    try std.testing.expect(body.group != null);
    try std.testing.expectEqualStrings("log.txt", body.redirects[0].target);

    try std.testing.expectEqualStrings("usage", prog.stmts[1].fn_decl.name);
    try std.testing.expectEqualStrings("build", prog.stmts[2].fn_decl.name);
    try std.testing.expect(prog.stmts[3].fn_decl.body.stmts[0].pipeline.commands[0].subshell != null);
    try std.testing.expectEqualStrings("f", prog.stmts[4].fn_decl.name);
    try std.testing.expectEqual(@as(u32, 5), prog.stmts[4].fn_decl.line);

    var bad = Parser.init(arena_state.allocator(), "f() echo hi");
    try std.testing.expectError(error.SyntaxError, bad.parseProgram());

    var listed = Parser.init(arena_state.allocator(), "_comp() { :; } && complete -F _comp cmd");
    const chain = (try listed.parseProgram()).stmts[0].pipeline;
    try std.testing.expect(compoundOf(.{ .pipeline = chain }).statement == .fn_decl);
    try std.testing.expectEqual(@as(usize, 1), chain.links.len);
}

test "statements record their lines, from a chosen first line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const src = "echo a\n\nif true; then\n  echo b\nfi\nlet x = 1\n";
    var p = Parser.init(arena_state.allocator(), src);
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(u32, 1), prog.stmts[0].pipeline.line);
    try std.testing.expectEqual(@as(u32, 3), prog.stmts[1].pipeline.line);
    try std.testing.expectEqual(@as(u32, 4), compoundOf(prog.stmts[1]).if_.then.stmts[0].pipeline.line);
    try std.testing.expectEqual(@as(u32, 6), prog.stmts[2].var_decl.line);

    var shifted = Parser.initAt(arena_state.allocator(), src, 10);
    const later = try shifted.parseProgram();
    try std.testing.expectEqual(@as(u32, 13), compoundOf(later.stmts[1]).if_.then.stmts[0].pipeline.line);
}

test "time prefixes a pipeline" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(), "time ls | wc -l\ntime -p ! false\ntime\n");
    const prog = try p.parseProgram();
    try std.testing.expectEqual(ast.TimeMode.default, prog.stmts[0].pipeline.time);
    try std.testing.expectEqual(@as(usize, 2), prog.stmts[0].pipeline.commands.len);
    try std.testing.expectEqual(ast.TimeMode.posix, prog.stmts[1].pipeline.time);
    try std.testing.expect(prog.stmts[1].pipeline.negate);
    try std.testing.expectEqual(@as(usize, 0), prog.stmts[2].pipeline.commands.len);
}

test "here-documents inside compound commands and their conditions" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var p = Parser.init(arena_state.allocator(),
        \\if cat <<EOF; then
        \\in condition
        \\EOF
        \\  cat <<EOF
        \\in body
        \\EOF
        \\fi
        \\while read -r l; do echo $l; done <<EOF
        \\loop input
        \\EOF
    );
    const prog = try p.parseProgram();
    const branch = compoundOf(prog.stmts[0]).if_;
    try std.testing.expectEqualStrings("in condition\n", branch.cond.list.?[0].pipeline.commands[0].redirects[0].body);
    try std.testing.expectEqualStrings("in body\n", branch.then.stmts[0].pipeline.commands[0].redirects[0].body);
    try std.testing.expectEqualStrings("loop input\n", prog.stmts[1].pipeline.commands[0].redirects[0].body);
}
