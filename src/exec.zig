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

    while (true) {
        const tok = lx.next();
        if (tok.tag == .eof) break;
        switch (tok.tag) {
            .lbrace => braces += 1,
            .rbrace => braces -= 1,
            .lparen => parens += 1,
            .rparen => parens -= 1,
            .lbracket => brackets += 1,
            .rbracket => brackets -= 1,
            else => {},
        }
        last = tok.tag;
        last_text = tok.text;
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
        .pipe, .pipepipe, .ampamp, .lbrace, .lparen, .lbracket, .in, .out, .out_append => true,
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
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and !in_single and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '\'' and !in_double) {
            in_single = !in_single;
        } else if (c == '"' and !in_single) {
            in_double = !in_double;
        }
        i += 1;
    }
    return !in_single and !in_double;
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
        const fds = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
        const stage = try launchStage(sh, arena, argv, fds);
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
    "exists",    "is_dir",   "is_file",       "is_link",   "len",      "empty",
    "int",       "str",      "abs",           "min",       "max",      "upper",
    "lower",     "trim",     "basename",      "dirname",   "env",      "contains",
    "starts_with", "ends_with", "split",      "join",
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

fn runPipeline(sh: *Shell, commands: []const ast.Command, background: bool) u8 {
    const arena = sh.scratch();
    if (commands.len == 0) return 0;

    // Every descriptor opened for redirects is closed once the processes are up.
    var opened: std.ArrayList(i32) = .empty;
    defer for (opened.items) |fd| sys.closeFd(fd);

    if (commands.len == 1) return runSingle(sh, arena, commands[0], background, &opened);

    var stages: std.ArrayList(proc.Stage) = .empty;
    for (commands) |cmd| {
        if (misuseOfExpressionFunction(cmd.words)) |name| {
            reportExpressionFunctionMisuse(sh, name);
            return 2;
        }
        const words = resolveAliases(sh, arena, cmd.words) catch return 1;
        var argv: std.ArrayList([]const u8) = .empty;
        expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return exprError(sh, err);
        if (argv.items.len == 0) continue;

        const fds = applyRedirects(sh, arena, cmd, &opened) catch |err| return exprError(sh, err);
        const call_argv = argv.toOwnedSlice(arena) catch return 1;
        const stage = makeStage(sh, arena, call_argv, fds) catch |err| return exprError(sh, err);
        stages.append(arena, stage) catch return 1;
    }

    if (stages.items.len == 0) return 0;

    const text = pipelineText(arena, commands) catch "pipeline";
    if (background) return startBackground(sh, arena, stages.items, text);
    return runForeground(sh, arena, stages.items, text);
}

/// Builds a stage that either execs a program or runs shell code in the child.
fn makeStage(sh: *Shell, arena: std.mem.Allocator, argv: []const []const u8, fds: Fds) Error!proc.Stage {
    if (isInternal(sh, argv[0])) {
        const payload = try arena.create(ChildPayload);
        payload.* = .{ .sh = sh, .argv = argv };
        return .{
            .child_fn = childExecute,
            .child_ctx = payload,
            .stdio = .{ .in = fds.in, .out = fds.out, .err = fds.err },
        };
    }
    return try launchStage(sh, arena, argv, fds);
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

    const fds = applyRedirects(sh, arena, cmd, opened) catch |err| return exprError(sh, err);

    // `> file` with no command just creates the file.
    if (argv.items.len == 0) return 0;

    const call_argv = argv.toOwnedSlice(arena) catch return 1;
    const name = call_argv[0];
    const text = pipelineText(arena, &.{cmd}) catch name;

    if (isInternal(sh, name) and !background) {
        // Temporary defaults make the redirects visible to the nested commands
        // a function or `source` will run.
        const saved = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
        sh.default_in = fds.in;
        sh.default_out = fds.out;
        sh.default_err = fds.err;
        defer {
            sh.default_in = saved.in;
            sh.default_out = saved.out;
            sh.default_err = saved.err;
        }
        return dispatch(sh, call_argv);
    }

    const stage = makeStage(sh, arena, call_argv, fds) catch |err| return exprError(sh, err);
    if (background) return startBackground(sh, arena, &.{stage}, text);
    return runForeground(sh, arena, &.{stage}, text);
}

fn launchStage(sh: *Shell, arena: std.mem.Allocator, argv: []const []const u8, fds: Fds) Error!proc.Stage {
    const resolved = try proc.resolve(arena, argv[0], sh.pathEnv()) orelse {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: command not found: {s}\n", .{argv[0]}) catch return error.CommandNotFound;
        sys.writeStr(sh.default_err, msg);
        return error.CommandNotFound;
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
        .stdio = .{ .in = fds.in, .out = fds.out, .err = fds.err },
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
    const launched = proc.launch(arena, stages, .{}) catch |err| return exprError(sh, err);
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

    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: command not found: {s}\n", .{name}) catch return 127;
    sys.writeStr(sh.default_err, msg);
    return 127;
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

fn applyRedirects(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    opened: *std.ArrayList(i32),
) Error!Fds {
    var fds = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
    if (cmd.redirects.len == 0) return fds;

    for (cmd.redirects) |redirect| {
        const target = try expand_mod.expandLiteral(sh, arena, redirect.target);
        const z = try arena.dupeZ(u8, target);

        const fd = if (redirect.kind.isInput())
            sys.openRead(z.ptr)
        else
            sys.openWrite(z.ptr, redirect.kind.append());

        if (fd == null) {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}: cannot open file\n", .{target}) catch return error.ExecutionFailed;
            sys.writeStr(sh.default_err, msg);
            return error.ExecutionFailed;
        }

        // A later redirect for the same descriptor replaces the earlier one.
        const previous = switch (redirect.kind) {
            .in => fds.in,
            .err_out, .err_append => fds.err,
            else => fds.out,
        };
        if (previous > 2) sys.closeFd(previous);

        switch (redirect.kind) {
            .in => fds.in = fd.?,
            .err_out, .err_append => fds.err = fd.?,
            else => fds.out = fd.?,
        }
        try opened.append(arena, fd.?);
    }

    return fds;
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
        for (cmd.redirects) |r| {
            const op = switch (r.kind) {
                .in => " < ",
                .out_append => " >> ",
                .err_out => " 2> ",
                .err_append => " 2>> ",
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
