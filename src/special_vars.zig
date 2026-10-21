//! Variables the shell computes when read: `RANDOM`, `SECONDS`,
//! `EPOCHSECONDS`, `EPOCHREALTIME`, `LINENO`, `PPID`, `UID`, `EUID`,
//! `HOSTNAME`, `HOSTTYPE`, `OSTYPE`, `WSH_VERSION`, and the Bash identity and
//! defaults scripts probe: `IFS`, `PS4`, `BASH`, `BASH_VERSION`,
//! `BASH_VERSINFO`, `BASHPID`, `MACHTYPE`, `SRANDOM` and `SHELLOPTS`.
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
const set_options = @import("set_options.zig");

pub const names = [_][]const u8{
    "BASH_ALIASES", "BASH_COMMAND", "BASH_SUBSHELL", "DIRSTACK", "GROUPS",    "HISTCMD",       "OPTERR",       "OPTIND",
    "BASH_LINENO",  "BASH_SOURCE",  "FUNCNAME",      "BASH",     "BASHPID",   "BASH_VERSINFO", "BASH_VERSION", "EPOCHREALTIME",
    "EPOCHSECONDS", "EUID",         "HOSTNAME",      "HOSTTYPE", "IFS",       "LINENO",        "MACHTYPE",     "OSTYPE",
    "PPID",         "PS4",          "RANDOM",        "SECONDS",  "SHELLOPTS", "SRANDOM",       "UID",          "WSH_VERSION",
};

/// The Bash version scripts see. Scripts test the major number or look for
/// the variable to decide whether Bash features are available; the `wsh`
/// release suffix keeps the claim honest.
const bash_version = "5.3.0(1)-wsh";
const bash_versinfo = [_]value.Value{
    .{ .string = "5" }, .{ .string = "3" },   .{ .string = "0" },
    .{ .string = "1" }, .{ .string = "wsh" }, .{ .string = "x86_64-pc-linux-gnu" },
};
var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
var exe_len: ?usize = null;
var options_buf: [512]u8 = undefined;
/// Backing for the call-stack arrays: one entry per active call plus `main`.
var stack_funcname: [shell.Shell.max_call_depth + 2]value.Value = undefined;
var stack_source: [shell.Shell.max_call_depth + 2]value.Value = undefined;
var dirstack_buf: [shell.Shell.max_dirs + 1]value.Value = undefined;
var groups_buf: [64]value.Value = undefined;
var alias_entries: std.ArrayList(value.Entry) = .empty;
var stack_lineno: [shell.Shell.max_call_depth + 2]value.Value = undefined;

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

const lookup = blk: {
    var pairs: [names.len]struct { []const u8, void } = undefined;
    for (names, 0..) |name, i| pairs[i] = .{ name, {} };
    break :blk std.StaticStringMap(void).initComptime(pairs);
};

pub fn isSpecial(name: []const u8) bool {
    return lookup.has(name);
}

/// The computed value of `name`, or null when it is not a special variable.
pub fn get(sh: *const shell.Shell, name: []const u8) ?value.Value {
    if (name.len < 3 or name[0] < 'A' or name[0] > 'Z' or !lookup.has(name)) return null;
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
    // bash sets these three only when the environment has not.
    if (eql(u8, name, "HOSTNAME")) return if (sh.env.contains(name)) null else .{ .string = sh.hostname };
    if (eql(u8, name, "HOSTTYPE")) return if (sh.env.contains(name)) null else .{ .string = @tagName(builtin.cpu.arch) };
    if (eql(u8, name, "OSTYPE")) return if (sh.env.contains(name)) null else .{ .string = "linux-gnu" };
    if (eql(u8, name, "WSH_VERSION")) return .{ .string = build_options.version };
    if (eql(u8, name, "FUNCNAME") or eql(u8, name, "BASH_SOURCE") or eql(u8, name, "BASH_LINENO")) {
        return callStack(sh, name);
    }
    if (eql(u8, name, "BASH_COMMAND")) return .{ .string = sh.command_text[0..sh.command_len] };
    if (eql(u8, name, "BASH_SUBSHELL")) return .{ .int = sh.subshell_depth };
    if (eql(u8, name, "HISTCMD")) return .{ .int = @intCast(@max(sh.hist.count(), 1)) };
    if (eql(u8, name, "OPTIND") or eql(u8, name, "OPTERR")) return .{ .int = 1 };
    if (eql(u8, name, "DIRSTACK")) return dirStack(sh);
    if (eql(u8, name, "GROUPS")) return groups();
    if (eql(u8, name, "BASH_ALIASES")) return aliasMap(sh);
    // Bash starts with its own IFS and ignores the one it inherits.
    if (eql(u8, name, "IFS")) return .{ .string = " \t\n" };
    if (eql(u8, name, "PS4")) return .{ .string = "+ " };
    if (eql(u8, name, "BASH_VERSION")) return .{ .string = bash_version };
    if (eql(u8, name, "BASH_VERSINFO")) return .{ .list = &bash_versinfo };
    if (eql(u8, name, "MACHTYPE")) return .{ .string = @tagName(builtin.cpu.arch) ++ "-pc-linux-gnu" };
    if (eql(u8, name, "BASHPID")) return .{ .int = sys.getpid() };
    if (eql(u8, name, "SRANDOM")) return .{ .int = (nextRandom() << 17) ^ (nextRandom() << 2) ^ (nextRandom() & 3) };
    if (eql(u8, name, "BASH")) return if (shellPath()) |path| .{ .string = path } else null;
    if (eql(u8, name, "SHELLOPTS")) return .{ .string = shellOptions(sh) };
    return null;
}

/// `FUNCNAME`, `BASH_SOURCE` and `BASH_LINENO`: one entry per active call,
/// innermost first, then the top level (`main`, the script, line 0). Outside
/// any call `FUNCNAME` is unset and the other two describe the script alone.
fn callStack(sh: *const shell.Shell, name: []const u8) ?value.Value {
    const frames = sh.call_frames.items;
    const funcname = std.mem.eql(u8, name, "FUNCNAME");
    const source = std.mem.eql(u8, name, "BASH_SOURCE");
    // Bash leaves FUNCNAME unset until a function runs: a sourced file at the
    // top level is not listed.
    var in_function = false;
    for (frames) |frame| {
        if (!std.mem.eql(u8, frame.name, "source")) in_function = true;
    }
    if (funcname and !in_function) return null;
    if (frames.len == 0) {
        if (funcname) return null;
        if (source) {
            if (sh.script_file.len == 0) return null;
            stack_source[0] = .{ .string = sh.script_file };
            return .{ .list = stack_source[0..1] };
        }
        stack_lineno[0] = .{ .int = 0 };
        return .{ .list = stack_lineno[0..1] };
    }
    const out = if (funcname) &stack_funcname else if (source) &stack_source else &stack_lineno;
    const count = @min(frames.len, out.len - 1);
    for (0..count) |i| {
        const frame = frames[frames.len - 1 - i];
        out[i] = if (funcname) .{ .string = frame.name } else if (source) .{ .string = frame.file } else .{ .int = frame.call_line };
    }
    out[count] = if (funcname) .{ .string = "main" } else if (source) .{ .string = sh.script_file } else .{ .int = 0 };
    return .{ .list = out[0 .. count + 1] };
}

/// `DIRSTACK`: the current directory, then what `pushd` saved.
fn dirStack(sh: *const shell.Shell) value.Value {
    const count = @min(sh.dir_stack.items.len + 1, dirstack_buf.len);
    dirstack_buf[0] = .{ .string = sh.cwd };
    for (1..count) |i| dirstack_buf[i] = .{ .string = sh.dir_stack.items[i - 1] };
    return .{ .list = dirstack_buf[0..count] };
}

/// `GROUPS`: the groups the user is in.
fn groups() value.Value {
    var ids: [64]u32 = undefined;
    const rc = linux.getgroups(ids.len, &ids);
    const count: usize = if (linux.errno(rc) == .SUCCESS) @min(rc, ids.len) else 0;
    if (count == 0) {
        groups_buf[0] = .{ .int = linux.getgid() };
        return .{ .list = groups_buf[0..1] };
    }
    for (0..count) |i| groups_buf[i] = .{ .int = ids[i] };
    return .{ .list = groups_buf[0..count] };
}

/// `BASH_ALIASES`: every alias, keyed by name.
fn aliasMap(sh: *const shell.Shell) ?value.Value {
    alias_entries.clearRetainingCapacity();
    var it = sh.aliases.iterator();
    while (it.next()) |entry| {
        alias_entries.append(sh.gpa, .{ .key = entry.key_ptr.*, .value = .{ .string = entry.value_ptr.* } }) catch return null;
    }
    return .{ .map = alias_entries.items };
}

fn shellPath() ?[]const u8 {
    if (exe_len == null) {
        const rc = linux.readlink("/proc/self/exe", &exe_buf, exe_buf.len);
        exe_len = if (linux.errno(rc) == .SUCCESS) rc else 0;
    }
    return if (exe_len.? == 0) null else exe_buf[0..exe_len.?];
}

/// Colon-separated `set -o` options that are on, in `set -o` order.
fn shellOptions(sh: *const shell.Shell) []const u8 {
    var len: usize = 0;
    for (set_options.options, 0..) |option, index| {
        if (!set_options.get(&sh.options, index)) continue;
        if (len > 0) {
            options_buf[len] = ':';
            len += 1;
        }
        @memcpy(options_buf[len..][0..option.name.len], option.name);
        len += option.name.len;
    }
    return options_buf[0..len];
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
