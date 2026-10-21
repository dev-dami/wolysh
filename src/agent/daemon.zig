//! `wsh --daemon`: one per user, started on first `session` use.
//!
//! It listens on `<state>/daemon.sock` (mode 0600, and the peer's uid must
//! match), forks a host process per session and routes requests to it. It
//! supervises nothing and restarts nothing: runs keep their own supervisors
//! and their state on disk, so a daemon that dies loses no run. Sessions are
//! the daemon's children, as panes are a tmux server's, and end with it.
//! Once a minute it expires finished runs and idle sessions; it exits after
//! ten minutes with no session, no running run and no client.

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

/// Default idle time before the daemon exits: 10 minutes, or
/// `WSH_DAEMON_IDLE` seconds.
const default_idle_s: i64 = 600;

const Session = struct {
    name: []const u8,
    cwd: []const u8,
    pid: i32,
    /// The daemon's end of the socket pair to the host process.
    ctl: i32,
    /// Requests routed to the host that it has not finished yet.
    busy: u32 = 0,
    created_ms: i64,
    last_used_ms: i64,
    /// Set by `session kill`; the entry goes once the host is reaped.
    dying: bool = false,
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
            if (!session.dying and std.mem.eql(u8, session.name, name)) return session;
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

fn serve(self: *Daemon) void {
    var next_sweep = state.monotonicMs();
    var pollfds: std.ArrayList(linux.pollfd) = .empty;
    defer pollfds.deinit(self.gpa);
    while (true) {
        const now = state.monotonicMs();
        if (now >= next_sweep) {
            housekeeping(self);
            next_sweep = now + sweepInterval(self);
        }
        if (self.sessions.items.len == 0 and now - self.last_activity_ms >= self.idle_ms and !anyRunning(self)) return;

        pollfds.clearRetainingCapacity();
        pollfds.append(self.gpa, .{ .fd = self.listen_fd, .events = linux.POLL.IN, .revents = 0 }) catch return;
        for (self.sessions.items) |session| {
            pollfds.append(self.gpa, .{ .fd = session.ctl, .events = linux.POLL.IN, .revents = 0 }) catch return;
        }
        // Past the idle deadline with runs still going, the sweeps recheck.
        var timeout = next_sweep - now;
        const idle_deadline = self.last_activity_ms + self.idle_ms;
        if (self.sessions.items.len == 0 and idle_deadline > now) timeout = @min(timeout, idle_deadline - now);
        const rc = linux.poll(pollfds.items.ptr, @intCast(pollfds.items.len), @intCast(@max(timeout, 0)));
        if (linux.errno(rc) != .SUCCESS) continue;

        // Session events first: their indexes still match `pollfds`.
        var index = self.sessions.items.len;
        while (index > 0) {
            index -= 1;
            if (pollfds.items[index + 1].revents != 0) sessionEvent(self, index);
        }
        if (pollfds.items[0].revents & linux.POLL.IN != 0) {
            const conn_rc = linux.accept4(self.listen_fd, null, null, linux.SOCK.CLOEXEC);
            if (linux.errno(conn_rc) == .SUCCESS) {
                const conn: i32 = @intCast(conn_rc);
                handleClient(self, conn);
                _ = linux.close(conn);
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
        if (session.dying or session.busy != 0) continue;
        if (now - session.last_used_ms >= self.session_ttl_ms) stopSession(self, arena_state.allocator(), session);
    }
}

/// The host reported finished requests, or closed its socket by exiting.
fn sessionEvent(self: *Daemon, index: usize) void {
    const session = &self.sessions.items[index];
    var buf: [64]u8 = undefined;
    const rc = linux.read(session.ctl, &buf, buf.len);
    if (linux.errno(rc) == .SUCCESS and rc > 0) {
        session.busy -|= @intCast(rc);
        session.last_used_ms = state.nowMs();
        return;
    }
    if (linux.errno(rc) == .INTR or linux.errno(rc) == .AGAIN) return;
    _ = proc.waitPid(session.pid, 0);
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

fn handleClient(self: *Daemon, conn: i32) void {
    var arena_state = std.heap.ArenaAllocator.init(self.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The socket's mode already keeps other users out; the uid check holds
    // even if the directory or socket permissions were loosened.
    if (wire.peerUid(conn) != linux.getuid()) {
        reply(conn, arena, .{ .ok = false, .@"error" = "permission denied" });
        return;
    }
    wire.setReceiveTimeout(conn, 5000);
    var frame = (wire.recv(conn, arena) catch return) orelse return;
    defer frame.closeFds();
    const req = wire.parseJson(Request, arena, frame.body) orelse {
        reply(conn, arena, .{ .ok = false, .@"error" = "malformed request" });
        return;
    };
    if (std.mem.eql(u8, req.op, "ping")) return reply(conn, arena, .{ .ok = true });
    if (std.mem.eql(u8, req.op, "ls")) return listSessions(self, conn, arena);

    const name = req.name orelse return reply(conn, arena, .{ .ok = false, .@"error" = "missing session name" });
    if (!state.validName(name)) return reply(conn, arena, .{ .ok = false, .@"error" = "invalid session name" });
    if (std.mem.eql(u8, req.op, "new")) return newSession(self, conn, arena, name, req);

    const session = self.find(name) orelse return reply(conn, arena, .{ .ok = false, .@"error" = "no such session" });
    if (std.mem.eql(u8, req.op, "exec") or std.mem.eql(u8, req.op, "attach")) {
        // The host gets the client's connection with the request and
        // answers on it; the daemon is out of the path from here on.
        var fds: [wire.max_fds]i32 = undefined;
        fds[0] = conn;
        const passed = frame.passed();
        const count: usize = @min(passed.len, wire.max_fds - 1);
        @memcpy(fds[1 .. 1 + count], passed[0..count]);
        if (!wire.send(session.ctl, frame.body, fds[0 .. 1 + count])) {
            return reply(conn, arena, .{ .ok = false, .@"error" = "the session is not responding" });
        }
        session.busy += 1;
        session.last_used_ms = state.nowMs();
        return;
    }
    if (std.mem.eql(u8, req.op, "kill")) {
        stopSession(self, arena, session);
        return reply(conn, arena, .{ .ok = true });
    }
    if (std.mem.eql(u8, req.op, "signal")) {
        const sig = proc.signalFromName(req.signal orelse "INT") orelse return reply(conn, arena, .{ .ok = false, .@"error" = "invalid signal" });
        _ = proc.sendSignal(-session.pid, @intFromEnum(sig));
        return reply(conn, arena, .{ .ok = true });
    }
    reply(conn, arena, .{ .ok = false, .@"error" = "unknown request" });
}

fn listSessions(self: *Daemon, conn: i32, arena: std.mem.Allocator) void {
    var infos: std.ArrayList(SessionInfo) = .empty;
    for (self.sessions.items) |session| {
        if (session.dying) continue;
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
    const meta_path = std.fmt.allocPrint(arena, "{s}/meta.json", .{dir}) catch return;
    const meta = std.json.Stringify.valueAlloc(arena, .{ .name = name, .pid = @as(i32, @intCast(rc)), .cwd = cwd, .created_ms = now }, .{}) catch return;
    _ = state.writeAtomic(arena, meta_path, meta);
    reply(conn, arena, .{ .ok = true });
}
