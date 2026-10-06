//! Terminal raw mode, bracketed paste and resize notification.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const proc = @import("../proc.zig");

/// Bracketed paste: the terminal wraps pasted text in `ESC[200~ ... ESC[201~`.
pub const paste_on = "\x1b[?2004h";
pub const paste_off = "\x1b[?2004l";
pub const paste_end = "\x1b[201~";

var resized = std.atomic.Value(bool).init(false);
var previous_action: linux.Sigaction = undefined;
/// A `trap ... WINCH` handler that was installed before the editor's.
var chained: ?linux.Sigaction.handler_fn = null;

fn onResize(sig: linux.SIG) callconv(.c) void {
    resized.store(true, .monotonic);
    if (chained) |handler| handler(sig);
}

/// Routes SIGWINCH to a flag while the editor runs, then puts the previous
/// disposition back. The handler is installed without SA_RESTART, so a
/// blocked key read fails with EINTR and the editor redraws at the new width
/// immediately.
pub fn watchResize(enable: bool) void {
    if (!enable) {
        _ = linux.sigaction(.WINCH, &previous_action, null);
        chained = null;
        return;
    }
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = onResize };
    _ = linux.sigaction(.WINCH, &act, &previous_action);
    const handler = previous_action.handler.handler;
    chained = if (handler == linux.SIG.DFL or handler == linux.SIG.IGN or handler == onResize or
        previous_action.flags & linux.SA.SIGINFO != 0) null else handler;
}

/// True once per window-size change.
pub fn takeResize() bool {
    return resized.swap(false, .monotonic);
}

pub const ReadResult = union(enum) { byte: u8, eof, interrupted };

/// Reads one byte, reporting EINTR instead of retrying it.
pub fn readByteInterruptible(fd: i32) ReadResult {
    var b: [1]u8 = undefined;
    const rc = linux.read(fd, &b, 1);
    return switch (linux.errno(rc)) {
        .SUCCESS => if (rc == 0) .eof else .{ .byte = b[0] },
        .INTR => .interrupted,
        else => .eof,
    };
}

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

/// Reads one byte, blocking until it arrives. A SIGHUP ends the wait like end
/// of input, so the shell can hang up instead of waiting for a key.
pub fn readByte(fd: i32) ?u8 {
    var b: [1]u8 = undefined;
    while (!proc.hangupPending()) {
        const rc = std.os.linux.read(fd, &b, 1);
        switch (std.os.linux.errno(rc)) {
            .SUCCESS => return if (rc == 0) null else b[0],
            .INTR => continue,
            else => return null,
        }
    }
    return null;
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
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.SkipZigTest;
    defer {
        _ = linux.close(fds[0]);
        _ = linux.close(fds[1]);
    }
    try std.testing.expect(RawMode.enable(fds[0]) == null);
}
