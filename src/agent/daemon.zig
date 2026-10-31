//! `wsh --daemon`: one per user, started on first `session` use.
//!
//! It listens on `<state>/daemon.sock` (mode 0600, and the peer's uid must
//! match), forks a host process per session and routes requests to it. It
//! supervises nothing and restarts nothing: runs keep their own supervisors
//! and their state on disk, so a daemon that dies loses no run. Sessions are
//! the daemon's children, as panes are a tmux server's, and end with it.
//! Once a minute it expires finished runs and idle sessions; it exits after
//! ten minutes with no session, no running run and no client.
//!
//! The daemon never blocks on a session: frames for a host or a terminal
//! relay wait in a queue, and the poll loop sends them as the socket drains.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");
const state = @import("state.zig");
const wire = @import("wire.zig");
const runs = @import("runs.zig");
const sessions = @import("sessions.zig");

const Context = state.Context;

/// A request from a client. Which fields matter depends on `op`.
pub const Request = struct {
    op: []const u8,
    name: ?[]const u8 = null,
    source: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    env: ?[]const []const u8 = null,
    rows: ?u16 = null,
    cols: ?u16 = null,
    signal: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    name: []const u8,
    pid: i32,
    cwd: []const u8,
    created_ms: i64,
    last_used_ms: i64,
    busy: bool,
};

pub const Reply = struct {
    ok: bool,
    @"error": ?[]const u8 = null,
    status: ?u8 = null,
    sessions: ?[]const SessionInfo = null,
};

/// A message from a host to the daemon. `done` ends a routed request,
/// `cwd` reports a new directory, and `relay` brings the socket of the
/// session's terminal relay, which takes later attaches.
pub const HostMessage = struct {
    op: []const u8,
    cwd: ?[]const u8 = null,
};

/// Default idle time before the daemon exits: 10 minutes, or
/// `WSH_DAEMON_IDLE` seconds.
const default_idle_s: i64 = 600;

/// Frames waiting until a host or relay socket can take them.
const Queue = struct {
    items: std.ArrayList(Pending) = .empty,

    const Pending = struct {
        bytes: []u8,
        fds: [wire.max_fds]i32,
        fd_count: usize,
        sent: usize = 0,
    };

    /// Queues `body` as a frame. The queue owns `fds` from here on.
    fn push(self: *Queue, gpa: std.mem.Allocator, body: []const u8, fds: []const i32) !void {
        var item = Pending{ .bytes = try wire.encodeFrame(gpa, body), .fds = undefined, .fd_count = fds.len };
        errdefer gpa.free(item.bytes);
        @memcpy(item.fds[0..fds.len], fds);
        try self.items.append(gpa, item);
    }

    /// Sends what the socket takes now. False when the peer is gone.
    fn drain(self: *Queue, gpa: std.mem.Allocator, fd: i32) bool {
        while (self.items.items.len != 0) {
            const item = &self.items.items[0];
            const fds = if (item.sent == 0) item.fds[0..item.fd_count] else &.{};
            const n = wire.sendNow(fd, item.bytes[item.sent..], fds) catch |e| return e == error.WouldBlock;
            item.sent += n;
            if (item.sent < item.bytes.len) continue;
            // The receiver has its own copies now.
            for (item.fds[0..item.fd_count]) |passed| _ = linux.close(passed);
            gpa.free(item.bytes);
            _ = self.items.orderedRemove(0);
        }
        return true;
    }

    fn pending(self: *const Queue) bool {
        return self.items.items.len != 0;
    }

    /// Drops every frame. Closing a client's connection tells it the
    /// session went away.
    fn clear(self: *Queue, gpa: std.mem.Allocator) void {
        for (self.items.items) |item| {
            for (item.fds[0..item.fd_count]) |passed| _ = linux.close(passed);
            gpa.free(item.bytes);
        }
        self.items.deinit(gpa);
        self.items = .empty;
    }
};

const Session = struct {
    name: []const u8,
    /// The host's current directory, as it last reported.
    cwd: []const u8,
    pid: i32,
    /// The daemon's end of the socket pair to the host process.
    ctl: i32,
    /// The socket to the session's terminal relay, once one was attached.
    relay: i32 = -1,
    to_host: Queue = .{},
    to_relay: Queue = .{},
    /// Requests routed to the host that it has not finished yet.
    busy: u32 = 0,
    created_ms: i64,
    last_used_ms: i64,
    /// Set by `session kill`; the entry goes once the host is reaped.
    dying: bool = false,
    /// The host is gone; the entry goes at the end of this poll round.
    ended: bool = false,
};

const Daemon = struct {
    gpa: std.mem.Allocator,
    envp: [*:null]const ?[*:0]const u8,
    root: [:0]const u8,
    runs_dir: [:0]const u8,
    sessions_dir: [:0]const u8,
    listen_fd: i32,
    sessions: std.ArrayList(Session) = .empty,
    last_activity_ms: i64,
    run_ttl_ms: i64,
    session_ttl_ms: i64,
    idle_ms: i64,

    fn find(self: *Daemon, name: []const u8) ?*Session {
        for (self.sessions.items) |*session| {
            if (!session.dying and !session.ended and std.mem.eql(u8, session.name, name)) return session;
        }
        return null;
    }

    fn sessionDir(self: *Daemon, arena: std.mem.Allocator, name: []const u8) ?[:0]const u8 {
        return std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ self.sessions_dir, name }, 0) catch null;
    }
};

pub fn main(ctx: Context) u8 {
    const gpa = ctx.gpa;
    const root = state.ensureDir(ctx, "daemon") orelse return 1;
    const sessions_dir = state.ensureSubdir(ctx, root, "sessions", "daemon") orelse return 1;
    const runs_dir = std.fmt.allocPrintSentinel(ctx.arena, "{s}/runs", .{root}, 0) catch return 1;

    // One daemon per state directory: the lock decides, and it is released
    // only when the holder exits, however it exits.
    const lock_path = std.fmt.allocPrintSentinel(ctx.arena, "{s}/daemon.lock", .{root}, 0) catch return 1;
    const lock_rc = linux.openat(linux.AT.FDCWD, lock_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(lock_rc) != .SUCCESS) {
        ctx.errFmt("wsh: daemon: {s}: cannot open the lock file\n", .{lock_path});
        return 1;
    }
    const lock_fd: i32 = @intCast(lock_rc);
    if (!state.tryLock(lock_fd)) return 0;

    const sock_path = std.fmt.allocPrintSentinel(ctx.arena, "{s}/daemon.sock", .{root}, 0) catch return 1;
    _ = linux.unlinkat(linux.AT.FDCWD, sock_path.ptr, 0);
    const listen_fd = wire.listen(sock_path) orelse {
        ctx.errFmt("wsh: daemon: {s}: cannot listen\n", .{sock_path});
        return 1;
    };
    const pid_path = std.fmt.allocPrint(ctx.arena, "{s}/daemon.pid", .{root}) catch return 1;
    _ = state.writeAtomic(ctx.arena, pid_path, std.fmt.allocPrint(ctx.arena, "{d}\n", .{linux.getpid()}) catch return 1);

    var ignore = std.mem.zeroes(linux.Sigaction);
    ignore.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.PIPE, &ignore, null);
    _ = linux.sigaction(.HUP, &ignore, null);

    var self = Daemon{
        .gpa = gpa,
        .envp = ctx.envp,
        .root = root,
        .runs_dir = runs_dir,
        .sessions_dir = sessions_dir,
        .listen_fd = listen_fd,
        .last_activity_ms = state.monotonicMs(),
        .run_ttl_ms = state.envSeconds(ctx.envp, "WSH_RUN_TTL", runs.default_ttl_s) * 1000,
        .session_ttl_ms = state.envSeconds(ctx.envp, "WSH_SESSION_TTL", sessions.default_ttl_s) * 1000,
        .idle_ms = state.envSeconds(ctx.envp, "WSH_DAEMON_IDLE", default_idle_s) * 1000,
    };
    // Sessions lived in the previous daemon; whatever is on disk is stale.
    clearStaleSessions(&self, ctx.arena);
    serve(&self);
    _ = linux.unlinkat(linux.AT.FDCWD, sock_path.ptr, 0);
    _ = linux.unlinkat(linux.AT.FDCWD, (ctx.arena.dupeZ(u8, pid_path) catch return 0).ptr, 0);
    return 0;
}

fn clearStaleSessions(self: *Daemon, arena: std.mem.Allocator) void {
    var dir = fs.openDir(self.sessions_dir) orelse return;
    defer dir.close();
    while (dir.next()) |entry| {
        const path = self.sessionDir(arena, entry.name) orelse continue;
        _ = state.removeTree(arena, path);
    }
}

/// Seconds between housekeeping passes: a minute, or less when a short TTL
/// asks for it.
fn sweepInterval(self: *const Daemon) i64 {
    return std.math.clamp(@divTrunc(@min(self.run_ttl_ms, self.session_ttl_ms), 2), 1000, 60_000);
}

/// What a polled descriptor belongs to.
const Target = struct { session: usize, relay: bool };

fn serve(self: *Daemon) void {
    var next_sweep = state.monotonicMs();
    var pollfds: std.ArrayList(linux.pollfd) = .empty;
    defer pollfds.deinit(self.gpa);
    var targets: std.ArrayList(Target) = .empty;
    defer targets.deinit(self.gpa);
    while (true) {
        const now = state.monotonicMs();
        if (now >= next_sweep) {
            housekeeping(self);
            next_sweep = now + sweepInterval(self);
        }
        if (self.sessions.items.len == 0 and now - self.last_activity_ms >= self.idle_ms and !anyRunning(self)) return;

        pollfds.clearRetainingCapacity();
        targets.clearRetainingCapacity();
        pollfds.append(self.gpa, .{ .fd = self.listen_fd, .events = linux.POLL.IN, .revents = 0 }) catch return;
        targets.append(self.gpa, undefined) catch return;
        for (self.sessions.items, 0..) |session, index| {
            const host_events: i16 = linux.POLL.IN | (if (session.to_host.pending()) @as(i16, linux.POLL.OUT) else 0);
            pollfds.append(self.gpa, .{ .fd = session.ctl, .events = host_events, .revents = 0 }) catch return;
            targets.append(self.gpa, .{ .session = index, .relay = false }) catch return;
            if (session.relay < 0) continue;
            const relay_events: i16 = linux.POLL.IN | (if (session.to_relay.pending()) @as(i16, linux.POLL.OUT) else 0);
            pollfds.append(self.gpa, .{ .fd = session.relay, .events = relay_events, .revents = 0 }) catch return;
            targets.append(self.gpa, .{ .session = index, .relay = true }) catch return;
        }
        // Past the idle deadline with runs still going, the sweeps recheck.
        var timeout = next_sweep - now;
        const idle_deadline = self.last_activity_ms + self.idle_ms;
        if (self.sessions.items.len == 0 and idle_deadline > now) timeout = @min(timeout, idle_deadline - now);
        const rc = linux.poll(pollfds.items.ptr, @intCast(pollfds.items.len), @intCast(@max(timeout, 0)));
        if (linux.errno(rc) != .SUCCESS) continue;

        // Session events first, so a host's report (a new directory, say)
        // lands before a client that waited for that host is answered.
        for (pollfds.items[1..], targets.items[1..]) |polled, target| {
            if (polled.revents == 0) continue;
            const session = &self.sessions.items[target.session];
            if (target.relay) relayEvent(self, session, polled.revents) else hostEvent(self, session, polled.revents);
        }
        var index = self.sessions.items.len;
        while (index > 0) {
            index -= 1;
            if (self.sessions.items[index].ended) endSession(self, index);
        }
        if (pollfds.items[0].revents & linux.POLL.IN != 0) {
            const conn_rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(conn_rc) == .SUCCESS) {
                const conn: i32 = @intCast(conn_rc);
                if (!handleClient(self, conn)) _ = linux.close(conn);
                self.last_activity_ms = state.monotonicMs();
            }
        }
        // Hosts are reaped when their socket closes; this catches anything else.
        while (proc.waitPid(-1, linux.W.NOHANG)) |_| {}
    }
}

fn anyRunning(self: *Daemon) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    for (runs.loadAll(arena_state.allocator(), self.runs_dir)) |run| {
        if (run.state == .running) return true;
    }
    return false;
}

fn housekeeping(self: *Daemon) void {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    _ = runs.sweep(arena_state.allocator(), self.runs_dir, self.run_ttl_ms, true);
    const now = state.nowMs();
    for (self.sessions.items) |*session| {
        if (session.dying or session.busy != 0 or session.to_host.pending()) continue;
        if (now - session.last_used_ms >= self.session_ttl_ms) stopSession(self, arena_state.allocator(), session);
    }
}

fn hostEvent(self: *Daemon, session: *Session, revents: i16) void {
    if (revents & linux.POLL.OUT != 0 and !session.to_host.drain(self.gpa, session.ctl)) {
        session.ended = true;
        return;
    }
    if (revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0 and !hostMessage(self, session)) session.ended = true;
}

/// Reads one report from a host. False when the host closed its socket,
/// which it does only by exiting.
fn hostMessage(self: *Daemon, session: *Session) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var frame = (wire.recv(session.ctl, arena) catch return false) orelse return false;
    defer frame.closeFds();
    const message = wire.parseJson(HostMessage, arena, frame.body) orelse return true;
    if (message.cwd) |cwd| setCwd(self, arena, session, cwd);
    if (std.mem.eql(u8, message.op, "done")) {
        session.busy -|= 1;
        session.last_used_ms = state.nowMs();
    } else if (std.mem.eql(u8, message.op, "relay") and frame.fd_count == 1) {
        dropRelay(self, session);
        session.relay = frame.fds[0];
        frame.fd_count = 0;
    }
    return true;
}

fn setCwd(self: *Daemon, arena: std.mem.Allocator, session: *Session, cwd: []const u8) void {
    if (std.mem.eql(u8, session.cwd, cwd)) return;
    const owned = self.gpa.dupe(u8, cwd) catch return;
    self.gpa.free(session.cwd);
    session.cwd = owned;
    writeSessionMeta(self, arena, session.*);
}

fn relayEvent(self: *Daemon, session: *Session, revents: i16) void {
    // A relay never writes to the daemon: readable means it exited.
    if (revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0) return dropRelay(self, session);
    if (revents & linux.POLL.OUT != 0 and !session.to_relay.drain(self.gpa, session.relay)) dropRelay(self, session);
}

fn dropRelay(self: *Daemon, session: *Session) void {
    if (session.relay < 0) return;
    session.to_relay.clear(self.gpa);
    _ = linux.close(session.relay);
    session.relay = -1;
}

fn endSession(self: *Daemon, index: usize) void {
    const session = &self.sessions.items[index];
    // A host closes its socket only by exiting; make sure of it before the
    // blocking reap.
    _ = linux.kill(session.pid, .KILL);
    _ = proc.waitPid(session.pid, 0);
    dropRelay(self, session);
    session.to_host.clear(self.gpa);
    _ = linux.close(session.ctl);
    if (!session.dying) {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        if (self.sessionDir(arena_state.allocator(), session.name)) |dir| _ = state.removeTree(arena_state.allocator(), dir);
    }
    self.gpa.free(session.name);
    self.gpa.free(session.cwd);
    _ = self.sessions.swapRemove(index);
}

/// Hangs up every process of the session, as closing a terminal would, and
/// kills the host, which ignores SIGHUP. The host leads its own session.
fn stopSession(self: *Daemon, arena: std.mem.Allocator, session: *Session) void {
    state.signalSession(session.pid, session.pid, null, @intFromEnum(linux.SIG.HUP));
    _ = linux.kill(session.pid, .KILL);
    session.dying = true;
    if (self.sessionDir(arena, session.name)) |dir| _ = state.removeTree(arena, dir);
}

fn reply(conn: i32, arena: std.mem.Allocator, value: Reply) void {
    _ = wire.sendJson(conn, arena, value, &.{});
}

/// Answers or routes one client request. True when the connection went to
/// a session, which then owns it.
fn handleClient(self: *Daemon, conn: i32) bool {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The socket's mode already keeps other users out; the uid check holds
    // even if the directory or socket permissions were loosened.
    if (wire.peerUid(conn) != linux.getuid()) {
        reply(conn, arena, .{ .ok = false, .@"error" = "permission denied" });
        return false;
    }
    wire.setReceiveTimeout(conn, 5000);
    var frame = (wire.recv(conn, arena) catch return false) orelse return false;
    defer frame.closeFds();
    const req = wire.parseJson(Request, arena, frame.body) orelse {
        reply(conn, arena, .{ .ok = false, .@"error" = "malformed request" });
        return false;
    };
    if (std.mem.eql(u8, req.op, "ping")) {
        reply(conn, arena, .{ .ok = true });
        return false;
    }
    if (std.mem.eql(u8, req.op, "ls")) {
        listSessions(self, conn, arena);
        return false;
    }

    const name = req.name orelse {
        reply(conn, arena, .{ .ok = false, .@"error" = "missing session name" });
        return false;
    };
    if (!state.validName(name)) {
        reply(conn, arena, .{ .ok = false, .@"error" = "invalid session name" });
        return false;
    }
    if (std.mem.eql(u8, req.op, "new")) {
        newSession(self, conn, arena, name, req);
        return false;
    }

    const session = self.find(name) orelse {
        reply(conn, arena, .{ .ok = false, .@"error" = "no such session" });
        return false;
    };
    if (std.mem.eql(u8, req.op, "exec") or std.mem.eql(u8, req.op, "attach")) {
        // The host, or for a second attach the terminal relay, gets the
        // client's connection with the request and answers on it; the daemon
        // is out of the path from here on.
        const to_relay = std.mem.eql(u8, req.op, "attach") and session.relay >= 0;
        var fds: [wire.max_fds]i32 = undefined;
        fds[0] = conn;
        const passed = frame.passed();
        const count: usize = @min(passed.len, wire.max_fds - 1);
        @memcpy(fds[1 .. 1 + count], passed[0..count]);
        const queue = if (to_relay) &session.to_relay else &session.to_host;
        queue.push(self.gpa, frame.body, fds[0 .. 1 + count]) catch {
            reply(conn, arena, .{ .ok = false, .@"error" = "out of memory" });
            return false;
        };
        frame.fd_count = 0;
        if (!to_relay) session.busy += 1;
        session.last_used_ms = state.nowMs();
        // Whatever the socket does not take now, the poll loop sends later.
        if (to_relay) {
            if (!queue.drain(self.gpa, session.relay)) dropRelay(self, session);
        } else if (!queue.drain(self.gpa, session.ctl)) session.ended = true;
        return true;
    }
    if (std.mem.eql(u8, req.op, "kill")) {
        stopSession(self, arena, session);
        reply(conn, arena, .{ .ok = true });
        return false;
    }
    if (std.mem.eql(u8, req.op, "signal")) {
        const sig = proc.signalFromName(req.signal orelse "INT") orelse {
            reply(conn, arena, .{ .ok = false, .@"error" = "invalid signal" });
            return false;
        };
        _ = proc.sendSignal(-session.pid, @intFromEnum(sig));
        reply(conn, arena, .{ .ok = true });
        return false;
    }
    reply(conn, arena, .{ .ok = false, .@"error" = "unknown request" });
    return false;
}

fn listSessions(self: *Daemon, conn: i32, arena: std.mem.Allocator) void {
    var infos: std.ArrayList(SessionInfo) = .empty;
    for (self.sessions.items) |session| {
        if (session.dying or session.ended) continue;
        infos.append(arena, .{
            .name = session.name,
            .pid = session.pid,
            .cwd = session.cwd,
            .created_ms = session.created_ms,
            .last_used_ms = session.last_used_ms,
            .busy = session.busy != 0,
        }) catch return;
    }
    std.mem.sort(SessionInfo, infos.items, {}, struct {
        fn lessThan(_: void, a: SessionInfo, b: SessionInfo) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    reply(conn, arena, .{ .ok = true, .sessions = infos.items });
}

fn writeSessionMeta(self: *Daemon, arena: std.mem.Allocator, session: Session) void {
    const dir = self.sessionDir(arena, session.name) orelse return;
    const meta_path = std.fmt.allocPrint(arena, "{s}/meta.json", .{dir}) catch return;
    const meta = std.json.Stringify.valueAlloc(arena, .{ .name = session.name, .pid = session.pid, .cwd = session.cwd, .created_ms = session.created_ms }, .{}) catch return;
    _ = state.writeAtomic(arena, meta_path, meta);
}

fn newSession(self: *Daemon, conn: i32, arena: std.mem.Allocator, name: []const u8, req: Request) void {
    if (self.find(name) != null) return reply(conn, arena, .{ .ok = false, .@"error" = "already exists" });
    const cwd = req.cwd orelse "/";
    const cwd_z = arena.dupeZ(u8, cwd) catch return;
    if (!fs.isDir(cwd_z)) return reply(conn, arena, .{ .ok = false, .@"error" = "the working directory does not exist" });
    const dir = self.sessionDir(arena, name) orelse return;
    if (linux.errno(linux.mkdirat(linux.AT.FDCWD, dir.ptr, 0o700)) != .SUCCESS) {
        return reply(conn, arena, .{ .ok = false, .@"error" = "cannot create the session directory" });
    }

    var pair: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)) != .SUCCESS) {
        _ = state.removeTree(arena, dir);
        return reply(conn, arena, .{ .ok = false, .@"error" = "cannot create a socket pair" });
    }
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(pair[0]);
        _ = linux.close(pair[1]);
        _ = state.removeTree(arena, dir);
        return reply(conn, arena, .{ .ok = false, .@"error" = "cannot fork" });
    }
    if (rc == 0) {
        // The host must not keep the daemon's lock, listening socket or the
        // other hosts' sockets: those would outlive the daemon in it.
        runs.keepOnly(&.{pair[1]});
        proc.resetSignals();
        sessions.host(self.gpa, pair[1], name, cwd, req.env orelse &.{});
    }
    _ = linux.close(pair[1]);
    const now = state.nowMs();
    const owned_name = self.gpa.dupe(u8, name) catch return;
    const owned_cwd = self.gpa.dupe(u8, cwd) catch return;
    self.sessions.append(self.gpa, .{
        .name = owned_name,
        .cwd = owned_cwd,
        .pid = @intCast(rc),
        .ctl = pair[0],
        .created_ms = now,
        .last_used_ms = now,
    }) catch return;
    writeSessionMeta(self, arena, self.sessions.items[self.sessions.items.len - 1]);
    reply(conn, arena, .{ .ok = true });
}

test "a queue sends what a full socket takes and keeps the rest" {
    const testing = std.testing;
    var pair: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &pair)));
    defer _ = linux.close(pair[0]);
    defer _ = linux.close(pair[1]);

    const body = try testing.allocator.alloc(u8, 1 << 20);
    defer testing.allocator.free(body);
    @memset(body, 'x');
    var queue = Queue{};
    defer queue.clear(testing.allocator);
    try queue.push(testing.allocator, body, &.{});
    try queue.push(testing.allocator, "small", &.{});
    // Nobody reads yet: the first frame stays partly sent, and nothing blocks.
    try testing.expect(queue.drain(testing.allocator, pair[0]));
    try testing.expect(queue.pending());

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var received: std.ArrayList(u8) = .empty;
    var buf: [65536]u8 = undefined;
    while (true) {
        try testing.expect(queue.drain(testing.allocator, pair[0]));
        var fds = [_]linux.pollfd{.{ .fd = pair[1], .events = linux.POLL.IN, .revents = 0 }};
        if (!queue.pending() and linux.poll(&fds, 1, 0) == 0) break;
        const n = sys.readSome(pair[1], &buf) orelse break;
        try received.appendSlice(arena, buf[0..n]);
    }
    try testing.expectEqual(@as(usize, 4 + body.len + 4 + 5), received.items.len);
    try testing.expect(std.mem.endsWith(u8, received.items, "small"));
}
