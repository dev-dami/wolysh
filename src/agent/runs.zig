//! `run`: background commands that outlive the caller and keep every byte
//! of their output.
//!
//! `run -d` needs no daemon. The caller forks a detached supervisor, which
//! forks the worker in its own process group with stdout and stderr on one
//! append-only `output.log`, writes `meta.json`, waits, and records the exit
//! status. The supervisor holds an exclusive `flock` on the run directory
//! for as long as it lives, so a reader can tell a running run from one whose
//! supervisor died (`lost`) without trusting a pid that may have been reused.
//! Every other subcommand reads or signals through the files directly.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");
const regex = @import("../regex.zig");
const strict = @import("../strict.zig");
const state = @import("state.zig");
const wire = @import("wire.zig");
const pty = @import("pty.zig");
const out_builtin = @import("../builtins/out.zig");
const Shell = @import("../shell.zig").Shell;

const Context = state.Context;

const usage =
    \\usage: run -d [--name NAME] [--tty] [--] command...
    \\       run status [NAME] [--json]
    \\       run wait NAME [--match TEXT] [--regex] [--timeout DURATION]
    \\       run logs NAME [--tail N | --head N | --since OFFSET] [--json]
    \\       run logs NAME [--budget N] [--find QUERY | --grep TEXT | --failures | --stats]
    \\                [--limit K] [--context C] [--json]
    \\       run kill NAME [--signal SIG]
    \\       run rm NAME...
    \\
;

/// Default lifetime of a finished run: 24 hours, or `WSH_RUN_TTL` seconds.
pub const default_ttl_s: i64 = 24 * 3600;

/// `meta.json`. Other tools read it, so field names are part of the format.
pub const Meta = struct {
    name: []const u8,
    command: []const u8,
    cwd: []const u8,
    pid: ?i32 = null,
    pgid: ?i32 = null,
    supervisor: ?i32 = null,
    /// The session holding every process of the run, background jobs too.
    sid: ?i32 = null,
    started_ms: i64 = 0,
    ended_ms: ?i64 = null,
    status: ?u8 = null,
    signal: ?[]const u8 = null,
    /// What the supervisor last wrote: `running`, `exited`, `killed` or
    /// `lost`. Readers trust the directory lock over a stale `running`.
    state: []const u8 = "running",
    session: ?[]const u8 = null,
    tty: bool = false,
};

pub const State = enum {
    running,
    exited,
    killed,
    lost,

    pub fn finished(self: State) bool {
        return self != .running;
    }
};

pub const Run = struct {
    meta: Meta,
    state: State,
    bytes: u64,
    dir: [:0]const u8,

    fn elapsedMs(self: Run, now: i64) i64 {
        const end = self.meta.ended_ms orelse if (self.state == .running) now else self.meta.started_ms;
        return end - self.meta.started_ms;
    }

    /// The status `run wait` returns: the exit status, or 128 + the signal.
    fn exitStatus(self: Run) u8 {
        return self.meta.status orelse 0;
    }
};

/// The state a run is in, from its meta data and whether its supervisor
/// still holds the directory lock.
fn deriveState(meta: Meta, supervisor_alive: bool) State {
    if (std.mem.eql(u8, meta.state, "lost")) return .lost;
    if (meta.status != null) return if (meta.signal != null) .killed else .exited;
    return if (supervisor_alive) .running else .lost;
}

fn encodeMeta(arena: std.mem.Allocator, meta: Meta) ![]u8 {
    var text = try std.json.Stringify.valueAlloc(arena, meta, .{});
    text = try arena.realloc(text, text.len + 1);
    text[text.len - 1] = '\n';
    return text;
}

fn decodeMeta(arena: std.mem.Allocator, bytes: []const u8) ?Meta {
    return wire.parseJson(Meta, arena, bytes);
}

fn writeMeta(arena: std.mem.Allocator, dir: []const u8, meta: Meta) bool {
    const path = std.fmt.allocPrint(arena, "{s}/meta.json", .{dir}) catch return false;
    const bytes = encodeMeta(arena, meta) catch return false;
    return state.writeAtomic(arena, path, bytes);
}

/// Loads `<runs>/<name>`. Null when the run does not exist or has not
/// written its meta data yet.
fn load(arena: std.mem.Allocator, runs: []const u8, name: []const u8) ?Run {
    const dir = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ runs, name }, 0) catch return null;
    const meta_path = std.fmt.allocPrintSentinel(arena, "{s}/meta.json", .{dir}, 0) catch return null;
    var meta = readMetaFile(arena, meta_path) orelse return null;
    var alive = false;
    if (meta.status == null) {
        if (state.openDirFd(dir)) |fd| {
            alive = state.lockHeld(fd);
            _ = linux.close(fd);
        }
        // The supervisor writes the final meta data before its exit frees
        // the lock, so a free lock means a fresh read is the final one.
        if (!alive) meta = readMetaFile(arena, meta_path) orelse return null;
    }
    const log_path = std.fmt.allocPrint(arena, "{s}/output.log", .{dir}) catch return null;
    return .{ .meta = meta, .state = deriveState(meta, alive), .bytes = state.fileSizeOr0(arena, log_path), .dir = dir };
}

fn readMetaFile(arena: std.mem.Allocator, path: [:0]const u8) ?Meta {
    const bytes = (fs.readFileAlloc(arena, path, 1 << 20) catch return null) orelse return null;
    return decodeMeta(arena, bytes);
}

/// Every run with meta data, oldest first.
pub fn loadAll(arena: std.mem.Allocator, runs: [:0]const u8) []Run {
    var list: std.ArrayList(Run) = .empty;
    var dir = fs.openDir(runs) orelse return &.{};
    defer dir.close();
    while (dir.next()) |entry| {
        if (!state.validName(entry.name)) continue;
        const name = arena.dupe(u8, entry.name) catch break;
        const run = load(arena, runs, name) orelse continue;
        list.append(arena, run) catch break;
    }
    std.mem.sort(Run, list.items, {}, struct {
        fn lessThan(_: void, a: Run, b: Run) bool {
            if (a.meta.started_ms != b.meta.started_ms) return a.meta.started_ms < b.meta.started_ms;
            return std.mem.lessThan(u8, a.meta.name, b.meta.name);
        }
    }.lessThan);
    return list.items;
}

/// Deletes finished runs older than `ttl_ms`. With `persist_lost`, also
/// records `lost` for runs whose supervisor died without writing a status.
/// Returns the runs that are left, oldest first.
pub fn sweep(arena: std.mem.Allocator, runs: [:0]const u8, ttl_ms: i64, persist_lost: bool) []Run {
    const now = state.nowMs();
    const all = loadAll(arena, runs);
    var kept: usize = 0;
    for (all) |run| {
        if (run.state.finished()) {
            if (run.state == .lost and persist_lost and !std.mem.eql(u8, run.meta.state, "lost")) {
                var meta = run.meta;
                meta.state = "lost";
                meta.ended_ms = now;
                _ = writeMeta(arena, run.dir, meta);
            } else {
                const ended = run.meta.ended_ms orelse run.meta.started_ms;
                if (now - ended >= ttl_ms and state.removeTree(arena, run.dir)) continue;
            }
        }
        all[kept] = run;
        kept += 1;
    }
    return all[0..kept];
}

fn ttlMs(ctx: Context) i64 {
    return state.envSeconds(ctx.envp, "WSH_RUN_TTL", default_ttl_s) * 1000;
}

/// `run ...`: `argv[0]` is the command name.
pub fn command(ctx: Context, argv: []const []const u8) u8 {
    if (argv.len < 2) {
        ctx.err(usage);
        return 2;
    }
    const sub = argv[1];
    const rest = argv[2..];
    if (eql(sub, "--help") or eql(sub, "-h")) {
        ctx.out(usage);
        return 0;
    }
    if (eql(sub, "status")) return status(ctx, rest);
    if (eql(sub, "wait")) return wait(ctx, rest);
    if (eql(sub, "logs")) return logs(ctx, rest);
    if (eql(sub, "kill")) return kill(ctx, rest);
    if (eql(sub, "rm")) return remove(ctx, rest);
    if (sub.len != 0 and sub[0] == '-') return start(ctx, argv[1..]);
    ctx.errFmt("wsh: run: {s}: unknown subcommand\n", .{sub});
    ctx.err(usage);
    return 2;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn usageError(ctx: Context) u8 {
    ctx.err(usage);
    return 2;
}

/// `--name value` or `--name=value`. Advances `index` past a separate value.
fn optionValue(args: []const []const u8, index: *usize, long: []const u8) ?[]const u8 {
    const arg = args[index.*];
    if (arg.len > long.len and std.mem.startsWith(u8, arg, long) and arg[long.len] == '=') return arg[long.len + 1 ..];
    if (!eql(arg, long)) return null;
    if (index.* + 1 >= args.len) return null;
    index.* += 1;
    return args[index.*];
}

fn isOption(arg: []const u8, long: []const u8) bool {
    return eql(arg, long) or (std.mem.startsWith(u8, arg, long) and arg.len > long.len and arg[long.len] == '=');
}

/// The runs directory for a read-only command. Null when nothing was ever
/// started, which callers report as an unknown run.
fn runsDir(ctx: Context) ?[:0]const u8 {
    const root = state.dirPath(ctx.arena, ctx.envp) catch return null;
    return std.fmt.allocPrintSentinel(ctx.arena, "{s}/runs", .{root}, 0) catch null;
}

fn loadNamed(ctx: Context, name: []const u8) ?Run {
    if (!state.validName(name)) {
        ctx.errFmt("wsh: run: {s}: invalid run name\n", .{name});
        return null;
    }
    const runs = runsDir(ctx) orelse return null;
    return load(ctx.arena, runs, name) orelse {
        ctx.errFmt("wsh: run: {s}: no such run\n", .{name});
        return null;
    };
}

// --- start ---------------------------------------------------------------------

const StartOptions = struct {
    detach: bool = false,
    name: ?[]const u8 = null,
    tty: bool = false,
    words: []const []const u8 = &.{},
};

fn parseStart(args: []const []const u8) ?StartOptions {
    var options = StartOptions{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eql(arg, "--")) {
            index += 1;
            break;
        }
        if (eql(arg, "-d") or eql(arg, "--detach")) {
            options.detach = true;
        } else if (eql(arg, "--tty") or eql(arg, "-t")) {
            options.tty = true;
        } else if (isOption(arg, "--name")) {
            options.name = optionValue(args, &index, "--name") orelse return null;
        } else if (arg.len > 1 and arg[0] == '-') {
            return null;
        } else break;
    }
    options.words = args[index..];
    if (options.words.len == 0) return null;
    return options;
}

/// Words are joined with spaces and run as one command line, as `ssh` does,
/// so `run -d -- cargo test` and `run -d -- 'make 2>&1 | tee log'` both work.
fn joinWords(arena: std.mem.Allocator, words: []const []const u8) ![]const u8 {
    return std.mem.join(arena, " ", words);
}

/// The next free `run-N`, one past the highest number in use.
fn nextAutoNumber(runs: [:0]const u8) u64 {
    var highest: u64 = 0;
    var dir = fs.openDir(runs) orelse return 1;
    defer dir.close();
    while (dir.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "run-")) continue;
        const n = std.fmt.parseInt(u64, entry.name[4..], 10) catch continue;
        highest = @max(highest, n);
    }
    return highest + 1;
}

const Launch = struct {
    ctx: Context,
    name: []const u8,
    command: []const u8,
    dir: [:0]const u8,
    log_fd: i32,
    dir_fd: i32,
    ready_fd: i32,
    tty: bool,
    session: ?[]const u8,
    started_ms: i64,
};

fn start(ctx: Context, args: []const []const u8) u8 {
    const options = parseStart(args) orelse return usageError(ctx);
    if (!options.detach) {
        ctx.err("wsh: run: use -d to start a background run\n");
        return usageError(ctx);
    }
    if (options.name) |name| {
        if (!state.validName(name)) {
            ctx.errFmt("wsh: run: {s}: invalid run name\n", .{name});
            return 2;
        }
    }
    const arena = ctx.arena;
    const root = state.ensureDir(ctx, "run") orelse return 1;
    const runs = state.ensureSubdir(ctx, root, "runs", "run") orelse return 1;
    _ = sweep(arena, runs, ttlMs(ctx), false);

    const command_text = joinWords(arena, options.words) catch return 1;
    var name: []const u8 = undefined;
    var dir: [:0]const u8 = undefined;
    var attempt: u64 = if (options.name == null) nextAutoNumber(runs) else 0;
    while (true) : (attempt += 1) {
        name = options.name orelse (std.fmt.allocPrint(arena, "run-{d}", .{attempt}) catch return 1);
        dir = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ runs, name }, 0) catch return 1;
        switch (linux.errno(linux.mkdirat(linux.AT.FDCWD, dir.ptr, 0o700))) {
            .SUCCESS => break,
            .EXIST => if (options.name != null) {
                ctx.errFmt("wsh: run: {s}: already exists\n", .{name});
                return 1;
            },
            else => {
                ctx.errFmt("wsh: run: {s}: cannot create the run directory\n", .{dir});
                return 1;
            },
        }
    }

    const log_path = std.fmt.allocPrintSentinel(arena, "{s}/output.log", .{dir}, 0) catch return 1;
    const log_rc = linux.openat(linux.AT.FDCWD, log_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(log_rc) != .SUCCESS) {
        ctx.errFmt("wsh: run: {s}: cannot create the output log\n", .{log_path});
        _ = state.removeTree(arena, dir);
        return 1;
    }
    const log_fd: i32 = @intCast(log_rc);
    defer _ = linux.close(log_fd);
    const dir_fd = state.openDirFd(dir) orelse return 1;
    defer _ = linux.close(dir_fd);

    var ready: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&ready, .{ .CLOEXEC = true })) != .SUCCESS) return 1;
    defer _ = linux.close(ready[0]);

    const launch = Launch{
        .ctx = ctx,
        .name = name,
        .command = command_text,
        .dir = dir,
        .log_fd = log_fd,
        .dir_fd = dir_fd,
        .ready_fd = ready[1],
        .tty = options.tty,
        .session = ctx.getEnv("WSH_SESSION"),
        .started_ms = state.nowMs(),
    };
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(ready[1]);
        ctx.err("wsh: run: cannot fork\n");
        _ = state.removeTree(arena, dir);
        return 1;
    }
    if (rc == 0) detach(&launch);
    _ = linux.close(ready[1]);
    _ = proc.waitPid(@intCast(rc), 0);

    var byte: [1]u8 = undefined;
    if (sys.readAll(ready[0], &byte) != 1) {
        ctx.errFmt("wsh: run: {s}: the run did not start\n", .{name});
        _ = state.removeTree(arena, dir);
        return 1;
    }
    ctx.outFmt("{s}\n", .{name});
    return 0;
}

/// The first child: leaves the caller's session so terminal hangups and
/// job-control signals do not reach the run, then forks the supervisor and
/// exits at once, so the caller never has a child to reap later.
fn detach(launch: *const Launch) noreturn {
    _ = sys.setsid();
    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) linux.exit(1);
    if (rc == 0) supervise(launch);
    linux.exit(0);
}

/// Closes every descriptor above 2 except those in `keep`, so the run does
/// not hold the caller's pipes or terminal open.
pub fn keepOnly(keep: []const i32) void {
    var highest: i32 = 2;
    for (keep) |fd| highest = @max(highest, fd);
    var fd: i32 = 3;
    while (fd < highest) : (fd += 1) {
        if (std.mem.indexOfScalar(i32, keep, fd) == null) _ = linux.close(fd);
    }
    _ = linux.close_range(highest + 1, std.math.maxInt(i32), .{ .UNSHARE = false, .CLOEXEC = false });
}

fn supervise(launch: *const Launch) noreturn {
    proc.resetSignals();
    var ignore = std.mem.zeroes(linux.Sigaction);
    ignore.handler = .{ .handler = linux.SIG.IGN };
    _ = linux.sigaction(.PIPE, &ignore, null);
    state.nullStdio();

    const log_fd = launch.log_fd;
    const dir_fd = launch.dir_fd;
    const ready_fd = launch.ready_fd;
    keepOnly(&.{ log_fd, dir_fd, ready_fd });
    if (!state.tryLock(dir_fd)) linux.exit(1);

    const pair: ?pty.Pair = if (launch.tty) (pty.open(40, 120) orelse linux.exit(1)) else null;
    if (pair) |p| pty.plainNewlines(p.slave);
    var sync: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&sync, .{ .CLOEXEC = true })) != .SUCCESS) linux.exit(1);

    const rc = linux.fork();
    if (linux.errno(rc) != .SUCCESS) linux.exit(1);
    if (rc == 0) {
        _ = linux.close(sync[0]);
        _ = linux.close(ready_fd);
        _ = linux.close(dir_fd);
        work(launch, log_fd, pair, sync[1]);
    }
    const pid: i32 = @intCast(rc);
    _ = linux.close(sync[1]);
    if (pair == null) sys.setpgid(pid, pid);
    if (pair) |p| _ = linux.close(p.slave);
    // The worker reports once it leads its own group, so `run kill` cannot
    // race its setup.
    var byte: [1]u8 = undefined;
    _ = sys.readAll(sync[0], &byte);
    _ = linux.close(sync[0]);

    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    var meta = Meta{
        .name = launch.name,
        .command = launch.command,
        .cwd = launch.ctx.cwd,
        .pid = pid,
        .pgid = pid,
        .supervisor = linux.getpid(),
        .sid = if (pair != null) pid else state.getsid(),
        .started_ms = launch.started_ms,
        .session = launch.session,
        .tty = launch.tty,
    };
    if (!writeMeta(arena, launch.dir, meta)) {
        proc.signalGroup(pid, .KILL);
        linux.exit(1);
    }
    _ = sys.writeAll(ready_fd, "r");
    _ = linux.close(ready_fd);

    const outcome = if (pair) |p| relay(p.master, log_fd, pid) else proc.waitPid(pid, 0);
    meta.ended_ms = state.nowMs();
    if (outcome) |st| {
        meta.status = st.exitCode();
        if (st.kind == .signaled) {
            meta.signal = proc.signalName(st.sig);
            meta.state = "killed";
        } else meta.state = "exited";
    } else meta.state = "lost";
    _ = writeMeta(arena, launch.dir, meta);
    linux.exit(0);
}

/// Copies the terminal's output into the log until the worker has exited
/// and nothing more is buffered. Background children may keep the terminal
/// open, so the worker's exit, not end of file, ends the run.
fn relay(master: i32, log_fd: i32, pid: i32) ?proc.Status {
    var buf: [65536]u8 = undefined;
    var finished: ?proc.Status = null;
    while (true) {
        var fds = [_]linux.pollfd{.{ .fd = master, .events = linux.POLL.IN, .revents = 0 }};
        const ready = linux.poll(&fds, 1, if (finished != null) 0 else 100);
        if (linux.errno(ready) == .SUCCESS and ready > 0 and fds[0].revents & (linux.POLL.IN | linux.POLL.HUP) != 0) {
            const n = sys.readSome(master, &buf) orelse break;
            if (n == 0) break;
            _ = sys.writeAll(log_fd, buf[0..n]);
            continue;
        }
        if (finished != null) break;
        finished = proc.waitPid(pid, linux.W.NOHANG);
    }
    return finished orelse proc.waitPid(pid, 0);
}

fn work(launch: *const Launch, log_fd: i32, pair: ?pty.Pair, sync_fd: i32) noreturn {
    if (pair) |p| {
        _ = sys.setsid();
        _ = pty.makeControlling(p.slave);
        for ([_]i32{ 0, 1, 2 }) |target| _ = linux.dup3(p.slave, target, 0);
        _ = linux.close(p.master);
        _ = linux.close(p.slave);
    } else {
        sys.setpgid(0, 0);
        state.nullStdio();
        _ = linux.dup3(log_fd, 1, 0);
        _ = linux.dup3(log_fd, 2, 0);
    }
    _ = linux.close(log_fd);
    _ = sys.writeAll(sync_fd, "w");
    _ = linux.close(sync_fd);
    proc.resetSignals();

    const ctx = launch.ctx;
    if (ctx.sh) |sh| {
        // As a builtin, the run inherits the shell's functions and variables,
        // like a `parallel` task.
        sh.jobs = .{};
        sh.pid = linux.getpid();
        sh.interactive = false;
        sh.job_control = false;
        sh.tty_fd = -1;
        sh.default_in = 0;
        sh.default_out = 1;
        sh.default_err = 2;
        sh.last_bg_pid = 0;
        sh.should_exit = false;
        sh.return_pending = false;
        sh.break_pending = false;
        sh.continue_pending = false;
        sh.setEnv("WSH_RUN", launch.name) catch {};
        strict.enterSubshell(sh);
        strict.exitChild(sh, ctx.run_source.?(sh, launch.command));
    }
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const arena = arena_state.allocator();
    const argv = proc.buildArgv(arena, &.{ "wsh", "-c", launch.command }) catch linux.exit(126);
    const envp = withEnv(arena, ctx.envp, "WSH_RUN", launch.name) catch linux.exit(126);
    const err = linux.errno(linux.execve("/proc/self/exe", argv, envp));
    var buf: [256]u8 = undefined;
    sys.writeStr(2, std.fmt.bufPrint(&buf, "wsh: run: cannot execute the shell: {s}\n", .{proc.errorText(err)}) catch "wsh: run: cannot execute the shell\n");
    linux.exit(126);
}

/// `envp` with `name=value` in place of any existing entry for `name`.
fn withEnv(arena: std.mem.Allocator, envp: [*:null]const ?[*:0]const u8, name: []const u8, value: []const u8) ![*:null]const ?[*:0]const u8 {
    var list: std.ArrayList(?[*:0]const u8) = .empty;
    var index: usize = 0;
    while (envp[index]) |entry| : (index += 1) {
        const text = std.mem.span(entry);
        if (text.len > name.len and text[name.len] == '=' and std.mem.eql(u8, text[0..name.len], name)) continue;
        try list.append(arena, entry);
    }
    try list.append(arena, (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ name, value }, 0)).ptr);
    try list.append(arena, null);
    return @ptrCast(list.items.ptr);
}

// --- status --------------------------------------------------------------------

fn status(ctx: Context, args: []const []const u8) u8 {
    var json = false;
    var name: ?[]const u8 = null;
    for (args) |arg| {
        if (eql(arg, "--json")) {
            json = true;
        } else if (arg.len != 0 and arg[0] == '-') {
            return usageError(ctx);
        } else if (name == null) {
            name = arg;
        } else return usageError(ctx);
    }
    const now = state.nowMs();
    if (name) |one| {
        const run = loadNamed(ctx, one) orelse return 1;
        if (json) printJson(ctx, run, now) else printRow(ctx, run, now);
        return 0;
    }
    const runs = runsDir(ctx) orelse return 0;
    const all = sweep(ctx.arena, runs, ttlMs(ctx), false);
    if (!json and all.len != 0) ctx.out("NAME             STATE    STATUS  ELAPSED        BYTES  COMMAND\n");
    for (all) |run| {
        if (json) printJson(ctx, run, now) else printRow(ctx, run, now);
    }
    return 0;
}

fn printRow(ctx: Context, run: Run, now: i64) void {
    var elapsed_buf: [32]u8 = undefined;
    var status_buf: [8]u8 = undefined;
    const status_text = if (run.meta.status) |code| std.fmt.bufPrint(&status_buf, "{d}", .{code}) catch "?" else "-";
    ctx.outFmt("{s: <16} {s: <8} {s: <6}  {s: <8} {d: >10}  {s}\n", .{
        run.meta.name,
        @tagName(run.state),
        status_text,
        state.formatElapsed(&elapsed_buf, run.elapsedMs(now)),
        run.bytes,
        run.meta.command,
    });
}

fn printJson(ctx: Context, run: Run, now: i64) void {
    const text = std.json.Stringify.valueAlloc(ctx.arena, .{
        .name = run.meta.name,
        .state = @tagName(run.state),
        .status = run.meta.status,
        .signal = run.meta.signal,
        .pid = run.meta.pid,
        .pgid = run.meta.pgid,
        .started_ms = run.meta.started_ms,
        .ended_ms = run.meta.ended_ms,
        .elapsed_ms = run.elapsedMs(now),
        .bytes = run.bytes,
        .command = run.meta.command,
        .cwd = run.meta.cwd,
        .session = run.meta.session,
        .tty = run.meta.tty,
    }, .{}) catch return;
    ctx.outFmt("{s}\n", .{text});
}

// --- wait ----------------------------------------------------------------------

/// `run wait` status when the time limit passes first, as in `timeout(1)`.
const timeout_status: u8 = 124;
/// `run wait` status for a run whose supervisor died: its status is unknown.
const lost_status: u8 = 125;

const Matcher = struct {
    text: []const u8,
    compiled: ?regex.Regex,

    fn matches(self: *const Matcher, line: []const u8) bool {
        if (self.compiled) |*re| return (re.match(line) catch null) != null;
        return std.mem.indexOf(u8, line, self.text) != null;
    }
};

/// Scans `output.log` for a matching line, reading only what is new.
const LineScanner = struct {
    fd: i32,
    offset: u64 = 0,
    /// The current line so far, which has no newline yet.
    partial: std.ArrayList(u8) = .empty,

    const max_partial = 1 << 20;

    /// The first matching line in the new output, if any. `at_end` also
    /// tries a last line without a newline.
    fn scan(self: *LineScanner, arena: std.mem.Allocator, matcher: *const Matcher, at_end: bool) ?[]const u8 {
        var buf: [65536]u8 = undefined;
        while (true) {
            const rc = linux.pread(self.fd, &buf, buf.len, @intCast(self.offset));
            if (linux.errno(rc) != .SUCCESS or rc == 0) break;
            const chunk = buf[0..rc];
            self.offset += rc;
            var rest: []const u8 = chunk;
            while (std.mem.indexOfScalar(u8, rest, '\n')) |newline| {
                const piece = rest[0..newline];
                rest = rest[newline + 1 ..];
                const line = if (self.partial.items.len == 0) piece else blk: {
                    self.partial.appendSlice(arena, piece) catch {};
                    break :blk self.partial.items;
                };
                if (matcher.matches(line)) return arena.dupe(u8, line) catch line;
                self.partial.clearRetainingCapacity();
            }
            // Only whole lines match, so the line printed is the one the
            // program wrote (`READY on 8080`, not `READY on `); a last line
            // without a newline is tried once the run has ended.
            if (self.partial.items.len + rest.len <= max_partial) self.partial.appendSlice(arena, rest) catch {};
        }
        if (at_end and self.partial.items.len != 0 and matcher.matches(self.partial.items)) return self.partial.items;
        return null;
    }
};

fn wait(ctx: Context, args: []const []const u8) u8 {
    var name: ?[]const u8 = null;
    var pattern: ?[]const u8 = null;
    var use_regex = false;
    var timeout_ms: ?i64 = null;
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (isOption(arg, "--match")) {
            pattern = optionValue(args, &index, "--match") orelse return usageError(ctx);
        } else if (isOption(arg, "--timeout")) {
            const text = optionValue(args, &index, "--timeout") orelse return usageError(ctx);
            timeout_ms = state.parseDuration(text) orelse {
                ctx.errFmt("wsh: run: {s}: invalid duration\n", .{text});
                return 2;
            };
        } else if (eql(arg, "--regex")) {
            use_regex = true;
        } else if (arg.len != 0 and arg[0] == '-') {
            return usageError(ctx);
        } else if (name == null) {
            name = arg;
        } else return usageError(ctx);
    }
    const run_name = name orelse return usageError(ctx);
    var run = loadNamed(ctx, run_name) orelse return 1;
    const arena = ctx.arena;

    var matcher: ?Matcher = null;
    if (pattern) |text| {
        matcher = .{ .text = text, .compiled = null };
        if (use_regex) {
            matcher.?.compiled = regex.compile(arena, text) catch |e| {
                ctx.errFmt("wsh: run: {s}: {s}\n", .{ text, regex.errorMessage(e) });
                return 2;
            };
        }
    }
    const log_path = std.fmt.allocPrintSentinel(arena, "{s}/output.log", .{run.dir}, 0) catch return 1;
    var scanner = LineScanner{ .fd = sys.openRead(log_path) orelse -1 };
    defer if (scanner.fd >= 0) sys.closeFd(scanner.fd);

    // inotify wakes the wait on new output or a rewritten `meta.json`; the
    // poll timeout still catches a supervisor that dies without writing. The
    // watch is made only when the wait has to sleep: tearing it down costs
    // the exiting process about 15 ms in the kernel.
    var notify: i32 = -1;
    var watch_tried = false;
    defer if (notify >= 0) sys.closeFd(notify);

    const deadline = if (timeout_ms) |ms| state.monotonicMs() + ms else null;
    const runs = runsDir(ctx) orelse return 1;
    while (true) {
        if (matcher) |*m| {
            if (scanner.fd >= 0) {
                if (scanner.scan(arena, m, false)) |line| {
                    ctx.outFmt("{s}\n", .{line});
                    return 0;
                }
            }
        }
        if (run.state.finished()) break;
        var wait_ms: i64 = 500;
        if (deadline) |limit| {
            const left = limit - state.monotonicMs();
            if (left <= 0) {
                ctx.errFmt("wsh: run: {s}: timed out\n", .{run_name});
                return timeout_status;
            }
            wait_ms = @min(wait_ms, left);
        }
        if (!watch_tried) {
            // Look again before the first sleep: anything written before the
            // watch existed raises no event.
            watch_tried = true;
            const rc = linux.inotify_init1(linux.IN.CLOEXEC | linux.IN.NONBLOCK);
            if (linux.errno(rc) == .SUCCESS) {
                notify = @intCast(rc);
                _ = linux.inotify_add_watch(notify, run.dir.ptr, linux.IN.MODIFY | linux.IN.MOVED_TO | linux.IN.DELETE_SELF);
            }
        } else if (notify >= 0) {
            var fds = [_]linux.pollfd{.{ .fd = notify, .events = linux.POLL.IN, .revents = 0 }};
            _ = linux.poll(&fds, 1, @intCast(wait_ms));
            var events: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
            while (sys.readSome(notify, &events)) |n| {
                if (n == 0) break;
            }
        } else state.sleepMs(@intCast(@min(wait_ms, 50)));
        if (interrupted(ctx)) return 130;
        run = load(arena, runs, run_name) orelse {
            ctx.errFmt("wsh: run: {s}: removed while waiting\n", .{run_name});
            return 1;
        };
    }

    if (matcher) |*m| {
        if (scanner.fd >= 0) {
            if (scanner.scan(arena, m, true)) |line| {
                ctx.outFmt("{s}\n", .{line});
                return 0;
            }
        }
    }
    if (run.state == .lost) {
        ctx.errFmt("wsh: run: {s}: lost; its supervisor ended without recording a status\n", .{run_name});
        return lost_status;
    }
    if (matcher != null) {
        ctx.errFmt("wsh: run: {s}: ended with status {d} before a line matched\n", .{ run_name, run.exitStatus() });
        return if (run.exitStatus() != 0) run.exitStatus() else 1;
    }
    return run.exitStatus();
}

/// Ctrl-C in an interactive shell ends a blocking `run wait`.
fn interrupted(ctx: Context) bool {
    const sh = ctx.sh orelse return false;
    return sh.interrupted;
}

// --- logs ----------------------------------------------------------------------

const LogsMode = union(enum) { all, head: u64, tail: u64, since: u64 };

fn logs(ctx: Context, args: []const []const u8) u8 {
    var name: ?[]const u8 = null;
    var mode: LogsMode = .all;
    var json = false;
    var query: Query = .{};
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (eql(arg, "--json")) {
            json = true;
            continue;
        }
        if (query.take(args, &index)) |taken| {
            if (!taken) return usageError(ctx);
            continue;
        }
        const kinds = [_][]const u8{ "--tail", "--head", "--since" };
        const kind = for (kinds, 0..) |long, k| {
            if (isOption(arg, long)) break k;
        } else null;
        if (kind) |k| {
            if (std.meta.activeTag(mode) != .all) return usageError(ctx);
            const text = optionValue(args, &index, kinds[k]) orelse return usageError(ctx);
            const n = std.fmt.parseInt(u64, text, 10) catch {
                ctx.errFmt("wsh: run: {s}: invalid number\n", .{text});
                return 2;
            };
            mode = switch (k) {
                0 => .{ .tail = n },
                1 => .{ .head = n },
                else => .{ .since = n },
            };
            continue;
        }
        if (arg.len != 0 and arg[0] == '-') return usageError(ctx);
        if (name != null) return usageError(ctx);
        name = arg;
    }
    const run_name = name orelse return usageError(ctx);
    const run = loadNamed(ctx, run_name) orelse return 1;
    const arena = ctx.arena;
    const log_path = std.fmt.allocPrintSentinel(arena, "{s}/output.log", .{run.dir}, 0) catch return 1;
    if (query.wanted()) {
        // Questions about the whole log; a byte range would cut lines apart.
        if (std.meta.activeTag(mode) != .all) return usageError(ctx);
        return query.answer(ctx, log_path, json);
    }
    const fd = sys.openRead(log_path) orelse {
        ctx.errFmt("wsh: run: {s}: cannot read the output log\n", .{run_name});
        return 1;
    };
    defer sys.closeFd(fd);
    const size = run.bytes;

    const range: struct { start: u64, end: u64 } = switch (mode) {
        .all => .{ .start = 0, .end = size },
        .since => |offset| .{ .start = @min(offset, size), .end = size },
        .head => |lines| .{ .start = 0, .end = headEnd(fd, size, lines) },
        .tail => |lines| .{ .start = tailStart(fd, size, lines), .end = size },
    };
    if (json) {
        const data = arena.alloc(u8, range.end - range.start) catch return 1;
        const n = preadAll(fd, data, range.start);
        const text = std.json.Stringify.valueAlloc(arena, .{
            .name = run.meta.name,
            .state = @tagName(run.state),
            .offset = range.start,
            .next_offset = range.start + n,
            .data = validUtf8(arena, data[0..n]) catch return 1,
        }, .{}) catch return 1;
        ctx.outFmt("{s}\n", .{text});
        return 0;
    }
    var buf: [65536]u8 = undefined;
    var offset = range.start;
    while (offset < range.end) {
        const want: usize = @intCast(@min(buf.len, range.end - offset));
        const n = preadAll(fd, buf[0..want], offset);
        if (n == 0) break;
        if (sys.writeAll(ctx.stdout, buf[0..n]) != .ok) return 1;
        offset += n;
    }
    if (std.meta.activeTag(mode) == .since) ctx.errFmt("next_offset={d}\n", .{offset});
    return 0;
}

/// `run logs --budget/--find/--grep/--failures/--stats`: the log is handed
/// to the `out` builtin, which answers within a byte budget.
const Query = struct {
    budget: ?[]const u8 = null,
    find: ?[]const u8 = null,
    grep: ?[]const u8 = null,
    failures: bool = false,
    stats: bool = false,
    limit: ?[]const u8 = null,
    context: ?[]const u8 = null,

    /// Consumes a query option at `args[index.*]`: null when it is not one,
    /// false when it is malformed or repeats another question.
    fn take(self: *Query, args: []const []const u8, index: *usize) ?bool {
        const arg = args[index.*];
        if (eql(arg, "--failures") or eql(arg, "--stats")) {
            if (self.question() != null) return false;
            if (eql(arg, "--failures")) self.failures = true else self.stats = true;
            return true;
        }
        const options = [_][]const u8{ "--budget", "--find", "--grep", "--limit", "--context" };
        for (options, 0..) |long, k| {
            if (!isOption(arg, long)) continue;
            const value = optionValue(args, index, long) orelse return false;
            switch (k) {
                0 => self.budget = value,
                3 => self.limit = value,
                4 => self.context = value,
                1 => {
                    if (self.question() != null) return false;
                    self.find = value;
                },
                else => {
                    if (self.question() != null) return false;
                    self.grep = value;
                },
            }
            return true;
        }
        return null;
    }

    fn question(self: Query) ?[]const u8 {
        if (self.find != null) return "find";
        if (self.grep != null) return "grep";
        if (self.failures) return "failures";
        if (self.stats) return "stats";
        return null;
    }

    fn wanted(self: Query) bool {
        return self.budget != null or self.question() != null;
    }

    fn answer(self: Query, ctx: Context, log_path: [:0]const u8, json: bool) u8 {
        const arena = ctx.arena;
        var argv: std.ArrayList([]const u8) = .empty;
        const subcommand = self.question() orelse "budget";
        argv.appendSlice(arena, &.{ "out", subcommand }) catch return 1;
        if (self.find) |text| argv.append(arena, text) catch return 1;
        if (self.grep) |text| argv.append(arena, text) catch return 1;
        if (self.budget) |size| {
            if (self.question() == null) {
                argv.append(arena, size) catch return 1;
            } else {
                argv.appendSlice(arena, &.{ "--budget", size }) catch return 1;
            }
        }
        if (self.limit) |n| argv.appendSlice(arena, &.{ "--limit", n }) catch return 1;
        if (self.context) |n| argv.appendSlice(arena, &.{ "--context", n }) catch return 1;
        if (json) argv.append(arena, "--json") catch return 1;
        argv.appendSlice(arena, &.{ "--file", log_path }) catch return 1;

        // On the CLI fast path there is no shell; `out` only needs one for
        // its allocator and environment, so a bare one will do.
        var bare: ?Shell = null;
        defer if (bare) |*sh| sh.deinit();
        const sh = ctx.sh orelse blk: {
            bare = Shell.initBare(ctx.gpa) catch return 1;
            break :blk &bare.?;
        };
        return out_builtin.run(.{ .sh = sh, .argv = argv.items, .stdin = ctx.stdin, .stdout = ctx.stdout, .stderr = ctx.stderr });
    }
};

fn preadAll(fd: i32, buf: []u8, offset: u64) usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = linux.pread(fd, buf[total..].ptr, buf.len - total, @intCast(offset + total));
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) break;
                total += rc;
            },
            .INTR => continue,
            else => break,
        }
    }
    return total;
}

/// The offset just past the `lines`-th newline, or `size`.
fn headEnd(fd: i32, size: u64, lines: u64) u64 {
    if (lines == 0) return 0;
    var buf: [65536]u8 = undefined;
    var offset: u64 = 0;
    var seen: u64 = 0;
    while (offset < size) {
        const n = preadAll(fd, buf[0..@intCast(@min(buf.len, size - offset))], offset);
        if (n == 0) break;
        for (buf[0..n], 0..) |c, i| {
            if (c != '\n') continue;
            seen += 1;
            if (seen == lines) return offset + i + 1;
        }
        offset += n;
    }
    return size;
}

/// The offset where the last `lines` lines begin. A final line without a
/// newline counts as a line.
fn tailStart(fd: i32, size: u64, lines: u64) u64 {
    if (lines == 0 or size == 0) return size;
    var buf: [65536]u8 = undefined;
    var end = size;
    var seen: u64 = 0;
    var last_byte: [1]u8 = undefined;
    // A trailing newline ends the last line rather than starting a new one.
    const skip_final = preadAll(fd, &last_byte, size - 1) == 1 and last_byte[0] == '\n';
    while (end > 0) {
        const len: usize = @intCast(@min(buf.len, end));
        const begin = end - len;
        const n = preadAll(fd, buf[0..len], begin);
        if (n != len) return 0;
        var i = len;
        while (i > 0) {
            i -= 1;
            if (buf[i] != '\n') continue;
            if (skip_final and begin + i == size - 1) continue;
            seen += 1;
            if (seen == lines) return begin + i + 1;
        }
        end = begin;
    }
    return 0;
}

/// `bytes` with each invalid UTF-8 sequence replaced by U+FFFD, so JSON
/// output always carries a string.
fn validUtf8(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(arena, bytes[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(arena, "\u{FFFD}");
            i += 1;
        }
    }
    return out.items;
}

// --- kill and rm ----------------------------------------------------------------

fn kill(ctx: Context, args: []const []const u8) u8 {
    var name: ?[]const u8 = null;
    var sig: u32 = @intFromEnum(linux.SIG.TERM);
    var index: usize = 0;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        const spec: ?[]const u8 = if (isOption(arg, "--signal"))
            optionValue(args, &index, "--signal") orelse return usageError(ctx)
        else if (eql(arg, "-s")) blk: {
            index += 1;
            if (index >= args.len) return usageError(ctx);
            break :blk args[index];
        } else if (arg.len > 1 and arg[0] == '-') arg[1..] else null;
        if (spec) |text| {
            sig = @intFromEnum(proc.signalFromName(text) orelse {
                ctx.errFmt("wsh: run: {s}: invalid signal specification\n", .{text});
                return 2;
            });
        } else if (name == null) {
            name = arg;
        } else return usageError(ctx);
    }
    const run_name = name orelse return usageError(ctx);
    const run = loadNamed(ctx, run_name) orelse return 1;
    if (run.state != .running) {
        ctx.errFmt("wsh: run: {s}: not running\n", .{run_name});
        return 1;
    }
    const pgid = run.meta.pgid orelse return 1;
    const err = proc.sendSignal(-pgid, sig);
    if (err != .SUCCESS) {
        ctx.errFmt("wsh: run: {s}: {s}\n", .{ run_name, proc.errorText(err) });
        return 1;
    }
    // Background jobs of the run sit in process groups of their own.
    if (run.meta.sid) |sid| state.signalSession(sid, run.meta.supervisor orelse 0, pgid, sig);
    return 0;
}

fn remove(ctx: Context, args: []const []const u8) u8 {
    if (args.len == 0) return usageError(ctx);
    var result: u8 = 0;
    for (args) |name| {
        const run = loadNamed(ctx, name) orelse {
            result = 1;
            continue;
        };
        // The exclusive lock proves no supervisor is left. A reader holds a
        // shared lock only for a moment, so try a few times.
        const fd = state.openDirFd(run.dir) orelse {
            result = 1;
            continue;
        };
        defer _ = linux.close(fd);
        var locked = false;
        for (0..5) |_| {
            locked = state.tryLock(fd);
            if (locked) break;
            state.sleepMs(2);
        }
        if (!locked) {
            ctx.errFmt("wsh: run: {s}: still running; use `run kill {s}` first\n", .{ name, name });
            result = 1;
            continue;
        }
        if (!state.removeTree(ctx.arena, run.dir)) {
            ctx.errFmt("wsh: run: {s}: cannot remove {s}\n", .{ name, run.dir });
            result = 1;
        }
    }
    return result;
}

const testing = std.testing;

test "meta data round-trips and tolerates unknown and missing fields" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = Meta{ .name = "test", .command = "cargo test", .cwd = "/src", .pid = 41, .pgid = 41, .started_ms = 1000, .ended_ms = 2500, .status = 143, .signal = "TERM", .state = "killed" };
    const bytes = try encodeMeta(arena, meta);
    try testing.expect(std.mem.endsWith(u8, bytes, "}\n"));
    try testing.expect(std.mem.indexOf(u8, bytes, "\"session\":null") != null);
    const back = decodeMeta(arena, bytes).?;
    try testing.expectEqualStrings("cargo test", back.command);
    try testing.expectEqual(@as(?u8, 143), back.status);
    try testing.expectEqualStrings("TERM", back.signal.?);
    try testing.expectEqual(State.killed, deriveState(back, false));

    const minimal = decodeMeta(arena, "{\"name\":\"x\",\"command\":\"true\",\"cwd\":\"/\",\"future\":[1,2]}").?;
    try testing.expect(minimal.status == null and minimal.ended_ms == null);
    try testing.expectEqual(State.running, deriveState(minimal, true));
    try testing.expectEqual(State.lost, deriveState(minimal, false));
    try testing.expect(decodeMeta(arena, "{\"name\":1}") == null);
    try testing.expect(decodeMeta(arena, "not json") == null);
}

test "start options and command words" {
    const options = parseStart(&.{ "-d", "--name", "test", "--", "cargo", "test" }).?;
    try testing.expect(options.detach);
    try testing.expectEqualStrings("test", options.name.?);
    try testing.expectEqual(@as(usize, 2), options.words.len);
    const joined = try joinWords(testing.allocator, options.words);
    defer testing.allocator.free(joined);
    try testing.expectEqualStrings("cargo test", joined);

    const inline_name = parseStart(&.{ "-d", "--name=x", "--tty", "make" }).?;
    try testing.expectEqualStrings("x", inline_name.name.?);
    try testing.expect(inline_name.tty);
    try testing.expect(parseStart(&.{"-d"}) == null);
    try testing.expect(parseStart(&.{ "-d", "--name" }) == null);
    try testing.expect(parseStart(&.{ "-d", "--bogus", "x" }) == null);
}

test "invalid UTF-8 is replaced for JSON output" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("ok é", try validUtf8(arena, "ok é"));
    try testing.expectEqualStrings("a\u{FFFD}b", try validUtf8(arena, "a\xffb"));
}

test "line scanner matches lines across reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const fd_rc = linux.memfd_create("wsh-test", linux.MFD.CLOEXEC);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_rc));
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);

    var scanner = LineScanner{ .fd = fd };
    const matcher = Matcher{ .text = "ready on", .compiled = null };
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(fd, "booting\nrea"));
    try testing.expect(scanner.scan(arena, &matcher, false) == null);
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(fd, "dy on 8080\nmore\n"));
    try testing.expectEqualStrings("ready on 8080", scanner.scan(arena, &matcher, false).?);

    const anchored = Matcher{ .text = "^done$", .compiled = try regex.compile(arena, "^done$") };
    var second = LineScanner{ .fd = fd, .offset = scanner.offset };
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(fd, "not done\ndone"));
    try testing.expect(second.scan(arena, &anchored, false) == null);
    try testing.expectEqualStrings("done", second.scan(arena, &anchored, true).?);
}

test "head and tail find line boundaries" {
    const fd_rc = linux.memfd_create("wsh-test", linux.MFD.CLOEXEC);
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(fd_rc));
    const fd: i32 = @intCast(fd_rc);
    defer _ = linux.close(fd);
    try testing.expectEqual(sys.WriteResult.ok, sys.writeAll(fd, "one\ntwo\nthree\n"));
    try testing.expectEqual(@as(u64, 4), headEnd(fd, 14, 1));
    try testing.expectEqual(@as(u64, 14), headEnd(fd, 14, 9));
    try testing.expectEqual(@as(u64, 8), tailStart(fd, 14, 1));
    try testing.expectEqual(@as(u64, 4), tailStart(fd, 14, 2));
    try testing.expectEqual(@as(u64, 0), tailStart(fd, 14, 5));
    try testing.expectEqual(@as(u64, 8), tailStart(fd, 13, 1));
}
