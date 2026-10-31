//! `session`: named shells that outlive the caller.
//!
//! The daemon forks one host process per session and routes requests to it.
//! `session exec` passes the caller's stdin, stdout and stderr along with the
//! request, so the command reads and writes them directly with no copying,
//! and the host replies with the exit status on the caller's connection.
//! `session attach` gives the host a pseudo-terminal for the rest of its life
//! and runs the line editor on it. A relay process copies bytes between the
//! terminal and the attached caller, keeps the newest output while nobody is
//! attached, and replays it on the next attach, so a detached foreground
//! command keeps running, as in tmux.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");
const exec = @import("../exec.zig");
const strict = @import("../strict.zig");
const Shell = @import("../shell.zig").Shell;
const editor_mod = @import("../interactive/editor.zig");
const prompt = @import("../interactive/prompt.zig");
const term = @import("../interactive/term.zig");
const state = @import("state.zig");
const wire = @import("wire.zig");
const pty = @import("pty.zig");
const runs = @import("runs.zig");
const daemon = @import("daemon.zig");

const Context = state.Context;
const Request = daemon.Request;
const Reply = daemon.Reply;

const usage =
    \\usage: session new NAME
    \\       session ls [--json]
    \\       session exec NAME [--] command...
    \\       session attach NAME      (detach with Ctrl-\ then d)
    \\       session kill NAME
    \\
;

/// Default idle lifetime of a session: 12 hours, or `WSH_SESSION_TTL` seconds.
pub const default_ttl_s: i64 = 12 * 3600;

/// Status of `session exec` when the session ended before replying.
const ended_status: u8 = 125;

/// Ctrl-\ followed by `d` detaches from `session attach`.
const detach_prefix: u8 = 0x1c;

pub fn command(ctx: Context, argv: []const []const u8) u8 {
    if (argv.len < 2) return usageError(ctx);
    const sub = argv[1];
    const rest = argv[2..];
    if (eql(sub, "--help") or eql(sub, "-h")) {
        ctx.out(usage);
        return 0;
    }
    if (eql(sub, "new")) return new(ctx, rest);
    if (eql(sub, "ls")) return list(ctx, rest);
    if (eql(sub, "exec")) return execIn(ctx, rest);
    if (eql(sub, "attach")) return attach(ctx, rest);
    if (eql(sub, "kill")) return killSession(ctx, rest);
    ctx.errFmt("wsh: session: {s}: unknown subcommand\n", .{sub});
    return usageError(ctx);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(ctx: Context) u8 {
    ctx.err(usage);
    return 2;
}

fn checkName(ctx: Context, name: []const u8) bool {
    if (state.validName(name)) return true;
    ctx.errFmt("wsh: session: {s}: invalid session name\n", .{name});
    return false;
}

// --- talking to the daemon -----------------------------------------------------

/// Connects to the daemon. With `spawn`, starts one when none answers;
/// without, a missing daemon means there are no sessions.
fn connect(ctx: Context, spawn: bool) ?i32 {
    const root = if (spawn) (state.ensureDir(ctx, "session") orelse return null) else (state.dirPath(ctx.arena, ctx.envp) catch return null);
    const path = std.fmt.allocPrint(ctx.arena, "{s}/daemon.sock", .{root}) catch return null;
    if (wire.connect(path)) |fd| return fd else |e| switch (e) {
        error.NoDaemon => if (!spawn) return null,
        error.PathTooLong => {
            ctx.errFmt("wsh: session: {s}: socket path too long\n", .{path});
            return null;
        },
        error.SocketFailed => {
            ctx.err("wsh: session: cannot create a socket\n");
            return null;
        },
    }
    spawnDaemon(ctx);
    // The daemon binds its socket within milliseconds of starting.
    var delay: u64 = 1;
    var waited: u64 = 0;
    while (waited < 5000) : (waited += delay) {
        state.sleepMs(delay);
        if (wire.connect(path)) |fd| return fd else |_| {}
        delay = @min(delay * 2, 50);
    }
    ctx.err("wsh: session: cannot start the daemon\n");
    return null;
}

/// Starts `wsh --daemon` detached: in its own session, with no terminal
/// and none of the caller's descriptors.
fn spawnDaemon(ctx: Context) void {
    const argv = proc.buildArgv(ctx.arena, &.{ "wsh", "--daemon" }) catch return;
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) return;
    if (rc == 0) {
        _ = sys.setsid();
        const grandchild = linux.fork();
        if (grandchild == 0) {
            proc.resetSignals();
            runs.keepOnly(&.{});
            state.nullStdio();
            _ = linux.execve("/proc/self/exe", argv, ctx.envp);
            linux.exit(127);
        }
        linux.exit(0);
    }
    _ = proc.waitPid(@intCast(rc), 0);
}

/// Sends one request and reads its reply.
fn roundTrip(ctx: Context, fd: i32, req: Request, fds: []const i32) ?Reply {
    if (!wire.sendJson(fd, ctx.arena, req, fds)) {
        ctx.err("wsh: session: the daemon closed the connection\n");
        return null;
    }
    return readReply(ctx, fd);
}

fn readReply(ctx: Context, fd: i32) ?Reply {
    const frame = (wire.recv(fd, ctx.arena) catch null) orelse return null;
    return wire.parseJson(Reply, ctx.arena, frame.body);
}

/// Prints a refused request as `wsh: session: NAME: reason`.
fn refused(ctx: Context, name: []const u8, reply: Reply) u8 {
    ctx.errFmt("wsh: session: {s}: {s}\n", .{ name, reply.@"error" orelse "request failed" });
    return 1;
}

fn envList(ctx: Context) []const []const u8 {
    var entries: std.ArrayList([]const u8) = .empty;
    var index: usize = 0;
    while (ctx.envp[index]) |entry| : (index += 1) entries.append(ctx.arena, std.mem.span(entry)) catch break;
    return entries.items;
}

// --- client commands -----------------------------------------------------------

fn new(ctx: Context, args: []const []const u8) u8 {
    if (args.len != 1) return usageError(ctx);
    const name = args[0];
    if (!checkName(ctx, name)) return 2;
    const fd = connect(ctx, true) orelse return 1;
    defer sys.closeFd(fd);
    const reply = roundTrip(ctx, fd, .{ .op = "new", .name = name, .cwd = ctx.cwd, .env = envList(ctx) }, &.{}) orelse return 1;
    if (!reply.ok) return refused(ctx, name, reply);
    return 0;
}

fn list(ctx: Context, args: []const []const u8) u8 {
    var json = false;
    for (args) |arg| {
        if (eql(arg, "--json")) json = true else return usageError(ctx);
    }
    const fd = connect(ctx, false) orelse return 0;
    defer sys.closeFd(fd);
    const reply = roundTrip(ctx, fd, .{ .op = "ls" }, &.{}) orelse return 1;
    if (!reply.ok) {
        ctx.errFmt("wsh: session: {s}\n", .{reply.@"error" orelse "request failed"});
        return 1;
    }
    const all = reply.sessions orelse &.{};
    const now = state.nowMs();
    if (!json and all.len != 0) ctx.out("NAME             PID      STATE  IDLE      CWD\n");
    for (all) |info| {
        if (json) {
            const text = std.json.Stringify.valueAlloc(ctx.arena, info, .{}) catch continue;
            ctx.outFmt("{s}\n", .{text});
            continue;
        }
        var idle_buf: [32]u8 = undefined;
        ctx.outFmt("{s: <16} {d: <8} {s: <6} {s: <9} {s}\n", .{
            info.name,
            @as(u32, @intCast(@max(info.pid, 0))),
            if (info.busy) "busy" else "idle",
            state.formatElapsed(&idle_buf, now - info.last_used_ms),
            info.cwd,
        });
    }
    return 0;
}

fn killSession(ctx: Context, args: []const []const u8) u8 {
    if (args.len != 1) return usageError(ctx);
    const name = args[0];
    if (!checkName(ctx, name)) return 2;
    const fd = connect(ctx, false) orelse {
        ctx.errFmt("wsh: session: {s}: no such session\n", .{name});
        return 1;
    };
    defer sys.closeFd(fd);
    const reply = roundTrip(ctx, fd, .{ .op = "kill", .name = name }, &.{}) orelse return 1;
    if (!reply.ok) return refused(ctx, name, reply);
    return 0;
}

var client_interrupted = std.atomic.Value(bool).init(false);

fn onClientInterrupt(_: linux.SIG) callconv(.c) void {
    client_interrupted.store(true, .monotonic);
}

fn execIn(ctx: Context, args: []const []const u8) u8 {
    if (args.len < 2) return usageError(ctx);
    const name = args[0];
    if (!checkName(ctx, name)) return 2;
    const words = if (eql(args[1], "--")) args[2..] else args[1..];
    if (words.len == 0) return usageError(ctx);
    const source = std.mem.join(ctx.arena, " ", words) catch return 1;

    const fd = connect(ctx, false) orelse {
        ctx.errFmt("wsh: session: {s}: no such session\n", .{name});
        return 1;
    };
    defer sys.closeFd(fd);
    if (!wire.sendJson(fd, ctx.arena, Request{ .op = "exec", .name = name, .source = source }, &.{ ctx.stdin, ctx.stdout, ctx.stderr })) {
        ctx.err("wsh: session: the daemon closed the connection\n");
        return 1;
    }

    // Ctrl-C reaches this client, not the session: pass it on as SIGINT to
    // the session's process group and keep waiting for the status.
    var previous: linux.Sigaction = undefined;
    if (ctx.sh == null) {
        var act = std.mem.zeroes(linux.Sigaction);
        act.handler = .{ .handler = onClientInterrupt };
        _ = linux.sigaction(.INT, &act, &previous);
    }
    defer if (ctx.sh == null) {
        _ = linux.sigaction(.INT, &previous, null);
    };
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
        const rc = linux.poll(&fds, 1, -1);
        if (linux.errno(rc) == .INTR) {
            const pending = client_interrupted.swap(false, .monotonic) or (if (ctx.sh) |sh| sh.interrupted else false);
            if (ctx.sh) |sh| sh.interrupted = false;
            if (pending) forwardSignal(ctx, name, "INT");
            continue;
        }
        break;
    }
    const reply = readReply(ctx, fd) orelse {
        ctx.errFmt("wsh: session: {s}: the session ended before the command finished\n", .{name});
        return ended_status;
    };
    if (!reply.ok) return refused(ctx, name, reply);
    return reply.status orelse 0;
}

fn forwardSignal(ctx: Context, name: []const u8, signal: []const u8) void {
    const fd = connect(ctx, false) orelse return;
    defer sys.closeFd(fd);
    _ = roundTrip(ctx, fd, .{ .op = "signal", .name = name, .signal = signal }, &.{});
}

var client_resized = std.atomic.Value(bool).init(false);

fn onClientResize(_: linux.SIG) callconv(.c) void {
    client_resized.store(true, .monotonic);
}

fn attach(ctx: Context, args: []const []const u8) u8 {
    if (args.len != 1) return usageError(ctx);
    const name = args[0];
    if (!checkName(ctx, name)) return 2;
    if (!sys.isTty(ctx.stdin)) {
        ctx.err("wsh: session: attach needs a terminal on standard input\n");
        return 1;
    }
    const size = sys.windowSize(ctx.stdout) orelse sys.WinSize{ .cols = 80, .rows = 24 };
    const fd = connect(ctx, false) orelse {
        ctx.errFmt("wsh: session: {s}: no such session\n", .{name});
        return 1;
    };
    defer sys.closeFd(fd);
    const reply = roundTrip(ctx, fd, .{ .op = "attach", .name = name, .rows = size.rows, .cols = size.cols }, &.{}) orelse {
        ctx.errFmt("wsh: session: {s}: the session ended\n", .{name});
        return 1;
    };
    if (!reply.ok) return refused(ctx, name, reply);

    var raw = term.RawMode.enable(ctx.stdin) orelse {
        ctx.err("wsh: session: cannot switch the terminal to raw mode\n");
        return 1;
    };
    defer raw.disable();
    // A resize interrupts the wait below; the new size goes to the session.
    var act = std.mem.zeroes(linux.Sigaction);
    act.handler = .{ .handler = onClientResize };
    var previous: linux.Sigaction = undefined;
    _ = linux.sigaction(.WINCH, &act, &previous);
    defer _ = linux.sigaction(.WINCH, &previous, null);

    var buf: [65536]u8 = undefined;
    var prefix_seen = false;
    var detached = false;
    loop: while (true) {
        if (client_resized.swap(false, .monotonic)) {
            if (sys.windowSize(ctx.stdout)) |now| {
                if (!sendSize(fd, now)) break;
            }
        }
        var fds = [_]linux.pollfd{
            .{ .fd = ctx.stdin, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = fd, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, 2, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) break;
        if (fds[1].revents != 0) {
            const n = sys.readSome(fd, &buf) orelse break;
            if (n == 0) break;
            if (sys.writeAll(ctx.stdout, buf[0..n]) != .ok) break;
        }
        if (fds[0].revents != 0) {
            const n = sys.readSome(ctx.stdin, &buf) orelse break;
            if (n == 0) break;
            // Bytes go through unchanged except the detach chord; the prefix
            // typed twice sends one literal prefix byte.
            var out: [65536 + 1]u8 = undefined;
            var len: usize = 0;
            for (buf[0..n]) |c| {
                if (prefix_seen) {
                    prefix_seen = false;
                    if (c == 'd') {
                        detached = true;
                        _ = sendInput(fd, .bytes, out[0..len]);
                        break :loop;
                    }
                    out[len] = detach_prefix;
                    len += 1;
                    if (c == detach_prefix) continue;
                } else if (c == detach_prefix) {
                    prefix_seen = true;
                    continue;
                }
                out[len] = c;
                len += 1;
            }
            if (len != 0 and !sendInput(fd, .bytes, out[0..len])) break;
        }
    }
    raw.disable();
    ctx.errFmt("\r\n[{s} {s}]\r\n", .{ if (detached) "detached from session" else "left session", name });
    return 0;
}

// --- attached input ------------------------------------------------------------

/// Input from an attached client is framed, so a resize can travel with the
/// keystrokes: a kind byte, a 4-byte little-endian length, then the data.
const InputKind = enum(u8) { bytes = 0, resize = 1, _ };

fn sendInput(fd: i32, kind: InputKind, data: []const u8) bool {
    var head: [5]u8 = undefined;
    head[0] = @intFromEnum(kind);
    std.mem.writeInt(u32, head[1..5], @intCast(data.len), .little);
    return sys.writeAll(fd, &head) == .ok and sys.writeAll(fd, data) == .ok;
}

/// A resize carries rows then columns, two bytes each.
fn sendSize(fd: i32, size: sys.WinSize) bool {
    var data: [4]u8 = undefined;
    std.mem.writeInt(u16, data[0..2], size.rows, .little);
    std.mem.writeInt(u16, data[2..4], size.cols, .little);
    return sendInput(fd, .resize, &data);
}

/// Splits the framed input stream back into keystrokes and resizes, however
/// the reads cut it.
const InputParser = struct {
    head: [5]u8 = undefined,
    head_len: usize = 0,
    remaining: usize = 0,
    size: [4]u8 = undefined,
    size_len: usize = 0,

    const Event = union(enum) { bytes: []const u8, resize: sys.WinSize };

    /// The next event in `input`, which it advances. Null once `input` is
    /// used up; a partial frame waits for the next call.
    fn next(self: *InputParser, input: *[]const u8) ?Event {
        while (input.len != 0) {
            if (self.head_len < self.head.len) {
                const take = @min(self.head.len - self.head_len, input.len);
                @memcpy(self.head[self.head_len..][0..take], input.*[0..take]);
                self.head_len += take;
                input.* = input.*[take..];
                if (self.head_len < self.head.len) return null;
                self.remaining = std.mem.readInt(u32, self.head[1..5], .little);
                self.size_len = 0;
                if (self.remaining == 0) self.head_len = 0;
                continue;
            }
            const take = @min(self.remaining, input.len);
            const chunk = input.*[0..take];
            input.* = input.*[take..];
            self.remaining -= take;
            const kind: InputKind = @enumFromInt(self.head[0]);
            if (self.remaining == 0) self.head_len = 0;
            switch (kind) {
                .bytes => return .{ .bytes = chunk },
                .resize => {
                    const room = @min(chunk.len, self.size.len - self.size_len);
                    @memcpy(self.size[self.size_len..][0..room], chunk[0..room]);
                    self.size_len += room;
                    if (self.remaining == 0 and self.size_len == self.size.len) return .{ .resize = .{
                        .rows = std.mem.readInt(u16, self.size[0..2], .little),
                        .cols = std.mem.readInt(u16, self.size[2..4], .little),
                    } };
                },
                // Unknown kinds from a newer client are skipped.
                _ => {},
            }
        }
        return null;
    }
};

/// The last 64 KiB of terminal output, replayed to a client that attaches,
/// so it sees what happened while nobody watched.
const Ring = struct {
    data: [capacity]u8 = undefined,
    start: usize = 0,
    len: usize = 0,

    const capacity = 64 * 1024;

    fn append(self: *Ring, bytes: []const u8) void {
        var rest = if (bytes.len > capacity) bytes[bytes.len - capacity ..] else bytes;
        while (rest.len != 0) {
            const end = (self.start + self.len) % capacity;
            const n = @min(rest.len, capacity - end);
            @memcpy(self.data[end..][0..n], rest[0..n]);
            rest = rest[n..];
            self.len += n;
            if (self.len > capacity) {
                self.start = (self.start + self.len - capacity) % capacity;
                self.len = capacity;
            }
        }
    }

    /// The buffered bytes, oldest first, in at most two pieces.
    fn pieces(self: *const Ring) [2][]const u8 {
        const first_len = @min(self.len, capacity - self.start);
        return .{ self.data[self.start..][0..first_len], self.data[0 .. self.len - first_len] };
    }
};

// --- the session host ----------------------------------------------------------

/// The session process: a shell that runs requests from the daemon, one at a
/// time, until the daemon goes away, the session is killed or a command
/// runs `exit`. `ctl` is its end of the daemon's socket pair. After the
/// first attach it also keeps a terminal and a prompt on it for the rest of
/// its life; requests from the daemon interrupt the prompt.
pub fn host(gpa: std.mem.Allocator, ctl: i32, name: []const u8, cwd: []const u8, env: []const []const u8) noreturn {
    _ = sys.setsid();
    state.nullStdio();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const setup = arena_state.allocator();
    const cwd_z = setup.dupeZ(u8, cwd) catch linux.exit(1);
    _ = fs.chdir(cwd_z);

    var entries: std.ArrayList(?[*:0]const u8) = .empty;
    for (env) |entry| {
        if (std.mem.startsWith(u8, entry, "WSH_SESSION=")) continue;
        entries.append(setup, (setup.dupeZ(u8, entry) catch linux.exit(1)).ptr) catch linux.exit(1);
    }
    entries.append(setup, (std.fmt.allocPrintSentinel(setup, "WSH_SESSION={s}", .{name}, 0) catch linux.exit(1)).ptr) catch linux.exit(1);
    entries.append(setup, null) catch linux.exit(1);
    const block: [:null]const ?[*:0]const u8 = entries.items[0 .. entries.items.len - 1 :null];

    var sh = Shell.init(gpa, .{ .environ = .{ .block = .{ .slice = block } }, .args = .{ .vector = &.{} } }) catch linux.exit(1);
    exec.install(&sh);
    sh.interactive = false;
    sh.job_control = false;
    // Like an interactive shell: SIGINT, forwarded from a client's Ctrl-C,
    // stops the command line instead of killing the session. SIGHUP is
    // ignored because `session kill` hangs up the whole process group.
    proc.shellSignals(&sh.interrupted);
    var ignore = std.mem.zeroes(linux.Sigaction);
    ignore.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.HUP, &ignore, null);
    term.wake_fd = ctl;

    var tty: i32 = -1;
    // One editor for the terminal's life, so a line typed when a request
    // interrupts the prompt comes back after it.
    var editor: editor_mod.Editor = undefined;
    while (!sh.should_exit) {
        if (tty >= 0) {
            if (repl(&sh, &editor, tty, name, ctl) == .hangup) {
                closeTerminal(&sh, &editor, tty);
                tty = -1;
            }
            if (sh.should_exit) break;
        }
        var request_arena = std.heap.ArenaAllocator.init(gpa);
        defer request_arena.deinit();
        const arena = request_arena.allocator();
        var frame = (wire.recv(ctl, arena) catch break) orelse break;
        defer frame.closeFds();
        const req = wire.parseJson(Request, arena, frame.body);
        const op = if (req) |r| r.op else "";
        if (eql(op, "exec") and frame.fd_count == 4) {
            hostExec(&sh, arena, ctl, frame.passed(), req.?.source orelse "", tty);
        } else if (eql(op, "attach") and frame.fd_count >= 1) {
            // The relay of an older terminal is gone, or the daemon would
            // have sent the attach there.
            if (tty >= 0) closeTerminal(&sh, &editor, tty);
            tty = openTerminal(&sh, arena, ctl, frame.fds[0], req.?.rows orelse 24, req.?.cols orelse 80);
            if (tty >= 0) editor = editor_mod.Editor.init(&sh, tty, tty);
            reportDone(&sh, arena, ctl);
        } else reportDone(&sh, arena, ctl);
    }
    // Jobs left running belong to the session; hang them up with it.
    state.signalSession(linux.getpid(), linux.getpid(), null, @intFromEnum(linux.SIG.HUP));
    linux.exit(sh.exit_code);
}

/// Tells the daemon a request is finished, with the directory it left.
fn reportDone(sh: *Shell, arena: std.mem.Allocator, ctl: i32) void {
    _ = wire.sendJson(ctl, arena, daemon.HostMessage{ .op = "done", .cwd = sh.cwd }, &.{});
}

fn hostExec(sh: *Shell, arena: std.mem.Allocator, ctl: i32, fds: []const i32, source: []const u8, tty: i32) void {
    const conn = fds[0];
    // The command runs on the caller's descriptors, never as a job of the
    // attached terminal.
    const was_interactive = sh.interactive;
    const had_job_control = sh.job_control;
    sh.interactive = false;
    sh.job_control = false;
    for (fds[1..], 0..) |fd, target| _ = linux.dup3(fd, @intCast(target), 0);
    sh.interrupted = false;
    var status = exec.runSource(sh, source);
    sh.reapJobs();
    if (sh.should_exit) status = strict.finish(sh, status);
    sh.interactive = was_interactive;
    sh.job_control = had_job_control;
    restoreStdio(tty);
    // The daemon hears of the new directory before the caller hears the
    // status, so a `session ls` right after shows it.
    reportDone(sh, arena, ctl);
    _ = wire.sendJson(conn, arena, Reply{ .ok = true, .status = status }, &.{});
}

fn restoreStdio(tty: i32) void {
    if (tty < 0) return state.nullStdio();
    for ([_]i32{ 0, 1, 2 }) |target| _ = linux.dup3(tty, target, 0);
}

/// Gives the session a terminal for good: a relay copies between it and the
/// client, keeps the output while no client is attached, and takes later
/// attaches, which the daemon routes to it. Returns the terminal, or -1.
fn openTerminal(sh: *Shell, arena: std.mem.Allocator, ctl: i32, conn: i32, rows: u16, cols: u16) i32 {
    const pair = pty.open(rows, cols) orelse {
        _ = wire.sendJson(conn, arena, Reply{ .ok = false, .@"error" = "cannot open a terminal" }, &.{});
        return -1;
    };
    var channel: [2]i32 = undefined;
    if (linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &channel)) != .SUCCESS or
        !wire.sendJson(conn, arena, Reply{ .ok = true }, &.{}))
    {
        _ = linux.close(pair.master);
        _ = linux.close(pair.slave);
        return -1;
    }
    const rc = linux.fork();
    if (rc == 0) {
        // A grandchild nobody has to reap.
        if (linux.fork() == 0) relay(channel[1], pair.master, conn);
        linux.exit(0);
    }
    if (linux.errno(rc) == .SUCCESS) _ = proc.waitPid(@intCast(rc), 0);
    _ = linux.close(pair.master);
    _ = linux.close(channel[1]);
    _ = wire.sendJson(ctl, arena, daemon.HostMessage{ .op = "relay" }, &.{channel[0]});
    _ = linux.close(channel[0]);

    const controlling = pty.makeControlling(pair.slave);
    for ([_]i32{ 0, 1, 2 }) |target| _ = linux.dup3(pair.slave, target, 0);
    const tty = sys.duplicateAbove(pair.slave, 255) orelse pair.slave;
    if (tty != pair.slave) _ = linux.close(pair.slave);
    sh.interactive = true;
    if (controlling) {
        sh.tty_fd = tty;
        sh.job_control = true;
        sh.shell_pgid = sys.getpgid(0) orelse sh.pid;
        sys.tcsetpgrp(tty, sh.shell_pgid);
    }
    return tty;
}

fn closeTerminal(sh: *Shell, editor: *editor_mod.Editor, tty: i32) void {
    editor.deinit();
    if (sh.job_control) pty.releaseControlling(tty);
    sh.interactive = false;
    sh.job_control = false;
    sh.tty_fd = -1;
    _ = linux.close(tty);
    state.nullStdio();
}

const ReplEnd = enum { request, hangup };

/// The attached shell's prompt loop. It returns when the daemon has a
/// request (the prompt comes back after it), when the terminal is gone, or
/// when a command runs `exit`.
fn repl(sh: *Shell, editor: *editor_mod.Editor, tty: i32, name: []const u8, ctl: i32) ReplEnd {
    var prompt_text: std.Io.Writer.Allocating = .init(sh.gpa);
    defer prompt_text.deinit();
    var reported_cwd: std.ArrayList(u8) = .empty;
    defer reported_cwd.deinit(sh.gpa);
    reported_cwd.appendSlice(sh.gpa, sh.cwd) catch {};
    while (!sh.should_exit) {
        sh.resetLineArena();
        sh.reapJobs();
        sh.notifyFinishedJobs(2);
        sh.interrupted = false;
        prompt_text.writer.end = 0;
        prompt_text.writer.print("[{s}] ", .{name}) catch {};
        prompt.write(&prompt_text.writer, sh) catch {};
        const full = prompt_text.writer.buffered();
        const last_line = if (std.mem.lastIndexOfScalar(u8, full, '\n')) |newline| newline + 1 else 0;
        // A resumed line is still on screen under the earlier prompt lines.
        if (!editor.woken) sys.writeStr(2, full[0..last_line]);
        const source = editor.readCommand(full[last_line..], exec.isComplete, prompt.writeContinuation) orelse {
            if (editor.woken or term.wakePending()) return .request;
            if (hungUp(tty)) return .hangup;
            // Ctrl-D on an empty line: the session stays, as it does when
            // the client detaches.
            sys.writeStr(2, "wsh: session: type `exit` to end the session, or Ctrl-\\ then d to detach\n");
            continue;
        };
        sh.interrupted = false;
        if (editor.interrupted or source.len == 0) continue;
        _ = sh.hist.record(sh.gpa, source, .{}) catch null;
        _ = exec.runSource(sh, source);
        if (sh.interrupted) {
            sh.last_status = 130;
            sys.writeStr(2, "\n");
        }
        if (!std.mem.eql(u8, reported_cwd.items, sh.cwd)) {
            reported_cwd.clearRetainingCapacity();
            reported_cwd.appendSlice(sh.gpa, sh.cwd) catch {};
            var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
            defer arena_state.deinit();
            _ = wire.sendJson(ctl, arena_state.allocator(), daemon.HostMessage{ .op = "cwd", .cwd = sh.cwd }, &.{});
        }
    }
    _ = strict.finish(sh, sh.exit_code);
    return .request;
}

fn hungUp(tty: i32) bool {
    var fds = [_]linux.pollfd{.{ .fd = tty, .events = linux.POLL.IN, .revents = 0 }};
    return linux.poll(&fds, 1, 0) == 1 and fds[0].revents & linux.POLL.HUP != 0;
}

/// Bytes waiting for a descriptor that cannot take them yet.
const Backlog = struct {
    bytes: std.ArrayList(u8) = .empty,
    start: usize = 0,

    fn len(self: *const Backlog) usize {
        return self.bytes.items.len - self.start;
    }

    fn pending(self: *const Backlog) []const u8 {
        return self.bytes.items[self.start..];
    }

    fn push(self: *Backlog, gpa: std.mem.Allocator, data: []const u8) !void {
        try self.bytes.appendSlice(gpa, data);
    }

    /// Forgets the first `n` pending bytes, compacting now and then so the
    /// buffer does not grow without bound.
    fn consume(self: *Backlog, n: usize) void {
        self.start += n;
        if (self.start == self.bytes.items.len) return self.clear();
        if (self.start >= 64 * 1024 and self.start * 2 >= self.bytes.items.len) {
            const rest = self.bytes.items.len - self.start;
            std.mem.copyForwards(u8, self.bytes.items[0..rest], self.bytes.items[self.start..]);
            self.bytes.shrinkRetainingCapacity(rest);
            self.start = 0;
        }
    }

    fn clear(self: *Backlog) void {
        self.bytes.clearRetainingCapacity();
        self.start = 0;
    }
};

/// Output an attached client has not read yet. Past this the client is
/// dropped rather than let the session wait; it can attach again and gets
/// the replay buffer.
const max_client_backlog = 1 << 20;

/// The terminal relay's state. Nothing in it blocks: the client and the
/// master side are written without waiting, so the session's programs
/// always have somewhere to put their output.
const Relay = struct {
    gpa: std.mem.Allocator,
    channel: i32,
    master: i32,
    client: i32,
    ring: Ring = .{},
    parser: InputParser = .{},
    /// Output for the client.
    out: Backlog = .{},
    /// Keystrokes for the terminal. While any wait, the relay stops reading
    /// the client, so a program that does not read its input slows the
    /// client down instead of filling memory.
    input: Backlog = .{},

    fn dropClient(self: *Relay) void {
        if (self.client >= 0) _ = linux.close(self.client);
        self.client = -1;
        self.out.clear();
    }

    /// Sends `data` to the client after what is already waiting.
    fn toClient(self: *Relay, data: []const u8) void {
        if (self.client < 0) return;
        var rest = data;
        if (self.out.len() == 0) {
            const n = wire.sendNow(self.client, rest, &.{}) catch |e| switch (e) {
                error.WouldBlock => 0,
                error.Failed => return self.dropClient(),
            };
            rest = rest[n..];
        }
        if (rest.len == 0) return;
        if (self.out.len() + rest.len > max_client_backlog) return self.dropClient();
        self.out.push(self.gpa, rest) catch self.dropClient();
    }

    fn flushClient(self: *Relay) void {
        while (self.client >= 0 and self.out.len() != 0) {
            const n = wire.sendNow(self.client, self.out.pending(), &.{}) catch |e| switch (e) {
                error.WouldBlock => return,
                error.Failed => return self.dropClient(),
            };
            self.out.consume(n);
        }
    }

    fn flushInput(self: *Relay) void {
        while (self.input.len() != 0) {
            const pending_input = self.input.pending();
            const rc = linux.write(self.master, pending_input.ptr, pending_input.len);
            switch (linux.errno(rc)) {
                .SUCCESS => self.input.consume(rc),
                .INTR => continue,
                .AGAIN => return,
                else => return self.input.clear(),
            }
        }
    }

    /// A new client from the daemon replaces the old one and first gets the
    /// replay buffer.
    fn takeClient(self: *Relay, arena: std.mem.Allocator, frame: *wire.Frame) void {
        const conn = frame.fds[0];
        frame.fds[0] = -1;
        frame.closeFds();
        self.dropClient();
        self.client = conn;
        self.parser = .{};
        if (wire.parseJson(Request, arena, frame.body)) |req| pty.setSize(self.master, req.rows orelse 24, req.cols orelse 80);
        const body = std.json.Stringify.valueAlloc(arena, Reply{ .ok = true }, .{}) catch return self.dropClient();
        self.toClient(wire.encodeFrame(arena, body) catch return self.dropClient());
        const replay = self.ring.pieces();
        self.toClient(replay[0]);
        self.toClient(replay[1]);
    }

    /// False when the terminal is gone.
    fn readMaster(self: *Relay, buf: []u8) bool {
        const rc = linux.read(self.master, buf.ptr, buf.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return false;
                self.ring.append(buf[0..rc]);
                self.toClient(buf[0..rc]);
                return true;
            },
            .INTR, .AGAIN => return true,
            else => return false,
        }
    }

    fn readClient(self: *Relay, buf: []u8) void {
        const n = sys.readSome(self.client, buf) orelse 0;
        // End of input: detached. The terminal and its programs carry on.
        if (n == 0) return self.dropClient();
        var rest: []const u8 = buf[0..n];
        while (self.parser.next(&rest)) |event| switch (event) {
            .bytes => |bytes| self.input.push(self.gpa, bytes) catch {},
            .resize => |size| pty.setSize(self.master, size.rows, size.cols),
        };
        self.flushInput();
    }
};

/// Owns the terminal's master side for the session's life. It copies output
/// to the attached client and into the replay buffer, passes keystrokes and
/// resizes to the terminal, and takes new clients from the daemon on
/// `channel`; a new client replaces the old one. The relay exits with the
/// host, which hangs up its session, or when the daemon goes away.
fn relay(channel: i32, master: i32, first: i32) noreturn {
    proc.resetSignals();
    var ignore = std.mem.zeroes(linux.Sigaction);
    ignore.handler = .{ .handler = linux.SIG.IGN };
    // A client that vanishes mid-write must not take the relay with it.
    _ = linux.sigaction(.PIPE, &ignore, null);
    // Out of the foreground group, so Ctrl-C on the terminal never hits it.
    sys.setpgid(0, 0);
    runs.keepOnly(&.{ channel, master, first });
    state.nullStdio();
    const flags = linux.fcntl(master, linux.F.GETFL, 0);
    const nonblock: u32 = @bitCast(linux.O{ .NONBLOCK = true });
    _ = linux.fcntl(master, linux.F.SETFL, flags | nonblock);

    var self = Relay{ .gpa = std.heap.page_allocator, .channel = channel, .master = master, .client = first };
    var buf: [65536]u8 = undefined;
    while (true) {
        const polled_client = self.client;
        const waiting_input = self.input.len() != 0;
        var fds = [_]linux.pollfd{
            .{ .fd = channel, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = master, .events = linux.POLL.IN | (if (waiting_input) @as(i16, linux.POLL.OUT) else 0), .revents = 0 },
            .{
                .fd = self.client,
                .events = (if (waiting_input) 0 else @as(i16, linux.POLL.IN)) | (if (self.out.len() != 0) @as(i16, linux.POLL.OUT) else 0),
                .revents = 0,
            },
        };
        const rc = linux.poll(&fds, fds.len, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) break;
        if (fds[0].revents != 0) {
            var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena_state.deinit();
            var frame = (wire.recv(channel, arena_state.allocator()) catch break) orelse break;
            if (frame.fd_count != 0) self.takeClient(arena_state.allocator(), &frame);
        }
        if (fds[1].revents & linux.POLL.OUT != 0) self.flushInput();
        if (fds[1].revents & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) != 0 and !self.readMaster(&buf)) break;
        if (self.client < 0 or self.client != polled_client) continue;
        const client_events = fds[2].revents;
        if (client_events & linux.POLL.OUT != 0) self.flushClient();
        if (self.client < 0 or client_events & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR) == 0) continue;
        if (self.input.len() == 0) self.readClient(&buf) else if (client_events & linux.POLL.IN == 0) self.dropClient();
    }
    linux.exit(0);
}

const testing = std.testing;

test "framed input survives any split" {
    var stream: std.ArrayList(u8) = .empty;
    defer stream.deinit(testing.allocator);
    const frames = [_]struct { InputKind, []const u8 }{
        .{ .bytes, "ls -l\r" },
        .{ .resize, &.{ 40, 0, 132, 0 } },
        .{ @enumFromInt(9), "ignored" },
        .{ .bytes, "" },
        .{ .bytes, "x" },
    };
    for (frames) |frame| {
        try stream.append(testing.allocator, @intFromEnum(frame[0]));
        var len: [4]u8 = undefined;
        std.mem.writeInt(u32, &len, @intCast(frame[1].len), .little);
        try stream.appendSlice(testing.allocator, &len);
        try stream.appendSlice(testing.allocator, frame[1]);
    }
    for ([_]usize{ 1, 2, 3, 7, stream.items.len }) |step| {
        var parser = InputParser{};
        var text: std.ArrayList(u8) = .empty;
        defer text.deinit(testing.allocator);
        var sizes: usize = 0;
        var offset: usize = 0;
        while (offset < stream.items.len) : (offset += step) {
            var rest: []const u8 = stream.items[offset..@min(offset + step, stream.items.len)];
            while (parser.next(&rest)) |event| switch (event) {
                .bytes => |bytes| try text.appendSlice(testing.allocator, bytes),
                .resize => |size| {
                    try testing.expectEqual(@as(u16, 40), size.rows);
                    try testing.expectEqual(@as(u16, 132), size.cols);
                    sizes += 1;
                },
            };
        }
        try testing.expectEqualStrings("ls -l\rx", text.items);
        try testing.expectEqual(@as(usize, 1), sizes);
    }
}

test "the replay buffer keeps the newest 64 KiB" {
    var ring = Ring{};
    ring.append("hello ");
    ring.append("world");
    var parts = ring.pieces();
    try testing.expectEqualStrings("hello world", parts[0]);
    try testing.expectEqual(@as(usize, 0), parts[1].len);

    const block = [_]u8{'a'} ** 40_000 ++ [_]u8{'b'} ** 40_000;
    ring.append(&block);
    parts = ring.pieces();
    try testing.expectEqual(@as(usize, Ring.capacity), parts[0].len + parts[1].len);
    const last = if (parts[1].len != 0) parts[1] else parts[0];
    try testing.expectEqual(@as(u8, 'b'), last[last.len - 1]);
    try testing.expectEqual(@as(u8, 'a'), parts[0][0]);
    // The 'a's that survive are the newest ones: 64 KiB minus 40 000 'b's.
    try testing.expectEqual(Ring.capacity - 40_000, std.mem.count(u8, parts[0], "a") + std.mem.count(u8, parts[1], "a"));
}

test "a backlog hands out what is pending and compacts" {
    var backlog = Backlog{};
    defer backlog.bytes.deinit(testing.allocator);
    try backlog.push(testing.allocator, "hello ");
    try backlog.push(testing.allocator, "world");
    backlog.consume(6);
    try testing.expectEqualStrings("world", backlog.pending());
    backlog.consume(5);
    try testing.expectEqual(@as(usize, 0), backlog.len());

    const block = [_]u8{'z'} ** (100 * 1024);
    try backlog.push(testing.allocator, &block);
    try backlog.push(testing.allocator, "end");
    backlog.consume(block.len - 1);
    try testing.expectEqualStrings("zend", backlog.pending());
    // Compacted: the consumed part is gone from the buffer.
    try testing.expectEqual(@as(usize, 0), backlog.start);
}
