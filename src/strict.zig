//! Hooks the executor calls around each command for strict mode and traps:
//! `set -e` and the ERR trap, the EXIT, DEBUG and RETURN traps, `set -x`
//! tracing and PIPESTATUS. The rules follow bash.

const std = @import("std");
const linux = std.os.linux;
const shellmod = @import("shell.zig");
const sys = @import("sys.zig");
const proc = @import("proc.zig");
const value = @import("value.zig");
const expand_mod = @import("expand.zig");
const quote = @import("quote.zig");

const Shell = shellmod.Shell;

/// Trap handlers currently running. DEBUG, ERR and RETURN stay quiet inside
/// them so a handler cannot set itself off.
var running_traps: u32 = 0;
/// How many times `set -x` repeats the first character of `$PS4`: one more
/// inside each command substitution.
var trace_level: usize = 1;
/// Set while `$PS4` is being expanded, so a substitution in it is not traced
/// (which would expand `$PS4` again, forever).
var expanding_ps4 = false;
/// The status the shell is leaving with while its EXIT trap runs; a bare
/// `exit` inside the trap keeps it.
var exit_trap_status: ?u8 = null;
/// HUP, INT and TERM caught only so the EXIT trap runs before they end a
/// non-interactive shell.
var fatal_caught: u64 = 0;
/// In a subshell, the parent's traps that were dropped. `trap -p` still lists
/// them until the subshell changes a trap, so `saved=$(trap)` works.
var inherited_traps: ?[Shell.trap_count]?[]const u8 = null;

const fatal_signals = [_]linux.SIG{ .HUP, .INT, .TERM };

fn bit(sig: u32) u64 {
    return @as(u64, 1) << @intCast(sig - 1);
}

// --- set -e and ERR -----------------------------------------------------------

/// Called with the status of each simple command, subshell and multi-command
/// pipeline: where bash applies `set -e` and the ERR trap. Neither fires
/// inside a condition (`Shell.condition_depth`).
pub fn commandDone(sh: *Shell, status: u8) void {
    if (status == 0 or sh.condition_depth != 0 or sh.should_exit) return;
    if (running_traps == 0) {
        if (sh.getTrap(Shell.err_trap)) |handler| {
            if (handler.len != 0) {
                sh.last_status = status;
                runHandler(sh, handler);
            }
        }
    }
    if (sh.options.errexit and !sh.should_exit) {
        sh.should_exit = true;
        sh.exit_code = status;
    }
}

// --- traps ------------------------------------------------------------------

/// Runs a trap handler without disturbing `$?` or a pending `return`. The text
/// is copied first because the handler may replace its own trap.
fn runHandler(sh: *Shell, handler: []const u8) void {
    const runner = sh.trap_runner orelse return;
    const text = sh.gpa.dupe(u8, handler) catch return outOfMemory(sh);
    defer sh.gpa.free(text);
    const saved_status = sh.last_status;
    const saved_return = sh.return_pending;
    const saved_code = sh.return_code;
    sh.return_pending = false;
    running_traps += 1;
    _ = runner(sh, text);
    running_traps -= 1;
    sh.return_pending = saved_return;
    sh.return_code = saved_code;
    sh.last_status = saved_status;
}

/// A signal caught since the last check (see `Shell.runPendingTraps`).
pub fn signalArrived(sh: *Shell, sig: u32) void {
    const handler = sh.getTrap(sig) orelse {
        if (fatal_caught & bit(sig) != 0) terminate(sh, sig);
        return;
    };
    if (handler.len != 0) runHandler(sh, handler);
}

/// Ends the shell the way `sig` would have, after running the EXIT trap, so
/// the parent still sees death by that signal. Interactive shells call this
/// when SIGHUP arrives.
pub fn terminate(sh: *Shell, sig: u32) noreturn {
    runExitTrap(sh);
    const signal: linux.SIG = @enumFromInt(sig);
    proc.installHandler(signal, linux.SIG.DFL);
    var set = linux.sigemptyset();
    linux.sigaddset(&set, signal);
    _ = linux.sigprocmask(linux.SIG.UNBLOCK, &set, null);
    _ = linux.kill(linux.getpid(), signal);
    sys.exitProcess(128 +% @as(u8, @intCast(@min(sig, 127))));
}

/// Whether a Ctrl-C is already waiting before a foreground job starts; pass
/// it to `foregroundDone`.
pub fn interruptPending() bool {
    return shellmod.signalPending(@intFromEnum(linux.SIG.INT));
}

/// After a foreground job: as in bash, a Ctrl-C that arrived while the job
/// ran and that the job dealt with itself (it did not die of SIGINT) does not
/// end the shell.
pub fn foregroundDone(signal: ?u32, interrupted_before: bool) void {
    const int = @intFromEnum(linux.SIG.INT);
    if (fatal_caught & bit(int) == 0 or interrupted_before or signal == int) return;
    shellmod.discardPendingSignal(int);
}

/// Runs the EXIT trap, at most once. Interactive shells call this (or
/// `terminate`) when they end in a way the REPL does not see.
pub fn runExitTrap(sh: *Shell) void {
    const handler = sh.takeTrap(Shell.exit_trap) orelse return;
    defer sh.gpa.free(handler);
    syncFatalHandlers(sh);
    if (handler.len == 0) return;
    const runner = sh.trap_runner orelse return;
    exit_trap_status = sh.last_status;
    defer exit_trap_status = null;
    sh.should_exit = false;
    sh.return_pending = false;
    sh.break_pending = false;
    sh.continue_pending = false;
    running_traps += 1;
    defer running_traps -= 1;
    _ = runner(sh, handler);
}

/// The shell's last act: runs pending signal traps and the EXIT trap and
/// returns the status to exit with. `exit N` wins over the last command's
/// status, and an `exit` inside the trap wins over both.
pub fn finish(sh: *Shell, status: u8) u8 {
    sh.runPendingTraps();
    const code = if (sh.should_exit) sh.exit_code else status;
    sh.last_status = code;
    runExitTrap(sh);
    return if (sh.should_exit) sh.exit_code else code;
}

/// The status a bare `exit` uses inside the EXIT trap.
pub fn exitTrapStatus() ?u8 {
    return exit_trap_status;
}

/// The handler `trap -p` lists for `id`: the shell's own, or in a subshell
/// that has not changed any trap, the parent's.
pub fn listedTrap(sh: *const Shell, id: u32) ?[]const u8 {
    if (sh.getTrap(id)) |handler| return handler;
    const inherited = inherited_traps orelse return null;
    return if (id < inherited.len) inherited[id] else null;
}

/// Call after `trap` changes anything.
pub fn trapsChanged(sh: *Shell) void {
    if (inherited_traps) |inherited| {
        for (inherited) |maybe| {
            if (maybe) |text| sh.gpa.free(text);
        }
        inherited_traps = null;
    }
    syncFatalHandlers(sh);
}

/// Keeps HUP, INT and TERM caught while a non-interactive shell has an EXIT
/// trap, so the trap still runs when one of them ends the shell. Signals the
/// shell started out ignoring are left alone.
fn syncFatalHandlers(sh: *Shell) void {
    const exit_handler = sh.getTrap(Shell.exit_trap) orelse "";
    const wanted = !sh.interactive and exit_handler.len != 0;
    for (fatal_signals) |signal| {
        const sig = @intFromEnum(signal);
        const caught = fatal_caught & bit(sig) != 0;
        if (sh.getTrap(sig) != null) {
            // The signal's own trap decides its disposition.
            fatal_caught &= ~bit(sig);
        } else if (wanted and !caught and proc.startedDefault(signal)) {
            proc.installHandler(signal, shellmod.trapHandler);
            fatal_caught |= bit(sig);
        } else if (!wanted and caught) {
            proc.restoreHandler(signal);
            fatal_caught &= ~bit(sig);
        }
    }
}

// --- forked children -----------------------------------------------------------

/// A forked child that runs shell code (a subshell, a pipeline stage or a
/// background group). Caught signals go back to their defaults while ignored
/// ones stay ignored, and the parent's EXIT, DEBUG and RETURN traps (and ERR,
/// unless `set -E`) are dropped. Traps the child sets itself still run.
pub fn enterSubshell(sh: *Shell) void {
    var sig: u32 = 1;
    while (sig <= Shell.max_signal) : (sig += 1) {
        // A signal the parent has yet to handle is the parent's business.
        shellmod.discardPendingSignal(sig);
        const handler = sh.getTrap(sig) orelse {
            if (fatal_caught & bit(sig) != 0) proc.installHandler(@enumFromInt(sig), linux.SIG.DFL);
            continue;
        };
        if (handler.len == 0) continue;
        dropTrap(sh, sig);
        proc.installHandler(@enumFromInt(sig), linux.SIG.DFL);
    }
    fatal_caught = 0;
    dropTrap(sh, Shell.exit_trap);
    dropTrap(sh, Shell.debug_trap);
    dropTrap(sh, Shell.return_trap);
    if (!sh.options.errtrace) dropTrap(sh, Shell.err_trap);
    sh.exit_warned = false;
}

/// Removes a trap in a subshell, keeping it for `trap -p`.
fn dropTrap(sh: *Shell, id: u32) void {
    const handler = sh.takeTrap(id) orelse return;
    if (inherited_traps == null) inherited_traps = [_]?[]const u8{null} ** Shell.trap_count;
    if (inherited_traps.?[id]) |old| sh.gpa.free(old);
    inherited_traps.?[id] = handler;
}

/// A command substitution child: a subshell that also drops `set -e`, as bash
/// does by default, and traces one level deeper.
pub fn enterSubstitution(sh: *Shell) void {
    enterSubshell(sh);
    sh.options.errexit = false;
    trace_level += 1;
}

/// Ends a forked child, running an EXIT trap the child set itself.
pub fn exitChild(sh: *Shell, status: u8) noreturn {
    linux.exit(finish(sh, status));
}

// --- functions and source -----------------------------------------------------

pub const FunctionTraps = struct {
    debug: ?[]const u8,
    err: ?[]const u8,
    ret: ?[]const u8,
};

/// Function bodies do not see the caller's DEBUG and RETURN traps, nor its
/// ERR trap unless `set -E` is on.
pub fn enterFunction(sh: *Shell) FunctionTraps {
    return .{
        .debug = sh.takeTrap(Shell.debug_trap),
        .err = if (sh.options.errtrace) null else sh.takeTrap(Shell.err_trap),
        .ret = sh.takeTrap(Shell.return_trap),
    };
}

/// Runs a RETURN trap the body set, then gives the caller its traps back. A
/// trap the body set where the caller had none stays set, as in bash.
pub fn leaveFunction(sh: *Shell, saved: FunctionTraps) void {
    runReturnTrap(sh);
    if (saved.debug) |text| sh.putTrap(Shell.debug_trap, text);
    if (saved.err) |text| sh.putTrap(Shell.err_trap, text);
    if (saved.ret) |text| sh.putTrap(Shell.return_trap, text);
}

/// The RETURN trap: after a function body or a sourced file.
pub fn runReturnTrap(sh: *Shell) void {
    if (running_traps != 0) return;
    const handler = sh.getTrap(Shell.return_trap) orelse return;
    if (handler.len != 0) runHandler(sh, handler);
}

/// The DEBUG trap: before each simple command.
pub fn beforeCommand(sh: *Shell) void {
    if (running_traps != 0) return;
    const handler = sh.getTrap(Shell.debug_trap) orelse return;
    if (handler.len != 0) runHandler(sh, handler);
}

// --- set -x -----------------------------------------------------------------

/// `set -x`: writes `$PS4` and the expanded words, quoted so they read back
/// the same, to standard error.
pub fn traceCommand(sh: *Shell, words: []const []const u8) void {
    if (!sh.options.xtrace or expanding_ps4 or words.len == 0) return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(sh.gpa);
    appendPrefix(sh, &line) catch return outOfMemory(sh);
    for (words, 0..) |word, index| {
        if (index != 0) line.append(sh.gpa, ' ') catch return outOfMemory(sh);
        quote.appendWord(&line, sh.gpa, word) catch return outOfMemory(sh);
    }
    line.append(sh.gpa, '\n') catch return outOfMemory(sh);
    sys.writeStr(sh.default_err, line.items);
}

/// `eval` and `source` trace their commands one level deeper, as in bash.
pub fn traceDeeper() void {
    trace_level += 1;
}

pub fn traceShallower() void {
    trace_level -= 1;
}

/// `set -x` for one `NAME=value` assignment.
pub fn traceAssignment(sh: *Shell, name: []const u8, text: []const u8) void {
    if (!sh.options.xtrace or expanding_ps4) return;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(sh.gpa);
    appendPrefix(sh, &line) catch return outOfMemory(sh);
    line.appendSlice(sh.gpa, name) catch return outOfMemory(sh);
    line.append(sh.gpa, '=') catch return outOfMemory(sh);
    if (text.len != 0) quote.appendWord(&line, sh.gpa, text) catch return outOfMemory(sh);
    line.append(sh.gpa, '\n') catch return outOfMemory(sh);
    sys.writeStr(sh.default_err, line.items);
}

/// `$PS4` (default `+ `), expanded, with its first character repeated once
/// per enclosing command substitution.
fn appendPrefix(sh: *Shell, line: *std.ArrayList(u8)) !void {
    const arena = sh.scratch();
    const raw: []const u8 = if (sh.getVar("PS4")) |v|
        try v.renderAlloc(arena)
    else
        sh.getEnv("PS4") orelse "+ ";
    var text = raw;
    if (std.mem.indexOfAny(u8, raw, "$`") != null) {
        expanding_ps4 = true;
        defer expanding_ps4 = false;
        text = expand_mod.expandHereDoc(sh, arena, raw) catch raw;
    }
    if (text.len == 0) return;
    try line.appendNTimes(sh.gpa, text[0], trace_level - 1);
    try line.appendSlice(sh.gpa, text);
}

// --- PIPESTATUS ---------------------------------------------------------------

/// Records the status of each command in the last foreground pipeline in the
/// list variable PIPESTATUS.
pub fn setPipeStatus(sh: *Shell, statuses: []const u8) void {
    if (sh.getVar("PIPESTATUS")) |current| {
        if (sameStatuses(current, statuses)) return;
    }
    const items = sh.scratch().alloc(value.Value, statuses.len) catch return outOfMemory(sh);
    for (statuses, items) |status, *item| item.* = .{ .int = status };
    sh.setVar("PIPESTATUS", .{ .list = items }) catch outOfMemory(sh);
}

fn sameStatuses(current: value.Value, statuses: []const u8) bool {
    const items = switch (current) {
        .list => |list| list,
        else => return false,
    };
    if (items.len != statuses.len) return false;
    for (items, statuses) |item, status| {
        switch (item) {
            .int => |n| if (n != status) return false,
            else => return false,
        }
    }
    return true;
}

// --- exit -------------------------------------------------------------------

/// `exit` or Ctrl-D in an interactive shell with stopped jobs: warn and stay.
/// An immediately repeated request leaves anyway.
pub fn confirmExit(sh: *Shell) bool {
    if (!sh.interactive or !sh.job_control or sh.exit_warned) return true;
    sh.reapJobs();
    for (sh.jobs.jobs.items) |job| {
        if (job.state != .stopped) continue;
        sys.writeStr(sh.default_err, "There are stopped jobs.\n");
        sh.exit_warned = true;
        return false;
    }
    return true;
}

fn outOfMemory(sh: *Shell) void {
    sys.writeStr(sh.default_err, "wsh: out of memory\n");
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

test "PIPESTATUS records each stage and skips identical updates" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    setPipeStatus(&sh, &.{ 1, 0 });
    const first = sh.getVar("PIPESTATUS").?.list;
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expectEqual(@as(i64, 1), first[0].int);
    setPipeStatus(&sh, &.{ 1, 0 });
    try testing.expectEqual(first.ptr, sh.getVar("PIPESTATUS").?.list.ptr);
    setPipeStatus(&sh, &.{3});
    try testing.expectEqual(@as(i64, 3), sh.getVar("PIPESTATUS").?.list[0].int);
}

test "errexit stops the shell outside conditions only" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    sh.options.errexit = true;

    sh.condition_depth = 1;
    commandDone(&sh, 1);
    try testing.expect(!sh.should_exit);
    sh.condition_depth = 0;
    commandDone(&sh, 0);
    try testing.expect(!sh.should_exit);
    commandDone(&sh, 3);
    try testing.expect(sh.should_exit);
    try testing.expectEqual(@as(u8, 3), sh.exit_code);
}

test "function calls hide the caller's DEBUG, ERR and RETURN traps" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try sh.setTrap(Shell.debug_trap, "d");
    try sh.setTrap(Shell.err_trap, "e");
    const saved = enterFunction(&sh);
    try testing.expect(sh.getTrap(Shell.debug_trap) == null);
    try testing.expect(sh.getTrap(Shell.err_trap) == null);
    try sh.setTrap(Shell.return_trap, "r");
    leaveFunction(&sh, saved);
    try testing.expectEqualStrings("d", sh.getTrap(Shell.debug_trap).?);
    try testing.expectEqualStrings("e", sh.getTrap(Shell.err_trap).?);
    try testing.expectEqualStrings("r", sh.getTrap(Shell.return_trap).?);

    sh.options.errtrace = true;
    const traced = enterFunction(&sh);
    try testing.expectEqualStrings("e", sh.getTrap(Shell.err_trap).?);
    leaveFunction(&sh, traced);
}
