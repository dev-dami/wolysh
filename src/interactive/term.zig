//! Terminal raw mode.

const std = @import("std");
const posix = std.posix;
const sys = @import("../sys.zig");

pub const RawMode = struct {
    fd: i32,
    saved: posix.termios,
    active: bool = false,

    /// Switches the terminal into raw mode. Returns null when `fd` is not a
    /// terminal, so callers can fall back to a plain line reader.
    pub fn enable(fd: i32) ?RawMode {
        const saved = posix.tcgetattr(fd) catch return null;

        var raw = saved;
        // Input: no line editing, no echo, no signal generation, no flow control.
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;
        raw.iflag.BRKINT = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        // Output: keep OPOST so `\n` still moves the carriage as expected.
        raw.lflag.ICANON = false;
        raw.lflag.ECHO = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(fd, .NOW, raw) catch return null;
        return .{ .fd = fd, .saved = saved, .active = true };
    }

    pub fn disable(self: *RawMode) void {
        if (!self.active) return;
        posix.tcsetattr(self.fd, .NOW, self.saved) catch {};
        self.active = false;
    }
};

/// Reads one byte, blocking until it arrives.
pub fn readByte(fd: i32) ?u8 {
    var b: [1]u8 = undefined;
    const n = sys.readSome(fd, &b) orelse return null;
    if (n == 0) return null;
    return b[0];
}

/// Reads a byte with a short timeout (100 ms), used to tell a bare ESC from an
/// escape sequence.
pub fn readByteTimeout(fd: i32, ms: i32) ?u8 {
    var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
    const ready = posix.poll(&fds, ms) catch return null;
    if (ready == 0) return null;
    return readByte(fd);
}

test "raw mode is refused on a non-terminal" {
    // A pipe is never a terminal, so this must return null rather than fail.
    var fds: [2]i32 = undefined;
    const linux = std.os.linux;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }
    try std.testing.expect(RawMode.enable(fds[0]) == null);
}
