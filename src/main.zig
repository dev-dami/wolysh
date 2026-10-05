//! wolysh (`wsh`) — a modern Unix shell with a sane scripting language.

const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const sys = @import("sys.zig");
const shellmod = @import("shell.zig");
const exec = @import("exec.zig");
const strict = @import("strict.zig");
const set_builtin = @import("builtins/set.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const editor_mod = @import("interactive/editor.zig");
const prompt = @import("interactive/prompt.zig");
const session = @import("interactive/session.zig");
const history = @import("history.zig");
const login = @import("login.zig");
const stdin_script = @import("stdin_script.zig");

const Shell = shellmod.Shell;

const version_text = "wolysh " ++ build_options.version ++ "\n";

const help_text =
    \\wsh — wolysh, a modern Unix shell
    \\
    \\usage: wsh [options] [script [arguments...]]
    \\       wsh [options] -c command [name [arguments...]]
    \\       wsh [options] -s [arguments...]
    \\
    \\options:
    \\  -c               run the first argument as a command; the next one is $0
    \\  -s               read commands from standard input; arguments are positional
    \\  -i               force interactive mode
    \\  -l, --login      run as a login shell
    \\  -n, --check      check syntax without executing commands
    \\  -e -u -x -f -C -a  set errexit, nounset, xtrace, noglob, noclobber, allexport
    \\  -o NAME, +o NAME   set or clear a shell option (errexit, pipefail, ...)
    \\      --norc, --no-config  skip the configuration file
    \\      --rcfile FILE  read FILE instead of the configuration file
    \\      --noprofile    skip login initialisation
    \\  -h, --help       show this help
    \\  -v, --version    show the version
    \\
    \\Short options combine (`-lc`, `-ec`), `+` clears a flag, and `--` or `-`
    \\ends the options.
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

    const argv0: []const u8 = if (argv.len > 0) argv[0] else "wsh";
    // `login` and `sshd` start a login shell with a `-` in front of its name.
    sh.login = options.login or (argv0.len > 0 and argv0[0] == '-');
    sh.options = options.shell;
    sh.script_name = argv0;
    sh.positional = parsed.rest;
    bumpShellLevel(&sh) catch {
        sys.writeStr(2, "wsh: cannot initialise the shell\n");
        return 1;
    };

    // bash's rule: interactive when commands come from a terminal and errors
    // go to one, or when `-i` asks for it. Standard output may be a pipe.
    const reads_input = options.command == null and options.script == null;
    sh.interactive = options.interactive or (reads_input and sys.isTty(0) and sys.isTty(2));

    if (!options.check) {
        if (sh.login) {
            if (sh.interactive) proc.shellSignals(&sh.interrupted);
            login.initialise(&sh, options.no_profile);
            if (sh.should_exit) return strict.finish(&sh, sh.exit_code);
        }
        if (options.rcfile) |path| {
            if (!useRcFile(&sh, gpa, path)) return 1;
        }
    }

    if (options.command) |command| {
        if (options.name) |name| sh.script_name = name;
        if (options.check) return exec.checkSource(&sh, command);
        if (sh.interactive) loadInteractiveConfig(&sh, gpa, options.no_config);
        return strict.finish(&sh, exec.runSource(&sh, command));
    }

    if (options.script) |script| {
        sh.script_name = script;
        // A script file is parsed as a whole: a syntax error anywhere means
        // none of it runs.
        const data = readWholeFile(gpa, script) orelse {
            var buf: [512]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "wsh: {s}: cannot read script\n", .{script}) catch return 1;
            sys.writeStr(2, msg);
            return 1;
        };
        defer gpa.free(data);
        if (options.check) return exec.checkSource(&sh, data);
        if (sh.interactive) loadInteractiveConfig(&sh, gpa, options.no_config);
        return strict.finish(&sh, exec.runSource(&sh, data));
    }

    if (options.check) {
        const data = readAllStdin(gpa) orelse return 1;
        defer gpa.free(data);
        return exec.checkSource(&sh, data);
    }
    if (!sh.interactive) return strict.finish(&sh, stdin_script.run(&sh));

    return runRepl(&sh, gpa, options.no_config);
}

const Options = struct {
    command: ?[]const u8 = null,
    script: ?[]const u8 = null,
    /// `$0` given after a `-c` command.
    name: ?[]const u8 = null,
    command_mode: bool = false,
    read_stdin: bool = false,
    interactive: bool = false,
    login: bool = false,
    no_config: bool = false,
    no_profile: bool = false,
    rcfile: ?[]const u8 = null,
    check: bool = false,
    shell: shellmod.Options = .{},
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

/// Options are read up to the first operand, `--` or `-`, as bash does. With
/// `-c` the first operand is the command and the next one `$0`; with `-s` all
/// operands are positional; otherwise the first operand is a script file.
fn parseArgs(argv: []const [:0]const u8, options: *Options) ?ParsedArgs {
    var rest: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    var result = ParsedArgs{};

    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (eql(arg, "--") or eql(arg, "-")) {
            i += 1;
            break;
        }
        if (std.mem.startsWith(u8, arg, "--")) {
            if (eql(arg, "--check")) {
                options.check = true;
            } else if (eql(arg, "--login")) {
                options.login = true;
            } else if (eql(arg, "--no-config") or eql(arg, "--norc")) {
                options.no_config = true;
            } else if (eql(arg, "--noprofile")) {
                options.no_profile = true;
            } else if (eql(arg, "--rcfile")) {
                i += 1;
                if (i >= argv.len) return missingArgument(arg);
                options.rcfile = argv[i];
            } else if (eql(arg, "--help")) {
                result.show_help = true;
                result.stop = true;
                return result;
            } else if (eql(arg, "--version")) {
                result.show_version = true;
                result.stop = true;
                return result;
            } else {
                return unknownOption(arg);
            }
            continue;
        }
        // `-h` and `-v` only stand alone; `-v` is the version, not bash's verbose.
        if (eql(arg, "-h")) {
            result.show_help = true;
            result.stop = true;
            return result;
        }
        if (eql(arg, "-v")) {
            result.show_version = true;
            result.stop = true;
            return result;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;

        const on = arg[0] == '-';
        for (arg[1..]) |letter| {
            if (letter == 'o') {
                i += 1;
                if (i >= argv.len) return missingArgument(if (on) "-o" else "+o");
                if (!setNamedOption(&options.shell, argv[i], on)) {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "wsh: {s}: invalid option name\n", .{argv[i]}) catch return null;
                    sys.writeStr(2, msg);
                    return null;
                }
            } else if (!setFlag(options, letter, on)) {
                return unknownOption(arg);
            }
        }
    }

    const operands = argv[i..];
    var params = operands;
    if (options.command_mode) {
        if (operands.len == 0) return missingArgument("-c");
        options.command = operands[0];
        params = operands[1..];
        if (params.len > 0) {
            options.name = params[0];
            params = params[1..];
        }
    } else if (!options.read_stdin and operands.len > 0) {
        options.script = operands[0];
        params = operands[1..];
    }

    for (params) |param| rest.append(gpaOf(argv), param) catch return null;
    result.rest = rest.toOwnedSlice(gpaOf(argv)) catch return null;
    return result;
}

/// One letter of a short-option group; `on` is false for the `+` form. The
/// shell options are the ones `set` takes.
fn setFlag(options: *Options, letter: u8, on: bool) bool {
    if (set_builtin.setByLetter(&options.shell, letter, on)) return true;
    // The invocation-only options have no `+` form.
    if (!on) return false;
    switch (letter) {
        'c' => options.command_mode = true,
        's' => options.read_stdin = true,
        'i' => options.interactive = true,
        'l' => options.login = true,
        'n' => options.check = true,
        else => return false,
    }
    return true;
}

/// `-o NAME`: the names `set -o` takes.
fn setNamedOption(shell: *shellmod.Options, name: []const u8, on: bool) bool {
    return set_builtin.setByName(shell, name, on);
}

fn unknownOption(arg: []const u8) ?ParsedArgs {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: unknown option: {s}\n", .{arg}) catch return null;
    sys.writeStr(2, msg);
    return null;
}

fn missingArgument(option: []const u8) ?ParsedArgs {
    var buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: {s}: option requires an argument\n", .{option}) catch return null;
    sys.writeStr(2, msg);
    return null;
}

/// `parseArgs` needs an allocator only for the positional list; the process
/// arena is not available here, so the arguments are copied into a small
/// leak-free page-backed list that lives as long as the process.
fn gpaOf(argv: []const [:0]const u8) std.mem.Allocator {
    _ = argv;
    return std.heap.smp_allocator;
}

/// Increments and exports `SHLVL`; a missing or malformed value counts as 0.
fn bumpShellLevel(sh: *Shell) !void {
    const current = std.mem.trim(u8, sh.getEnv("SHLVL") orelse "", " \t");
    var level = (std.fmt.parseInt(i64, current, 10) catch 0) +| 1;
    if (level < 0) level = 0;
    if (level >= 1000) {
        var warn: [96]u8 = undefined;
        sys.writeStr(2, std.fmt.bufPrint(&warn, "wsh: warning: shell level ({d}) too high, resetting to 1\n", .{level}) catch "");
        level = 1;
    }
    var buf: [24]u8 = undefined;
    try sh.setEnv("SHLVL", try std.fmt.bufPrint(&buf, "{d}", .{level}));
}

/// `--rcfile FILE` replaces the configuration file of an interactive shell.
fn useRcFile(sh: *Shell, gpa: std.mem.Allocator, path: []const u8) bool {
    if (!sh.interactive) return true;
    const z = gpa.dupeZ(u8, path) catch return false;
    defer gpa.free(z);
    if (!sys.canAccess(z, 4)) {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: {s}: cannot read the configuration file\n", .{path}) catch "wsh: cannot read the configuration file\n";
        sys.writeStr(2, msg);
    }
    sh.config_path = gpa.dupe(u8, path) catch return false;
    return true;
}

/// `-i` with a command or a script: read the configuration as an interactive
/// shell would, then run.
fn loadInteractiveConfig(sh: *Shell, gpa: std.mem.Allocator, no_config: bool) void {
    setupPaths(sh, gpa) catch {};
    if (!no_config) loadConfig(sh);
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
            if (strict.confirmExit(sh)) break;
            continue;
        };
        if (proc.hangupPending()) return hangUp(sh);
        // A SIGINT sent while the line was being typed must not cancel it.
        sh.interrupted = false;
        if (editor_state.interrupted) continue;
        if (source.len == 0) continue;

        recordHistory(sh, source, &history_error_reported);
        prompt.command_number += 1;
        session.beforeCommand(sh, source);
        const warned = sh.exit_warned;
        var status = exec.runSource(sh, source);
        // Only an immediately repeated `exit` gets past the stopped-jobs warning.
        if (warned) sh.exit_warned = false;
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

    return strict.finish(sh, sh.exit_code);
}

/// SIGHUP: entries already reached the history file as they were entered, so
/// the jobs get the hangup, the EXIT trap runs and the shell exits.
fn hangUp(sh: *Shell) u8 {
    session.hangUpJobs(sh);
    strict.runExitTrap(sh);
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
    // `--rcfile` has already chosen the file.
    if (sh.config_path.len == 0) sh.config_path = try std.fmt.allocPrint(gpa, "{s}/wsh/config", .{config_dir});

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

test "bundled options, -c operands and named options" {
    const argv = [_][:0]const u8{ "wsh", "-lec", "+e", "-o", "pipefail", "echo", "name", "one" };
    var options = Options{};
    const parsed = parseArgs(&argv, &options).?;
    try std.testing.expect(options.login);
    try std.testing.expect(!options.shell.errexit);
    try std.testing.expect(options.shell.pipefail);
    try std.testing.expectEqualStrings("echo", options.command.?);
    try std.testing.expectEqualStrings("name", options.name.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.rest.len);
    try std.testing.expectEqualStrings("one", parsed.rest[0]);

    const stdin_argv = [_][:0]const u8{ "wsh", "-s", "--noprofile", "--rcfile", "rc", "a", "b" };
    var stdin_options = Options{};
    const stdin_parsed = parseArgs(&stdin_argv, &stdin_options).?;
    try std.testing.expect(stdin_options.read_stdin and stdin_options.no_profile);
    try std.testing.expectEqualStrings("rc", stdin_options.rcfile.?);
    try std.testing.expect(stdin_options.script == null);
    try std.testing.expectEqual(@as(usize, 2), stdin_parsed.rest.len);

    const dash_argv = [_][:0]const u8{ "wsh", "-x", "-", "-script" };
    var dash_options = Options{};
    _ = parseArgs(&dash_argv, &dash_options).?;
    try std.testing.expect(dash_options.shell.xtrace);
    try std.testing.expectEqualStrings("-script", dash_options.script.?);
}
