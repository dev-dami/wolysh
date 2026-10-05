//! Process attributes: `ulimit`, `umask`, `times` and `logout`.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const sys = @import("../sys.zig");

const Ctx = builtins.Ctx;

// --- ulimit ------------------------------------------------------------------

const Limit = struct {
    option: u8,
    description: []const u8,
    units: ?[]const u8,
    /// `null` for the pipe size, which is reported but cannot be changed.
    resource: ?linux.rlimit_resource,
    /// Values are shown and given in units of this many bytes (or 1).
    factor: u64,
};

/// The order `ulimit -a` prints in, matching bash on Linux.
const limits = [_]Limit{
    .{ .option = 'R', .description = "real-time non-blocking time", .units = "microseconds", .resource = .RTTIME, .factor = 1 },
    .{ .option = 'c', .description = "core file size", .units = "blocks", .resource = .CORE, .factor = 512 },
    .{ .option = 'd', .description = "data seg size", .units = "kbytes", .resource = .DATA, .factor = 1024 },
    .{ .option = 'e', .description = "scheduling priority", .units = null, .resource = .NICE, .factor = 1 },
    .{ .option = 'f', .description = "file size", .units = "blocks", .resource = .FSIZE, .factor = 512 },
    .{ .option = 'i', .description = "pending signals", .units = null, .resource = .SIGPENDING, .factor = 1 },
    .{ .option = 'l', .description = "max locked memory", .units = "kbytes", .resource = .MEMLOCK, .factor = 1024 },
    .{ .option = 'm', .description = "max memory size", .units = "kbytes", .resource = .RSS, .factor = 1024 },
    .{ .option = 'n', .description = "open files", .units = null, .resource = .NOFILE, .factor = 1 },
    .{ .option = 'p', .description = "pipe size", .units = "512 bytes", .resource = null, .factor = 512 },
    .{ .option = 'q', .description = "POSIX message queues", .units = "bytes", .resource = .MSGQUEUE, .factor = 1 },
    .{ .option = 'r', .description = "real-time priority", .units = null, .resource = .RTPRIO, .factor = 1 },
    .{ .option = 's', .description = "stack size", .units = "kbytes", .resource = .STACK, .factor = 1024 },
    .{ .option = 't', .description = "cpu time", .units = "seconds", .resource = .CPU, .factor = 1 },
    .{ .option = 'u', .description = "max user processes", .units = null, .resource = .NPROC, .factor = 1 },
    .{ .option = 'v', .description = "virtual memory", .units = "kbytes", .resource = .AS, .factor = 1024 },
    .{ .option = 'x', .description = "file locks", .units = null, .resource = .LOCKS, .factor = 1 },
};

const ulimit_usage = "wsh: ulimit: usage: ulimit [-SHaRcdefilmnpqrstuvx] [limit]\n";

/// `PIPE_BUF` in 512-byte blocks, as bash reports it.
const pipe_blocks: u64 = 4096 / 512;

fn findLimit(option: u8) ?*const Limit {
    for (&limits) |*limit| {
        if (limit.option == option) return limit;
    }
    return null;
}

fn getLimit(limit: *const Limit) ?linux.rlimit {
    const resource = limit.resource orelse return .{ .cur = pipe_blocks * 512, .max = pipe_blocks * 512 };
    var current: linux.rlimit = undefined;
    if (linux.errno(linux.prlimit(0, resource, null, &current)) != .SUCCESS) return null;
    return current;
}

fn errorText(e: linux.E) []const u8 {
    return switch (e) {
        .PERM => "Operation not permitted",
        .INVAL => "Invalid argument",
        .FAULT => "Bad address",
        else => @tagName(e),
    };
}

fn showLimit(ctx: Ctx, limit: *const Limit, hard: bool, describe: bool) bool {
    if (describe) {
        var unit_buf: [48]u8 = undefined;
        const unit = if (limit.units) |units|
            std.fmt.bufPrint(&unit_buf, "({s}, -{c}) ", .{ units, limit.option }) catch unreachable
        else
            std.fmt.bufPrint(&unit_buf, "(-{c}) ", .{limit.option}) catch unreachable;
        ctx.outFmt("{s: <20} {s: >20}", .{ limit.description, unit });
    }
    const current = getLimit(limit) orelse {
        ctx.errFmt("wsh: ulimit: {s}: cannot get limit\n", .{limit.description});
        return false;
    };
    const val = if (hard) current.max else current.cur;
    if (val == linux.RLIM.INFINITY) {
        ctx.out("unlimited\n");
    } else {
        ctx.outFmt("{d}\n", .{val / limit.factor});
    }
    return true;
}

fn setLimit(ctx: Ctx, limit: *const Limit, text: []const u8, hard: bool, soft: bool) bool {
    const resource = limit.resource orelse {
        ctx.errFmt("wsh: ulimit: {s}: cannot modify limit: Invalid argument\n", .{limit.description});
        return false;
    };
    var current = getLimit(limit) orelse {
        ctx.errFmt("wsh: ulimit: {s}: cannot get limit\n", .{limit.description});
        return false;
    };
    const wanted: u64 = if (std.mem.eql(u8, text, "unlimited"))
        linux.RLIM.INFINITY
    else if (std.mem.eql(u8, text, "hard"))
        current.max
    else if (std.mem.eql(u8, text, "soft"))
        current.cur
    else blk: {
        const n = std.fmt.parseInt(u64, text, 10) catch {
            ctx.errFmt("wsh: ulimit: {s}: invalid number\n", .{text});
            return false;
        };
        break :blk std.math.mul(u64, n, limit.factor) catch {
            ctx.errFmt("wsh: ulimit: {s}: limit out of range\n", .{text});
            return false;
        };
    };
    // Without -H or -S both limits change.
    if (hard or !soft) current.max = wanted;
    if (soft or !hard) current.cur = wanted;
    const rc = linux.prlimit(0, resource, &current, null);
    if (linux.errno(rc) != .SUCCESS) {
        ctx.errFmt("wsh: ulimit: {s}: cannot modify limit: {s}\n", .{ limit.description, errorText(linux.errno(rc)) });
        return false;
    }
    return true;
}

pub fn ulimit(ctx: Ctx) u8 {
    var hard = false;
    var soft = false;
    var all = false;
    var selected: std.ArrayList(*const Limit) = .empty;
    defer selected.deinit(ctx.sh.gpa);

    var parser = options.Parser.init(ctx.argv, "HSaRcdefilmnpqrstuvx");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: ulimit: -{c}: invalid option\n", .{c});
                ctx.err(ulimit_usage);
                return 2;
            },
            .option => |c| switch (c) {
                'H' => hard = true,
                'S' => soft = true,
                'a' => all = true,
                else => selected.append(ctx.sh.gpa, findLimit(c).?) catch return 1,
            },
        }
    }
    const operands = parser.rest();
    if (operands.len > 1) {
        ctx.errFmt("wsh: ulimit: {s}: too many arguments\n", .{operands[1]});
        return 2;
    }

    if (all) {
        var status: u8 = 0;
        for (&limits) |*limit| {
            if (!showLimit(ctx, limit, hard and !soft, true)) status = 1;
        }
        return status;
    }
    if (selected.items.len == 0) selected.append(ctx.sh.gpa, findLimit('f').?) catch return 1;

    if (operands.len == 1) {
        // The new value applies to the last resource named, like bash.
        const target = selected.items[selected.items.len - 1];
        if (!setLimit(ctx, target, operands[0], hard, soft)) return 1;
        _ = selected.pop();
    }
    var status: u8 = 0;
    const describe = selected.items.len > 1;
    for (selected.items) |limit| {
        if (!showLimit(ctx, limit, hard and !soft, describe)) status = 1;
    }
    return status;
}

// --- times -------------------------------------------------------------------

fn writeTime(ctx: Ctx, tv: linux.timeval, separator: []const u8) void {
    const seconds: u64 = @intCast(@max(tv.sec, 0));
    const millis: u64 = @intCast(@divTrunc(@max(tv.usec, 0), 1000));
    ctx.outFmt("{d}m{d}.{d:0>3}s{s}", .{ seconds / 60, seconds % 60, millis, separator });
}

pub fn times(ctx: Ctx) u8 {
    var self_usage: linux.rusage = undefined;
    var child_usage: linux.rusage = undefined;
    if (linux.errno(linux.getrusage(linux.rusage.SELF, &self_usage)) != .SUCCESS or
        linux.errno(linux.getrusage(linux.rusage.CHILDREN, &child_usage)) != .SUCCESS)
    {
        ctx.err("wsh: times: cannot read resource usage\n");
        return 1;
    }
    writeTime(ctx, self_usage.utime, " ");
    writeTime(ctx, self_usage.stime, "\n");
    writeTime(ctx, child_usage.utime, " ");
    writeTime(ctx, child_usage.stime, "\n");
    return 0;
}

// --- umask -------------------------------------------------------------------

fn currentMask() u32 {
    // There is no way to read the mask without setting it, so restore it.
    const mask = sys.umask(0);
    _ = sys.umask(mask);
    return mask;
}

fn writeSymbolic(ctx: Ctx, mask: u32) void {
    const allowed = ~mask & 0o777;
    const classes = [_]struct { u8, u5 }{ .{ 'u', 6 }, .{ 'g', 3 }, .{ 'o', 0 } };
    for (classes, 0..) |class, i| {
        if (i != 0) ctx.out(",");
        const bits = (allowed >> class[1]) & 0o7;
        var buf: [5]u8 = undefined;
        var len: usize = 0;
        buf[len] = class[0];
        buf[len + 1] = '=';
        len += 2;
        if (bits & 4 != 0) {
            buf[len] = 'r';
            len += 1;
        }
        if (bits & 2 != 0) {
            buf[len] = 'w';
            len += 1;
        }
        if (bits & 1 != 0) {
            buf[len] = 'x';
            len += 1;
        }
        ctx.out(buf[0..len]);
    }
    ctx.out("\n");
}

/// Applies a chmod-style symbolic mode (`u=rwx,g+w,o-x`) to the permissions
/// the mask allows and returns the new mask, or null after reporting.
fn symbolicMask(ctx: Ctx, mode: []const u8, mask: u32) ?u32 {
    var allowed = ~mask & 0o777;
    var i: usize = 0;
    while (true) {
        var who: u32 = 0;
        while (i < mode.len) : (i += 1) {
            switch (mode[i]) {
                'u' => who |= 0o700,
                'g' => who |= 0o070,
                'o' => who |= 0o007,
                'a' => who |= 0o777,
                else => break,
            }
        }
        if (who == 0) who = 0o777;
        if (i >= mode.len or std.mem.indexOfScalar(u8, "+-=", mode[i]) == null) {
            const c: u8 = if (i < mode.len) mode[i] else 0;
            ctx.errFmt("wsh: umask: `{c}': invalid symbolic mode operator\n", .{c});
            return null;
        }
        const op = mode[i];
        i += 1;
        var perm: u32 = 0;
        while (i < mode.len and mode[i] != ',') : (i += 1) {
            perm |= switch (mode[i]) {
                'r' => 0o444,
                'w' => 0o222,
                'x' => 0o111,
                else => {
                    ctx.errFmt("wsh: umask: `{c}': invalid symbolic mode character\n", .{mode[i]});
                    return null;
                },
            };
        }
        perm &= who;
        switch (op) {
            '+' => allowed |= perm,
            '-' => allowed &= ~perm,
            else => allowed = (allowed & ~who) | perm,
        }
        if (i >= mode.len) break;
        i += 1;
    }
    return ~allowed & 0o777;
}

pub fn umask(ctx: Ctx) u8 {
    var symbolic = false;
    var reusable = false;
    var parser = options.Parser.init(ctx.argv, "Sp");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: umask: -{c}: invalid option\n", .{c});
                ctx.err("wsh: umask: usage: umask [-p] [-S] [mode]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'S' => symbolic = true,
                'p' => reusable = true,
                else => unreachable,
            },
        }
    }
    const operands = parser.rest();
    if (operands.len > 1) {
        ctx.err("wsh: umask: too many arguments\n");
        return 2;
    }

    if (operands.len == 1) {
        const mode = operands[0];
        const mask = if (mode.len != 0 and std.ascii.isDigit(mode[0])) blk: {
            const n = std.fmt.parseInt(u32, mode, 8) catch {
                ctx.errFmt("wsh: umask: {s}: octal number out of range\n", .{mode});
                return 1;
            };
            if (n > 0o7777) {
                ctx.errFmt("wsh: umask: {s}: octal number out of range\n", .{mode});
                return 1;
            }
            break :blk n & 0o777;
        } else symbolicMask(ctx, mode, currentMask()) orelse return 1;
        _ = sys.umask(mask);
        if (!symbolic) return 0;
    }

    const mask = currentMask();
    if (reusable) ctx.out(if (symbolic) "umask -S " else "umask ");
    if (symbolic) {
        writeSymbolic(ctx, mask);
    } else {
        ctx.outFmt("{o:0>4}\n", .{mask});
    }
    return 0;
}

// --- logout ------------------------------------------------------------------

pub fn logout(ctx: Ctx) u8 {
    if (!ctx.sh.login) {
        ctx.err("wsh: logout: not login shell: use `exit'\n");
        return 1;
    }
    return builtins.lookup("exit").?.run(ctx);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const shellmod = @import("../shell.zig");

fn capture(sh: *shellmod.Shell, run: *const fn (Ctx) u8, argv: []const []const u8, status: *u8) ![]u8 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    status.* = run(.{ .sh = sh, .argv = argv, .stdout = fds[1], .stderr = -1 });
    _ = linux.close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        try out.appendSlice(testing.allocator, buf[0..rc]);
    }
    _ = linux.close(fds[0]);
    return out.toOwnedSlice(testing.allocator);
}

test "umask prints octal, symbolic and reusable forms and parses symbolic modes" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    const original = currentMask();
    defer _ = sys.umask(original);
    var status: u8 = undefined;

    _ = sys.umask(0o022);
    const octal = try capture(&sh, umask, &.{"umask"}, &status);
    defer testing.allocator.free(octal);
    try testing.expectEqualStrings("0022\n", octal);
    const sym = try capture(&sh, umask, &.{ "umask", "-S" }, &status);
    defer testing.allocator.free(sym);
    try testing.expectEqualStrings("u=rwx,g=rx,o=rx\n", sym);
    const reusable = try capture(&sh, umask, &.{ "umask", "-p" }, &status);
    defer testing.allocator.free(reusable);
    try testing.expectEqualStrings("umask 0022\n", reusable);

    try testing.expectEqual(@as(u8, 0), umask(.{ .sh = &sh, .argv = &.{ "umask", "u=rwx,g=rx,o=" } }));
    try testing.expectEqual(@as(u32, 0o027), currentMask());
    try testing.expectEqual(@as(u8, 0), umask(.{ .sh = &sh, .argv = &.{ "umask", "g+w" } }));
    try testing.expectEqual(@as(u32, 0o007), currentMask());
    try testing.expectEqual(@as(u8, 0), umask(.{ .sh = &sh, .argv = &.{ "umask", "o-x,a+r" } }));
    try testing.expectEqual(@as(u32, 0o003), currentMask());
    try testing.expectEqual(@as(u8, 1), umask(.{ .sh = &sh, .argv = &.{ "umask", "999" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), umask(.{ .sh = &sh, .argv = &.{ "umask", "u=rwz" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), umask(.{ .sh = &sh, .argv = &.{ "umask", "abc" }, .stderr = -1 }));
    try testing.expectEqual(@as(u32, 0o003), currentMask());
}

test "ulimit reads and lowers the open-file limit" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var status: u8 = undefined;
    var saved: linux.rlimit = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.prlimit(0, .NOFILE, null, &saved)));
    defer _ = linux.prlimit(0, .NOFILE, &saved, null);

    const shown = try capture(&sh, ulimit, &.{ "ulimit", "-n" }, &status);
    defer testing.allocator.free(shown);
    var expected_buf: [32]u8 = undefined;
    const expected = if (saved.cur == linux.RLIM.INFINITY) "unlimited\n" else try std.fmt.bufPrint(&expected_buf, "{d}\n", .{saved.cur});
    try testing.expectEqualStrings(expected, shown);

    try testing.expectEqual(@as(u8, 0), ulimit(.{ .sh = &sh, .argv = &.{ "ulimit", "-S", "-n", "64" } }));
    var now: linux.rlimit = undefined;
    _ = linux.prlimit(0, .NOFILE, null, &now);
    try testing.expectEqual(@as(u64, 64), now.cur);
    try testing.expectEqual(saved.max, now.max);

    const both = try capture(&sh, ulimit, &.{ "ulimit", "-n", "-p" }, &status);
    defer testing.allocator.free(both);
    try testing.expectEqualStrings("open files                          (-n) 64\npipe size                (512 bytes, -p) 8\n", both);

    try testing.expectEqual(@as(u8, 1), ulimit(.{ .sh = &sh, .argv = &.{ "ulimit", "-n", "abc" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 2), ulimit(.{ .sh = &sh, .argv = &.{ "ulimit", "-z" }, .stderr = -1 }));
}

test "times prints two lines and logout refuses non-login shells" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var status: u8 = undefined;
    const out = try capture(&sh, times, &.{"times"}, &status);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, out, "\n"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, out, "s"));

    try testing.expectEqual(@as(u8, 1), logout(.{ .sh = &sh, .argv = &.{"logout"}, .stderr = -1 }));
    try testing.expect(!sh.should_exit);
    sh.login = true;
    try testing.expectEqual(@as(u8, 3), logout(.{ .sh = &sh, .argv = &.{ "logout", "3" }, .stderr = -1 }));
    try testing.expect(sh.should_exit);
}
