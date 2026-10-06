//! `trap`: signal handlers plus the EXIT, ERR, DEBUG and RETURN
//! pseudo-signals, with bash's listing formats.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const proc = @import("../proc.zig");
const quote = @import("../quote.zig");
const strict = @import("../strict.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;

const usage = "wsh: trap: usage: trap [-lp] [[action] signal_spec ...]\n";

/// Signal names without the `SIG` prefix, by number; empty where Linux has
/// none (32 and 33 belong to the C library).
const signal_names = blk: {
    var names: [Shell.max_signal + 1][]const u8 = undefined;
    const fixed = [_][]const u8{
        "",     "HUP",  "INT",  "QUIT", "ILL",    "TRAP",   "ABRT",  "BUS",  "FPE",  "KILL", "USR1",
        "SEGV", "USR2", "PIPE", "ALRM", "TERM",   "STKFLT", "CHLD",  "CONT", "STOP", "TSTP", "TTIN",
        "TTOU", "URG",  "XCPU", "XFSZ", "VTALRM", "PROF",   "WINCH", "IO",   "PWR",  "SYS",  "",
        "",
    };
    for (fixed, 0..) |name, index| names[index] = name;
    names[34] = "RTMIN";
    for (35..50) |index| names[index] = std.fmt.comptimePrint("RTMIN+{d}", .{index - 34});
    for (50..64) |index| names[index] = std.fmt.comptimePrint("RTMAX-{d}", .{64 - index});
    names[64] = "RTMAX";
    break :blk names;
};

const pseudo = [_]struct { []const u8, u32 }{
    .{ "EXIT", Shell.exit_trap },
    .{ "DEBUG", Shell.debug_trap },
    .{ "ERR", Shell.err_trap },
    .{ "RETURN", Shell.return_trap },
};

/// Resolves `INT`, `SIGINT`, `int`, `2`, `EXIT`, `0`, `ERR`, `DEBUG` or
/// `RETURN` to a trap id.
pub fn parseSpec(text: []const u8) ?u32 {
    if (text.len != 0 and std.ascii.isDigit(text[0])) {
        const n = std.fmt.parseInt(u32, text, 10) catch return null;
        if (n == 0) return Shell.exit_trap;
        if (n > Shell.max_signal or signal_names[n].len == 0) return null;
        return n;
    }
    for (pseudo) |entry| {
        if (std.ascii.eqlIgnoreCase(text, entry[0])) return entry[1];
    }
    const name = if (text.len > 3 and std.ascii.eqlIgnoreCase(text[0..3], "SIG")) text[3..] else text;
    for (signal_names, 0..) |candidate, number| {
        if (candidate.len != 0 and std.ascii.eqlIgnoreCase(name, candidate)) return @intCast(number);
    }
    return null;
}

/// The name `trap -p` prints: `SIGINT`, or `EXIT`/`ERR`/`DEBUG`/`RETURN`.
fn specName(buf: []u8, id: u32) []const u8 {
    for (pseudo) |entry| {
        if (entry[1] == id) return entry[0];
    }
    return std.fmt.bufPrint(buf, "SIG{s}", .{signal_names[id]}) catch "SIG";
}

pub fn run(ctx: Ctx) u8 {
    var args = ctx.argv[1..];
    var list = false;
    var print = false;
    while (args.len != 0 and args[0].len > 1 and args[0][0] == '-') {
        const option = args[0];
        args = args[1..];
        if (std.mem.eql(u8, option, "--")) break;
        for (option[1..]) |letter| {
            switch (letter) {
                'l' => list = true,
                'p' => print = true,
                else => {
                    ctx.errFmt("wsh: trap: -{c}: invalid option\n", .{letter});
                    ctx.err(usage);
                    return 2;
                },
            }
        }
    }

    if (list) {
        listSignals(ctx);
        return 0;
    }
    if (print or args.len == 0) return printTraps(ctx, args);

    // A single operand that names a signal resets it, as does an action of
    // `-`. POSIX: a leading unsigned integer means every operand is a signal.
    const resetting = args.len == 1 or std.mem.eql(u8, args[0], "-") or isUnsigned(args[0]);
    if (resetting) {
        const specs = if (std.mem.eql(u8, args[0], "-")) args[1..] else args;
        if (args.len == 1 and parseSpec(args[0]) == null) {
            ctx.err(usage);
            return 2;
        }
        return update(ctx, null, specs);
    }
    return update(ctx, args[0], args[1..]);
}

fn isUnsigned(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// Sets (`action` non-null) or resets each spec; an empty action ignores.
fn update(ctx: Ctx, action: ?[]const u8, specs: []const []const u8) u8 {
    var status: u8 = 0;
    for (specs) |spec| {
        const id = parseSpec(spec) orelse {
            ctx.errFmt("wsh: trap: {s}: invalid signal specification\n", .{spec});
            status = 1;
            continue;
        };
        if (id >= 1 and id <= Shell.max_signal and proc.isUncatchable(@enumFromInt(id))) {
            ctx.errFmt("wsh: trap: {s}: cannot be caught\n", .{spec});
            status = 1;
            continue;
        }
        if (action) |handler| {
            ctx.sh.setTrap(id, handler) catch {
                ctx.err("wsh: trap: out of memory\n");
                return 1;
            };
        } else {
            _ = ctx.sh.clearTrap(id);
        }
        if (id >= 1 and id <= Shell.max_signal) {
            const sig: linux.SIG = @enumFromInt(id);
            if (action) |handler| {
                proc.installHandler(sig, if (handler.len == 0) linux.SIG.IGN else shellmod.trapHandler);
            } else {
                proc.restoreHandler(sig);
            }
        }
    }
    strict.trapsChanged(ctx.sh);
    return status;
}

/// `trap -p [SPEC...]` and bare `trap`: commands that recreate the traps.
fn printTraps(ctx: Ctx, specs: []const []const u8) u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.sh.gpa);
    var status: u8 = 0;
    if (specs.len == 0) {
        var id: u32 = 0;
        while (id < Shell.trap_count) : (id += 1) {
            appendTrap(ctx, &out, id) catch return outOfMemory(ctx);
        }
    } else {
        for (specs) |spec| {
            const id = parseSpec(spec) orelse {
                ctx.errFmt("wsh: trap: {s}: invalid signal specification\n", .{spec});
                status = 1;
                continue;
            };
            appendTrap(ctx, &out, id) catch return outOfMemory(ctx);
        }
    }
    ctx.out(out.items);
    return status;
}

fn appendTrap(ctx: Ctx, out: *std.ArrayList(u8), id: u32) !void {
    const handler = strict.listedTrap(ctx.sh, id) orelse return;
    const gpa = ctx.sh.gpa;
    try out.appendSlice(gpa, "trap -- ");
    try quote.appendSingle(out, gpa, handler);
    var buf: [32]u8 = undefined;
    try out.append(gpa, ' ');
    try out.appendSlice(gpa, specName(&buf, id));
    try out.append(gpa, '\n');
}

/// `trap -l`: bash's five-column table.
fn listSignals(ctx: Ctx) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.sh.gpa);
    var column: usize = 0;
    for (signal_names, 0..) |name, number| {
        if (name.len == 0) continue;
        var buf: [32]u8 = undefined;
        const entry = std.fmt.bufPrint(&buf, "{d:>2}) SIG{s}", .{ number, name }) catch continue;
        out.appendSlice(ctx.sh.gpa, entry) catch return;
        column += 1;
        const separator: u8 = if (column == 5) '\n' else '\t';
        if (column == 5) column = 0;
        out.append(ctx.sh.gpa, separator) catch return;
    }
    if (column != 0) out.append(ctx.sh.gpa, '\n') catch return;
    ctx.out(out.items);
}

fn outOfMemory(ctx: Ctx) u8 {
    ctx.err("wsh: trap: out of memory\n");
    return 1;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

const Capture = struct {
    read_fd: i32,
    write_fd: i32,

    fn open() !Capture {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn finish(self: Capture) ![]u8 {
        _ = linux.close(self.write_fd);
        defer _ = linux.close(self.read_fd);
        var buf: [8192]u8 = undefined;
        var total: usize = 0;
        while (total < buf.len) {
            const rc = linux.read(self.read_fd, buf[total..].ptr, buf.len - total);
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            total += rc;
        }
        return testing.allocator.dupe(u8, buf[0..total]);
    }
};

fn runTrap(sh: *Shell, argv: []const []const u8) u8 {
    return run(Ctx{ .sh = sh, .argv = argv, .stdout = -1, .stderr = -1 });
}

test "signal specs cover names, numbers and pseudo-signals" {
    try testing.expectEqual(@as(?u32, 2), parseSpec("INT"));
    try testing.expectEqual(@as(?u32, 2), parseSpec("sigint"));
    try testing.expectEqual(@as(?u32, 15), parseSpec("15"));
    try testing.expectEqual(@as(?u32, Shell.exit_trap), parseSpec("EXIT"));
    try testing.expectEqual(@as(?u32, Shell.exit_trap), parseSpec("0"));
    try testing.expectEqual(@as(?u32, Shell.err_trap), parseSpec("err"));
    try testing.expectEqual(@as(?u32, 37), parseSpec("SIGRTMIN+3"));
    try testing.expectEqual(@as(?u32, 64), parseSpec("RTMAX"));
    try testing.expectEqual(@as(?u32, null), parseSpec("NOPE"));
    try testing.expectEqual(@as(?u32, null), parseSpec("32"));
    try testing.expectEqual(@as(?u32, null), parseSpec("SIGEXIT"));
}

test "trap stores, prints and resets handlers" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "echo it's", "EXIT", "INT" }));
    try testing.expectEqualStrings("echo it's", sh.getTrap(Shell.exit_trap).?);
    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "", "TERM" }));

    const cap = try Capture.open();
    try testing.expectEqual(@as(u8, 0), run(Ctx{ .sh = &sh, .argv = &.{ "trap", "-p" }, .stdout = cap.write_fd, .stderr = -1 }));
    const out = try cap.finish();
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "trap -- 'echo it'\\''s' EXIT\ntrap -- 'echo it'\\''s' SIGINT\ntrap -- '' SIGTERM\n",
        out,
    );

    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "-", "EXIT", "INT" }));
    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "TERM" }));
    try testing.expect(sh.getTrap(Shell.exit_trap) == null);
    try testing.expect(sh.getTrap(2) == null);
    try testing.expect(sh.getTrap(15) == null);

    try testing.expectEqual(@as(u8, 1), runTrap(&sh, &.{ "trap", "x", "KILL" }));
    try testing.expectEqual(@as(u8, 1), runTrap(&sh, &.{ "trap", "x", "NOPE" }));
    try testing.expectEqual(@as(u8, 2), runTrap(&sh, &.{ "trap", "echo" }));
    try testing.expectEqual(@as(u8, 2), runTrap(&sh, &.{ "trap", "-x" }));
}

var trap_hits: usize = 0;

fn countingRunner(_: *Shell, _: []const u8) u8 {
    trap_hits += 1;
    return 0;
}

test "a trapped signal is installed and its handler runs" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    trap_hits = 0;
    sh.trap_runner = countingRunner;

    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "note", "USR1" }));
    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
    sh.runPendingTraps();
    try testing.expectEqual(@as(usize, 1), trap_hits);

    // An empty handler ignores the signal instead of running code.
    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "", "USR1" }));
    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
    sh.runPendingTraps();
    try testing.expectEqual(@as(usize, 1), trap_hits);

    try testing.expectEqual(@as(u8, 0), runTrap(&sh, &.{ "trap", "-", "USR1" }));
    try testing.expect(sh.getTrap(10) == null);
}

test "trap -l prints bash's table" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    const cap = try Capture.open();
    try testing.expectEqual(@as(u8, 0), run(Ctx{ .sh = &sh, .argv = &.{ "trap", "-l" }, .stdout = cap.write_fd }));
    const out = try cap.finish();
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, " 1) SIGHUP\t 2) SIGINT\t 3) SIGQUIT\t 4) SIGILL\t 5) SIGTRAP\n"));
    try testing.expect(std.mem.indexOf(u8, out, "31) SIGSYS\t34) SIGRTMIN\t") != null);
    try testing.expect(std.mem.endsWith(u8, out, "63) SIGRTMAX-1\t64) SIGRTMAX\t\n"));
}
