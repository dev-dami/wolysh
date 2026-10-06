//! Execution: statements, pipelines, functions and expression evaluation.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");
const shellmod = @import("shell.zig");
const expand_mod = @import("expand.zig");
const arith = @import("arith.zig");
const proc = @import("proc.zig");
const value = @import("value.zig");
const fs = @import("fs.zig");
const glob = @import("glob.zig");
const completeness = @import("executor/completeness.zig");
const substitution = @import("executor/substitution.zig");
const command = @import("executor/command.zig");
const expression = @import("executor/expression.zig");
const function = @import("executor/function.zig");
const pipeline = @import("executor/pipeline.zig");
const session = @import("interactive/session.zig");
const strict = @import("strict.zig");
const procsub = @import("executor/procsub.zig");
const conditional = @import("executor/conditional.zig");

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
        if (sh.interrupted) return 130;
        sh.runPendingTraps();
        status = runStmt(sh, stmt);
        sh.last_status = status;
        session.checkDirectory(sh);
        if (stopRequested(sh) or sh.break_pending or sh.continue_pending) break;
    }
    return status;
}

/// `exit`, `return` or Ctrl-C: the enclosing lists and loops unwind.
fn stopRequested(sh: *const Shell) bool {
    return sh.should_exit or sh.return_pending or sh.interrupted;
}

fn setLine(sh: *Shell, line: u32) void {
    if (line != 0) sh.current_line = line;
}

fn runStmt(sh: *Shell, stmt: ast.Stmt) u8 {
    const arena = sh.scratch();
    switch (stmt) {
        .pipeline => |chain| return runChain(sh, chain),

        .var_decl => |decl| {
            setLine(sh, decl.line);
            const v = evalExpr(sh, arena, decl.value) catch |err| return statementFailed(sh, exprError(sh, err));
            sh.assignVar(decl.name, v) catch |err| {
                if (err == error.ReadonlyVariable) reportReadonly(sh, decl.name);
                return statementFailed(sh, 1);
            };
            return 0;
        },

        .env_assign => |assign| {
            setLine(sh, assign.line);
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

        .fn_decl => |decl| {
            setLine(sh, decl.line);
            sh.defineFunc(decl.name, decl.source) catch return 1;
            sh.setFuncLine(decl.name, decl.line) catch return 1;
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
        error.InvalidArithmetic, error.DivisionByZero => {
            const detail = arith.takeErrorMessage() orelse
                if (err == error.DivisionByZero) "division by zero" else "arithmetic syntax error";
            var buf: [1100]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}\n", .{detail}) catch "wsh: arithmetic error\n";
            sys.writeStr(sh.default_err, msg);
            return 1;
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
        error.BadSubstitution, error.UnboundVariable => return expansionFailed(sh),
        error.ReadonlyVariable => {
            sys.writeStr(sh.default_err, "wsh: readonly variable\n");
            return 1;
        },
        error.BraceExpansionTooLarge => {
            sys.writeStr(sh.default_err, "wsh: brace expansion: too many words\n");
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

/// A failed `${...}` (its message already printed) aborts the command, and a
/// non-interactive shell exits with status 1, as a bash script does.
fn expansionFailed(sh: *Shell) u8 {
    if (!sh.interactive) {
        sh.should_exit = true;
        sh.exit_code = 1;
    }
    return 1;
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

/// What a loop does after its body ran once.
const AfterBody = enum { next, stop, leave };

/// Applies a pending `break`/`continue` and the stop conditions. `.leave`
/// means a count reaches an outer loop, which must stop too.
fn afterBody(sh: *Shell) AfterBody {
    const brk = takeBreak(sh);
    if (brk == .here) return .stop;
    if (brk == .outer) return .leave;
    const next = takeContinue(sh);
    if (next == .here) return .next;
    if (next == .outer) return .leave;
    if (stopRequested(sh)) return .stop;
    return .next;
}

/// A per-iteration arena installed as the shell's scratch allocator while a
/// loop runs, so long loops do not grow the line arena.
const LoopScope = struct {
    arena: std.heap.ArenaAllocator,
    saved: ?std.mem.Allocator,

    fn enter(sh: *Shell) LoopScope {
        loop_depth += 1;
        return .{ .arena = std.heap.ArenaAllocator.init(sh.gpa), .saved = sh.scratch_override };
    }

    fn install(self: *LoopScope, sh: *Shell) void {
        sh.scratch_override = self.arena.allocator();
    }

    fn nextIteration(self: *LoopScope) void {
        _ = self.arena.reset(.retain_capacity);
    }

    fn leave(self: *LoopScope, sh: *Shell) void {
        sh.scratch_override = self.saved;
        self.arena.deinit();
        loop_depth -= 1;
    }
};

/// Expands a `for`/`select` word list in the enclosing arena, so the items
/// survive the per-iteration resets.
fn expandItems(sh: *Shell, words: []const ast.Word) Error![]const []const u8 {
    const outer = sh.scratch();
    var items: std.ArrayList([]const u8) = .empty;
    for (words) |word| try expand_mod.expandWord(sh, outer, word, &items);
    return items.items;
}

fn runFor(sh: *Shell, loop: ast.For) u8 {
    // `for f in <(ls)` keeps the substitution open for the whole loop.
    const substitutions = procsub.mark();
    defer procsub.release(substitutions);
    const items = expandItems(sh, loop.items) catch |err| return exprError(sh, err);
    var scope = LoopScope.enter(sh);
    defer scope.leave(sh);
    scope.install(sh);

    var status: u8 = 0;
    for (items) |item| {
        if (sh.interrupted) break;
        scope.nextIteration();
        sh.setVar(loop.name, .{ .string = item }) catch return 1;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        switch (afterBody(sh)) {
            .next => {},
            .stop, .leave => break,
        }
    }
    return status;
}

fn runWhile(sh: *Shell, loop: ast.While) u8 {
    var scope = LoopScope.enter(sh);
    defer scope.leave(sh);
    scope.install(sh);

    var status: u8 = 0;
    while (!sh.interrupted) {
        scope.nextIteration();
        const passed = switch (testCondition(sh, loop.cond)) {
            .failed => |code| return code,
            .passed => |passed| passed,
        };
        if (afterBody(sh) != .next or passed == loop.until) break;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        switch (afterBody(sh)) {
            .next => {},
            .stop, .leave => break,
        }
    }
    return status;
}

fn runIf(sh: *Shell, branch: ast.If) u8 {
    const passed = switch (testCondition(sh, branch.cond)) {
        .failed => |code| return code,
        .passed => |passed| passed,
    };
    if (stopRequested(sh) or sh.break_pending or sh.continue_pending) return sh.last_status;
    if (passed) return runStmts(sh, branch.then.stmts);
    if (branch.else_) |else_block| return runStmts(sh, else_block.stmts);
    return 0;
}

const TestResult = union(enum) {
    passed: bool,
    /// The expression could not be evaluated; this is the status.
    failed: u8,
};

/// Runs an `if`/`while`/`until` test where `set -e` does not apply.
fn testCondition(sh: *Shell, cond: ast.Condition) TestResult {
    sh.condition_depth += 1;
    defer sh.condition_depth -= 1;
    if (cond.expr) |expr| {
        if (cond.list == null or namesBound(sh, expr)) {
            const result = evalExpr(sh, sh.scratch(), expr) catch |err| return .{ .failed = exprError(sh, err) };
            return .{ .passed = result.truthy() };
        }
    }
    return .{ .passed = runStmts(sh, cond.list orelse &.{}) == 0 };
}

/// For a condition that is only bare names (`if ! ready {`): true when every
/// name is a variable, so it reads as an expression rather than commands.
fn namesBound(sh: *Shell, expr: *const ast.Expr) bool {
    return switch (expr.*) {
        .ident => |name| expression.isBound(sh, name),
        .un => |unary| namesBound(sh, unary.operand),
        .logic => |logic| namesBound(sh, logic.lhs) and namesBound(sh, logic.rhs),
        else => true,
    };
}

fn runCase(sh: *Shell, case: ast.Case) u8 {
    const substitutions = procsub.mark();
    defer procsub.release(substitutions);
    const arena = sh.scratch();
    const subject = expand_mod.expandLiteral(sh, arena, case.word) catch |err| return exprError(sh, err);
    var status: u8 = 0;
    // Set by `;&`: the next body runs without testing its patterns.
    var fall_through = false;
    for (case.items) |item| {
        if (!fall_through) {
            const matched = caseMatches(sh, arena, item.patterns, subject) catch |err| return exprError(sh, err);
            if (!matched) continue;
        }
        status = runStmts(sh, item.body);
        if (stopRequested(sh) or sh.break_pending or sh.continue_pending) return status;
        switch (item.next) {
            .stop => return status,
            .fallthrough => fall_through = true,
            .test_next => fall_through = false,
        }
    }
    return status;
}

fn caseMatches(sh: *Shell, arena: std.mem.Allocator, patterns: []const ast.Word, subject: []const u8) Error!bool {
    for (patterns) |word| {
        const pattern = try expand_mod.expandPattern(sh, arena, word);
        if (glob.matchSegmentWith(pattern, subject, .{ .nocase = sh.options.nocasematch })) return true;
    }
    return false;
}

/// `select NAME in WORDS`: prints a numbered menu on standard error, reads
/// a choice from standard input into `REPLY` and runs the body with NAME set
/// to the chosen word (empty for an invalid choice) until `break` or EOF.
fn runSelect(sh: *Shell, loop: ast.For) u8 {
    const substitutions = procsub.mark();
    defer procsub.release(substitutions);
    const items = expandItems(sh, loop.items) catch |err| return exprError(sh, err);
    var scope = LoopScope.enter(sh);
    defer scope.leave(sh);
    scope.install(sh);

    var status: u8 = 0;
    var show_menu = true;
    while (!sh.interrupted) {
        scope.nextIteration();
        const arena = sh.scratch();
        if (show_menu) printMenu(sh, arena, items);
        show_menu = false;
        const prompt = if (sh.getVar("PS3")) |v| (v.renderAlloc(arena) catch "#? ") else sh.getEnv("PS3") orelse "#? ";
        sys.writeStr(sh.default_err, prompt);

        const line = readLine(sh, arena) orelse {
            sys.writeStr(sh.default_err, "\n");
            status = 1;
            break;
        };
        // An empty answer shows the menu again.
        if (line.len == 0) {
            show_menu = true;
            continue;
        }
        sh.setVar("REPLY", .{ .string = line }) catch return 1;
        const trimmed = std.mem.trim(u8, line, " \t");
        const choice = std.fmt.parseInt(usize, trimmed, 10) catch 0;
        const picked = if (choice >= 1 and choice <= items.len) items[choice - 1] else "";
        sh.setVar(loop.name, .{ .string = picked }) catch return 1;
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        switch (afterBody(sh)) {
            .next => {},
            .stop, .leave => break,
        }
    }
    return status;
}

fn printMenu(sh: *Shell, arena: std.mem.Allocator, items: []const []const u8) void {
    // Numbers are right-aligned to the widest one, like bash.
    const width = digitCount(items.len);
    var out: std.ArrayList(u8) = .empty;
    for (items, 1..) |item, index| {
        out.appendNTimes(arena, ' ', width - digitCount(index)) catch return;
        out.print(arena, "{d}) {s}\n", .{ index, item }) catch return;
    }
    sys.writeStr(sh.default_err, out.items);
}

fn digitCount(n: usize) usize {
    var count: usize = 1;
    var rest = n;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

/// One line from the shell's standard input without its newline, or null at
/// end of input.
fn readLine(sh: *Shell, arena: std.mem.Allocator) ?[]const u8 {
    var line: std.ArrayList(u8) = .empty;
    var got_any = false;
    while (sys.readByte(sh.default_in)) |c| {
        got_any = true;
        if (c == '\n') return line.items;
        line.append(arena, c) catch return null;
    }
    return if (got_any) line.items else null;
}

fn runCompound(sh: *Shell, compound: *const ast.Compound) u8 {
    return switch (compound.kind) {
        .if_ => |branch| runIf(sh, branch),
        .for_ => |loop| runFor(sh, loop),
        .while_ => |loop| runWhile(sh, loop),
        .case_ => |case| runCase(sh, case),
        .select_ => |loop| runSelect(sh, loop),
        .statement => |stmt| runStmt(sh, stmt),
        .cond => |cond| runCond(sh, cond),
        .arith => |text| runArith(sh, text),
        .arith_for => |loop| runArithFor(sh, loop),
    };
}

fn runCond(sh: *Shell, cond: *const ast.Cond) u8 {
    // `[[ -s <(cmd) ]]` keeps the substitution open while the test runs.
    const substitutions = procsub.mark();
    defer procsub.release(substitutions);
    const passed = conditional.evaluate(sh, sh.scratch(), cond) catch |err| return switch (err) {
        error.BadRegex => 2,
        else => arithFailed(sh, "[[", err),
    };
    return if (passed) 0 else 1;
}

/// `(( expression ))`: 0 when the expression is non-zero.
fn runArith(sh: *Shell, text: []const u8) u8 {
    const n = arithmetic(sh, text) catch |err| return arithFailed(sh, "((", err);
    return if (n != 0) 0 else 1;
}

fn runArithFor(sh: *Shell, loop: ast.ArithFor) u8 {
    if (!isBlank(loop.init)) _ = arithmetic(sh, loop.init) catch |err| return arithFailed(sh, "((", err);
    var scope = LoopScope.enter(sh);
    defer scope.leave(sh);
    scope.install(sh);

    var status: u8 = 0;
    while (!sh.interrupted) {
        scope.nextIteration();
        if (!isBlank(loop.cond)) {
            const n = arithmetic(sh, loop.cond) catch |err| return arithFailed(sh, "((", err);
            if (n == 0) break;
        }
        status = runStmts(sh, loop.body.stmts);
        sh.last_status = status;
        switch (afterBody(sh)) {
            .next => {},
            .stop, .leave => break,
        }
        if (!isBlank(loop.step)) _ = arithmetic(sh, loop.step) catch |err| return arithFailed(sh, "((", err);
    }
    return status;
}

fn isBlank(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len == 0;
}

/// Expands and evaluates the text of `(( ))` or one part of `for (( ))`,
/// which `set -x` shows the way bash does.
fn arithmetic(sh: *Shell, text: []const u8) arith.Error!i64 {
    const arena = sh.scratch();
    const expanded = try arith.expandText(sh, arena, text);
    if (sh.options.xtrace) strict.traceText(sh, try std.fmt.allocPrint(arena, "(( {s} ))", .{expanded}));
    return arith.evaluateExpanded(sh, arena, expanded);
}

/// A failed `((` or `[[` evaluation, worded like bash:
/// `((: 1/0 : division by 0 (error token is "0 ")`.
fn arithFailed(sh: *Shell, name: []const u8, err: anyerror) u8 {
    switch (err) {
        error.InvalidArithmetic, error.DivisionByZero => {
            const detail = arith.takeErrorMessage() orelse "arithmetic syntax error";
            var buf: [1100]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}: {s}\n", .{ name, detail }) catch "wsh: arithmetic error\n";
            sys.writeStr(sh.default_err, msg);
            return 1;
        },
        else => return exprError(sh, err),
    }
}

// --- expression evaluation --------------------------------------------------

fn evalExpr(sh: *Shell, arena: std.mem.Allocator, expr: *const ast.Expr) Error!Value {
    return expression.evaluate(sh, arena, expr, executeExpressionCall);
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
        .run_compound = runCompound,
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

/// Calls the shell function `name` as an interactive hook. It runs apart from
/// any loop the caller is in, so a stray `break` in it cannot leak out.
/// Returns null when no such function is defined.
pub fn callFunction(sh: *Shell, name: []const u8, args: []const []const u8) ?u8 {
    const source = sh.getFunc(name) orelse return null;
    const argv = sh.scratch().alloc([]const u8, args.len + 1) catch return 1;
    argv[0] = name;
    @memcpy(argv[1..], args);

    const saved = .{ loop_depth, break_level, continue_level, sh.break_pending, sh.continue_pending };
    loop_depth = 0;
    break_level = 0;
    continue_level = 0;
    sh.break_pending = false;
    sh.continue_pending = false;
    defer loop_depth, break_level, continue_level, sh.break_pending, sh.continue_pending = saved;
    return runFunction(sh, name, source, argv);
}

// --- substitution -----------------------------------------------------------

pub fn substitutionRunner(sh: *Shell, src: []const u8, arena: std.mem.Allocator) anyerror![]const u8 {
    return substitution.run(sh, src, arena, runSource);
}

/// Called once at startup to wire command substitution into expansion.
pub fn install(sh: *Shell) void {
    sh.subst_runner = substitutionRunner;
    sh.trap_runner = runSource;
    procsub.run_source = runSource;
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

    // Real errors are reported straight away. (`if { }` is now an unfinished
    // POSIX `if` whose condition is an empty group.)
    try testing.expect(isComplete("fi"));
    try testing.expect(isComplete("echo hi"));

    // And a closed block is complete.
    try testing.expect(isComplete("if true {\n echo hi\n}"));

    // `[[` waits for its `]]`, and `for ((...))` for its body.
    try testing.expect(!isComplete("[[ -n $x &&"));
    try testing.expect(!isComplete("[[ a == b"));
    try testing.expect(isComplete("[[ a < b ]] && echo yes"));
    try testing.expect(isComplete("echo [["));
    try testing.expect(!isComplete("for ((i = 0; i < 3; i++))"));
    try testing.expect(isComplete("(( i > 2 ))"));
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

test "POSIX if, loops and case" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\if false; then echo no; elif true; then echo elif; else echo else; fi
        \\i=0
        \\while [ $i -lt 2 ]; do i=$((i+1)); echo w$i; done
        \\until [ $i -eq 0 ]; do i=$((i-1)); done; echo u$i
        \\for x in a b; do for y in 1 2; do [ $y = 2 ] && continue 2; echo $x$y; done; done
        \\case abc in a*) echo one;& z*) echo two;; *) echo three;; esac
        \\case abc in a*) echo first;;& *c) echo second;;& z*) echo third;; esac
        \\case "a*" in "a*") echo quoted;; esac
        \\case /usr/bin in */bin) echo slash;; esac
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("elif\nw1\nw2\nu0\na1\nb1\none\ntwo\nfirst\nsecond\nquoted\nslash\n", out);

    // No branch taken and no match both succeed.
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "false; if false; then :; fi\n"));
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "false; case x in y) ;; esac\n"));
    try testing.expectEqual(@as(u8, 1), runSource(&sh, "case x in x) false;; esac\n"));
}

test "case honours nocasematch" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    try testing.expectEqual(@as(u8, 1), runSource(&sh, "case ABC in abc) true;; *) false;; esac\n"));
    sh.options.nocasematch = true;
    try testing.expectEqual(@as(u8, 0), runSource(&sh, "case ABC in abc) true;; *) false;; esac\n"));
}

test "POSIX functions take arguments, locals, return and redirections" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-function-redirect-test.txt";
    var buf: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf,
        \\count() {{ local n=$#; echo "$FUNCNAME:$n:$1"; return $n; }}
        \\count a b; echo "status $? [$FUNCNAME]"
        \\logged() {{ echo "$1"; }} > {s}
        \\logged hidden
        \\function twice {{ echo "$@" "$@"; }}
        \\twice x
    , .{path});
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("count:2:a\nstatus 2 []\nx x\n", out);

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    const data = (try fs.readFileAlloc(testing.allocator, z, 1024)).?;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings("hidden\n", data);
    _ = fs.removeFile(z);
}

test "native conditions run commands when they are not expressions" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const source =
        \\if /bin/sh -c 'exit 0' { echo ran }
        \\if ! /bin/sh -c 'exit 3' { echo negated }
        \\false
        \\if $? == 1 { echo status }
        \\let ready = true
        \\if ready { echo variable }
        \\if ! ready { echo wrong } else { echo not-negated }
        \\let n = 0
        \\until n == 2 { let n = n + 1 }
        \\echo $n
    ;
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("ran\nnegated\nstatus\nvariable\nnot-negated\n2\n", out);
}

test "compound commands are redirected and piped" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    const path = "zig-cache-compound-redirect-test.txt";
    var buf: [512]u8 = undefined;
    const source = try std.fmt.bufPrint(&buf,
        \\for i in a b {{ echo $i }} > {s}
        \\while read -r line; do echo "got $line"; done < {s}
        \\for i in 1 2; do echo $i; done | /bin/cat
    , .{ path, path });
    const out = try collectOutput(&sh, source);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("got a\ngot b\n1\n2\n", out);

    const z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(z);
    _ = fs.removeFile(z);
}

test "an interrupt stops loops and statement lists" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    sh.interrupted = true;
    const out = try collectOutput(&sh, "for i in a b; do echo $i; done\nwhile true { echo spin }\necho after\n");
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("", out);
}

var recorded_line: u32 = 0;

/// Stands in for command substitution so a test can see `current_line` at
/// the moment a word is expanded.
fn recordLine(sh: *Shell, _: []const u8, _: std.mem.Allocator) anyerror![]const u8 {
    recorded_line = sh.current_line;
    return "";
}

test "statements set the current line, and function bodies keep theirs" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);
    sh.subst_runner = recordLine;

    _ = runSource(&sh, "true\n\nif true; then\n  : $(x)\nfi\n");
    try testing.expectEqual(@as(u32, 4), recorded_line);

    _ = runSource(&sh, "true\nwhile true {\n  : $(x)\n  break\n}\n");
    try testing.expectEqual(@as(u32, 3), recorded_line);

    _ = runSource(&sh, "\n\nshow() {\n  : $(x)\n}\n\nshow\n");
    try testing.expectEqual(@as(u32, 4), recorded_line);
    try testing.expectEqual(@as(u32, 7), sh.current_line);
}

test "isComplete waits for POSIX blocks and function bodies" {
    try testing.expect(!isComplete("if true; then"));
    try testing.expect(!isComplete("if true; then\n echo hi"));
    try testing.expect(isComplete("if true; then\n echo hi\nfi"));
    try testing.expect(!isComplete("if true; then echo; elif false; then echo; else"));
    try testing.expect(isComplete("if true; then echo; elif false; then echo; else echo; fi"));
    try testing.expect(!isComplete("if true"));
    try testing.expect(!isComplete("for i in 1 2; do"));
    try testing.expect(isComplete("for i in 1 2; do echo $i; done"));
    try testing.expect(!isComplete("while read -r l; do\n  case $l in"));
    try testing.expect(!isComplete("case $1 in\n  a) echo a;;"));
    try testing.expect(isComplete("case $1 in\n  a) if true; then echo; fi;;\nesac"));
    try testing.expect(!isComplete("f() {"));
    try testing.expect(!isComplete("f()"));
    try testing.expect(isComplete("f() { echo; }"));
    try testing.expect(!isComplete("function f"));
    try testing.expect(isComplete("echo if then do case"));
    try testing.expect(!isComplete("while true; do cat <<EOF\nbody"));
    try testing.expect(isComplete("while read l; do echo $l; done <<EOF\na\nEOF\n"));
    // Native blocks still close with a brace.
    try testing.expect(!isComplete("while x == 1 {"));
    try testing.expect(isComplete("if grep -q x f { echo }"));
    try testing.expect(isComplete("for f in a b { echo $f }"));
}

test "time reports on standard error" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    install(&sh);

    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    const saved = sh.default_err;
    sh.default_err = fds[1];
    const status = runSource(&sh, "time -p true\nTIMEFORMAT='took %0R'\ntime { false; }\n");
    sh.default_err = saved;
    _ = linux.close(fds[1]);
    var buf: [256]u8 = undefined;
    const n = sys.readAll(fds[0], &buf);
    _ = linux.close(fds[0]);
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expectEqualStrings("real 0.00\nuser 0.00\nsys 0.00\ntook 0\n", buf[0..n]);
}
