//! Variables the shell computes when read: `RANDOM`, `SECONDS`,
//! `EPOCHSECONDS`, `EPOCHREALTIME`, `LINENO`, `PPID`, `UID`, `EUID`,
//! `HOSTNAME`, `HOSTTYPE`, `OSTYPE` and `WSH_VERSION`.
//!
//! A stored variable of the same name wins, as in bash (see `Shell.getVar`).
//! Assigning `RANDOM` seeds the generator and assigning `SECONDS` restarts the
//! count from the assigned value; neither assignment is stored.

const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;
const build_options = @import("build_options");
const shell = @import("shell.zig");
const value = @import("value.zig");
const sys = @import("sys.zig");

pub const names = [_][]const u8{
    "EPOCHREALTIME", "EPOCHSECONDS", "EUID",   "HOSTNAME", "HOSTTYPE", "LINENO",
    "OSTYPE",        "PPID",         "RANDOM", "SECONDS",  "UID",      "WSH_VERSION",
};

/// Monotonic time at which `SECONDS` read zero.
var seconds_origin_ns: ?i64 = null;
var parent_pid: ?i32 = null;
var random_state: u64 = 0;
/// The process that seeded `random_state`; a forked subshell reseeds so it
/// does not repeat its parent's sequence.
var random_owner: i32 = 0;
var realtime_buf: [48]u8 = undefined;

/// Records the shell's start time and parent, which `SECONDS` and `PPID`
/// report for the life of the shell, subshells included.
pub fn start() void {
    seconds_origin_ns = monotonicNs();
    parent_pid = linux.getppid();
}

pub fn isSpecial(name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// The computed value of `name`, or null when it is not a special variable.
pub fn get(sh: *const shell.Shell, name: []const u8) ?value.Value {
    if (name.len < 3 or name[0] < 'A' or name[0] > 'Z') return null;
    const eql = std.mem.eql;
    if (eql(u8, name, "RANDOM")) return .{ .int = nextRandom() };
    if (eql(u8, name, "SECONDS")) return .{ .int = @divFloor(monotonicNs() - secondsOrigin(), std.time.ns_per_s) };
    if (eql(u8, name, "EPOCHSECONDS")) return .{ .int = realtime().sec };
    if (eql(u8, name, "EPOCHREALTIME")) {
        const now = realtime();
        const micros: u64 = @intCast(@divTrunc(now.nsec, std.time.ns_per_us));
        const text = std.fmt.bufPrint(&realtime_buf, "{d}.{d:0>6}", .{ now.sec, micros }) catch return null;
        return .{ .string = text };
    }
    if (eql(u8, name, "LINENO")) return .{ .int = sh.current_line };
    if (eql(u8, name, "PPID")) return .{ .int = parent_pid orelse linux.getppid() };
    if (eql(u8, name, "UID")) return .{ .int = linux.getuid() };
    if (eql(u8, name, "EUID")) return .{ .int = linux.geteuid() };
    if (eql(u8, name, "HOSTNAME")) return .{ .string = sh.hostname };
    if (eql(u8, name, "HOSTTYPE")) return .{ .string = @tagName(builtin.cpu.arch) };
    if (eql(u8, name, "OSTYPE")) return .{ .string = "linux-gnu" };
    if (eql(u8, name, "WSH_VERSION")) return .{ .string = build_options.version };
    return null;
}

/// Handles an assignment to `RANDOM` or `SECONDS`. Returns true when the
/// assignment was consumed and must not be stored.
pub fn assign(sh: *const shell.Shell, name: []const u8, val: value.Value) bool {
    _ = sh;
    if (std.mem.eql(u8, name, "RANDOM")) {
        random_state = @bitCast(integerOf(val));
        random_owner = sys.getpid();
        return true;
    }
    if (std.mem.eql(u8, name, "SECONDS")) {
        seconds_origin_ns = monotonicNs() -% integerOf(val) *% std.time.ns_per_s;
        return true;
    }
    return false;
}

fn integerOf(val: value.Value) i64 {
    return switch (val) {
        .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\n"), 10) catch 0,
        else => val.asInt() orelse 0,
    };
}

fn secondsOrigin() i64 {
    if (seconds_origin_ns == null) seconds_origin_ns = monotonicNs();
    return seconds_origin_ns.?;
}

/// 0..32767 from a 64-bit LCG, as bash's range promises.
fn nextRandom() i64 {
    const pid = sys.getpid();
    if (pid != random_owner) {
        random_state ^= @as(u64, @bitCast(monotonicNs())) ^ (@as(u64, @intCast(pid)) *% 0x9E3779B97F4A7C15);
        random_owner = pid;
    }
    random_state = random_state *% 6364136223846793005 +% 1442695040888963407;
    return @intCast((random_state >> 33) & 0x7fff);
}

fn monotonicNs() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &ts)) != .SUCCESS) return 0;
    return @as(i64, ts.sec) * std.time.ns_per_s + ts.nsec;
}

const Realtime = struct { sec: i64, nsec: i64 };

fn realtime() Realtime {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return .{ .sec = 0, .nsec = 0 };
    return .{ .sec = ts.sec, .nsec = ts.nsec };
}

test "special variables are computed and seeding is deterministic" {
    var sh = try shell.Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    try std.testing.expect(assign(&sh, "RANDOM", .{ .string = "42" }));
    const first = get(&sh, "RANDOM").?.int;
    _ = assign(&sh, "RANDOM", .{ .int = 42 });
    try std.testing.expectEqual(first, get(&sh, "RANDOM").?.int);
    try std.testing.expect(first >= 0 and first <= 32767);

    try std.testing.expect(assign(&sh, "SECONDS", .{ .string = "100" }));
    try std.testing.expect(get(&sh, "SECONDS").?.int >= 100);

    sh.current_line = 7;
    try std.testing.expectEqual(@as(i64, 7), get(&sh, "LINENO").?.int);
    try std.testing.expectEqualStrings("linux-gnu", get(&sh, "OSTYPE").?.string);
    try std.testing.expect(get(&sh, "EPOCHSECONDS").?.int > 1_600_000_000);
    try std.testing.expect(std.mem.indexOfScalar(u8, get(&sh, "EPOCHREALTIME").?.string, '.') != null);
    try std.testing.expect(get(&sh, "PATH") == null);
    try std.testing.expect(!assign(&sh, "PATH", .{ .string = "x" }));
}
