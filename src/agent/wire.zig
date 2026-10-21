//! Framed messages over Unix sockets, with descriptor passing.
//!
//! A frame is a 4-byte little-endian length followed by that many bytes of
//! JSON. Descriptors (`SCM_RIGHTS`) ride on the first byte of a frame, so one
//! `recvmsg` of the header collects them.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");

/// Requests carry command text; 16 MiB is far beyond any real script.
pub const max_frame: u32 = 16 << 20;
/// The most descriptors one frame carries: a connection and three stdio.
pub const max_fds = 4;

pub const FrameError = error{ FrameTooLarge, Truncated, ReadFailed } || std.mem.Allocator.Error;

fn header(len: usize) [4]u8 {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, @intCast(len), .little);
    return bytes;
}

/// The body length a header announces.
fn frameLength(bytes: [4]u8) error{FrameTooLarge}!u32 {
    const len = std.mem.readInt(u32, &bytes, .little);
    if (len > max_frame) return error.FrameTooLarge;
    return len;
}

const cmsg_header_len = @sizeOf(linux.cmsghdr);
const control_len = cmsg_header_len + std.mem.alignForward(usize, max_fds * @sizeOf(i32), @sizeOf(usize));

/// Sends one frame, passing `fds` along with it. False when the peer is gone.
pub fn send(fd: i32, body: []const u8, fds: []const i32) bool {
    std.debug.assert(fds.len <= max_fds);
    if (body.len > max_frame) return false;
    const head = header(body.len);
    const iov = [_]std.posix.iovec_const{
        .{ .base = &head, .len = head.len },
        .{ .base = body.ptr, .len = body.len },
    };
    var control: [control_len]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = iov.len,
        .control = null,
        .controllen = 0,
        .flags = 0,
    };
    if (fds.len != 0) {
        const data_len = fds.len * @sizeOf(i32);
        const cmsg: *linux.cmsghdr = @ptrCast(&control);
        cmsg.* = .{ .len = cmsg_header_len + data_len, .level = linux.SOL.SOCKET, .type = linux.SCM.RIGHTS };
        @memcpy(control[cmsg_header_len..][0..data_len], std.mem.sliceAsBytes(fds));
        msg.control = &control;
        msg.controllen = cmsg_header_len + std.mem.alignForward(usize, data_len, @sizeOf(usize));
    }
    var sent: usize = 0;
    while (true) {
        const rc = linux.sendmsg(fd, &msg, linux.MSG.NOSIGNAL);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                sent = rc;
                break;
            },
            .INTR => continue,
            else => return false,
        }
    }
    // The descriptors went with the first bytes; the rest is plain data.
    const total = head.len + body.len;
    if (sent < head.len) {
        if (sys.writeAll(fd, head[sent..]) != .ok) return false;
        sent = head.len;
    }
    if (sent < total) return sys.writeAll(fd, body[sent - head.len ..]) == .ok;
    return true;
}

pub const Frame = struct {
    body: []u8,
    fds: [max_fds]i32 = undefined,
    fd_count: usize = 0,

    pub fn passed(self: *const Frame) []const i32 {
        return self.fds[0..self.fd_count];
    }

    /// Closes every descriptor the frame brought.
    pub fn closeFds(self: *Frame) void {
        for (self.fds[0..self.fd_count]) |fd| _ = linux.close(fd);
        self.fd_count = 0;
    }
};

/// Receives one frame. Null on a clean end of stream before a header.
/// Received descriptors are close-on-exec.
pub fn recv(fd: i32, arena: std.mem.Allocator) FrameError!?Frame {
    var head: [4]u8 = undefined;
    var control: [control_len]u8 align(@alignOf(linux.cmsghdr)) = undefined;
    var iov = [_]std.posix.iovec{.{ .base = &head, .len = head.len }};
    var msg = linux.msghdr{
        .name = null,
        .namelen = 0,
        .iov = &iov,
        .iovlen = 1,
        .control = &control,
        .controllen = control.len,
        .flags = 0,
    };
    var got: usize = 0;
    while (true) {
        const rc = linux.recvmsg(fd, &msg, linux.MSG.CMSG_CLOEXEC);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                got = rc;
                break;
            },
            .INTR => continue,
            else => return error.ReadFailed,
        }
    }
    var frame = Frame{ .body = &.{} };
    collectFds(&msg, &frame);
    errdefer frame.closeFds();
    if (got == 0) {
        frame.closeFds();
        return null;
    }
    if (msg.flags & linux.MSG.CTRUNC != 0) return error.Truncated;
    if (got < head.len and sys.readAll(fd, head[got..]) != head.len - got) return error.Truncated;
    const len = try frameLength(head);
    frame.body = try arena.alloc(u8, len);
    if (sys.readAll(fd, frame.body) != len) return error.Truncated;
    return frame;
}

fn collectFds(msg: *const linux.msghdr, frame: *Frame) void {
    const control: [*]const u8 = @ptrCast(msg.control orelse return);
    var offset: usize = 0;
    while (offset + cmsg_header_len <= msg.controllen) {
        const cmsg: *align(1) const linux.cmsghdr = @ptrCast(control + offset);
        if (cmsg.len < cmsg_header_len or offset + cmsg.len > msg.controllen) return;
        if (cmsg.level == linux.SOL.SOCKET and cmsg.type == linux.SCM.RIGHTS) {
            const count = (cmsg.len - cmsg_header_len) / @sizeOf(i32);
            for (0..count) |index| {
                var fd: i32 = undefined;
                @memcpy(std.mem.asBytes(&fd), (control + offset + cmsg_header_len + index * @sizeOf(i32))[0..@sizeOf(i32)]);
                if (frame.fd_count < max_fds) {
                    frame.fds[frame.fd_count] = fd;
                    frame.fd_count += 1;
                } else _ = linux.close(fd);
            }
        }
        offset += std.mem.alignForward(usize, cmsg.len, @sizeOf(usize));
    }
}

/// Serialises `value` as JSON and sends it as one frame.
pub fn sendJson(fd: i32, arena: std.mem.Allocator, value: anytype, fds: []const i32) bool {
    const body = std.json.Stringify.valueAlloc(arena, value, .{}) catch return false;
    return send(fd, body, fds);
}

/// Parses a frame body, ignoring fields this version does not know.
pub fn parseJson(comptime T: type, arena: std.mem.Allocator, body: []const u8) ?T {
    return std.json.parseFromSliceLeaky(T, arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch null;
}

fn unixAddress(path: []const u8) ?linux.sockaddr.un {
    var addr = linux.sockaddr.un{ .path = undefined };
    if (path.len >= addr.path.len) return null;
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    return addr;
}

pub const ConnectError = error{ NoDaemon, PathTooLong, SocketFailed };

/// Connects a stream socket to `path`. `NoDaemon` covers a missing socket
/// file and one nobody listens on.
pub fn connect(path: []const u8) ConnectError!i32 {
    const addr = unixAddress(path) orelse return error.PathTooLong;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return error.SocketFailed;
    const fd: i32 = @intCast(rc);
    while (true) {
        switch (linux.errno(linux.connect(fd, &addr, @sizeOf(linux.sockaddr.un)))) {
            .SUCCESS => return fd,
            .INTR => continue,
            else => {
                _ = linux.close(fd);
                return error.NoDaemon;
            },
        }
    }
}

/// A listening stream socket at `path`, mode 0600. A stale file must be
/// removed first.
pub fn listen(path: [:0]const u8) ?i32 {
    const addr = unixAddress(path) orelse return null;
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    // The umask decides the socket file's mode at bind time.
    const previous = sys.umask(0o177);
    const bound = linux.errno(linux.bind(fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.un))) == .SUCCESS;
    _ = sys.umask(previous);
    if (!bound or linux.errno(linux.listen(fd, 64)) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

const Ucred = extern struct { pid: i32, uid: u32, gid: u32 };

/// The uid of the process at the other end of a Unix socket.
pub fn peerUid(fd: i32) ?u32 {
    var cred: Ucred = undefined;
    var len: linux.socklen_t = @sizeOf(Ucred);
    const rc = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.PEERCRED, std.mem.asBytes(&cred), &len);
    if (linux.errno(rc) != .SUCCESS or len != @sizeOf(Ucred)) return null;
    return cred.uid;
}

/// Bounds how long a read on `fd` may block, so one stalled client cannot
/// hold up the daemon.
pub fn setReceiveTimeout(fd: i32, ms: u32) void {
    const tv = linux.timeval{ .sec = @intCast(ms / 1000), .usec = @intCast((ms % 1000) * 1000) };
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.RCVTIMEO, std.mem.asBytes(&tv), @sizeOf(linux.timeval));
}

const testing = std.testing;

test "frame headers carry a bounded length" {
    try testing.expectEqual(@as(u32, 5), try frameLength(header(5)));
    try testing.expectEqualSlices(u8, &.{ 0x05, 0x01, 0, 0 }, &header(261));
    try testing.expectEqual(@as(u32, max_frame), try frameLength(header(max_frame)));
    var too_big: [4]u8 = undefined;
    std.mem.writeInt(u32, &too_big, max_frame + 1, .little);
    try testing.expectError(error.FrameTooLarge, frameLength(too_big));
}

test "frames and descriptors cross a socket pair" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var pair: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)));
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);
    var pipe: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&pipe, .{ .CLOEXEC = true })));
    defer _ = linux.close(pipe[0]);

    try testing.expect(sendJson(pair[0], arena, .{ .op = "exec", .name = "w" }, &.{pipe[1]}));
    _ = linux.close(pipe[1]);
    try testing.expect(send(pair[0], "second", &.{}));

    var first = (try recv(pair[1], arena)).?;
    try testing.expectEqual(@as(usize, 1), first.fd_count);
    const Request = struct { op: []const u8, name: ?[]const u8 = null, source: ?[]const u8 = null };
    const request = parseJson(Request, arena, first.body).?;
    try testing.expectEqualStrings("exec", request.op);
    try testing.expectEqualStrings("w", request.name.?);
    try testing.expect(request.source == null);

    // The passed descriptor is the pipe's write end.
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(first.fds[0], "via fd"));
    first.closeFds();
    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("via fd", buf[0..sys.readAll(pipe[0], &buf)]);

    const second = (try recv(pair[1], arena)).?;
    try testing.expectEqual(@as(usize, 0), second.fd_count);
    try testing.expectEqualStrings("second", second.body);

    _ = linux.shutdown(pair[0], linux.SHUT.WR);
    try testing.expect((try recv(pair[1], arena)) == null);
}

test "a truncated frame is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var pair: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)));
    defer _ = linux.close(pair[1]);
    const head = header(10);
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(pair[0], &head));
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(pair[0], "abc"));
    _ = linux.close(pair[0]);
    try testing.expectError(error.Truncated, recv(pair[1], arena_state.allocator()));
}
