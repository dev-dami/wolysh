//! wolysh (`wsh`) — a modern Unix shell with a sane scripting language.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const shellmod = @import("shell.zig");
const exec = @import("exec.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const editor_mod = @import("interactive/editor.zig");
const prompt = @import("interactive/prompt.zig");

const Shell = shellmod.Shell;

const version_text = "wolysh 0.1.0\n";

const help_text =
    \\wsh — wolysh, a modern Unix shell
    \\
    \\usage: wsh [options] [script [arguments...]]
    \\
    \\options:
    \\  -c <command>   run a command string and exit
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
        const status = exec.runSource(&sh, command);
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
        return exec.runSource(&sh, data);
    }

    // No command and no script: interactive when stdin is a terminal,
    // otherwise read a script from standard input.
    const is_tty = sys.isTty(0) and sys.isTty(1);
    sh.interactive = options.interactive or is_tty;

    if (!sh.interactive) {
        const data = readAllStdin(gpa) orelse return 1;
        defer gpa.free(data);
        sh.script_name = "wsh";
        return exec.runSource(&sh, data);
    }

    return runRepl(&sh, gpa, options.no_config);
}

const Options = struct {
    command: ?[]const u8 = null,
    script: ?[]const u8 = null,
    interactive: bool = false,
    login: bool = false,
    no_config: bool = false,
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
    proc.shellSignals();
    takeControllingTerminal(sh);

    setupPaths(sh, gpa) catch {};
    if (!no_config) loadConfig(sh);
    loadHistory(sh);

    var editor_state = editor_mod.Editor.init(sh, 0, 2);
    defer editor_state.deinit();

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);

    var prompt_allocating: std.Io.Writer.Allocating = .init(gpa);
    defer prompt_allocating.deinit();

    if (sh.login) sys.writeStr(1, "wolysh — type `help` in your shell for the language overview\n");

    while (!sh.should_exit) {
        sh.resetLineArena();
        sh.reapJobs();
        sh.notifyFinishedJobs(2);

        line.clearRetainingCapacity();

        // First line, then continuation lines while the construct is open.
        prompt_allocating.writer.end = 0;
        prompt.write(&prompt_allocating.writer, sh) catch {};
        const first = editor_state.readLine(prompt_allocating.writer.buffered()) orelse {
            sys.writeStr(1, "\n");
            break;
        };
        if (editor_state.interrupted) continue;
        line.appendSlice(gpa, first) catch break;

        var depth: usize = 0;
        while (!exec.isComplete(line.items)) {
            depth += 1;
            prompt_allocating.writer.end = 0;
            prompt.writeContinuation(&prompt_allocating.writer, sh, depth) catch {};
            const next = editor_state.readLine(prompt_allocating.writer.buffered()) orelse break;
            if (editor_state.interrupted) {
                line.clearRetainingCapacity();
                break;
            }
            line.append(gpa, '\n') catch break;
            line.appendSlice(gpa, next) catch break;
        }
        if (line.items.len == 0) continue;

        sh.hist.add(gpa, line.items) catch {};
        _ = exec.runSource(sh, line.items);
        // `let prompt = ...` or `let autosuggest = false` should take effect
        // on the very next prompt.
        sh.applyConfig();
    }

    saveHistory(sh);
    return sh.exit_code;
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
    sh.hist.load(sh.gpa, sh.history_path) catch {};
}

fn saveHistory(sh: *Shell) void {
    if (sh.history_path.len == 0) return;
    sh.hist.save(sh.gpa, sh.history_path);
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
