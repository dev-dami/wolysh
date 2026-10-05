//! Services the REPL provides around each command line: the `precmd`,
//! `preexec` and `chpwd` hook functions, `PROMPT_COMMAND`, terminal
//! integration escapes (OSC 7, OSC 133 and the window title) and hanging up
//! jobs on SIGHUP.

const std = @import("std");
const linux = std.os.linux;
const shellmod = @import("../shell.zig");
const exec = @import("../exec.zig");
const sys = @import("../sys.zig");
const proc = @import("../proc.zig");
const jobs = @import("../jobs.zig");
const prompt = @import("prompt.zig");

const Shell = shellmod.Shell;

/// The descriptor the prompt and the terminal escapes go to.
const term_fd = 2;

pub const Hook = enum { precmd, preexec, chpwd, PROMPT_COMMAND };

/// Pid of the interactive shell while its REPL runs, 0 otherwise. Forked
/// subshells inherit it, which is how they know not to run `chpwd`.
var session_pid: i32 = 0;
var known_cwd: std.ArrayList(u8) = .empty;
var in_chpwd = false;
var failure_reported = std.EnumArray(Hook, bool).initFill(false);
var integration = false;

pub fn begin(sh: *Shell) void {
    session_pid = sys.getpid();
    known_cwd.clearRetainingCapacity();
    known_cwd.appendSlice(sh.gpa, sh.cwd) catch {};
}

pub fn end(sh: *Shell) void {
    session_pid = 0;
    known_cwd.deinit(sh.gpa);
    known_cwd = .empty;
}

/// Runs one hook. Hooks see the last command's `$?` and leave it as they found
/// it, `set -e` does not apply inside them, and a failing hook is reported
/// once until it succeeds again.
fn run(sh: *Shell, hook: Hook, args: []const []const u8) void {
    const saved_status = sh.last_status;
    const saved_return = sh.return_pending;
    sh.condition_depth += 1;
    defer {
        sh.condition_depth -= 1;
        sh.last_status = saved_status;
        sh.return_pending = saved_return;
    }

    const status = switch (hook) {
        .PROMPT_COMMAND => blk: {
            const text = (prompt.textVar(sh, sh.scratch(), "PROMPT_COMMAND") catch null) orelse return;
            if (std.mem.trim(u8, text, " \t\n").len == 0) return;
            break :blk exec.runSource(sh, text);
        },
        else => exec.callFunction(sh, @tagName(hook), args) orelse return,
    };

    if (status == 0) {
        failure_reported.set(hook, false);
    } else if (!sh.interrupted and !failure_reported.get(hook)) {
        failure_reported.set(hook, true);
        var buf: [128]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "wsh: {s} hook failed with status {d}\n", .{ @tagName(hook), status }) catch return;
        sys.writeStr(term_fd, message);
    }
}

/// Before each prompt: `precmd`, then `PROMPT_COMMAND`, then the terminal's
/// directory, title and prompt-start mark.
pub fn beforePrompt(sh: *Shell) void {
    run(sh, .precmd, &.{});
    run(sh, .PROMPT_COMMAND, &.{});
    integration = integrationEnabled(sh);
    if (!integration) return;

    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    writeCwdReport(arena, &out, sh.hostname, sh.cwd) catch return;
    out.appendSlice(arena, "\x1b]2;") catch return;
    appendTitle(arena, &out, sh.shortenHome(arena, sh.cwd) catch sh.cwd) catch return;
    out.appendSlice(arena, "\x07\x1b]133;A\x1b\\") catch return;
    sys.writeStr(term_fd, out.items);
}

/// Marks the end of the prompt; the REPL appends it to the prompt text so it
/// lands right before the user's input on every redraw.
pub fn promptEnd() []const u8 {
    return if (integration) "\x1b]133;B\x1b\\" else "";
}

/// After the line is read: the window title shows the command, the output
/// mark is set, and `preexec` gets the line as `$1`.
pub fn beforeCommand(sh: *Shell, line: []const u8) void {
    if (integration) {
        var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var out: std.ArrayList(u8) = .empty;
        out.appendSlice(arena, "\x1b]2;") catch return;
        appendTitle(arena, &out, line) catch return;
        out.appendSlice(arena, "\x07\x1b]133;C\x1b\\") catch return;
        sys.writeStr(term_fd, out.items);
    }
    run(sh, .preexec, &.{line});
}

pub fn afterCommand(status: u8) void {
    if (!integration) return;
    var buf: [32]u8 = undefined;
    const mark = std.fmt.bufPrint(&buf, "\x1b]133;D;{d}\x1b\\", .{status}) catch return;
    sys.writeStr(term_fd, mark);
}

/// Called after every statement: runs `chpwd` once the working directory has
/// changed. Only the session process does; subshells and command
/// substitutions would otherwise print into captured output.
pub fn checkDirectory(sh: *Shell) void {
    if (session_pid == 0 or std.mem.eql(u8, known_cwd.items, sh.cwd)) return;
    known_cwd.clearRetainingCapacity();
    known_cwd.appendSlice(sh.gpa, sh.cwd) catch {};
    if (in_chpwd or sys.getpid() != session_pid) return;
    in_chpwd = true;
    defer in_chpwd = false;
    run(sh, .chpwd, &.{});
}

/// SIGHUP: forwards the hangup to every job not marked by `disown -h`, waking
/// stopped ones so they can act on it.
pub fn hangUpJobs(sh: *Shell) void {
    for (sh.jobs.jobs.items) |job| {
        if (job.state == .done or job.no_hup) continue;
        signalJob(sh, job, .HUP);
        if (job.state == .stopped) signalJob(sh, job, .CONT);
    }
}

fn signalJob(sh: *const Shell, job: jobs.Job, sig: linux.SIG) void {
    if (job.pgid > 0 and job.pgid != sh.shell_pgid) {
        proc.signalGroup(job.pgid, sig);
        return;
    }
    for (job.pids) |pid| {
        if (pid > 0) proc.signalProcess(pid, sig);
    }
}

fn integrationEnabled(sh: *const Shell) bool {
    if (sh.getVar("terminal_integration")) |v| {
        if (!v.truthy()) return false;
    }
    // The Linux console prints OSC sequences it does not know as text.
    if (sh.getEnv("TERM")) |term| {
        if (std.mem.eql(u8, term, "dumb") or std.mem.eql(u8, term, "linux")) return false;
    }
    return sys.isTty(term_fd);
}

/// OSC 7: `file://HOST/path`, percent-encoding everything but unreserved
/// characters and `/`.
fn writeCwdReport(arena: std.mem.Allocator, out: *std.ArrayList(u8), host: []const u8, cwd: []const u8) !void {
    try out.appendSlice(arena, "\x1b]7;file://");
    try out.appendSlice(arena, host);
    for (cwd) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '/' or c == '-' or c == '.' or c == '_' or c == '~') {
            try out.append(arena, c);
        } else {
            try out.print(arena, "%{X:0>2}", .{c});
        }
    }
    try out.appendSlice(arena, "\x1b\\");
}

/// The first line of `text` without control characters, cut at a character
/// boundary so the title stays short and cannot end the escape early.
fn appendTitle(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    const max = 96;
    var cut = std.mem.indexOfScalar(u8, text, '\n') orelse text.len;
    if (cut > max) {
        cut = max;
        while (cut > 0 and (text[cut] & 0xc0) == 0x80) cut -= 1;
    }
    for (text[0..cut]) |c| try out.append(arena, if (c < 0x20 or c == 0x7f) ' ' else c);
}

test "OSC 7 percent-encodes the directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try writeCwdReport(arena, &out, "box", "/home/dev/my dir/ü");
    try std.testing.expectEqualStrings("\x1b]7;file://box/home/dev/my%20dir/%C3%BC\x1b\\", out.items);
}

test "prompt marks take no columns" {
    const displayWidth = @import("editor.zig").displayWidth;
    try std.testing.expectEqual(@as(usize, 2), displayWidth("\x1b]133;A\x1b\\ab\x1b]133;B\x1b\\"));
    try std.testing.expectEqual(@as(usize, 3), displayWidth("\x1b]0;title\x07a\x1b[1mbc"));
}

test "titles keep one sanitised line" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    try appendTitle(arena, &out, "echo a\tb\x1b]0;x\nsecond line");
    try std.testing.expectEqualStrings("echo a b ]0;x", out.items);
}
