//! `session`: named shells that outlive the caller.
//!
//! The daemon forks one host process per session and routes requests to it.
//! `session exec` passes the caller's stdin, stdout and stderr along with the
//! request, so the command reads and writes them directly with no copying,
//! and the host replies with the exit status on the caller's connection.
//! `session attach` gives the host a fresh pseudo-terminal and runs the line
//! editor on it; a relay process copies bytes between the terminal and the
//! caller until the caller detaches.

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
    var buf: [65536]u8 = undefined;
    var prefix_seen = false;
    var detached = false;
    loop: while (true) {
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
                        _ = sys.writeAll(fd, out[0..len]);
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
            if (sys.writeAll(fd, out[0..len]) != .ok) break;
        }
    }
    raw.disable();
    ctx.errFmt("\r\n[{s} {s}]\r\n", .{ if (detached) "detached from session" else "left session", name });
    return 0;
}

// --- the session host ----------------------------------------------------------

/// The session process: a shell that runs requests from the daemon, one at a
/// time, until the daemon goes away, the session is killed or a command
/// runs `exit`. `ctl` is its end of the daemon's socket pair.
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

    while (!sh.should_exit) {
        var request_arena = std.heap.ArenaAllocator.init(gpa);
        defer request_arena.deinit();
        const arena = request_arena.allocator();
        var frame = (wire.recv(ctl, arena) catch break) orelse break;
        defer frame.closeFds();
        const req = wire.parseJson(Request, arena, frame.body) orelse continue;
        if (frame.fd_count == 0) continue;
        if (eql(req.op, "exec") and frame.fd_count == 4) {
            hostExec(&sh, arena, frame.passed(), req.source orelse "");
        } else if (eql(req.op, "attach")) {
            hostAttach(&sh, arena, frame.fds[0], name, req.rows orelse 24, req.cols orelse 80);
        }
        _ = sys.writeAll(ctl, "d");
    }
    // Jobs left running belong to the session; hang them up with it.
    state.signalSession(linux.getpid(), linux.getpid(), null, @intFromEnum(linux.SIG.HUP));
    linux.exit(sh.exit_code);
}

fn hostExec(sh: *Shell, arena: std.mem.Allocator, fds: []const i32, source: []const u8) void {
    const conn = fds[0];
    for (fds[1..], 0..) |fd, target| _ = linux.dup3(fd, @intCast(target), 0);
    sh.interrupted = false;
    var status = exec.runSource(sh, source);
    sh.reapJobs();
    if (sh.should_exit) status = strict.finish(sh, status);
    state.nullStdio();
    _ = wire.sendJson(conn, arena, Reply{ .ok = true, .status = status }, &.{});
}

fn hostAttach(sh: *Shell, arena: std.mem.Allocator, conn: i32, name: []const u8, rows: u16, cols: u16) void {
    const pair = pty.open(rows, cols) orelse {
        _ = wire.sendJson(conn, arena, Reply{ .ok = false, .@"error" = "cannot open a terminal" }, &.{});
        return;
    };
    if (!wire.sendJson(conn, arena, Reply{ .ok = true }, &.{})) {
        _ = linux.close(pair.master);
        _ = linux.close(pair.slave);
        return;
    }
    const rc = linux.fork();
    if (rc == 0) {
        // A grandchild nobody has to reap copies the bytes.
        if (linux.fork() == 0) relay(conn, pair.master);
        linux.exit(0);
    }
    if (linux.errno(rc) == .SUCCESS) _ = proc.waitPid(@intCast(rc), 0);
    _ = linux.close(pair.master);

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
    repl(sh, tty, name);
    sh.reapJobs();
    if (sh.should_exit) _ = strict.finish(sh, sh.exit_code);
    if (controlling) pty.releaseControlling(tty);
    sh.interactive = false;
    sh.job_control = false;
    sh.tty_fd = -1;
    _ = linux.close(tty);
    state.nullStdio();
}

/// The attached shell's prompt loop. It ends at end of input: the relay
/// closing the terminal on detach, or Ctrl-D on an empty line.
fn repl(sh: *Shell, tty: i32, name: []const u8) void {
    var editor = editor_mod.Editor.init(sh, tty, tty);
    defer editor.deinit();
    var prompt_text: std.Io.Writer.Allocating = .init(sh.gpa);
    defer prompt_text.deinit();
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
        sys.writeStr(2, full[0..last_line]);
        const source = editor.readCommand(full[last_line..], exec.isComplete, prompt.writeContinuation) orelse break;
        sh.interrupted = false;
        if (editor.interrupted or source.len == 0) continue;
        _ = sh.hist.record(sh.gpa, source, .{}) catch null;
        _ = exec.runSource(sh, source);
        if (sh.interrupted) {
            sh.last_status = 130;
            sys.writeStr(2, "\n");
        }
    }
}

/// Copies bytes between the caller's connection and the terminal until
/// either side closes. Exiting closes the terminal's master side, which
/// ends the attached prompt with end of input.
fn relay(conn: i32, master: i32) noreturn {
    runs.keepOnly(&.{ conn, master });
    state.nullStdio();
    var buf: [65536]u8 = undefined;
    while (true) {
        var fds = [_]linux.pollfd{
            .{ .fd = conn, .events = linux.POLL.IN, .revents = 0 },
            .{ .fd = master, .events = linux.POLL.IN, .revents = 0 },
        };
        const rc = linux.poll(&fds, 2, -1);
        if (linux.errno(rc) == .INTR) continue;
        if (linux.errno(rc) != .SUCCESS) break;
        if (fds[0].revents != 0) {
            const n = sys.readSome(conn, &buf) orelse break;
            if (n == 0 or sys.writeAll(master, buf[0..n]) != .ok) break;
        }
        if (fds[1].revents != 0) {
            const n = sys.readSome(master, &buf) orelse break;
            if (n == 0 or sys.writeAll(conn, buf[0..n]) != .ok) break;
        }
    }
    linux.exit(0);
}
