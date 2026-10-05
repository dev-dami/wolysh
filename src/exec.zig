//! Execution: statements, pipelines, functions and expression evaluation.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const shellmod = @import("shell.zig");
const expand_mod = @import("expand.zig");
const proc = @import("proc.zig");
const value = @import("value.zig");
const fs = @import("fs.zig");
const completeness = @import("executor/completeness.zig");
const substitution = @import("executor/substitution.zig");
const command = @import("executor/command.zig");
const expression = @import("executor/expression.zig");
const function = @import("executor/function.zig");
const pipeline = @import("executor/pipeline.zig");
const strict = @import("strict.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };

/// How many loops are currently executing. `break N`/`continue N` count from
/// the innermost one.
var loop_depth: u32 = 0;
/// Enclosing loops a pending `break`/`continue` still has to reach.
var break_level: u32 = 0;
var continue_level: u32 = 0;

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
    // A `break`/`continue` with no enclosing loop must not leak into the next
    // command line.
    if (loop_depth == 0) {
        sh.break_pending = false;
        sh.continue_pending = false;
        break_level = 0;
        continue_level = 0;
    }
    return status;
}

pub fn checkSource(sh: *Shell, src: []const u8) u8 {
    var p = parser_mod.Parser.init(sh.scratch(), src);
    _ = p.parseProgram() catch {
        reportSyntaxError(sh, &p);
        return 2;
    };
    return 0;
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
pub const isComplete = completeness.isComplete;

// --- statements -------------------------------------------------------------

pub fn runStmts(sh: *Shell, stmts: []const ast.Stmt) u8 {
    var status: u8 = 0;
    for (stmts) |stmt| {
        sh.runPendingTraps();
        status = runStmt(sh, stmt);
        sh.last_status = status;
        if (sh.should_exit or sh.return_pending or sh.break_pending or sh.continue_pending) break;
    }
    return status;
}

fn runStmt(sh: *Shell, stmt: ast.Stmt) u8 {
    const arena = sh.scratch();
    switch (stmt) {
        .pipeline => |chain| return runChain(sh, chain),

        .var_decl => |decl| {
            const v = evalExpr(sh, arena, decl.value) catch |err| return statementFailed(sh, exprError(sh, err));
            sh.assignVar(decl.name, v) catch |err| {
                if (err == error.ReadonlyVariable) reportReadonly(sh, decl.name);
                return statementFailed(sh, 1);
            };
            return 0;
        },

        .env_assign => |assign| {
            const v = evalExpr(sh, arena, assign.value) catch |err| return statementFailed(sh, exprError(sh, err));
            const text = v.renderAlloc(arena) catch return 1;
            const final = switch (assign.op) {
                .set => text,
                .append => blk: {
                    const existing = sh.getEnv(assign.name) orelse "";
                    break :blk std.fmt.allocPrint(arena, "{s}{s}", .{ existing, text }) catch return 1;
                },
            };
            sh.assignEnv(assign.name, final) catch |err| {
                if (err == error.ReadonlyVariable) reportReadonly(sh, assign.name);
                return statementFailed(sh, 1);
            };
            return 0;
        },

        .if_ => |branch| {
            const cond = evalCondition(sh, arena, branch.cond) catch |err| return exprError(sh, err);
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

        .break_ => |count| {
            sh.break_pending = true;
            break_level = if (loop_depth == 0) 1 else @min(count, loop_depth);
            return 0;
        },

        .continue_ => |count| {
            sh.continue_pending = true;
            continue_level = if (loop_depth == 0) 1 else @min(count, loop_depth);
            return 0;
        },

        .alias => |a| {
            sh.setAlias(a.name, a.value) catch return 1;
            return 0;
        },
    }
}

/// A failed `let` or `env` statement counts as a failed command for `set -e`
/// and the ERR trap.
fn statementFailed(sh: *Shell, status: u8) u8 {
    strict.commandDone(sh, status);
    return status;
}

fn exprError(sh: *Shell, err: anyerror) u8 {
    switch (err) {
        error.CommandNotFound => return 127,
        error.OutOfMemory => {
            sys.writeStr(sh.default_err, "wsh: out of memory\n");
            return 1;
        },
        error.InvalidArithmetic => {
            sys.writeStr(sh.default_err, "wsh: arithmetic syntax error\n");
            return 2;
        },
        error.DivisionByZero => {
            sys.writeStr(sh.default_err, "wsh: division by zero\n");
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
        error.ReadonlyVariable => {
            sys.writeStr(sh.default_err, "wsh: readonly variable\n");
            return 1;
        },
        else => {
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}\n", .{@errorName(err)}) catch "wsh: error\n";
            sys.writeStr(sh.default_err, msg);
            return 2;
        },
    }
}

fn reportReadonly(sh: *Shell, name: []const u8) void {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: {s}: readonly variable\n", .{name}) catch return;
    sys.writeStr(sh.default_err, msg);
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

/// What the loop boundary should do with a pending `break`/`continue`.
const LoopControl = enum {
    none,
    /// The innermost loop handles it.
    here,
    /// The count reaches further out: stop this loop and pass it upward.
    outer,
};

fn takeBreak(sh: *Shell) LoopControl {
    if (!sh.break_pending and break_level == 0) return .none;
    sh.break_pending = false;
    if (break_level > 1) {
        break_level -= 1;
        sh.break_pending = true;
        return .outer;
    }
    break_level = 0;
    return .here;
}

fn takeContinue(sh: *Shell) LoopControl {
    if (!sh.continue_pending and continue_level == 0) return .none;
    sh.continue_pending = false;
    if (continue_level > 1) {
        continue_level -= 1;
        sh.continue_pending = true;
        return .outer;
    }
    continue_level = 0;
    return .here;
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
    defer {
        sh.scratch_override = saved;
        loop_depth -= 1;
    }
    loop_depth += 1;

    var status: u8 = 0;
    for (items.items) |item| {
        _ = iter_arena.reset(.retain_capacity);
        sh.setVar(loop.name, .{ .string = item }) catch return 1;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        const brk = takeBreak(sh);
        if (brk == .here) break;
        if (brk == .outer) return status;
        const next = takeContinue(sh);
        if (next == .here) continue;
        if (next == .outer) return status;
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
    defer {
        sh.scratch_override = saved;
        loop_depth -= 1;
    }
    loop_depth += 1;

    var status: u8 = 0;
    while (true) {
        _ = iter_arena.reset(.retain_capacity);
        const cond = evalCondition(sh, outer, loop.cond) catch |err| return exprError(sh, err);
        if (!cond.truthy()) break;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        const brk = takeBreak(sh);
        if (brk == .here) break;
        if (brk == .outer) return status;
        const next = takeContinue(sh);
        if (next == .here) continue;
        if (next == .outer) return status;
        if (sh.should_exit or sh.return_pending) break;
    }
    return status;
}

// --- expression evaluation --------------------------------------------------

fn evalExpr(sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    return expression.evaluate(sh, arena, expr, executeExpressionCall);
}

/// An `if`/`while` test: commands it runs may fail without `set -e` or the
/// ERR trap firing.
fn evalCondition(sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    sh.condition_depth += 1;
    defer sh.condition_depth -= 1;
    return evalExpr(sh, arena, expr);
}

fn executeExpressionCall(sh: *Shell, arena: std.mem.Allocator, callee: []const u8, args: []const *ast.Expr) Error!Value {
    const argv = try arena.alloc([]const u8, args.len + 1);
    argv[0] = callee;
    for (args, 0..) |arg, index| {
        argv[index + 1] = try (try evalExpr(sh, arena, arg)).renderAlloc(arena);
    }
    // A call in an expression is a test whose result becomes a value, so a
    // failure is not an error.
    sh.condition_depth += 1;
    defer sh.condition_depth -= 1;

    if (command.isInternal(sh, callee)) {
        return Value{ .boolean = command.dispatch(sh, argv, commandRuntime()) == 0 };
    }

    if (try proc.resolve(arena, callee, sh.pathEnv()) != null) {
        const stage = try pipeline.launchStage(sh, arena, argv, &.{});
        return Value{ .boolean = pipeline.runForeground(sh, arena, &.{stage}, callee, exprError) == 0 };
    }

    var buf: [160]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "wsh: unknown function '{s}'\n", .{callee}) catch "wsh: unknown function\n";
    sys.writeStr(sh.default_err, message);
    return error.ExecutionFailed;
}

pub fn isExpressionFunction(name: []const u8) bool {
    return expression.isFunction(name);
}

fn runChain(sh: *Shell, chain: ast.Pipeline) u8 {
    return pipeline.runChain(sh, chain, pipelineRuntime());
}

fn commandRuntime() command.Runtime {
    return .{ .run_source = runSource, .run_function = runFunction };
}

fn pipelineRuntime() pipeline.Runtime {
    return .{
        .command = commandRuntime(),
        .run_statements = runStmts,
        .expression_error = exprError,
    };
}

fn runFunction(sh: *Shell, name: []const u8, source: []const u8, argv: []const []const u8) u8 {
    return function.run(sh, name, source, argv, .{
        .evaluate = evalExpr,
        .expression_error = exprError,
        .run_statements = runStmts,
    });
}

// --- substitution -----------------------------------------------------------

pub fn substitutionRunner(sh: *Shell, src: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    return substitution.run(sh, src, arena, runSource);
}

/// Called once at startup to wire command substitution into expansion.
pub fn install(sh: *Shell) void {
    sh.subst_runner = substitutionRunner;
    sh.trap_runner = runSource;
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
    const command_text = try std.fmt.bufPrint(&source, "/bin/sh -c 'printf out; printf err >&2' 2>&1 > {s}\n", .{path});
    const out = try collectOutput(&sh, command_text);
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

test "isComplete knows about groups, here-strings and tab-stripping here-documents" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    try testing.expect(!isComplete("{ echo hi"));
    try testing.expect(isComplete("{ echo hi; }"));
    try testing.expect(isComplete("{ echo hi; } && echo done"));
    try testing.expect(!isComplete("{ cd /tmp;"));
    try testing.expect(isComplete("/bin/echo {} ${HOME}"));

    try testing.expect(!isComplete("cmd &>"));
    try testing.expect(isComplete("cmd &> out.txt"));
    try testing.expect(isComplete("cmd &>> out.txt"));

    try testing.expect(!isComplete("cat <<<"));
    try testing.expect(isComplete("cat <<<word"));
    try testing.expect(!isComplete("cat <<-EOF\n\tbody"));
    try testing.expect(isComplete("cat <<-EOF\n\tbody\n\tEOF\n"));
    try testing.expect(isComplete("cat <<-EOF # |\n\tbody\n\tEOF\n"));
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

test "break N leaves N enclosing loops" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\for i in a b {
        \\    for j in 1 2 {
        \\        echo inner
        \\        break 2
        \\    }
        \\    echo outer-body
        \\}
        \\echo done
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("inner\ndone\n", out);
}

test "continue N resumes the Nth enclosing loop" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\for i in a b {
        \\    for j in 1 2 {
        \\        echo inner
        \\        continue 2
        \\    }
        \\    echo outer-body
        \\}
        \\echo done
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("inner\ninner\ndone\n", out);
}

test "break N deeper than the loop nest stops every loop" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\for i in a b {
        \\    echo once
        \\    break 5
        \\}
        \\echo done
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("once\ndone\n", out);
}

test "brace groups run in the current shell" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\let value = "parent"
        \\{ let value = "child"; echo $value }
        \\echo $value
        \\{ echo grouped; } | /bin/cat
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("child\nchild\ngrouped\n", out);
    try testing.expectEqualStrings("child", sh.getVar("value").?.string);
}

test "brace groups change directory in the current shell" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const original = (try fs.getCwd(testing.allocator)) orelse return;
    defer testing.allocator.free(original);
    defer {
        var buf: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&buf, "cd {s}\n", .{original})) |restore| {
            _ = runSource(&sh, restore);
        } else |_| {}
    }

    const out = try collectOutput(&sh, "{ cd /; pwd }\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("/\n", out);
    try testing.expectEqualStrings("/", sh.cwd);
}

test "a brace group honours redirections" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-group-redirect-test.txt";
    var buf: [256]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "{{ echo grouped; }} > {s}\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("grouped\n", data);
    _ = fs.removeFile(z);
}

test "! inverts a pipeline status" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    try testing.expectEqual(@as(u8, 1), runSource(&sh, "! true\n"));
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "! false\n"));
    // `! !` cancels out, so the pipeline's own status stands.
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "! ! true\n"));
    try testing.expectEqual(@as(u8, 1), runSource(&sh, "! ! false\n"));
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "! true || echo fallback\n"));

    // A pipeline killed by a signal counts as a failure, so `!` succeeds. The
    // shell's own "Killed" notice is sent to /dev/null to keep the log clean.
    const null_fd = sys.openWrite("/dev/null", false).?;
    const saved_err = sh.default_err;
    sh.default_err = null_fd;
    const status = runSource(&sh, "! /bin/sh -c 'kill -9 $$'\n");
    sh.default_err = saved_err;
    _ = linux.close(null_fd);
    try testing.expectEqual(@as(u8, 0), status);
}

test "command-prefix assignments are temporary" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "FOO=bar /bin/sh -c 'echo $FOO'\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("bar\n", out);
    try testing.expect(sh.getEnv("FOO") == null);
    try testing.expect(sh.getVar("FOO") == null);

    // A builtin run in-process sees it too, and the value is expanded.
    const expanded = try collectOutput(&sh, "let who = \"ada\"\nWHO=$who eval 'echo $WHO'\n");
    defer testing.allocator.free(expanded);
    try testing.expectEqualStrings("ada\n", expanded);
    try testing.expect(sh.getEnv("WHO") == null);

    // `KEEP` is already exported, so a bare assignment updates it.
    _ = runSource(&sh, "export KEEP=\"/tmp\"\n");
    _ = runSource(&sh, "KEEP=kept\n");
    try testing.expectEqualStrings("kept", sh.getEnv("KEEP").?);

    // An assignment is only a prefix when it comes before the command word.
    const out2 = try collectOutput(&sh, "/bin/echo FOO=bar\n");
    defer testing.allocator.free(out2);
    try testing.expectEqualStrings("FOO=bar\n", out2);
}

test "a bare assignment persists in the shell" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "FOO=persisted\necho $FOO\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("persisted\n", out);
    try testing.expectEqualStrings("persisted", sh.getVar("FOO").?.string);
}

test "redirects beyond the standard descriptors" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-fd3-test.txt";
    var buf: [320]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "/bin/sh -c 'echo to3 >&3' 3> {s}\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("to3\n", data);
    _ = fs.removeFile(z);
}

test "descriptor duplication from a numbered descriptor" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-dup3-test.txt";
    var buf: [320]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "/bin/sh -c 'echo err >&2' 3>{s} 2>&3\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("err\n", data);
    _ = fs.removeFile(z);
}

test "a closed numbered descriptor is gone in the child" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-close-test.txt";
    var buf: [480]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "/bin/sh -c 'if [ -e /dev/fd/3 ]; then echo open; else echo closed; fi' 3>{s} 3>&-\n", .{path});
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("closed\n", out);

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    _ = fs.removeFile(z);
}

test "&> redirects stdout and stderr to the same file" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-amp-test.txt";
    var buf: [320]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf, "/bin/sh -c 'echo out; echo err >&2' &> {s}\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, source));

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("out\nerr\n", data);
    _ = fs.removeFile(z);
}

test "$0 keeps naming the shell inside a function" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);
    sh.script_name = "myscript";

    const source =
        \\fn show(who) {
        \\    echo $0 $1
        \\}
        \\show ada
        \\echo $0
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("myscript ada\nmyscript\n", out);
}

test "source passes positional parameters" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-source-test.sh";
    var buf: [320]u8 = undefined;
    const setup = try std.fmt.bufPrint(&buf, "echo 'echo $1 $2' > {s}\n", .{path});
    try testing.expectEqual(@as(u8, 0), runSource(&sh, setup));

    var run: [320]u8 = undefined;
    const call = try std.fmt.bufPrint(&run, "source {s} a b\n", .{path});
    const sourced = try collectOutput(&sh, call);
    defer testing.allocator.free(sourced);
    try testing.expectEqualStrings("a b\n", sourced);
    try testing.expectEqual(@as(usize, 0), sh.positional.len);

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    _ = fs.removeFile(z);
}

test "tab-stripping here-documents feed the body" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "cat <<-EOF\n\tone\n\t\ttwo\n\tEOF\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("one\ntwo\n", out);
}

test "here-strings feed the expanded word" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "cat <<<hello\nlet v = \"a b\"\ncat <<<\"$v\"\ncat <<<$v\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("hello\na b\na b\n", out);
}

test "braces that belong to a word are left alone" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const out = try collectOutput(&sh, "let x = \"v\"\necho ${x}-suffix\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("v-suffix\n", out);
}
