//! The per-user state directory that background runs, sessions and the
//! daemon share, and the small file helpers they use.
//!
//! The directory is `$XDG_RUNTIME_DIR/wsh` when `XDG_RUNTIME_DIR` names a
//! directory, otherwise `/tmp/wsh-<uid>`. Other tools read it, so the layout is
//! fixed: `runs/<name>/{meta.json,output.log}`, `sessions/<name>/meta.json`,
//! `daemon.sock`, `daemon.pid` and `daemon.lock`.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const Shell = @import("../shell.zig").Shell;

pub const RunSource = *const fn (*Shell, []const u8) u8;

/// Everything a `run` or `session` command needs. The CLI fast path fills it
/// from the process; a builtin fills it from the shell it runs in.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    stdin: i32 = 0,
    stdout: i32 = 1,
    stderr: i32 = 2,
    /// `NAME=value` entries, as `execve` takes them.
    envp: [*:null]const ?[*:0]const u8,
    /// The logical working directory.
    cwd: []const u8,
    /// The calling shell when the command runs as a builtin; null on the
    /// CLI fast path, which has no shell.
    sh: ?*Shell = null,
    run_source: ?RunSource = null,

    pub fn out(self: Context, bytes: []const u8) void {
        sys.writeStr(self.stdout, bytes);
    }

    pub fn err(self: Context, bytes: []const u8) void {
        sys.writeStr(self.stderr, bytes);
    }

    pub fn outFmt(self: Context, comptime fmt: []const u8, args: anytype) void {
        const text = std.fmt.allocPrint(self.arena, fmt, args) catch return;
        self.out(text);
    }

    pub fn errFmt(self: Context, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.err(text);
    }

    pub fn getEnv(self: Context, name: []const u8) ?[]const u8 {
        return envLookup(self.envp, name);
    }
};

/// Finds `name` in an `execve`-style environment.
pub fn envLookup(envp: [*:null]const ?[*:0]const u8, name: []const u8) ?[]const u8 {
    var index: usize = 0;
    while (envp[index]) |entry| : (index += 1) {
        const text = std.mem.span(entry);
        if (text.len > name.len and text[name.len] == '=' and std.mem.eql(u8, text[0..name.len], name)) {
            return text[name.len + 1 ..];
        }
    }
    return null;
}

/// Milliseconds since the Unix epoch.
pub fn nowMs() i64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &time)) != .SUCCESS) return 0;
    return @as(i64, @intCast(time.sec)) * 1000 + @divTrunc(@as(i64, @intCast(time.nsec)), std.time.ns_per_ms);
}

/// Milliseconds on the monotonic clock, for timeouts.
pub fn monotonicMs() i64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return 0;
    return @as(i64, @intCast(time.sec)) * 1000 + @divTrunc(@as(i64, @intCast(time.nsec)), std.time.ns_per_ms);
}

pub fn sleepMs(ms: u64) void {
    var req = linux.timespec{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
    while (linux.errno(linux.nanosleep(&req, &req)) == .INTR) {}
}

/// The state directory path, without creating it.
pub fn dirPath(arena: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8) ![:0]const u8 {
    return dirPathFrom(arena, envLookup(envp, "XDG_RUNTIME_DIR"));
}

/// The state directory for a given `XDG_RUNTIME_DIR` value (null when unset).
pub fn dirPathFrom(arena: std.mem.Allocator, runtime_dir: ?[]const u8) ![:0]const u8 {
    if (runtime_dir) |runtime| {
        if (runtime.len != 0) {
            const z = try arena.dupeZ(u8, runtime);
            if (fs.isDir(z)) return std.fmt.allocPrintSentinel(arena, "{s}/wsh", .{runtime}, 0);
        }
    }
    return std.fmt.allocPrintSentinel(arena, "/tmp/wsh-{d}", .{linux.getuid()}, 0);
}

const Error = error{ StateDirUnsafe, StateDirUnavailable } || std.mem.Allocator.Error;

/// Creates `path` with mode 0700 if needed and checks that it is a directory
/// only this user can reach. `/tmp/wsh-<uid>` sits in a shared directory, so
/// one created by another user must be refused, not used.
fn ensurePrivateDir(path: [:0]const u8) Error!void {
    const rc = linux.mkdirat(linux.AT.FDCWD, path.ptr, 0o700);
    switch (linux.errno(rc)) {
        .SUCCESS, .EXIST => {},
        else => return error.StateDirUnavailable,
    }
    var st: linux.Statx = undefined;
    const src = linux.statx(linux.AT.FDCWD, path.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true }, &st);
    if (linux.errno(src) != .SUCCESS) return error.StateDirUnavailable;
    if (st.mode & linux.S.IFMT != linux.S.IFDIR or st.uid != linux.getuid()) return error.StateDirUnsafe;
    if (st.mode & 0o077 != 0) {
        if (linux.errno(linux.fchmodat(linux.AT.FDCWD, path.ptr, 0o700)) != .SUCCESS) return error.StateDirUnsafe;
    }
}

/// The state directory, created when missing. Reports why it is unusable.
pub fn ensureDir(ctx: Context, who: []const u8) ?[:0]const u8 {
    const path = dirPath(ctx.arena, ctx.envp) catch return null;
    ensurePrivateDir(path) catch |e| {
        switch (e) {
            error.StateDirUnsafe => ctx.errFmt("wsh: {s}: {s}: state directory is not private to this user\n", .{ who, path }),
            else => ctx.errFmt("wsh: {s}: {s}: cannot create the state directory\n", .{ who, path }),
        }
        return null;
    };
    return path;
}

/// `<state>/<sub>`, created with mode 0700 when missing.
pub fn ensureSubdir(ctx: Context, state: []const u8, sub: []const u8, who: []const u8) ?[:0]const u8 {
    const path = std.fmt.allocPrintSentinel(ctx.arena, "{s}/{s}", .{ state, sub }, 0) catch return null;
    ensurePrivateDir(path) catch {
        ctx.errFmt("wsh: {s}: {s}: cannot create the directory\n", .{ who, path });
        return null;
    };
    return path;
}

/// Run and session names become directory names: 1 to 64 letters, digits,
/// `.`, `_` or `-`, not starting with `.` or `-`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    if (name[0] == '.' or name[0] == '-') return false;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '.' and c != '_' and c != '-') return false;
    }
    return true;
}

/// Writes `bytes` to `path` through a temporary file and `rename(2)`, so a
/// reader sees either the old content or the new, never a partial file.
pub fn writeAtomic(arena: std.mem.Allocator, path: []const u8, bytes: []const u8) bool {
    const dir_end = std.mem.lastIndexOfScalar(u8, path, '/') orelse return false;
    const tmp = std.fmt.allocPrintSentinel(arena, "{s}/.{s}.{d}", .{ path[0..dir_end], path[dir_end + 1 ..], linux.getpid() }, 0) catch return false;
    const final = arena.dupeZ(u8, path) catch return false;
    const rc = linux.openat(linux.AT.FDCWD, tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return false;
    const fd: i32 = @intCast(rc);
    const ok = sys.writeAll(fd, bytes) == .ok;
    _ = linux.close(fd);
    if (!ok or linux.errno(linux.renameat(linux.AT.FDCWD, tmp.ptr, linux.AT.FDCWD, final.ptr)) != .SUCCESS) {
        _ = linux.unlinkat(linux.AT.FDCWD, tmp.ptr, 0);
        return false;
    }
    return true;
}

/// Opens a directory for `flock(2)`. Null when it does not exist.
pub fn openDirFd(path: [:0]const u8) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// True when another process holds an exclusive `flock` on `fd`'s file.
pub fn lockHeld(fd: i32) bool {
    const rc = linux.flock(fd, posix.LOCK.SH | posix.LOCK.NB);
    if (linux.errno(rc) == .SUCCESS) {
        _ = linux.flock(fd, posix.LOCK.UN);
        return false;
    }
    return true;
}

/// Takes an exclusive lock without waiting.
pub fn tryLock(fd: i32) bool {
    return linux.errno(linux.flock(fd, posix.LOCK.EX | posix.LOCK.NB)) == .SUCCESS;
}

/// Deletes `path` and the files directly inside it.
pub fn removeTree(arena: std.mem.Allocator, path: [:0]const u8) bool {
    var dir = fs.openDir(path) orelse return false;
    defer dir.close();
    while (dir.next()) |entry| {
        const child = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ path, entry.name }, 0) catch return false;
        _ = linux.unlinkat(linux.AT.FDCWD, child.ptr, 0);
    }
    return linux.errno(linux.unlinkat(linux.AT.FDCWD, path.ptr, linux.AT.REMOVEDIR)) == .SUCCESS;
}

/// Size of `path`, or 0 when it is missing.
pub fn fileSizeOr0(arena: std.mem.Allocator, path: []const u8) u64 {
    const z = arena.dupeZ(u8, path) catch return 0;
    return sys.fileSize(z) orelse 0;
}

/// Points 0, 1 and 2 at `/dev/null`, for processes that outlive the caller.
pub fn nullStdio() void {
    const rc = linux.openat(linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(rc) != .SUCCESS) return;
    const fd: i32 = @intCast(rc);
    for ([_]i32{ 0, 1, 2 }) |target| _ = linux.dup3(fd, target, 0);
    if (fd > 2) _ = linux.close(fd);
}

/// The session id of the calling process.
pub fn getsid() i32 {
    return @intCast(linux.syscall1(.getsid, 0));
}

/// Sends `sig` to every live process in session `sid` except `skip` and
/// the members of group `skip_group`, which the caller signals itself.
/// Background jobs get process groups of their own, so the session, which a
/// run or a session host starts with `setsid`, is what holds all of them.
pub fn signalSession(sid: i32, skip: i32, skip_group: ?i32, sig: u32) void {
    var dir = fs.openDir("/proc") orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        const pid = std.fmt.parseInt(i32, entry.name, 10) catch continue;
        if (pid == skip) continue;
        const ids = processIds(pid) orelse continue;
        if (ids.session != sid or (skip_group != null and ids.group == skip_group.?)) continue;
        _ = linux.syscall2(.kill, @bitCast(@as(isize, pid)), sig);
    }
}

const ProcessIds = struct { group: i32, session: i32 };

/// The group and session of `pid` from `/proc/<pid>/stat`, or null for a
/// zombie or a process that is gone.
fn processIds(pid: i32) ?ProcessIds {
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/{d}/stat", .{pid}, 0) catch return null;
    const fd = sys.openRead(path) orelse return null;
    defer sys.closeFd(fd);
    var buf: [512]u8 = undefined;
    const n = sys.readAll(fd, &buf);
    return parseStat(buf[0..n]);
}

/// The fields after the command name start: state, ppid, pgrp, session.
fn parseStat(stat: []const u8) ?ProcessIds {
    const close = std.mem.lastIndexOfScalar(u8, stat, ')') orelse return null;
    var fields = std.mem.tokenizeScalar(u8, stat[close + 1 ..], ' ');
    const run_state = fields.next() orelse return null;
    if (std.mem.eql(u8, run_state, "Z")) return null;
    _ = fields.next() orelse return null;
    const group = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    const session = std.fmt.parseInt(i32, fields.next() orelse return null, 10) catch return null;
    return .{ .group = group, .session = session };
}

/// A duration such as `60`, `1.5s`, `500ms`, `2m` or `1h`, in milliseconds.
/// A bare number counts seconds.
pub fn parseDuration(text: []const u8) ?i64 {
    const units = [_]struct { []const u8, f64 }{
        .{ "ms", 1 }, .{ "s", 1000 }, .{ "m", 60_000 }, .{ "h", 3_600_000 },
    };
    var number = text;
    var scale: f64 = 1000;
    for (units) |unit| {
        if (std.mem.endsWith(u8, text, unit[0])) {
            number = text[0 .. text.len - unit[0].len];
            scale = unit[1];
            break;
        }
    }
    if (number.len == 0) return null;
    for (number) |c| {
        if (!std.ascii.isDigit(c) and c != '.') return null;
    }
    const value = std.fmt.parseFloat(f64, number) catch return null;
    const ms = value * scale;
    if (ms > 1e15) return null;
    return @intFromFloat(ms);
}

/// `1.2s`, `3m04s` or `2h05m`.
pub fn formatElapsed(buf: []u8, ms: i64) []const u8 {
    const total = @max(ms, 0);
    if (total < 60_000) {
        return std.fmt.bufPrint(buf, "{d}.{d}s", .{ @divTrunc(total, 1000), @divTrunc(@mod(total, 1000), 100) }) catch "";
    }
    const seconds = @divTrunc(total, 1000);
    if (seconds < 3600) {
        return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ @divTrunc(seconds, 60), @mod(seconds, 60) }) catch "";
    }
    return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ @divTrunc(seconds, 3600), @divTrunc(@mod(seconds, 3600), 60) }) catch "";
}

/// Seconds from `name` in the environment, or `default` when unset or invalid.
pub fn envSeconds(envp: [*:null]const ?[*:0]const u8, name: []const u8, default: i64) i64 {
    const text = envLookup(envp, name) orelse return default;
    const seconds = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch return default;
    return if (seconds < 0) default else seconds;
}

const testing = std.testing;

test "names are safe directory names" {
    try testing.expect(validName("test"));
    try testing.expect(validName("run-12_a.b"));
    try testing.expect(!validName(""));
    try testing.expect(!validName(".hidden"));
    try testing.expect(!validName("-x"));
    try testing.expect(!validName("a/b"));
    try testing.expect(!validName("a b"));
    try testing.expect(!validName("x" ** 65));
}

test "durations accept units and bare seconds" {
    try testing.expectEqual(@as(?i64, 60_000), parseDuration("60"));
    try testing.expectEqual(@as(?i64, 60_000), parseDuration("60s"));
    try testing.expectEqual(@as(?i64, 1500), parseDuration("1.5s"));
    try testing.expectEqual(@as(?i64, 500), parseDuration("500ms"));
    try testing.expectEqual(@as(?i64, 120_000), parseDuration("2m"));
    try testing.expectEqual(@as(?i64, 3_600_000), parseDuration("1h"));
    try testing.expectEqual(@as(?i64, null), parseDuration("soon"));
    try testing.expectEqual(@as(?i64, null), parseDuration("s"));
    try testing.expectEqual(@as(?i64, null), parseDuration("-1s"));
}

test "elapsed times read naturally" {
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("1.2s", formatElapsed(&buf, 1234));
    try testing.expectEqualStrings("3m04s", formatElapsed(&buf, 184_000));
    try testing.expectEqualStrings("2h05m", formatElapsed(&buf, 7_500_000));
}

test "the session id comes from the end of /proc stat" {
    const ids = parseStat("12 (a) b) c) S 1 70 77 0 -1").?;
    try testing.expectEqual(@as(i32, 70), ids.group);
    try testing.expectEqual(@as(i32, 77), ids.session);
    try testing.expect(parseStat("12 (gone) Z 1 70 77 0") == null);
    try testing.expect(parseStat("garbage") == null);
    try testing.expectEqual(getsid(), processIds(linux.getpid()).?.session);
}

test "environment lookup matches whole names" {
    const entries = [_:null]?[*:0]const u8{ "XDG=1", "XDG_RUNTIME_DIR=/run/user/1", "WSH_RUN_TTL=60" };
    const envp: [*:null]const ?[*:0]const u8 = &entries;
    try testing.expectEqualStrings("/run/user/1", envLookup(envp, "XDG_RUNTIME_DIR").?);
    try testing.expectEqualStrings("1", envLookup(envp, "XDG").?);
    try testing.expect(envLookup(envp, "XDG_RUNTIME") == null);
    try testing.expectEqual(@as(i64, 60), envSeconds(envp, "WSH_RUN_TTL", 5));
    try testing.expectEqual(@as(i64, 5), envSeconds(envp, "WSH_SESSION_TTL", 5));
}
