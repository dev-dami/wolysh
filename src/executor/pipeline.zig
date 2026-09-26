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
    linux.exit(command.dispatch(sh, payload.argv, payload.command_runtime));
}

pub fn runChain(sh: *Shell, chain: ast.Pipeline, runtime: Runtime) u8 {
    var status = runPipeline(sh, chain.commands, chain.background, runtime);
    for (chain.links) |link| {
        const should_run = switch (link.op) {
            .and_ => status == 0,
            .or_ => status != 0,
        };
        if (should_run) status = runPipeline(sh, link.pipeline.commands, link.pipeline.background, runtime);
    }
    return status;
}

fn runPipeline(sh: *Shell, commands: []const ast.Command, background: bool, runtime: Runtime) u8 {
    const arena = sh.scratch();
    if (commands.len == 0) return 0;

    var opened: std.ArrayList(i32) = .empty;
    defer for (opened.items) |fd| sys.closeFd(fd);

    if (commands.len == 1) return runSingle(sh, arena, commands[0], background, &opened, runtime);

    var stages: std.ArrayList(proc.Stage) = .empty;
    for (commands) |cmd| {
        if (cmd.subshell) |statements| {
            const prepared = redirect.apply(sh, arena, cmd, &opened) catch |err| return runtime.expression_error(sh, err);
            const stage = subshell.makeStage(sh, arena, statements, prepared.redirects, runtime.run_statements) catch |err| {
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
        const stage = makeStage(sh, arena, call_argv, prepared.redirects, runtime) catch |err| {
            return runtime.expression_error(sh, err);
        };
        stages.append(arena, stage) catch return 1;
    }

    if (stages.items.len == 0) return 0;

    const text = pipelineText(arena, commands) catch "pipeline";
    if (background) return startBackground(sh, arena, stages.items, text, runtime.expression_error);
    return runForeground(sh, arena, stages.items, text, runtime.expression_error);
}

fn makeStage(
    sh: *Shell,
    arena: std.mem.Allocator,
    argv: []const []const u8,
    redirects: []const proc.Redirection,
    runtime: Runtime,
) Error!proc.Stage {
    if (command.isInternal(sh, argv[0])) {
        const payload = try arena.create(ChildPayload);
        payload.* = .{ .sh = sh, .argv = argv, .command_runtime = runtime.command };
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
    if (expression.misuse(cmd.words)) |name| {
        expression.reportMisuse(sh, name);
        return 2;
    }

    const words = command.resolveAliases(sh, arena, cmd.words) catch return 1;
    var argv: std.ArrayList([]const u8) = .empty;
    expand_mod.expandCommand(sh, arena, words, &argv) catch |err| return runtime.expression_error(sh, err);

    const prepared = redirect.apply(sh, arena, cmd, opened) catch |err| return runtime.expression_error(sh, err);
    if (argv.items.len == 0 and cmd.subshell == null) return 0;

    if (cmd.subshell) |statements| {
        const stage = subshell.makeStage(sh, arena, statements, prepared.redirects, runtime.run_statements) catch |err| {
            return runtime.expression_error(sh, err);
        };
        const text = pipelineText(arena, &.{cmd}) catch "subshell";
        if (background) return startBackground(sh, arena, &.{stage}, text, runtime.expression_error);
        return runForeground(sh, arena, &.{stage}, text, runtime.expression_error);
    }

    const call_argv = argv.toOwnedSlice(arena) catch return 1;
    const name = call_argv[0];
    const text = pipelineText(arena, &.{cmd}) catch name;

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

    const stage = makeStage(sh, arena, call_argv, prepared.redirects, runtime) catch |err| {
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
    const launched = proc.launch(arena, stages, .{ .new_group = sh.job_control }) catch |err| return expression_error(sh, err);
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
    if (outcome.signal) |signal| reportSignal(sh, signal);
    return outcome.status;
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
        for (cmd.redirects) |item| {
            const operator = switch (item.kind) {
                .in => " < ",
                .here_doc => " << ",
                .out_append => " >> ",
                .err_out => " 2> ",
                .err_append => " 2>> ",
                .out_dup => " >&",
                .err_dup => " 2>&",
                else => " > ",
            };
            try out.appendSlice(arena, operator);
            try out.appendSlice(arena, item.target);
        }
    }
    return out.toOwnedSlice(arena);
}
