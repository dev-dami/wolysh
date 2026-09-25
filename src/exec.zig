//! Execution: statements, pipelines, functions and expression evaluation.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const shellmod = @import("shell.zig");
const expand_mod = @import("expand.zig");
const builtins = @import("builtins.zig");
const proc = @import("proc.zig");
const value = @import("value.zig");
const fs = @import("fs.zig");
const command_suggest = @import("command_suggest.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };

// Two scratch buffers for value comparison, so both sides can be rendered at
// once. The shell is single-threaded, so these need no synchronisation.
var compare_buf_a: [64]u8 = undefined;
var compare_buf_b: [64]u8 = undefined;

inline fn isString(v: Value) bool {
    return std.meta.activeTag(v) == .string;
}
inline fn isList(v: Value) bool {
    return std.meta.activeTag(v) == .list;
}
inline fn isBool(v: Value) bool {
    return std.meta.activeTag(v) == .boolean;
}
inline fn isFloat(v: Value) bool {
    return std.meta.activeTag(v) == .float;
}

/// Parses and runs `src`, returning the resulting status.
pub fn runSource(sh: *Shell, src: []const u8) u8 {
    const arena = sh.scratch();
    var p = parser_mod.Parser.init(arena, src);
    const program = p.parseProgram() catch {
        reportSyntaxError(sh, &p);
        sh.last_status = 2;
        return 2;
    };
    const status = runStmts(sh, program.stmts);
    sh.last_status = status;
    return status;
}

fn reportSyntaxError(sh: *Shell, p: *const parser_mod.Parser) void {
    var buf: [512]u8 = undefined;
    const msg = p.message(&buf);
    var line: [640]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "wsh: {s}\n", .{msg}) catch msg;
    sys.writeStr(sh.default_err, text);
}

/// True when `src` is a complete statement. The REPL uses this to decide
/// whether to keep reading with a continuation prompt.
///
/// This inspects the token stream rather than the parser's error position: the
/// input is unfinished when a bracket, paren or quote is still open, or when
/// the last token is an operator that needs a right-hand side. So `if x {`
/// keeps the prompt open while a genuine error like `alias ll` (missing its
/// `=`) is reported straight away.
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
    // In word mode these are plain words, so they are matched by text: a
    // trailing `=` or `else` means the statement is not finished.
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

/// Tokens that cannot end a statement because something must follow them.
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

/// Reports whether every quote in `src` is closed.
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

// --- statements -------------------------------------------------------------

pub fn runStmts(sh: *Shell, stmts: []const ast.Stmt) u8 {
    var status: u8 = 0;
    for (stmts) |stmt| {
        status = runStmt(sh, stmt);
        sh.last_status = status;
        if (sh.should_exit or sh.return_pending or sh.break_pending or sh.continue_pending) break;
    }
    return status;
}

fn runStmt(sh: *Shell, stmt: ast.Stmt) u8 {
    const arena = sh.scratch();
    switch (stmt) {
        .pipeline => |pipeline| return runChain(sh, pipeline),

        .var_decl => |decl| {
            const v = evalExpr(sh, arena, decl.value) catch |err| return exprError(sh, err);
            sh.setVar(decl.name, v) catch return 1;
            return 0;
        },

        .env_assign => |assign| {
            const v = evalExpr(sh, arena, assign.value) catch |err| return exprError(sh, err);
            const text = v.renderAlloc(arena) catch return 1;
            switch (assign.op) {
                .set => sh.setEnv(assign.name, text) catch return 1,
                .append => {
                    const existing = sh.getEnv(assign.name) orelse "";
                    const joined = std.fmt.allocPrint(arena, "{s}{s}", .{ existing, text }) catch return 1;
                    sh.setEnv(assign.name, joined) catch return 1;
                },
            }
            return 0;
        },

        .if_ => |branch| {
            const cond = evalExpr(sh, arena, branch.cond) catch |err| return exprError(sh, err);
            if (cond.truthy()) return runStmts(sh, branch.then.stmts);
            if (branch.else_) |else_block| return runStmts(sh, else_block.stmts);
            return 0;
        },

        .for_ => |loop| return runFor(sh, loop),
        .while_ => |loop| return runWhile(sh, loop),

        .fn_decl => |decl| {
            sh.defineFunc(decl.name, decl.source) catch return 1;
            return 0;
        },

        .return_ => |maybe_expr| {
            if (maybe_expr) |e| {
                const v = evalExpr(sh, arena, e) catch |err| return exprError(sh, err);
                sh.return_code = statusFromValue(v);
            } else {
                sh.return_code = sh.last_status;
            }
            sh.return_pending = true;
            return sh.return_code;
        },

        .break_ => {
            sh.break_pending = true;
            return 0;
        },

        .continue_ => {
            sh.continue_pending = true;
            return 0;
        },

        .alias => |a| {
            sh.setAlias(a.name, a.value) catch return 1;
            return 0;
        },
    }
}

fn exprError(sh: *Shell, err: anyerror) u8 {
    switch (err) {
        error.CommandNotFound => return 127,
        error.OutOfMemory => {
            sys.writeStr(sh.default_err, "wsh: out of memory\n");
            return 1;
        },
        error.UnsupportedArithmetic => {
            sys.writeStr(sh.default_err, "wsh: $((...)) is not supported; use `let` for arithmetic\n");
            return 2;
        },
        error.UnterminatedSubstitution => {
            sys.writeStr(sh.default_err, "wsh: unterminated substitution\n");
            return 2;
        },
        error.SubstitutionFailed => {
            sys.writeStr(sh.default_err, "wsh: command substitution failed\n");
            return 1;
        },
        error.ExecutionFailed => return 1,
        else => {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}\n", .{@errorName(err)}) catch "wsh: error\n";
            sys.writeStr(sh.default_err, msg);
            return 2;
        },
    }
}

fn statusFromValue(v: Value) u8 {
    return switch (v) {
        .int => |n| @intCast(@mod(n, 256)),
        .boolean => |b| if (b) 0 else 1,
        .string => |s| blk: {
            // `return "2"` is as reasonable as `return 2`.
            const text = std.mem.trim(u8, s, " \t");
            if (std.fmt.parseInt(i64, text, 10)) |n| {
                break :blk @intCast(@mod(n, 256));
            } else |_| {}
            break :blk if (s.len == 0) 0 else 1;
        },
        else => 0,
    };
}

fn runFor(sh: *Shell, loop: ast.For) u8 {
    const outer = sh.scratch();
    // Items are expanded in the enclosing arena so they survive the per
    // iteration resets below.
    var items: std.ArrayList([]const u8) = .empty;
    for (loop.items) |word| {
        expand_mod.expandWord(sh, outer, word, &items) catch |err| return exprError(sh, err);
    }

    var iter_arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer iter_arena.deinit();
    const saved = sh.scratch_override;
    sh.scratch_override = iter_arena.allocator();
    defer sh.scratch_override = saved;

    var status: u8 = 0;
    for (items.items) |item| {
        _ = iter_arena.reset(.retain_capacity);
        sh.setVar(loop.name, .{ .string = item }) catch return 1;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        if (sh.break_pending) {
            sh.break_pending = false;
            break;
        }
        if (sh.continue_pending) {
            sh.continue_pending = false;
            continue;
        }
        if (sh.should_exit or sh.return_pending) break;
    }
    return status;
}

fn runWhile(sh: *Shell, loop: ast.While) u8 {
    const outer = sh.scratch();

    var iter_arena = std.heap.ArenaAllocator.init(sh.gpa);
    defer iter_arena.deinit();
    const saved = sh.scratch_override;
    sh.scratch_override = iter_arena.allocator();
    defer sh.scratch_override = saved;

    var status: u8 = 0;
    while (true) {
        _ = iter_arena.reset(.retain_capacity);
        const cond = evalExpr(sh, outer, loop.cond) catch |err| return exprError(sh, err);
        if (!cond.truthy()) break;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        if (sh.break_pending) {
            sh.break_pending = false;
            break;
        }
        if (sh.continue_pending) {
            sh.continue_pending = false;
            continue;
        }
        if (sh.should_exit or sh.return_pending) break;
    }
    return status;
}

// --- expressions ------------------------------------------------------------

fn evalExpr(sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    switch (expr.*) {
        .null_lit => return .none,
        .boolean => |b| return Value{ .boolean = b },
        .int => |n| return Value{ .int = n },
        .float => |f| return Value{ .float = f },
        .string => |word| return Value{ .string = try expand_mod.expandLiteral(sh, arena, word) },
        .ident => |name| return evalIdent(sh, arena, name),
        .list => |items| {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |item, i| out[i] = try evalExpr(sh, arena, item);
            return Value{ .list = out };
        },
        .logic => |l| {
            const lhs = try evalExpr(sh, arena, l.lhs);
            const take_rhs = switch (l.op) {
                .and_ => lhs.truthy(),
                .or_ => !lhs.truthy(),
            };
            if (!take_rhs) return Value{ .boolean = lhs.truthy() };
            const rhs = try evalExpr(sh, arena, l.rhs);
            return Value{ .boolean = rhs.truthy() };
        },
        .un => |u| {
            const operand = try evalExpr(sh, arena, u.operand);
            return switch (u.op) {
                .not => Value{ .boolean = !operand.truthy() },
                .neg => switch (operand) {
                    .int => |n| Value{ .int = -n },
                    .float => |f| Value{ .float = -f },
                    else => Value{ .int = -(operand.asInt() orelse 0) },
                },
            };
        },
        .bin => |b| {
            const lhs = try evalExpr(sh, arena, b.lhs);
            const rhs = try evalExpr(sh, arena, b.rhs);
            return try evalBinary(arena, b.op, lhs, rhs);
        },
        .call => |call| return try evalCall(sh, arena, call.callee, call.args),
    }
}

fn evalIdent(sh: *Shell, arena: std.mem.Allocator, name: []const u8) Error!Value {
    // Read-only conveniences, consulted before user variables.
    if (std.mem.eql(u8, name, "status")) return Value{ .int = sh.last_status };
    if (std.mem.eql(u8, name, "pid")) return Value{ .int = sh.pid };
    if (std.mem.eql(u8, name, "cwd")) return Value{ .string = try arena.dupe(u8, sh.cwd) };
    if (std.mem.eql(u8, name, "host")) return Value{ .string = try arena.dupe(u8, sh.hostname) };
    if (std.mem.eql(u8, name, "argv")) {
        const out = try arena.alloc(Value, sh.positional.len);
        for (sh.positional, 0..) |a, i| out[i] = Value{ .string = try arena.dupe(u8, a) };
        return Value{ .list = out };
    }
    if (std.mem.eql(u8, name, "env")) {
        var out: std.ArrayList(Value) = .empty;
        var it = sh.env.iterator();
        while (it.next()) |entry| {
            const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* });
            try out.append(arena, Value{ .string = pair });
        }
        return Value{ .list = try out.toOwnedSlice(arena) };
    }

    if (sh.getVar(name)) |v| return v;
    if (sh.getEnv(name)) |e| return Value{ .string = try arena.dupe(u8, e) };
    return .none;
}

fn evalBinary(arena: std.mem.Allocator, op: ast.BinOp, lhs: Value, rhs: Value) Error!Value {
    switch (op) {
        .eq, .ne => {
            const equal = valueEquals(lhs, rhs);
            return Value{ .boolean = if (op == .eq) equal else !equal };
        },
        .lt, .le, .gt, .ge => {
            const order = compare(lhs, rhs);
            return Value{ .boolean = switch (op) {
                .lt => order < 0,
                .le => order <= 0,
                .gt => order > 0,
                else => order >= 0,
            } };
        },
        .add => {
            // Numeric when both sides are numbers, so accumulation works even
            // though loop variables arrive as text:
            //     let sum = 0
            //     for n in 1 2 3 { let sum = sum + n }
            if (toNumber(lhs)) |a| {
                if (toNumber(rhs)) |b| return try numeric(.add, a, b);
            }
            // Otherwise concatenate, so building paths reads naturally:
            //     let p = dir + "/main.rs"
            var out: std.Io.Writer.Allocating = .init(arena);
            errdefer out.deinit();
            try lhs.render(&out.writer);
            try rhs.render(&out.writer);
            return Value{ .string = try out.toOwnedSlice() };
        },
        .sub, .mul, .div, .mod => return try numeric(op, lhs, rhs),
    }
}

fn numeric(op: ast.BinOp, lhs: Value, rhs: Value) Error!Value {
    if (isFloat(lhs) or isFloat(rhs)) {
        const a = lhs.asFloat() orelse 0;
        const b = rhs.asFloat() orelse 0;
        return Value{ .float = switch (op) {
            .add => a + b,
            .sub => a - b,
            .mul => a * b,
            .div => if (b == 0) 0 else a / b,
            .mod => if (b == 0) 0 else @mod(a, b),
            else => 0,
        } };
    }
    const a = lhs.asInt() orelse 0;
    const b = rhs.asInt() orelse 0;
    return Value{ .int = switch (op) {
        .add => a +% b,
        .sub => a -% b,
        .mul => a *% b,
        .div => if (b == 0) 0 else @divTrunc(a, b),
        .mod => if (b == 0) 0 else @rem(a, b),
        else => 0,
    } };
}

/// Numeric view of a value, as a number-typed value.
///
/// Strings that look like numbers count as numbers, because command words and
/// function arguments arrive as text: `for n in 1 2 3` binds `"1"`, and
/// `let sum = sum + n` has to add rather than concatenate.
fn toNumber(v: Value) ?Value {
    return switch (v) {
        .int, .float => v,
        .string => |s| blk: {
            const text = std.mem.trim(u8, s, " \t");
            if (std.fmt.parseInt(i64, text, 10)) |n| {
                break :blk Value{ .int = n };
            } else |_| {}
            if (std.fmt.parseFloat(f64, text)) |f| {
                break :blk Value{ .float = f };
            } else |_| {}
            break :blk null;
        },
        else => null,
    };
}

/// Numeric view of a value for comparison. Strings that look like numbers count
/// as numbers, because command words and function arguments arrive as text: a
/// function called as `check 5` binds `n` to "5", and `n > 10` must compare
/// numerically.
fn numericOf(v: Value) ?f64 {
    return switch (v) {
        .int => |n| @floatFromInt(n),
        .float => |f| f,
        .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t")) catch null,
        else => null,
    };
}

fn renderInto(v: Value, buf: []u8) []const u8 {
    if (isString(v)) return v.string[0..@min(v.string.len, buf.len)];
    var w = std.Io.Writer.fixed(buf);
    v.render(&w) catch return buf[0..0];
    return w.buffered();
}

fn valueEquals(lhs: Value, rhs: Value) bool {
    if (isList(lhs) or isList(rhs)) {
        if (!isList(lhs) or !isList(rhs)) return false;
        if (lhs.list.len != rhs.list.len) return false;
        for (lhs.list, rhs.list) |x, y| {
            if (!valueEquals(x, y)) return false;
        }
        return true;
    }
    if (numericOf(lhs)) |a| {
        if (numericOf(rhs)) |b| return a == b;
    }
    if (isBool(lhs) or isBool(rhs)) return lhs.truthy() == rhs.truthy();
    const a = renderInto(lhs, &compare_buf_a);
    const b = renderInto(rhs, &compare_buf_b);
    return std.mem.eql(u8, a, b);
}

fn compare(lhs: Value, rhs: Value) i8 {
    if (numericOf(lhs)) |a| {
        if (numericOf(rhs)) |b| {
            if (a < b) return -1;
            if (a > b) return 1;
            return 0;
        }
    }
    const a = renderInto(lhs, &compare_buf_a);
    const b = renderInto(rhs, &compare_buf_b);
    return switch (std.mem.order(u8, a, b)) {
        .lt => -1,
        .gt => 1,
        .eq => 0,
    };
}

// --- expression function calls ---------------------------------------------

fn evalCall(sh: *Shell, arena: std.mem.Allocator, callee: []const u8, args: []const *ast.Expr) Error!Value {
    if (std.mem.eql(u8, callee, "exists")) {
        return Value{ .boolean = try pathArg(sh, arena, args, &fs.exists) };
    }
    if (std.mem.eql(u8, callee, "is_dir")) {
        return Value{ .boolean = try pathArg(sh, arena, args, &fs.isDir) };
    }
    if (std.mem.eql(u8, callee, "is_file")) {
        return Value{ .boolean = try pathArg(sh, arena, args, &isRegularFile) };
    }
    if (std.mem.eql(u8, callee, "is_link")) {
        return Value{ .boolean = try pathArg(sh, arena, args, &isSymlink) };
    }
    if (std.mem.eql(u8, callee, "len")) {
        const v = try evalExpr(sh, arena, argAt(args, 0));
        return Value{ .int = switch (v) {
            .string => |s| @intCast(s.len),
            .list => |l| @intCast(l.len),
            else => 0,
        } };
    }
    if (std.mem.eql(u8, callee, "empty")) {
        return Value{ .boolean = (try evalExpr(sh, arena, argAt(args, 0))).isNull() };
    }
    if (std.mem.eql(u8, callee, "int")) {
        return Value{ .int = (try evalExpr(sh, arena, argAt(args, 0))).asInt() orelse 0 };
    }
    if (std.mem.eql(u8, callee, "str")) {
        const v = try evalExpr(sh, arena, argAt(args, 0));
        return Value{ .string = try v.renderAlloc(arena) };
    }
    if (std.mem.eql(u8, callee, "abs")) {
        const n = (try evalExpr(sh, arena, argAt(args, 0))).asInt() orelse 0;
        return Value{ .int = if (n < 0) -n else n };
    }
    if (std.mem.eql(u8, callee, "min") or std.mem.eql(u8, callee, "max")) {
        const want_min = std.mem.eql(u8, callee, "min");
        if (args.len == 0) return Value{ .int = 0 };
        var best = (try evalExpr(sh, arena, args[0])).asInt() orelse 0;
        for (args[1..]) |arg| {
            const n = (try evalExpr(sh, arena, arg)).asInt() orelse 0;
            if (want_min) {
                if (n < best) best = n;
            } else if (n > best) best = n;
        }
        return Value{ .int = best };
    }
    if (std.mem.eql(u8, callee, "upper") or std.mem.eql(u8, callee, "lower")) {
        const text = try stringArg(sh, arena, args, 0);
        const out = try arena.dupe(u8, text);
        const want_upper = std.mem.eql(u8, callee, "upper");
        for (out) |*c| c.* = if (want_upper) std.ascii.toUpper(c.*) else std.ascii.toLower(c.*);
        return Value{ .string = out };
    }
    if (std.mem.eql(u8, callee, "trim")) {
        const text = try stringArg(sh, arena, args, 0);
        return Value{ .string = std.mem.trim(u8, text, " \t\r\n") };
    }
    if (std.mem.eql(u8, callee, "basename")) {
        const text = try stringArg(sh, arena, args, 0);
        return Value{ .string = std.fs.path.basename(text) };
    }
    if (std.mem.eql(u8, callee, "dirname")) {
        const text = try stringArg(sh, arena, args, 0);
        return Value{ .string = try arena.dupe(u8, std.fs.path.dirname(text) orelse ".") };
    }
    if (std.mem.eql(u8, callee, "env")) {
        const name = try stringArg(sh, arena, args, 0);
        if (sh.getEnv(name)) |e| return Value{ .string = try arena.dupe(u8, e) };
        if (args.len >= 2) return Value{ .string = try stringArg(sh, arena, args, 1) };
        return Value{ .string = "" };
    }
    if (std.mem.eql(u8, callee, "contains") or
        std.mem.eql(u8, callee, "starts_with") or
        std.mem.eql(u8, callee, "ends_with"))
    {
        if (args.len < 2) return Value{ .boolean = false };
        const haystack = try stringArg(sh, arena, args, 0);
        const needle = try stringArg(sh, arena, args, 1);
        if (std.mem.eql(u8, callee, "contains")) {
            return Value{ .boolean = std.mem.indexOf(u8, haystack, needle) != null };
        }
        if (std.mem.eql(u8, callee, "starts_with")) {
            return Value{ .boolean = std.mem.startsWith(u8, haystack, needle) };
        }
        return Value{ .boolean = std.mem.endsWith(u8, haystack, needle) };
    }
    if (std.mem.eql(u8, callee, "split")) {
        if (args.len < 2) return Value{ .list = &.{} };
        const text = try stringArg(sh, arena, args, 0);
        const sep = try stringArg(sh, arena, args, 1);
        var out: std.ArrayList(Value) = .empty;
        if (sep.len == 0) {
            for (text) |c| try out.append(arena, Value{ .string = try arena.dupe(u8, &[_]u8{c}) });
        } else {
            var it = std.mem.splitSequence(u8, text, sep);
            while (it.next()) |part| try out.append(arena, Value{ .string = try arena.dupe(u8, part) });
        }
        return Value{ .list = try out.toOwnedSlice(arena) };
    }
    if (std.mem.eql(u8, callee, "join")) {
        if (args.len < 2) return Value{ .string = "" };
        const list = try evalExpr(sh, arena, args[0]);
        const sep = try stringArg(sh, arena, args, 1);
        if (!isList(list)) return Value{ .string = "" };
        var out: std.Io.Writer.Allocating = .init(arena);
        errdefer out.deinit();
        for (list.list, 0..) |item, i| {
            if (i != 0) try out.writer.writeAll(sep);
            try item.render(&out.writer);
        }
        return Value{ .string = try out.toOwnedSlice() };
    }

    // Not an expression function: if it names something runnable, run it and
    // report success. Expressions are predicates, so a command yields a bool --
    // `if is_big(500) { ... }`. Use `status` for the numeric exit code.
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = callee;
    for (args, 0..) |arg, i| {
        argv[i + 1] = try (try evalExpr(sh, arena, arg)).renderAlloc(arena);
    }

    if (isInternal(sh, callee)) {
        return Value{ .boolean = dispatch(sh, argv) == 0 };
    }

    if (try proc.resolve(arena, callee, sh.pathEnv()) != null) {
        const stage = try launchStage(sh, arena, argv, &.{});
        return Value{ .boolean = runForeground(sh, arena, &.{stage}, callee) == 0 };
    }

    var buf: [160]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: unknown function '{s}'\n", .{callee}) catch "wsh: unknown function\n";
    sys.writeStr(sh.default_err, msg);
    return error.ExecutionFailed;
}

/// Every built-in expression function. Kept next to `isExpressionFunction` so
/// the misuse check below can name them, and covered by a test that fails if
/// this list and `evalCall` drift apart.
const expression_function_names = [_][]const u8{
    "exists",      "is_dir",    "is_file",  "is_link", "len", "empty",
    "int",         "str",       "abs",      "min",     "max", "upper",
    "lower",       "trim",      "basename", "dirname", "env", "contains",
    "starts_with", "ends_with", "split",    "join",
};

pub fn isExpressionFunction(name: []const u8) bool {
    for (expression_function_names) |candidate| {
        if (std.mem.eql(u8, name, candidate)) return true;
    }
    return false;
}

/// Expression functions live in expressions, not in command arguments. Catching
/// `print len("abc")` here turns "prints the literal text" into a real error.
fn misuseOfExpressionFunction(words: []const []const u8) ?[]const u8 {
    for (words, 0..) |word, index| {
        if (index == 0) continue;
        const open = std.mem.indexOfScalar(u8, word, '(') orelse continue;
        const close = std.mem.lastIndexOfScalar(u8, word, ')') orelse continue;
        if (close <= open) continue;
        const name = word[0..open];
        if (!isExpressionFunction(name)) continue;
        // Only flag it when the remainder really looks like an argument list.
        for (word[close + 1 ..]) |c| {
            if (c != ' ' and c != 0x09) return null;
        }
        return name;
    }
    return null;
}

fn reportExpressionFunctionMisuse(sh: *Shell, name: []const u8) void {
    var buf: [320]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf,
        \\wsh: '{s}' is an expression function, not a command.
        \\     try: let result = {s}(...)
        \\
    , .{ name, name }) catch return;
    sys.writeStr(sh.default_err, msg);
}

fn argAt(args: []const *ast.Expr, index: usize) *const ast.Expr {
    if (index < args.len) return args[index];
    return &null_expr;
}

const null_expr: ast.Expr = .null_lit;

fn stringArg(sh: *Shell, arena: std.mem.Allocator, args: []const *ast.Expr, index: usize) Error![]const u8 {
    if (index >= args.len) return "";
    const v = try evalExpr(sh, arena, args[index]);
    return v.renderAlloc(arena);
}

fn pathArg(sh: *Shell, arena: std.mem.Allocator, args: []const *ast.Expr, predicate: *const fn ([:0]const u8) bool) Error!bool {
    const text = try stringArg(sh, arena, args, 0);
    if (text.len + 1 > linux.PATH_MAX) return false;
    const z = try arena.dupeZ(u8, text);
    return predicate(z);
}

fn isRegularFile(z: [:0]const u8) bool {
    return fs.kind(z) == .file;
}
fn isSymlink(z: [:0]const u8) bool {
    return fs.kind(z) == .symlink;
}

// --- pipelines --------------------------------------------------------------

fn runChain(sh: *Shell, chain: ast.Pipeline) u8 {
    var status = runPipeline(sh, chain.commands, chain.background);
    for (chain.links) |link| {
        const should_run = switch (link.op) {
            .and_ => status == 0,
            .or_ => status != 0,
        };
        if (should_run) status = runPipeline(sh, link.pipeline.commands, link.pipeline.background);
    }
    return status;
}

const Fds = struct {
    in: i32,
    out: i32,
    err: i32,
};

/// What a forked pipeline stage needs. Lives in the arena, so the child gets
/// its own copy across `fork`.
const ChildPayload = struct {
    sh: *Shell,
    argv: []const []const u8,
};

const MissingCommandPayload = struct { message: []const u8 };

fn childReportMissingCommand(ctx_ptr: *anyopaque) noreturn {
    const payload: *MissingCommandPayload = @ptrCast(@alignCast(ctx_ptr));
    sys.writeStr(2, payload.message);
    linux.exit(127);
}

fn runPipeline(sh: *Shell, commands: []const ast.Command, background: bool) u8 {
    const arena = sh.scratch();
    if (commands.len == 0) return 0;

    // Every descriptor opened for redirects is closed once the processes are up.
    var opened: std.ArrayList(i32) = .empty;
    defer for (opened.items) |fd| sys.closeFd(fd);

    if (commands.len == 1) return runSingle(sh, arena, commands[0], background, &opened);

    var stages: std.ArrayList(proc.Stage) = .empty;
    for (commands) |cmd| {
        if (cmd.subshell) |stmts| {
            const prepared = applyRedirects(sh, arena, cmd, &opened) catch |err| return exprError(sh, err);
            const stage = makeSubshellStage(sh, arena, stmts, prepared.redirects) catch |err| return exprError(sh, err);
            stages.append(arena, stage) catch return 1;
            continue;
        }
        if (misuseOfExpressionFunction(cmd.words)) |name| {
            reportExpressionFunctionMisuse(sh, name);
            return 2;
        }
        const words = resolveAliases(sh, arena, cmd.words) catch return 1;
        var argv: std.ArrayList([]const u8) = .empty;
        expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return exprError(sh, err);
        if (argv.items.len == 0) continue;

        const prepared = applyRedirects(sh, arena, cmd, &opened) catch |err| return exprError(sh, err);
        const call_argv = argv.toOwnedSlice(arena) catch return 1;
        const stage = makeStage(sh, arena, call_argv, prepared.redirects) catch |err| return exprError(sh, err);
        stages.append(arena, stage) catch return 1;
    }

    if (stages.items.len == 0) return 0;

    const text = pipelineText(arena, commands) catch "pipeline";
    if (background) return startBackground(sh, arena, stages.items, text);
    return runForeground(sh, arena, stages.items, text);
}

/// Builds a stage that either execs a program or runs shell code in the child.
fn makeStage(sh: *Shell, arena: std.mem.Allocator, argv: []const []const u8, redirects: []const proc.Redirection) Error!proc.Stage {
    if (isInternal(sh, argv[0])) {
        const payload = try arena.create(ChildPayload);
        payload.* = .{ .sh = sh, .argv = argv };
        return .{
            .child_fn = childExecute,
            .child_ctx = payload,
            .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
            .redirects = redirects,
        };
    }
    return try launchStage(sh, arena, argv, redirects);
}

const SubshellPayload = struct {
    sh: *Shell,
    stmts: []ast.Stmt,
};

fn makeSubshellStage(sh: *Shell, arena: std.mem.Allocator, stmts: []ast.Stmt, redirects: []const proc.Redirection) Error!proc.Stage {
    const payload = try arena.create(SubshellPayload);
    payload.* = .{ .sh = sh, .stmts = stmts };
    return .{
        .child_fn = childExecuteSubshell,
        .child_ctx = payload,
        .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
        .redirects = redirects,
    };
}

fn childExecuteSubshell(ctx_ptr: *anyopaque) noreturn {
    const payload: *SubshellPayload = @ptrCast(@alignCast(ctx_ptr));
    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    sh.return_pending = false;
    sh.break_pending = false;
    sh.continue_pending = false;
    linux.exit(runStmts(sh, payload.stmts));
}

fn isInternal(sh: *Shell, name: []const u8) bool {
    return isExecBuiltin(name) or builtins.isBuiltin(name) or sh.getFunc(name) != null;
}

fn isExecBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "source") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, ".");
}

/// Runs in the forked child. Builtins, functions and aliases execute here when
/// they appear in a pipeline or run in the background, which is why their state
/// changes never reach the shell.
fn childExecute(ctx_ptr: *anyopaque) noreturn {
    const payload: *ChildPayload = @ptrCast(@alignCast(ctx_ptr));
    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    linux.exit(dispatch(sh, payload.argv));
}

fn runSingle(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    background: bool,
    opened: *std.ArrayList(i32),
) u8 {
    if (misuseOfExpressionFunction(cmd.words)) |name| {
        reportExpressionFunctionMisuse(sh, name);
        return 2;
    }

    const words = resolveAliases(sh, arena, cmd.words) catch return 1;
    var argv: std.ArrayList([]const u8) = .empty;
    expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return exprError(sh, err);

    const prepared = applyRedirects(sh, arena, cmd, opened) catch |err| return exprError(sh, err);

    // `> file` with no command just creates the file.
    if (argv.items.len == 0 and cmd.subshell == null) return 0;

    if (cmd.subshell) |stmts| {
        const stage = makeSubshellStage(sh, arena, stmts, prepared.redirects) catch |err| return exprError(sh, err);
        if (background) return startBackground(sh, arena, &.{stage}, pipelineText(arena, &.{cmd}) catch "subshell");
        return runForeground(sh, arena, &.{stage}, pipelineText(arena, &.{cmd}) catch "subshell");
    }

    const call_argv = argv.toOwnedSlice(arena) catch return 1;
    const name = call_argv[0];
    const text = pipelineText(arena, &.{cmd}) catch name;

    if (isInternal(sh, name) and !background) {
        // Temporary defaults make the redirects visible to the nested commands
        // a function or `source` will run.
        const saved = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
        sh.default_in = prepared.fds.in;
        sh.default_out = prepared.fds.out;
        sh.default_err = prepared.fds.err;
        defer {
            sh.default_in = saved.in;
            sh.default_out = saved.out;
            sh.default_err = saved.err;
        }
        return dispatch(sh, call_argv);
    }

    const stage = makeStage(sh, arena, call_argv, prepared.redirects) catch |err| return exprError(sh, err);
    if (background) return startBackground(sh, arena, &.{stage}, text);
    return runForeground(sh, arena, &.{stage}, text);
}

fn launchStage(sh: *Shell, arena: std.mem.Allocator, argv: []const []const u8, redirects: []const proc.Redirection) Error!proc.Stage {
    const resolved = try proc.resolve(arena, argv[0], sh.pathEnv()) orelse {
        const payload = try arena.create(MissingCommandPayload);
        payload.* = .{ .message = try commandNotFoundMessage(sh, arena, argv[0]) };
        return .{
            .child_fn = childReportMissingCommand,
            .child_ctx = payload,
            .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
            .redirects = redirects,
        };
    };

    const exec = try arena.create(proc.Exec);
    exec.* = .{
        .path = (try arena.dupeZ(u8, resolved)).ptr,
        .argv = try proc.buildArgv(arena, argv),
        .envp = try sh.buildEnvp(arena),
    };

    // A script file without a shebang is run through /bin/sh, like a real shell.
    const shell_argv = try arena.alloc([]const u8, argv.len + 1);
    shell_argv[0] = "/bin/sh";
    shell_argv[1] = resolved;
    for (argv[1..], 0..) |a, i| shell_argv[i + 2] = a;
    exec.shell_path = "/bin/sh";
    exec.shell_argv = try proc.buildArgv(arena, shell_argv);

    return .{
        .exec = exec,
        .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
        .redirects = redirects,
    };
}

fn startBackground(sh: *Shell, arena: std.mem.Allocator, stages: []const proc.Stage, text: []const u8) u8 {
    const launched = proc.launch(arena, stages, .{}) catch |err| return exprError(sh, err);
    const last_pid = launched.pids[launched.pids.len - 1];
    sh.last_bg_pid = last_pid;

    const job = sh.jobs.add(sh.gpa, launched.pgid, launched.pids, text, false) catch return 1;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job.id, last_pid }) catch return 0;
    sys.writeStr(sh.default_err, line);
    return 0;
}

fn runForeground(sh: *Shell, arena: std.mem.Allocator, stages: []const proc.Stage, text: []const u8) u8 {
    const launched = proc.launch(arena, stages, .{ .new_group = sh.job_control }) catch |err| return exprError(sh, err);
    const job = sh.jobs.add(sh.gpa, launched.pgid, launched.pids, text, true) catch return 1;
    const outcome = sh.waitForeground(job);

    if (outcome.stopped) {
        job.state = .stopped;
        job.foreground = false;
        job.notified = true;
        var buf: [640]u8 = undefined;
        const line = std.fmt.bufPrint(&buf, "\n[{d}] Stopped  {s}\n", .{ job.id, job.command }) catch return outcome.status;
        sys.writeStr(sh.default_err, line);
        return outcome.status;
    }

    if (sh.jobs.indexOf(job)) |index| sh.jobs.removeAt(sh.gpa, index);
    if (outcome.signal) |sig| reportSignal(sh, sig);
    return outcome.status;
}

fn reportSignal(sh: *Shell, sig: u32) void {
    // Ctrl-C and a closed pipe are normal control flow, not news.
    const name: []const u8 = switch (sig) {
        2, 13, 17 => return,
        3 => "Quit",
        9 => "Killed",
        11 => "Segmentation fault",
        15 => "Terminated",
        else => "Signal",
    };
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}\n", .{name}) catch return;
    sys.writeStr(sh.default_err, line);
}

/// Runs a builtin, a shell function, `source`, `eval`, or reports a missing
/// command. External programs are launched before this is reached.
fn dispatch(sh: *Shell, argv: []const []const u8) u8 {
    if (argv.len == 0) return 0;
    const name = argv[0];

    if (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, ".")) return builtinSource(sh, argv);
    if (std.mem.eql(u8, name, "eval")) return builtinEval(sh, argv);

    if (builtins.lookup(name)) |b| {
        const ctx = builtins.Ctx{
            .sh = sh,
            .argv = argv,
            .stdin = sh.default_in,
            .stdout = sh.default_out,
            .stderr = sh.default_err,
        };
        return b.run(ctx);
    }

    if (sh.getFunc(name)) |source| return callFunction(sh, name, source, argv);

    reportCommandNotFound(sh, sh.scratch(), name);
    return 127;
}

fn reportCommandNotFound(sh: *Shell, arena: std.mem.Allocator, name: []const u8) void {
    const message = commandNotFoundMessage(sh, arena, name) catch return;
    sys.writeStr(sh.default_err, message);
}

fn commandNotFoundMessage(sh: *Shell, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    var message: std.ArrayList(u8) = .empty;
    const initial = try std.fmt.allocPrint(arena, "wsh: command not found: {s}\n", .{name});
    try message.appendSlice(arena, initial);

    const matches = if (sh.command_cache.lookup(name)) |cached| cached.matches else blk: {
        const found = command_suggest.find(sh, arena, name) catch return try message.toOwnedSlice(arena);
        if (sh.interactive) sh.command_cache.remember(sh.gpa, name, found) catch {
            try message.appendSlice(arena, "wsh: unable to cache command suggestions\n");
        };
        break :blk found;
    };
    if (matches.len > 0) {
        try message.appendSlice(arena, "wsh: did you mean: ");
        for (matches, 0..) |match, index| {
            if (index != 0) try message.appendSlice(arena, ", ");
            try message.appendSlice(arena, match.name);
        }
        try message.appendSlice(arena, "?\n");
    }
    return try message.toOwnedSlice(arena);
}

fn builtinSource(sh: *Shell, argv: []const []const u8) u8 {
    if (argv.len < 2) {
        sys.writeStr(sh.default_err, "wsh: source: expected a file name\n");
        return 1;
    }
    const arena = sh.scratch();
    const path = sh.tildeExpand(arena, argv[1]) catch argv[1];
    const z = arena.dupeZ(u8, path) catch return 1;
    const data = (fs.readFileAlloc(arena, z, 16 << 20) catch null) orelse {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: source: {s}: cannot read file\n", .{path}) catch return 1;
        sys.writeStr(sh.default_err, msg);
        return 1;
    };
    return runSource(sh, data);
}

fn builtinEval(sh: *Shell, argv: []const []const u8) u8 {
    if (argv.len < 2) return 0;
    const arena = sh.scratch();
    var joined: std.ArrayList(u8) = .empty;
    for (argv[1..], 0..) |part, i| {
        if (i != 0) joined.append(arena, ' ') catch return 1;
        joined.appendSlice(arena, part) catch return 1;
    }
    return runSource(sh, joined.items);
}

fn callFunction(sh: *Shell, name: []const u8, source: []const u8, argv: []const []const u8) u8 {
    if (sh.call_depth >= Shell.max_call_depth) {
        sys.writeStr(sh.default_err, "wsh: maximum function call depth reached\n");
        return 1;
    }

    const arena = sh.scratch();
    var p = parser_mod.Parser.init(arena, source);
    const program = p.parseProgram() catch {
        reportSyntaxError(sh, &p);
        return 2;
    };
    if (program.stmts.len == 0) return 0;

    const decl = switch (program.stmts[0]) {
        .fn_decl => |d| d,
        else => return 0,
    };

    // Bind parameters: positional arguments first, then defaults.
    for (decl.params, 0..) |param, index| {
        const arg_index = index + 1; // argv[0] is the function name
        if (arg_index < argv.len) {
            sh.setVar(param.name, .{ .string = argv[arg_index] }) catch return 1;
        } else if (param.default) |default| {
            const v = evalExpr(sh, arena, default) catch |err| return exprError(sh, err);
            sh.setVar(param.name, v) catch return 1;
        } else {
            sh.setVar(param.name, .{ .string = "" }) catch return 1;
        }
    }

    const saved_positional = sh.positional;
    const saved_name = sh.script_name;
    const saved_return = sh.return_pending;
    const saved_code = sh.return_code;
    sh.positional = if (argv.len > 1) argv[1..] else &.{};
    sh.script_name = name;
    sh.return_pending = false;
    sh.call_depth += 1;
    defer {
        sh.call_depth -= 1;
        sh.positional = saved_positional;
        sh.script_name = saved_name;
        sh.return_pending = saved_return;
        sh.return_code = saved_code;
    }

    const status = runStmts(sh, decl.body.stmts);
    if (sh.return_pending) {
        sh.last_status = sh.return_code;
        return sh.return_code;
    }
    return status;
}

// --- redirects --------------------------------------------------------------

const PreparedRedirects = struct {
    fds: Fds,
    redirects: []const proc.Redirection,
};

fn applyRedirects(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    opened: *std.ArrayList(i32),
) Error!PreparedRedirects {
    var fds = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
    if (cmd.redirects.len == 0) return .{ .fds = fds, .redirects = &.{} };
    var actions: std.ArrayList(proc.Redirection) = .empty;

    for (cmd.redirects) |redirect| {
        if (redirect.kind.duplicates()) {
            const source = redirect.target[0] - '0';
            const mapped_source = switch (source) {
                0 => fds.in,
                1 => fds.out,
                2 => fds.err,
                else => return error.ExecutionFailed,
            };
            switch (redirect.kind.fd()) {
                1 => fds.out = mapped_source,
                2 => fds.err = mapped_source,
                else => return error.ExecutionFailed,
            }
            try actions.append(arena, .{ .target = redirect.kind.fd(), .source = source });
            continue;
        }
        const target = try expand_mod.expandLiteral(sh, arena, redirect.target);
        const z = try arena.dupeZ(u8, target);

        const fd = if (redirect.kind == .here_doc) blk: {
            const body = if (redirect.expand_body)
                try expand_mod.expandHereDoc(sh, arena, redirect.body)
            else
                redirect.body;
            break :blk sys.createAnonymousFile(body);
        } else if (redirect.kind.isInput())
            sys.openRead(z.ptr)
        else
            sys.openWrite(z.ptr, redirect.kind.append());

        if (fd == null) {
            if (redirect.kind == .here_doc) {
                sys.writeStr(sh.default_err, "wsh: cannot prepare here-document\n");
                return error.ExecutionFailed;
            }
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}: cannot open file\n", .{target}) catch return error.ExecutionFailed;
            sys.writeStr(sh.default_err, msg);
            return error.ExecutionFailed;
        }

        switch (redirect.kind) {
            .in, .here_doc => fds.in = fd.?,
            .err_out, .err_append => fds.err = fd.?,
            else => fds.out = fd.?,
        }
        try opened.append(arena, fd.?);
        try actions.append(arena, .{ .target = redirect.kind.fd(), .source = fd.?, .close_source = true });
    }

    return .{ .fds = fds, .redirects = try actions.toOwnedSlice(arena) };
}

// --- aliases ----------------------------------------------------------------

fn resolveAliases(sh: *Shell, arena: std.mem.Allocator, words: []const []const u8) Error![]const []const u8 {
    var current: []const []const u8 = words;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        if (current.len == 0) break;
        const body = sh.getAlias(current[0]) orelse break;
        const body_words = try wordsFromSource(arena, body);
        if (body_words.len == 0) break;
        var combined: std.ArrayList([]const u8) = .empty;
        try combined.appendSlice(arena, body_words);
        try combined.appendSlice(arena, current[1..]);
        current = try combined.toOwnedSlice(arena);
    }
    return current;
}

/// Reads leading words from a fragment. Anything after an operator is dropped,
/// which is the documented limit of alias bodies.
fn wordsFromSource(arena: std.mem.Allocator, src: []const u8) Error![]const []const u8 {
    var lx = lexer.Lexer.init(src);
    var out: std.ArrayList([]const u8) = .empty;
    while (true) {
        const t = lx.next();
        switch (t.tag) {
            .eof, .newline => break,
            .word => try out.append(arena, t.text),
            else => break,
        }
    }
    return out.toOwnedSlice(arena);
}

// --- helpers ----------------------------------------------------------------

fn pipelineText(arena: std.mem.Allocator, commands: []const ast.Command) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (commands, 0..) |cmd, i| {
        if (i != 0) try out.appendSlice(arena, " | ");
        for (cmd.words, 0..) |word, j| {
            if (j != 0) try out.append(arena, ' ');
            try out.appendSlice(arena, word);
        }
        if (cmd.subshell != null) try out.appendSlice(arena, "(subshell)");
        for (cmd.redirects) |r| {
            const op = switch (r.kind) {
                .in => " < ",
                .here_doc => " << ",
                .out_append => " >> ",
                .err_out => " 2> ",
                .err_append => " 2>> ",
                .out_dup => " >&",
                .err_dup => " 2>&",
                else => " > ",
            };
            try out.appendSlice(arena, op);
            try out.appendSlice(arena, r.target);
        }
    }
    return out.toOwnedSlice(arena);
}

// --- command substitution ---------------------------------------------------

const SubstPayload = struct {
    sh: *Shell,
    src: []const u8,
};

fn substChild(ctx_ptr: *anyopaque) noreturn {
    const payload: *SubstPayload = @ptrCast(@alignCast(ctx_ptr));
    const sh = payload.sh;
    // The forked child's 0/1/2 already point at the substitution pipe; the
    // shell's own defaults still name the parent's descriptors, so reset them.
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    linux.exit(runSource(sh, payload.src));
}

/// Implements `$(...)`. Installed into the shell so the expander can call back
/// without a circular import.
pub fn substitutionRunner(sh: *Shell, src: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;

    const payload = try arena.create(SubstPayload);
    payload.* = .{ .sh = sh, .src = src };

    const stage = proc.Stage{
        .child_fn = substChild,
        .child_ctx = payload,
        .stdio = .{ .in = sh.default_in, .out = fds[1], .err = sh.default_err },
    };

    // Stay in the shell's process group so Ctrl-C still reaches it.
    const launched = proc.launch(arena, &.{stage}, .{ .new_group = false }) catch |err| {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
        return err;
    };
    _ = linux.close(fds[1]);

    var out: std.ArrayList(u8) = .empty;
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.readSome(fds[0], &buf) orelse break;
        if (n == 0) break;
        try out.appendSlice(arena, buf[0..n]);
    }
    _ = linux.close(fds[0]);

    if (proc.waitPid(launched.pids[0], 0)) |st| sh.last_status = st.exitCode();
    return try out.toOwnedSlice(arena);
}

/// Called once at startup to wire command substitution into expansion.
pub fn install(sh: *Shell) void {
    sh.subst_runner = substitutionRunner;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

/// Runs `src` with stdout captured through a pipe.
fn collectOutput(sh: *Shell, src: []const u8) ![]u8 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;

    const saved = sh.default_out;
    sh.default_out = fds[1];
    const status = runSource(sh, src);
    sh.default_out = saved;
    _ = linux.close(fds[1]);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = sys.readSome(fds[0], &buf) orelse break;
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0..n]);
    }
    _ = linux.close(fds[0]);
    sh.last_status = status;
    return out.toOwnedSlice(testing.allocator);
}

test "let and if" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "let name = \"dami\"\nif name == \"dami\" {\n    echo hello\n}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\n", out);

    try testing.expectEqual(@as(u8, 0), runSource(&sh, "if 1 == 2 {\n    echo nope\n}\n"));
}

test "for loop over words" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "for f in a b c {\n    echo item\n}\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("item\nitem\nitem\n", out);
}

test "for loop globs and pauses on break" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\for f in src/*.zig {
        \\    break
        \\}
        \\echo done
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("done\n", out);
}

test "while loop accumulates" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\let n = 0
        \\while n < 3 {
        \\    let n = n + 1
        \\}
        \\echo done
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("done\n", out);
    try testing.expectEqual(@as(i64, 3), sh.getVar("n").?.int);
}

test "accumulating a sum over a word list adds numerically" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\let total = 0
        \\for n in 1 2 3 4 5 {
        \\    let total = total + n
        \\}
        \\echo $total
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("15\n", out);
    try testing.expectEqual(@as(i64, 15), sh.getVar("total").?.int);
}

test "arithmetic and string concatenation" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    _ = runSource(&sh, "let x = 4 * (10 + 2)\n");
    try testing.expectEqual(@as(i64, 48), sh.getVar("x").?.int);

    _ = runSource(&sh, "let dir = \"/tmp\"\nlet p = dir + \"/main.rs\"\n");
    try testing.expectEqualStrings("/tmp/main.rs", sh.getVar("p").?.string);
}

test "functions with parameters and defaults" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\fn greet(who = "world") {
        \\    echo hi $who
        \\}
        \\greet
        \\greet dami
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hi world\nhi dami\n", out);
}

test "function return value becomes the status" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\fn check(n) {
        \\    if n > 10 {
        \\        return 0
        \\    }
        \\    return 1
        \\}
        \\check 20
    ;
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));
    try testing.expectEqual(@as(u8, 1), runSource(&sh, "check 5\n"));
}

test "command substitution" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "let who = $(echo ada)\necho hello $who\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello ada\n", out);
}

test "expression builtin functions" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    _ = runSource(&sh, "let n = len(\"hello\")\n");
    try testing.expectEqual(@as(i64, 5), sh.getVar("n").?.int);

    _ = runSource(&sh, "let u = upper(\"abc\")\n");
    try testing.expectEqualStrings("ABC", sh.getVar("u").?.string);

    _ = runSource(&sh, "let parts = split(\"a,b,c\", \",\")\n");
    try testing.expectEqual(@as(usize, 3), sh.getVar("parts").?.list.len);

    _ = runSource(&sh, "let has = contains(\"hello\", \"ell\")\n");
    try testing.expect(sh.getVar("has").?.boolean);
}

test "env assignment and append" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    _ = runSource(&sh, "env FOO = \"bar\"\n");
    try testing.expectEqualStrings("bar", sh.getEnv("FOO").?);

    _ = runSource(&sh, "env FOO += \"baz\"\n");
    try testing.expectEqualStrings("barbaz", sh.getEnv("FOO").?);
}

test "aliases expand only the command name" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    _ = runSource(&sh, "alias ll = echo listed\n");
    const out = try collectOutput(&sh, "ll here\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("listed here\n", out);
}

test "a failing command sets a non-zero status" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    try testing.expectEqual(@as(u8, 1), runSource(&sh, "false\n"));
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "true\n"));
}

test "&& and || short circuit" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "true && echo yes\nfalse || echo fallback\nfalse && echo nope\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("yes\nfallback\n", out);
}

test "redirects write to files" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-redirect-test.txt";
    var buf: [128]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "echo written > {s}\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("written\n", data);
    _ = fs.removeFile(z);
}

test "2>&1 merges stderr into pipeline stdout" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "/bin/sh -c 'printf out; printf err >&2' 2>&1 | /bin/cat\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("outerr", out);
}

test "2>&1 preserves redirection order" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-redirect-order-test.txt";
    var source: [256]u8 = undefined;
    const command = try std.fmt.bufPrint(&source, "/bin/sh -c 'printf out; printf err >&2' 2>&1 > {s}\n", .{path});
    const out = try collectOutput(&sh, command);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("err", out);

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("out", data);
    _ = fs.removeFile(z);
}

test "here-documents expand variables and preserve quoted bodies" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const src =
        \\let value = "expanded"
        \\cat <<EOF
        \\$value
        \\EOF
        \\cat <<'LITERAL'
        \\$value
        \\LITERAL
    ;
    const out = try collectOutput(&sh, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("expanded\n$value\n", out);
}

test "multiple here-documents on a semicolon-separated line use the final input" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const src =
        \\cat <<FIRST <<SECOND; echo done
        \\first body
        \\FIRST
        \\second body
        \\SECOND
    ;
    const out = try collectOutput(&sh, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("second body\ndone\n", out);
}

test "subshells isolate state and work in pipelines" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const src =
        \\let value = "parent"
        \\(let value = "child"; echo $value)
        \\echo $value
        \\(echo piped) | /bin/cat
    ;
    const out = try collectOutput(&sh, src);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("child\nparent\npiped\n", out);
    try testing.expectEqualStrings("parent", sh.getVar("value").?.string);
}

test "the expression function list matches what evalCall implements" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (expression_function_names) |name| {
        // No arguments: a real function answers (usually with a default) rather
        // than reporting that it does not exist.
        const result = evalCall(&sh, arena, name, &.{}) catch |err| {
            try testing.expect(err != error.ExecutionFailed);
            continue;
        };
        _ = result;
    }
}

test "misusing an expression function as a command is an error" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    try testing.expectEqual(@as(u8, 2), runSource(&sh, "print len(\"abc\")\n"));
    // A word that merely contains parentheses is left alone.
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "print not_a_fn(x)\n"));
}

test "isComplete distinguishes open constructs from real errors" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    // Open constructs keep the prompt reading.
    try testing.expect(!isComplete("echo \"unterminated"));
    try testing.expect(!isComplete("cat <<EOF\nbody"));
    try testing.expect(isComplete("cat <<\"\\EOF\"\nbody\n\\EOF\n"));
    try testing.expect(isComplete("cat <<''\nbody\n\n"));
    try testing.expect(isComplete("cat <<EOF # |\n' unmatched body quote\nEOF\n"));
    try testing.expect(isComplete("cat <<EOF\n}\"\nEOF\n"));
    try testing.expect(isComplete("# a comment <<NOT_A_HEREDOC\n"));
    try testing.expect(isComplete("cat <<EOF |\ncat\nbody\nEOF\n"));
    try testing.expect(!isComplete("(echo hi"));
    try testing.expect(isComplete("(echo hi)"));
    try testing.expect(!isComplete("echo hi |"));
    try testing.expect(!isComplete("let x ="));
    try testing.expect(isComplete("alias ll"));

    try testing.expect(!isComplete("if true {"));
    try testing.expect(!isComplete("for f in a b {"));
    try testing.expect(!isComplete("fn f() {"));
    try testing.expect(!isComplete("while true {"));

    // Real errors are reported straight away.
    try testing.expect(isComplete("if { }"));
    try testing.expect(isComplete("echo hi"));

    // And a closed block is complete.
    try testing.expect(isComplete("if true {\n echo hi\n}"));
}

test "a shell function can be called from an expression" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\fn is_big(n) {
        \\    if n > 100 {
        \\        return 0
        \\    }
        \\    return 1
        \\}
        \\if is_big(500) {
        \\    echo big
        \\} else {
        \\    echo small
        \\}
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("big\n", out);
}

test "quotes nested inside a substitution stay inside the string" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "echo \"a$(echo \"b c\")d\"\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ab cd\n", out);
}

test "text adjacent to quotes forms a single word" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "let x = \"B\"\necho \"a\"$x\"c\"\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("aBc\n", out);
}

test "pipelines connect stdout to stdin" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "/bin/echo hello | /bin/cat\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\n", out);
}
