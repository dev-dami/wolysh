const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");
const command = @import("command.zig");
const expression = @import("expression.zig");
const redirect = @import("redirect.zig");
const subshell = @import("subshell.zig");
const assign = @import("assign.zig");
const strict = @import("../strict.zig");

const Shell = shellmod.Shell;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };
pub const ErrorHandler = *const fn (*Shell, anyerror) u8;

pub const Runtime = struct {
    command: command.Runtime,
    run_statements: subshell.RunStatements,
    expression_error: ErrorHandler,
};

const ChildPayload = struct {
    sh: *Shell,
    argv: []const []const u8,
    command_runtime: command.Runtime,
    scope: assign.State,
};

const MissingCommandPayload = struct { message: []const u8 };

fn childReportMissingCommand(ctx_ptr: *anyopaque) noreturn {
    const payload: *MissingCommandPayload = @ptrCast(@alignCast(ctx_ptr));
    sys.writeStr(2, payload.message);
    linux.exit(127);
}

fn childExecute(ctx_ptr: *anyopaque) noreturn {
    const payload: *ChildPayload = @ptrCast(@alignCast(ctx_ptr));
    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    strict.enterSubshell(sh);
    payload.scope.apply() catch linux.exit(1);
    strict.exitChild(sh, command.dispatch(sh, payload.argv, payload.command_runtime));
}

pub fn runChain(sh: *Shell, chain: ast.Pipeline, runtime: Runtime) u8 {
    var status = runLink(sh, chain, chain.links.len != 0, runtime);
    for (chain.links, 0..) |link, index| {
        const should_run = switch (link.op) {
            .and_ => status == 0,
            .or_ => status != 0,
        };
        if (should_run) status = runLink(sh, link.pipeline, index + 1 < chain.links.len, runtime);
    }
    return status;
}

/// One pipeline of an `&&`/`||` list. Every part but the last, and any `!`
/// pipeline, is a condition: its failure does not trip `set -e` or ERR.
fn runLink(sh: *Shell, link: ast.Pipeline, more_follow: bool, runtime: Runtime) u8 {
    const condition = more_follow or link.negate;
    if (condition) sh.condition_depth += 1;
    defer if (condition) {
        sh.condition_depth -= 1;
    };
    const status = runPipeline(sh, link.commands, link.background, runtime);
    return if (link.negate) invert(status) else status;
}

/// `! pipeline`: success and failure trade places, so a signal-killed pipeline
/// (a non-zero status) becomes a success.
fn invert(status: u8) u8 {
    return if (status == 0) 1 else 0;
}

fn runPipeline(sh: *Shell, commands: []const ast.Command, background: bool, runtime: Runtime) u8 {
    var statuses: []const u8 = &.{};
    const status = runStages(sh, commands, background, runtime, &statuses);
    // A `{ ...; }` group's own status is not a command failure: the commands
    // inside it were checked as they ran.
    if (background or (commands.len == 1 and commands[0].group != null)) return status;
    strict.setPipeStatus(sh, if (statuses.len != 0) statuses else &.{status});
    strict.commandDone(sh, status);
    return status;
}

fn runStages(
    sh: *Shell,
    commands: []const ast.Command,
    background: bool,
    runtime: Runtime,
    statuses_out: *[]const u8,
) u8 {
    const arena = sh.scratch();
    if (commands.len == 0) return 0;

    var opened: std.ArrayList(i32) = .empty;
    defer for (opened.items) |fd| sys.closeFd(fd);

    if (commands.len == 1) return runSingle(sh, arena, commands[0], background, &opened, runtime);

    var stages: std.ArrayList(proc.Stage) = .empty;
    for (commands) |cmd| {
        if (cmd.subshell == null and cmd.group == null) strict.beforeCommand(sh);
        const scope = assign.enter(sh, arena, cmd) catch |err| return runtime.expression_error(sh, err);
        defer scope.restore();

        if (cmd.subshell orelse cmd.group) |statements| {
            const prepared = redirect.apply(sh, arena, cmd, &opened) catch |err| return runtime.expression_error(sh, err);
            const stage = subshell.makeStage(sh, arena, statements, prepared.redirects, scope, runtime.run_statements) catch |err| {
                return runtime.expression_error(sh, err);
            };
            stages.append(arena, stage) catch return 1;
            continue;
        }
        if (expression.misuse(cmd.words)) |name| {
            expression.reportMisuse(sh, name);
            return 2;
        }
        const words = command.resolveAliases(sh, arena, cmd.words) catch return 1;
        var argv: std.ArrayList([]const u8) = .empty;
        expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return runtime.expression_error(sh, err);
        if (argv.items.len == 0) continue;

        const prepared = redirect.apply(sh, arena, cmd, &opened) catch |err| return runtime.expression_error(sh, err);
        const call_argv = argv.toOwnedSlice(arena) catch return 1;
        strict.traceCommand(sh, call_argv);
        const stage = makeStage(sh, arena, call_argv, prepared.redirects, scope, runtime) catch |err| {
            return runtime.expression_error(sh, err);
        };
        stages.append(arena, stage) catch return 1;
    }

    if (stages.items.len == 0) return 0;

    const text = pipelineText(arena, commands) catch "pipeline";
    if (background) return startBackground(sh, arena, stages.items, text, runtime.expression_error);
    const statuses = arena.alloc(u8, stages.items.len) catch return runtime.expression_error(sh, error.OutOfMemory);
    statuses_out.* = statuses;
    return waitStages(sh, arena, stages.items, text, runtime.expression_error, statuses);
}

fn makeStage(
    sh: *Shell,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    redirects: []const proc.Redirection,
    scope: assign.State,
    runtime: Runtime,
) Error!proc.Stage {
    if (command.isInternal(sh, argv[0])) {
        const payload = try arena.create(ChildPayload);
        payload.* = .{ .sh = sh, .argv = argv, .command_runtime = runtime.command, .scope = scope };
        return .{
            .child_fn = childExecute,
            .child_ctx = payload,
            .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
            .redirects = redirects,
        };
    }
    return try launchStage(sh, arena, argv, redirects);
}

fn runSingle(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    background: bool,
    opened: *std.ArrayList(i32),
    runtime: Runtime,
) u8 {
    if (cmd.subshell == null and cmd.group == null) strict.beforeCommand(sh);
    if (expression.misuse(cmd.words)) |name| {
        expression.reportMisuse(sh, name);
        return 2;
    }

    const words = command.resolveAliases(sh, arena, cmd.words) catch return 1;
    var argv: std.ArrayList([]const u8) = .empty;
    sh.subst_status = null;
    expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return runtime.expression_error(sh, err);

    const prepared = redirect.apply(sh, arena, cmd, opened) catch |err| return runtime.expression_error(sh, err);
    if (argv.items.len == 0 and cmd.subshell == null and cmd.group == null) {
        // `NAME=value` on its own outlives the command line. Like bash, a
        // command with no words has the status of its last substitution.
        assign.persist(sh, arena, cmd.assigns) catch |err| return runtime.expression_error(sh, err);
        return sh.subst_status orelse 0;
    }

    const scope = assign.enter(sh, arena, cmd) catch |err| return runtime.expression_error(sh, err);
    defer scope.restore();

    if (cmd.group != null and !background) {
        const statements = cmd.group.?;
        const saved = redirect.Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
        sh.default_in = prepared.fds.in;
        sh.default_out = prepared.fds.out;
        sh.default_err = prepared.fds.err;
        defer {
            sh.default_in = saved.in;
            sh.default_out = saved.out;
            sh.default_err = saved.err;
        }
        return runtime.run_statements(sh, statements);
    }

    if (cmd.subshell orelse cmd.group) |statements| {
        const stage = subshell.makeStage(sh, arena, statements, prepared.redirects, scope, runtime.run_statements) catch |err| {
            return runtime.expression_error(sh, err);
        };
        const text = pipelineText(arena, &.{cmd}) catch "subshell";
        if (background) return startBackground(sh, arena, &.{stage}, text, runtime.expression_error);
        return runForeground(sh, arena, &.{stage}, text, runtime.expression_error);
    }

    const call_argv = argv.toOwnedSlice(arena) catch return 1;
    const name = call_argv[0];
    const text = pipelineText(arena, &.{cmd}) catch name;
    strict.traceCommand(sh, call_argv);

    if (command.isInternal(sh, name) and !background) {
        const saved = redirect.Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
        sh.default_in = prepared.fds.in;
        sh.default_out = prepared.fds.out;
        sh.default_err = prepared.fds.err;
        defer {
            sh.default_in = saved.in;
            sh.default_out = saved.out;
            sh.default_err = saved.err;
        }
        return command.dispatch(sh, call_argv, runtime.command);
    }

    const stage = makeStage(sh, arena, call_argv, prepared.redirects, scope, runtime) catch |err| {
        return runtime.expression_error(sh, err);
    };
    if (background) return startBackground(sh, arena, &.{stage}, text, runtime.expression_error);
    return runForeground(sh, arena, &.{stage}, text, runtime.expression_error);
}

pub fn launchStage(
    sh: *Shell,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    redirects: []const proc.Redirection,
) Error!proc.Stage {
    const resolved = try proc.resolve(arena, argv[0], sh.pathEnv()) orelse {
        const payload = try arena.create(MissingCommandPayload);
        payload.* = .{ .message = try command.commandNotFoundMessage(sh, arena, argv[0]) };
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

    const shell_argv = try arena.alloc([]const u8, argv.len + 1);
    shell_argv[0] = "/bin/sh";
    shell_argv[1] = resolved;
    for (argv[1..], 0..) |argument, index| shell_argv[index + 2] = argument;
    exec.shell_path = "/bin/sh";
    exec.shell_argv = try proc.buildArgv(arena, shell_argv);

    return .{
        .exec = exec,
        .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
        .redirects = redirects,
    };
}

fn startBackground(
    sh: *Shell,
    arena: std.mem.Allocator,
    stages: []const proc.Stage,
    text: []const u8,
    expression_error: ErrorHandler,
) u8 {
    const launched = proc.launch(arena, stages, .{}) catch |err| return expression_error(sh, err);
    const last_pid = launched.pids[launched.pids.len - 1];
    sh.last_bg_pid = last_pid;

    const job = sh.jobs.add(sh.gpa, launched.pgid, launched.pids, text, false) catch return 1;
    var buf: [64]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "[{d}] {d}\n", .{ job.id, last_pid }) catch return 0;
    sys.writeStr(sh.default_err, line);
    return 0;
}

pub fn runForeground(
    sh: *Shell,
    arena: std.mem.Allocator,
    stages: []const proc.Stage,
    text: []const u8,
    expression_error: ErrorHandler,
) u8 {
    const statuses = arena.alloc(u8, stages.len) catch return expression_error(sh, error.OutOfMemory);
    return waitStages(sh, arena, stages, text, expression_error, statuses);
}

/// Runs `stages` as a foreground job, recording each one's status in
/// `statuses`. With `set -o pipefail` the result is the last non-zero status.
fn waitStages(
    sh: *Shell,
    arena: std.mem.Allocator,
    stages: []const proc.Stage,
    text: []const u8,
    expression_error: ErrorHandler,
    statuses: []u8,
) u8 {
    const interrupted_before = strict.interruptPending();
    const launched = proc.launch(arena, stages, .{ .new_group = sh.job_control }) catch |err| {
        const status = expression_error(sh, err);
        @memset(statuses, status);
        return status;
    };
    @memset(statuses, 0);
    const job = sh.jobs.add(sh.gpa, launched.pgid, launched.pids, text, true) catch return 1;
    const outcome = sh.waitForegroundStages(job, statuses);

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
    if (outcome.signal) |signal| reportSignal(sh, signal);
    strict.foregroundDone(outcome.signal, interrupted_before);
    if (!sh.options.pipefail) return outcome.status;
    var status: u8 = 0;
    for (statuses) |stage_status| {
        if (stage_status != 0) status = stage_status;
    }
    return status;
}

fn reportSignal(sh: *Shell, signal: u32) void {
    const name: []const u8 = switch (signal) {
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

fn pipelineText(arena: std.mem.Allocator, commands: []const ast.Command) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    for (commands, 0..) |cmd, command_index| {
        if (command_index != 0) try out.appendSlice(arena, " | ");
        for (cmd.words, 0..) |word, word_index| {
            if (word_index != 0) try out.append(arena, ' ');
            try out.appendSlice(arena, word);
        }
        if (cmd.subshell != null) try out.appendSlice(arena, "(subshell)");
        if (cmd.group != null) try out.appendSlice(arena, "{group}");
        for (cmd.assigns) |assignment| {
            try out.appendSlice(arena, assignment.name);
            try out.append(arena, '=');
            try out.appendSlice(arena, assignment.value);
            try out.append(arena, ' ');
        }
        for (cmd.redirects) |item| {
            const operator = switch (item.kind) {
                .in => " < ",
                .here_doc => " << ",
                .here_string => " <<< ",
                .out_append => " >> ",
                .err_out => " 2> ",
                .err_append => " 2>> ",
                .out_dup => " >&",
                .err_dup => " 2>&",
                .in_dup => " <&",
                else => " > ",
            };
            try out.appendSlice(arena, operator);
            try out.appendSlice(arena, item.target);
        }
    }
    return out.toOwnedSlice(arena);
}
