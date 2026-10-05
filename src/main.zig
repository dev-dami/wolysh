//! wolysh (`wsh`) — a modern Unix shell with a sane scripting language.

const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const sys = @import("sys.zig");
const shellmod = @import("shell.zig");
const exec = @import("exec.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const editor_mod = @import("interactive/editor.zig");
const prompt = @import("interactive/prompt.zig");
const session = @import("interactive/session.zig");
const history = @import("history.zig");

const Shell = shellmod.Shell;

const version_text = "wolysh " ++ build_options.version ++ "\n";

const help_text =
    \\wsh — wolysh, a modern Unix shell
    \\
    \\usage: wsh [options] [script [arguments...]]
    \\
    \\options:
    \\  -c <command>   run a command string and exit
    \\  -n, --check    check syntax without executing commands
    \\  -i             force interactive mode
    \\  -l, --login    mark this as a login shell
    \\      --no-config  skip the configuration file
    \\  -h, --help     show this help
    \\  -v, --version  show the version
    \\
    \\language:
    \\  let name = "value"            bind a variable
    \\  env PATH += "/opt/bin"        modify the environment
    \\  if count > 10 { ... } else { ... }
    \\  for f in src/*.rs { ... }
    \\  while n < 10 { let n = n + 1 }
    \\  fn build(mode = "debug") { cargo build --profile $mode }
    \\  (cd /tmp; pwd)               run an isolated subshell
    \\  command 2>&1 | grep error    merge stderr into stdout
    \\  command <<EOF               read a here-document
    \\
;

pub fn main(init: std.process.Init.Minimal) u8 {
    const gpa = std.heap.smp_allocator;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const argv = init.args.toSlice(arena) catch {
        sys.writeStr(2, "wsh: cannot read arguments\n");
        return 1;
    };

    var options = Options{};
    const parsed = parseArgs(argv, &options) orelse {
        sys.writeStr(2, help_text);
        return 2;
    };
    if (parsed.stop) {
        if (parsed.show_help) sys.writeStr(1, help_text);
        if (parsed.show_version) sys.writeStr(1, version_text);
        return 0;
    }

    var sh = Shell.init(gpa, init) catch {
        sys.writeStr(2, "wsh: cannot initialise the shell\n");
        return 1;
    };
    defer sh.deinit();
    exec.install(&sh);

    sh.login = options.login;

    if (options.command) |command| {
        // `-c`: everything after the command string is positional.
        sh.positional = parsed.rest;
        sh.script_name = "wsh";
        const status = if (options.check) exec.checkSource(&sh, command) else exec.runSource(&sh, command);
        return status;
    }

    if (options.script) |script| {
        sh.positional = parsed.rest;
        sh.script_name = script;
        const data = readWholeFile(gpa, script) orelse {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}: cannot read script\n", .{script}) catch return 1;
            sys.writeStr(2, msg);
            return 1;
        };
        defer gpa.free(data);
        return if (options.check) exec.checkSource(&sh, data) else exec.runSource(&sh, data);
    }

    // No command and no script: interactive when stdin is a terminal,
    // otherwise read a script from standard input.
    const is_tty = sys.isTty(0) and sys.isTty(1);
    sh.interactive = options.interactive or is_tty;

    if (options.check or !sh.interactive) {
        const data = readAllStdin(gpa) orelse return 1;
        defer gpa.free(data);
        sh.script_name = "wsh";
        return if (options.check) exec.checkSource(&sh, data) else exec.runSource(&sh, data);
    }

    return runRepl(&sh, gpa, options.no_config);
}

const Options = struct {
    command: ?[]const u8 = null,
    script: ?[]const u8 = null,
    interactive: bool = false,
    login: bool = false,
    no_config: bool = false,
    check: bool = false,
};

const ParsedArgs = struct {
    rest: []const []const u8 = &.{},
    show_help: bool = false,
    show_version: bool = false,
    stop: bool = false,
};

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn parseArgs(argv: []const [:0]const u8, options: *Options) ?ParsedArgs {
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var result = ParsedArgs{};

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eql(arg, "--")) {
            i += 1;
            break;
        }
        if (eql(arg, "-c")) {
            i += 1;
            if (i >= argv.len) return null;
            options.command = argv[i];
            i += 1;
            break;
        }
        if (eql(arg, "-i")) {
            options.interactive = true;
            continue;
        }
        if (eql(arg, "-n") or eql(arg, "--check")) {
            options.check = true;
            continue;
        }
        if (eql(arg, "-l") or eql(arg, "--login")) {
            options.login = true;
            continue;
        }
        if (eql(arg, "--no-config")) {
            options.no_config = true;
            continue;
        }
        if (eql(arg, "-h") or eql(arg, "--help")) {
            result.show_help = true;
            result.stop = true;
            return result;
        }
        if (eql(arg, "-v") or eql(arg, "--version")) {
            result.show_version = true;
            result.stop = true;
            return result;
        }
        if (arg.len > 1 and arg[0] == '-') {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: unknown option: {s}\n", .{arg}) catch return null;
            sys.writeStr(2, msg);
            return null;
        }
        options.script = arg;
        i += 1;
        break;
    }

    while (i < argv.len) : (i += 1) rest.append(gpaOf(argv), argv[i]) catch return null;
    result.rest = rest.toOwnedSlice(gpaOf(argv)) catch return null;
    return result;
}

/// `parseArgs` needs an allocator only for the positional list; the process
/// arena is not available here, so the arguments are copied into a small
/// leak-free page-backed list that lives as long as the process.
fn gpaOf(argv: []const [:0]const u8) std.mem.Allocator {
    _ = argv;
    return std.heap.smp_allocator;
}

fn readWholeFile(gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const z = gpa.dupeZ(u8, path) catch return null;
    defer gpa.free(z);
    return fs.readFileAlloc(gpa, z, 32 << 20) catch null orelse null;
}

fn readAllStdin(gpa: std.mem.Allocator) ?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = sys.readSome(0, &buf) orelse break;
        if (n == 0) break;
        out.appendSlice(gpa, buf[0..n]) catch return null;
    }
    return out.toOwnedSlice(gpa) catch null;
}

// --- interactive shell ------------------------------------------------------

fn runRepl(sh: *Shell, gpa: std.mem.Allocator, no_config: bool) u8 {
    proc.shellSignals(&sh.interrupted);
    takeControllingTerminal(sh);

    setupPaths(sh, gpa) catch {};
    sh.setAlias("la", "ls -A") catch return 1;
    sh.setAlias("lh", "ls -lh") catch return 1;
    if (!no_config) loadConfig(sh);
    loadHistory(sh);

    var editor_state = editor_mod.Editor.init(sh, 0, 2);
    defer editor_state.deinit();

    var prompt_allocating: std.Io.Writer.Allocating = .init(gpa);
    defer prompt_allocating.deinit();

    if (sh.login) sys.writeStr(1, "wolysh — type `help` in your shell for the language overview\n");

    session.begin(sh);
    defer session.end(sh);
    var history_error_reported = false;

    while (!sh.should_exit) {
        sh.resetLineArena();
        sh.reapJobs();
        sh.notifyFinishedJobs(2);
        if (proc.hangupPending()) return hangUp(sh);

        sh.interrupted = false;
        session.beforePrompt(sh);
        sh.interrupted = false;

        prompt_allocating.writer.end = 0;
        prompt.write(&prompt_allocating.writer, sh) catch {};
        prompt_allocating.writer.writeAll(session.promptEnd()) catch {};
        // The editor redraws only the prompt's last line, so earlier lines of
        // a multi-line prompt are printed once, up front.
        const full_prompt = prompt_allocating.writer.buffered();
        const last_line = if (std.mem.lastIndexOfScalar(u8, full_prompt, '\n')) |newline| newline + 1 else 0;
        sys.writeStr(2, full_prompt[0..last_line]);
        const source = editor_state.readCommand(
            full_prompt[last_line..],
            exec.isComplete,
            prompt.writeContinuation,
        ) orelse {
            if (proc.hangupPending()) return hangUp(sh);
            sys.writeStr(1, "\n");
            break;
        };
        if (proc.hangupPending()) return hangUp(sh);
        // A SIGINT sent while the line was being typed must not cancel it.
        sh.interrupted = false;
        if (editor_state.interrupted) continue;
        if (source.len == 0) continue;

        recordHistory(sh, source, &history_error_reported);
        prompt.command_number += 1;
        session.beforeCommand(sh, source);
        var status = exec.runSource(sh, source);
        if (sh.interrupted) {
            status = 130;
            sh.last_status = status;
            // Keep the echoed ^C on its own line, as bash does.
            sys.writeStr(2, "\n");
        }
        session.afterCommand(status);
        // `let prompt = ...` or `let autosuggest = false` should take effect
        // on the very next prompt.
        sh.applyConfig();
    }

    return sh.exit_code;
}

/// SIGHUP: entries already reached the history file as they were entered, so
/// the jobs get the hangup and the shell exits.
fn hangUp(sh: *Shell) u8 {
    session.hangUpJobs(sh);
    return 129;
}

/// Adds an entered line to the history under `HISTCONTROL` and appends it to
/// the history file at once. A file that cannot be written is reported once.
fn recordHistory(sh: *Shell, source: []const u8, reported: *bool) void {
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const control_text = prompt.textVar(sh, arena_state.allocator(), "HISTCONTROL") catch null;
    const entry = (sh.hist.record(sh.gpa, source, history.Control.parse(control_text)) catch return) orelse return;
    if (sh.history_path.len == 0) return;
    sh.hist.appendToFile(sh.gpa, sh.history_path, entry) catch {
        if (reported.*) return;
        reported.* = true;
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: history: cannot write {s}\n", .{sh.history_path}) catch return;
        sys.writeStr(2, msg);
    };
}

/// Puts the shell in its own process group and claims the terminal, which is
/// what makes job control possible.
fn takeControllingTerminal(sh: *Shell) void {
    if (!sys.isTty(0)) return;

    const my_pgid = sys.getpgid(0) orelse return;
    if (my_pgid != sys.getpid()) {
        sys.setpgid(0, 0);
    }
    sh.shell_pgid = sys.getpgid(0) orelse sh.pid;

    while (true) {
        const foreground = sys.tcgetpgrp(0) orelse break;
        if (foreground == sh.shell_pgid) break;
        proc.signalGroup(sh.shell_pgid, .TTOU);
    }

    sh.tty_fd = 0;
    sh.job_control = true;
}

fn setupPaths(sh: *Shell, gpa: std.mem.Allocator) !void {
    const home = sh.getEnv("HOME") orelse return;

    const config_dir = sh.getEnv("XDG_CONFIG_HOME") orelse
        try std.fmt.allocPrint(gpa, "{s}/.config", .{home});
    sh.config_path = try std.fmt.allocPrint(gpa, "{s}/wsh/config", .{config_dir});

    const data_dir = sh.getEnv("XDG_DATA_HOME") orelse
        try std.fmt.allocPrint(gpa, "{s}/.local/share", .{home});
    sh.history_path = try std.fmt.allocPrint(gpa, "{s}/wsh/history", .{data_dir});
}

fn loadConfig(sh: *Shell) void {
    if (sh.config_path.len == 0) return;
    const z = sh.gpa.dupeZ(u8, sh.config_path) catch return;
    defer sh.gpa.free(z);
    const data = (fs.readFileAlloc(sh.gpa, z, 1 << 20) catch return) orelse return;
    defer sh.gpa.free(data);
    _ = exec.runSource(sh, data);
    sh.last_status = 0;
    sh.applyConfig();
}

fn loadHistory(sh: *Shell) void {
    if (sh.history_path.len == 0) return;
    sh.hist.limit = sh.config.history_limit;
    sh.hist.load(sh.gpa, sh.history_path) catch {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: history: cannot load {s}\n", .{sh.history_path}) catch return;
        sys.writeStr(2, msg);
    };
}

test "argument parsing" {
    const argv = [_][:0]const u8{ "wsh", "-c", "echo hi" };
    var options = Options{};
    const parsed = parseArgs(&argv, &options).?;
    try std.testing.expectEqualStrings("echo hi", options.command.?);
    _ = parsed;

    const argv2 = [_][:0]const u8{ "wsh", "script.wsh", "a", "b" };
    var options2 = Options{};
    const parsed2 = parseArgs(&argv2, &options2).?;
    try std.testing.expectEqualStrings("script.wsh", options2.script.?);
    try std.testing.expectEqual(@as(usize, 2), parsed2.rest.len);
}
