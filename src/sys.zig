//! Thin, allocation-free wrappers over the raw Linux syscalls wolysh needs.
//!
//! wolysh deliberately talks to the kernel directly for process, terminal and
//! job-control work: a shell *is* the process-group and controlling-terminal
//! manager, so it cannot outsource that to an I/O abstraction.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const fd_t = i32;

pub const STDIN: fd_t = 0;
pub const STDOUT: fd_t = 1;
pub const STDERR: fd_t = 2;

/// Result of a write, distinguishing a dead reader from a real failure so the
/// shell can stop writing to a closed pipe without printing an error.
pub const WriteResult = enum { ok, broken_pipe, failed };

fn waitWritable(fd: fd_t) bool {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.OUT, .revents = 0 }};
    _ = posix.poll(&fds, -1) catch return false;
    return true;
}

/// Writes every byte of `bytes`, retrying short writes and EINTR.
pub fn writeAll(fd: fd_t, bytes: []const u8) WriteResult {
    var rest = bytes;
    while (rest.len != 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                const n: usize = @intCast(rc);
                if (n == 0) return .failed;
                rest = rest[n..];
            },
            .INTR => continue,
            .AGAIN => if (!waitWritable(fd)) return .failed,
            .PIPE => return .broken_pipe,
            else => return .failed,
        }
    }
    return .ok;
}

pub fn writeAllIgnore(fd: fd_t, bytes: []const u8) void {
    _ = writeAll(fd, bytes);
}

pub fn writeStr(fd: fd_t, s: []const u8) void {
    _ = writeAll(fd, s);
}

/// Reads once into `buf`. Returns the byte count, or null on EOF/error.
pub fn readSome(fd: fd_t, buf: []u8) ?usize {
    while (true) {
        const rc = linux.read(fd, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => continue,
            else => return null,
        }
    }
}

/// Reads exactly `buf.len` bytes. Returns how many were read before EOF.
pub fn readAll(fd: fd_t, buf: []u8) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const n = readSome(fd, buf[total..]) orelse break;
        if (n == 0) break;
        total += n;
    }
    return total;
}

pub fn readByte(fd: fd_t) ?u8 {
    var b: [1]u8 = undefined;
    const n = readSome(fd, &b) orelse return null;
    if (n == 0) return null;
    return b[0];
}

pub fn isTty(fd: fd_t) bool {
    return posix.tcgetattr(fd) != error.NotATerminal;
}

pub const WinSize = struct { cols: u16, rows: u16 };

pub fn windowSize(fd: fd_t) ?WinSize {
    var ws: posix.winsize = undefined;
    const rc = linux.ioctl(fd, linux.T.IOCGWINSZ, @intFromPtr(&ws));
    if (linux.errno(rc) != .SUCCESS) return null;
    if (ws.col == 0) return null;
    return .{ .cols = ws.col, .rows = ws.row };
}

pub fn getpid() i32 {
    return linux.getpid();
}

pub fn getpgid(pid: i32) ?i32 {
    const rc = linux.getpgid(pid);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn setpgid(pid: i32, pgid: i32) void {
    _ = linux.setpgid(pid, pgid);
}

pub fn tcsetpgrp(fd: fd_t, pgid: i32) void {
    posix.tcsetpgrp(fd, pgid) catch {};
}

pub fn tcgetpgrp(fd: fd_t) ?i32 {
    return posix.tcgetpgrp(fd) catch null;
}

pub fn setsid() ?i32 {
    const rc = linux.setsid();
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn exitProcess(code: u8) noreturn {
    linux.exit_group(code);
}

pub fn closeFd(fd: fd_t) void {
    if (fd <= 2) return;
    _ = linux.close(fd);
}

pub fn dup2(old: fd_t, new: fd_t) void {
    if (old == new) return;
    _ = linux.dup3(old, new, 0);
}

pub fn duplicate(fd: fd_t) ?fd_t {
    const rc = linux.fcntl(fd, linux.F.DUPFD_CLOEXEC, 3);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn createAnonymousFile(bytes: []const u8) ?fd_t {
    const rc = linux.memfd_create("wsh-heredoc", linux.MFD.CLOEXEC);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: fd_t = @intCast(rc);
    if (writeAll(fd, bytes) != .ok or linux.errno(linux.lseek(fd, 0, linux.SEEK.SET)) != .SUCCESS) {
        closeFd(fd);
        return null;
    }
    return fd;
}

/// Both open helpers set `CLOEXEC`: a descriptor opened for one redirect must
/// not leak into the other processes of a pipeline, where it would keep a pipe
/// or file alive. `dup2` onto 0/1/2 clears the flag where it matters.
pub fn openRead(path: [*:0]const u8) ?fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

pub fn openWrite(path: [*:0]const u8, append: bool) ?fd_t {
    const flags: linux.O = .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = !append,
        .APPEND = append,
        .CLOEXEC = true,
    };
    const rc = linux.openat(linux.AT.FDCWD, path, flags, 0o644);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// A growable UTF-8 string builder. Thin wrapper over `std.Io.Writer.Allocating`
/// so the rest of the shell does not have to spell that out.
pub const StringBuilder = struct {
    allocating: std.Io.Writer.Allocating,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StringBuilder {
        return .{ .allocating = .init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *StringBuilder) void {
        self.allocating.deinit();
    }

    pub fn writer(self: *StringBuilder) *std.Io.Writer {
        return &self.allocating.writer;
    }

    pub fn append(self: *StringBuilder, bytes: []const u8) std.mem.Allocator.Error!void {
        try self.allocating.writer.writeAll(bytes);
    }

    pub fn appendByte(self: *StringBuilder, b: u8) std.mem.Allocator.Error!void {
        try self.allocating.writer.writeByte(b);
    }

    pub fn appendSplat(self: *StringBuilder, b: u8, n: usize) std.mem.Allocator.Error!void {
        try self.allocating.writer.splatByteAll(b, n);
    }

    pub fn print(self: *StringBuilder, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        try self.allocating.writer.print(fmt, args);
    }

    pub fn items(self: *const StringBuilder) []const u8 {
        return self.allocating.writer.buffer[0..self.allocating.writer.end];
    }

    pub fn len(self: *const StringBuilder) usize {
        return self.allocating.writer.end;
    }

    /// Truncates back to `n` bytes.
    pub fn truncate(self: *StringBuilder, n: usize) void {
        if (n <= self.allocating.writer.end) self.allocating.writer.end = n;
    }

    pub fn clear(self: *StringBuilder) void {
        self.allocating.writer.end = 0;
    }

    pub fn toOwnedSlice(self: *StringBuilder) std.mem.Allocator.Error![]u8 {
        return self.allocating.toOwnedSlice();
    }

    /// Returns the built string, allocating a copy in `allocator`.
    pub fn dupe(self: *const StringBuilder, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        return allocator.dupe(u8, self.items());
    }
};
