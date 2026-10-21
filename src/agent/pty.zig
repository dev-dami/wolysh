//! Pseudo-terminal pairs for `run --tty` and `session attach`.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;

pub const Pair = struct { master: i32, slave: i32 };

/// Opens a new pseudo-terminal of `rows` x `cols`. Both ends are
/// close-on-exec and neither becomes a controlling terminal yet.
pub fn open(rows: u16, cols: u16) ?Pair {
    const rc = linux.openat(linux.AT.FDCWD, "/dev/ptmx", .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const master: i32 = @intCast(rc);
    var unlock: c_int = 0;
    var number: c_uint = 0;
    if (linux.errno(linux.ioctl(master, linux.T.IOCSPTLCK, @intFromPtr(&unlock))) != .SUCCESS or
        linux.errno(linux.ioctl(master, linux.T.IOCGPTN, @intFromPtr(&number))) != .SUCCESS)
    {
        _ = linux.close(master);
        return null;
    }
    var path_buf: [32]u8 = undefined;
    const path = std.fmt.bufPrintSentinel(&path_buf, "/dev/pts/{d}", .{number}, 0) catch {
        _ = linux.close(master);
        return null;
    };
    const src = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDWR, .NOCTTY = true, .CLOEXEC = true }, 0);
    if (linux.errno(src) != .SUCCESS) {
        _ = linux.close(master);
        return null;
    }
    const slave: i32 = @intCast(src);
    setSize(slave, rows, cols);
    return .{ .master = master, .slave = slave };
}

fn setSize(fd: i32, rows: u16, cols: u16) void {
    var ws = posix.winsize{ .row = rows, .col = cols, .xpixel = 0, .ypixel = 0 };
    _ = linux.ioctl(fd, linux.T.IOCSWINSZ, @intFromPtr(&ws));
}

/// Makes `slave` the controlling terminal of the calling session leader.
pub fn makeControlling(slave: i32) bool {
    return linux.errno(linux.ioctl(slave, linux.T.IOCSCTTY, 0)) == .SUCCESS;
}

/// Gives up the controlling terminal, so a later attach can claim a new one.
pub fn releaseControlling(fd: i32) void {
    _ = linux.ioctl(fd, linux.T.IOCNOTTY, 0);
}

/// Stops the terminal turning `\n` into `\r\n`, so captured output keeps
/// plain line endings.
pub fn plainNewlines(fd: i32) void {
    var attrs = posix.tcgetattr(fd) catch return;
    attrs.oflag.ONLCR = false;
    posix.tcsetattr(fd, .NOW, attrs) catch {};
}

test "a pseudo-terminal pair carries bytes" {
    const pair = open(24, 80) orelse return error.SkipZigTest;
    defer _ = linux.close(pair.master);
    defer _ = linux.close(pair.slave);
    plainNewlines(pair.slave);
    try std.testing.expect(linux.write(pair.slave, "hi\n", 3) == 3);
    var buf: [8]u8 = undefined;
    const n = linux.read(pair.master, &buf, buf.len);
    try std.testing.expectEqualStrings("hi\n", buf[0..n]);
}
