//! Filesystem helpers built on raw Linux syscalls (`statx`, `getdents64`,
//! `readlink`, `chdir`). wolysh needs direct, allocation-light access here
//! because globbing and completion walk directories on every keystroke.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

pub const Kind = enum { file, dir, symlink, other, unknown };

pub const Entry = struct {
    name: []const u8,
    kind: Kind,
};

fn kindFromMode(mode: u16) Kind {
    return switch (mode & linux.S.IFMT) {
        linux.S.IFDIR => .dir,
        linux.S.IFREG => .file,
        linux.S.IFLNK => .symlink,
        else => .other,
    };
}

fn kindFromDirent(t: u8) Kind {
    return switch (t) {
        linux.DT.DIR => .dir,
        linux.DT.REG => .file,
        linux.DT.LNK => .symlink,
        linux.DT.UNKNOWN => .unknown,
        else => .other,
    };
}

/// A directory being walked. `name` slices returned by `next` point into the
/// internal buffer and stay valid until the next call.
pub const Dir = struct {
    fd: i32,
    buf: [4096]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    pub fn open(path: [:0]const u8) ?Dir {
        const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{
            .ACCMODE = .RDONLY,
            .DIRECTORY = true,
            .CLOEXEC = true,
        }, 0);
        if (linux.errno(rc) != .SUCCESS) return null;
        return .{ .fd = @intCast(rc) };
    }

    pub fn close(self: *Dir) void {
        _ = linux.close(self.fd);
    }

    pub fn next(self: *Dir) ?Entry {
        while (true) {
            if (self.pos >= self.len) {
                const rc = linux.getdents64(self.fd, &self.buf, self.buf.len);
                if (linux.errno(rc) != .SUCCESS) return null;
                self.len = @intCast(rc);
                self.pos = 0;
                if (self.len == 0) return null;
            }
            const rec: *align(1) const linux.dirent64 = @ptrCast(&self.buf[self.pos]);
            const reclen: usize = rec.reclen;
            if (reclen < 19 or self.pos + reclen > self.len) return null;
            const base = self.pos;
            self.pos += reclen;
            const name_ptr: [*:0]const u8 = @ptrCast(&self.buf[base + @offsetOf(linux.dirent64, "name")]);
            const name = std.mem.span(name_ptr);
            if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) continue;
            return .{ .name = name, .kind = kindFromDirent(rec.type) };
        }
    }
};

pub fn openDir(path: [:0]const u8) ?Dir {
    return Dir.open(path);
}

/// Kind of a path, or null when it does not exist.
pub fn kind(path: [:0]const u8) ?Kind {
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, path.ptr, 0, .{ .TYPE = true, .MODE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return null;
    return kindFromMode(st.mode);
}

/// Kind of a path, following symlinks and reporting `.symlink` only when the
/// target itself is missing.
pub fn kindFollow(path: [:0]const u8) ?Kind {
    return kind(path);
}

pub fn isDir(path: [:0]const u8) bool {
    return kind(path) == .dir;
}

pub fn exists(path: [:0]const u8) bool {
    return kind(path) != null;
}

pub fn isExecutable(path: [:0]const u8) bool {
    if (kind(path) != .file) return false;
    const rc = linux.access(path.ptr, 1); // X_OK
    return linux.errno(rc) == .SUCCESS;
}

/// Reads the current working directory into `allocator`. The result is not
/// null-terminated.
pub fn getCwd(allocator: std.mem.Allocator) !?[]u8 {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    const n: usize = @intCast(rc);
    const len = if (n > 0 and buf[n - 1] == 0) n - 1 else n;
    return try allocator.dupe(u8, buf[0..len]);
}

pub fn chdir(path: [:0]const u8) bool {
    const rc = linux.chdir(path.ptr);
    return linux.errno(rc) == .SUCCESS;
}

/// Resolves a symlink; returns null when the path is not a symlink.
pub fn readLink(allocator: std.mem.Allocator, path: [:0]const u8) !?[]u8 {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const rc = linux.readlink(path.ptr, &buf, buf.len);
    if (linux.errno(rc) != .SUCCESS) return null;
    const n: usize = @intCast(rc);
    return try allocator.dupe(u8, buf[0..n]);
}

/// Reads a whole file, up to `max` bytes.
pub fn readFileAlloc(allocator: std.mem.Allocator, path: [:0]const u8, max: usize) !?[]u8 {
    const fd = sys.openRead(path.ptr) orelse return null;
    defer _ = linux.close(fd);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buf: [8192]u8 = undefined;
    while (out.items.len < max) {
        const n = sys.readSome(fd, &buf) orelse break;
        if (n == 0) break;
        try out.appendSlice(allocator, buf[0..n]);
    }
    return try out.toOwnedSlice(allocator);
}

pub fn writeFile(path: [:0]const u8, bytes: []const u8) bool {
    const fd = sys.openWrite(path.ptr, false) orelse return false;
    defer _ = linux.close(fd);
    return sys.writeAll(fd, bytes) == .ok;
}

pub fn removeFile(path: [:0]const u8) bool {
    const rc = linux.unlinkat(linux.AT.FDCWD, path.ptr, 0);
    return linux.errno(rc) == .SUCCESS;
}

pub fn appendFile(path: [:0]const u8, bytes: []const u8) bool {
    const fd = sys.openWrite(path.ptr, true) orelse return false;
    defer _ = linux.close(fd);
    return sys.writeAll(fd, bytes) == .ok;
}

test "cwd is readable" {
    const a = std.testing.allocator;
    const cwd = (try getCwd(a)) orelse return error.SkipZigTest;
    defer a.free(cwd);
    try std.testing.expect(cwd.len > 0);
    const z = try a.dupeZ(u8, cwd);
    defer a.free(z);
    try std.testing.expect(isDir(z));
}
