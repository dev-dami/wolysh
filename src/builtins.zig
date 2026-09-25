//! Shell builtins.
//!
//! A builtin receives explicit input/output descriptors rather than writing to
//! its own fds, so redirects (`echo hi > file`) work without the executor
//! having to temporarily rearrange the shell's own descriptors.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const shellmod = @import("shell.zig");
const value = @import("value.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const glob = @import("glob.zig");
const jobs = @import("jobs.zig");

const Shell = shellmod.Shell;

pub const Ctx = struct {
    sh: *Shell,
    /// Expanded arguments; `argv[0]` is the builtin name.
    argv: []const []const u8,
    stdin: i32 = 0,
    stdout: i32 = 1,
    stderr: i32 = 2,

    fn arg(self: Ctx, index: usize) ?[]const u8 {
        if (index >= self.argv.len) return null;
        return self.argv[index];
    }

    fn out(self: Ctx, bytes: []const u8) void {
        sys.writeStr(self.stdout, bytes);
    }

    fn err(self: Ctx, bytes: []const u8) void {
        sys.writeStr(self.stderr, bytes);
    }

    fn errFmt(self: Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.err(text);
    }

    fn outFmt(self: Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [1024]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.out(text);
    }
};

pub const Builtin = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (Ctx) u8,
};

pub fn lookup(name: []const u8) ?*const Builtin {
    for (&table) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b;
    }
    return null;
}

pub fn isBuiltin(name: []const u8) bool {
    return lookup(name) != null;
}

pub fn all() []const Builtin {
    return &table;
}

// --- output ----------------------------------------------------------------

fn builtinEcho(ctx: Ctx) u8 {
    var newline = true;
    var escapes = false;

    // Leading flags only; `echo -- -n` still prints the literal argument.
    var start: usize = 1;
    while (start < ctx.argv.len) {
        const arg = ctx.argv[start];
        if (arg.len < 2 or arg[0] != '-' or std.mem.eql(u8, arg, "--")) {
            if (std.mem.eql(u8, arg, "--")) start += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "-n")) {
            newline = false;
        } else if (std.mem.eql(u8, arg, "-e")) {
            escapes = true;
        } else if (std.mem.eql(u8, arg, "-E")) {
            escapes = false;
        } else break;
        start += 1;
    }

    var i = start;
    while (i < ctx.argv.len) : (i += 1) {
        if (i != start) ctx.out(" ");
        if (escapes) writeEscaped(ctx, ctx.argv[i]) else ctx.out(ctx.argv[i]);
    }
    if (newline) ctx.out("\n");
    return 0;
}

fn writeEscaped(ctx: Ctx, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            ctx.out(text[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        switch (text[i]) {
            'n' => ctx.out("\n"),
            't' => ctx.out("\t"),
            'r' => ctx.out("\r"),
            'e' => ctx.out("\x1b"),
            '\\' => ctx.out("\\"),
            '0' => ctx.out("\x00"),
            else => {
                ctx.out("\\");
                ctx.out(text[i .. i + 1]);
            },
        }
        i += 1;
    }
}

fn builtinPrint(ctx: Ctx) u8 {
    // `print` is the scripting-language spelling: it also renders non-string
    // values, but by the time a builtin runs everything is already a string.
    return builtinEcho(ctx);
}

fn builtinPwd(ctx: Ctx) u8 {
    ctx.out(ctx.sh.cwd);
    ctx.out("\n");
    return 0;
}

fn builtinClear(ctx: Ctx) u8 {
    ctx.out("\x1b[2J\x1b[H");
    return 0;
}

fn builtinTrue(_: Ctx) u8 {
    return 0;
}

fn builtinFalse(_: Ctx) u8 {
    return 1;
}

// --- directory -------------------------------------------------------------

fn builtinCd(ctx: Ctx) u8 {
    const target = ctx.arg(1) orelse ctx.sh.getEnv("HOME") orelse {
        ctx.err("wsh: cd: HOME is not set\n");
        return 1;
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var dest: []const u8 = target;
    if (std.mem.eql(u8, target, "-")) {
        dest = ctx.sh.getEnv("OLDPWD") orelse {
            ctx.err("wsh: cd: OLDPWD is not set\n");
            return 1;
        };
    }
    dest = ctx.sh.tildeExpand(arena, dest) catch target;

    const z = arena.dupeZ(u8, dest) catch return 1;
    if (!fs.isDir(z)) {
        ctx.errFmt("wsh: cd: {s}: not a directory\n", .{dest});
        return 1;
    }
    if (!fs.chdir(z)) {
        ctx.errFmt("wsh: cd: {s}: permission denied\n", .{dest});
        return 1;
    }
    ctx.sh.updateCwd() catch {};
    ctx.sh.setEnv("OLDPWD", dest) catch {};
    if (std.mem.eql(u8, target, "-")) {
        ctx.out(dest);
        ctx.out("\n");
    }
    return 0;
}

// --- environment and variables ---------------------------------------------

fn builtinExport(ctx: Ctx) u8 {
    if (ctx.argv.len == 1) {
        var it = ctx.sh.env.iterator();
        while (it.next()) |entry| {
            ctx.outFmt("{s}={s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const spec = ctx.argv[i];
        if (std.mem.indexOfScalar(u8, spec, '=')) |at| {
            const name = spec[0..at];
            if (!validName(name)) {
                ctx.errFmt("wsh: export: '{s}' is not a valid name\n", .{name});
                return 1;
            }
            ctx.sh.setEnv(name, spec[at + 1 ..]) catch return 1;
        } else {
            // `export NAME` promotes an existing variable.
            if (ctx.sh.getVar(spec)) |v| {
                const text = v.renderAlloc(ctx.sh.gpa) catch return 1;
                defer ctx.sh.gpa.free(text);
                ctx.sh.setEnv(spec, text) catch return 1;
            }
        }
    }
    return 0;
}

fn builtinUnset(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: unset: expected a name\n");
        return 1;
    }
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        if (!ctx.sh.unsetVar(ctx.argv[i])) _ = ctx.sh.unsetEnv(ctx.argv[i]);
    }
    return 0;
}

fn builtinSet(ctx: Ctx) u8 {
    // `set` with no arguments lists shell variables; `set NAME value` assigns.
    if (ctx.argv.len == 1) {
        var it = ctx.sh.vars.iterator();
        while (it.next()) |entry| {
            var out: std.Io.Writer.Allocating = .init(ctx.sh.gpa);
            defer out.deinit();
            entry.value_ptr.render(&out.writer) catch continue;
            ctx.outFmt("{s} = {s}\n", .{ entry.key_ptr.*, out.writer.buffered() });
        }
        return 0;
    }
    if (ctx.argv.len < 3) {
        ctx.err("wsh: set: expected NAME VALUE\n");
        return 1;
    }
    ctx.sh.setVar(ctx.argv[1], .{ .string = ctx.argv[2] }) catch return 1;
    return 0;
}

fn builtinAlias(ctx: Ctx) u8 {
    if (ctx.argv.len == 1) {
        var it = ctx.sh.aliases.iterator();
        while (it.next()) |entry| {
            ctx.outFmt("{s} = {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
        return 0;
    }
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const spec = ctx.argv[i];
        if (std.mem.indexOfScalar(u8, spec, '=')) |at| {
            ctx.sh.setAlias(spec[0..at], spec[at + 1 ..]) catch return 1;
        } else if (ctx.sh.getAlias(spec)) |text| {
            ctx.outFmt("{s}\n", .{text});
        } else {
            ctx.errFmt("wsh: alias: {s}: not found\n", .{spec});
            return 1;
        }
    }
    return 0;
}

fn builtinUnalias(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: unalias: expected a name\n");
        return 1;
    }
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        if (ctx.sh.aliases.fetchRemove(ctx.argv[i])) |kv| {
            ctx.sh.gpa.free(kv.key);
            ctx.sh.gpa.free(kv.value);
        }
    }
    return 0;
}

// --- exit ------------------------------------------------------------------

fn builtinExit(ctx: Ctx) u8 {
    var code = ctx.sh.last_status;
    if (ctx.arg(1)) |arg| {
        code = std.fmt.parseInt(u8, arg, 10) catch blk: {
            ctx.errFmt("wsh: exit: {s}: numeric argument required\n", .{arg});
            break :blk 2;
        };
    }
    ctx.sh.exit_code = code;
    ctx.sh.should_exit = true;
    return code;
}

// --- jobs ------------------------------------------------------------------

fn resolveJob(ctx: Ctx, spec: ?[]const u8) ?*jobs.Job {
    const text = spec orelse return ctx.sh.jobs.mostRecent();
    if (text.len == 0) return ctx.sh.jobs.mostRecent();
    if (std.mem.eql(u8, text, "%+") or std.mem.eql(u8, text, "%%")) {
        return ctx.sh.jobs.mostRecent();
    }
    const bare = if (text[0] == '%') text[1..] else text;
    if (std.fmt.parseInt(u32, bare, 10)) |id| {
        return ctx.sh.jobs.findById(id);
    } else |_| {}
    return ctx.sh.jobs.findByCommandPrefix(bare);
}

fn printJob(ctx: Ctx, job: *const jobs.Job, is_current: bool) void {
    const marker: u8 = if (job.state == .done) ' ' else if (is_current) '+' else '-';
    ctx.outFmt("[{d}] {c} {s}  {s}\n", .{ job.id, marker, job.state.label(), job.command });
}

fn builtinJobs(ctx: Ctx) u8 {
    ctx.sh.reapJobs();

    // The most recently started live job is the "current" one, like bash.
    var current: ?*jobs.Job = null;
    for (ctx.sh.jobs.jobs.items) |*job| {
        if (job.state != .done) current = job;
    }

    for (ctx.sh.jobs.jobs.items) |*job| {
        printJob(ctx, job, job == current);
        job.notified = true;
    }
    ctx.sh.jobs.sweep(ctx.sh.gpa);
    return 0;
}

fn builtinFg(ctx: Ctx) u8 {
    ctx.sh.reapJobs();
    const job = resolveJob(ctx, ctx.arg(1)) orelse {
        ctx.err("wsh: fg: no such job\n");
        return 1;
    };
    ctx.outFmt("{s}\n", .{job.command});
    return resumeJob(ctx, job, true);
}

fn builtinBg(ctx: Ctx) u8 {
    ctx.sh.reapJobs();
    const job = resolveJob(ctx, ctx.arg(1)) orelse {
        ctx.err("wsh: bg: no such job\n");
        return 1;
    };
    return resumeJob(ctx, job, false);
}

fn resumeJob(ctx: Ctx, job: *jobs.Job, foreground: bool) u8 {
    job.state = .running;
    job.notified = false;
    proc.signalGroup(job.pgid, .CONT);
    if (!foreground) {
        ctx.outFmt("[{d}] {s}\n", .{ job.id, job.command });
        return 0;
    }
    const outcome = ctx.sh.waitForeground(job);
    if (outcome.stopped) {
        job.state = .stopped;
        job.foreground = false;
        return outcome.status;
    }
    if (ctx.sh.jobs.indexOf(job)) |index| ctx.sh.jobs.removeAt(ctx.sh.gpa, index);
    return outcome.status;
}

// --- wait ------------------------------------------------------------------

fn builtinWait(ctx: Ctx) u8 {
    // Reap whatever already finished, then block on what is left.
    ctx.sh.reapJobs();

    var status: u8 = 0;
    for (ctx.sh.jobs.jobs.items) |*job| {
        if (job.state == .done) continue;
        const outcome = ctx.sh.waitForeground(job);
        status = outcome.status;
        job.state = .done;
        job.notified = true;
    }
    ctx.sh.jobs.sweep(ctx.sh.gpa);
    return status;
}

// --- history ---------------------------------------------------------------

fn builtinHistory(ctx: Ctx) u8 {
    const sub = ctx.arg(1);
    if (sub != null and std.mem.eql(u8, sub.?, "clear")) {
        for (ctx.sh.hist.entries.items) |entry| ctx.sh.gpa.free(entry);
        ctx.sh.hist.entries.clearRetainingCapacity();
        return 0;
    }

    var limit: usize = 0; // 0 means everything
    if (sub) |s| {
        if (std.fmt.parseInt(usize, s, 10)) |n| {
            limit = n;
        } else |_| {}
    }

    const total = ctx.sh.hist.count();
    const start = if (limit != 0 and total > limit) total - limit else 0;
    var i = start;
    while (i < total) : (i += 1) {
        ctx.outFmt("{d: >5}  {s}\n", .{ i + 1, ctx.sh.hist.get(i) });
    }
    return 0;
}

// --- lookup helpers --------------------------------------------------------

fn builtinWhich(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: which: expected a command name\n");
        return 1;
    }
    var status: u8 = 0;
    for (ctx.argv[1..]) |name| {
        if (lookup(name)) |b| {
            ctx.outFmt("{s}: shell builtin\n", .{name});
            _ = b;
            continue;
        }
        if (ctx.sh.getFunc(name) != null) {
            ctx.outFmt("{s}: shell function\n", .{name});
            continue;
        }
        if (ctx.sh.getAlias(name)) |text| {
            ctx.outFmt("{s}: aliased to {s}\n", .{ name, text });
            continue;
        }
        var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const resolved = proc.resolve(arena, name, ctx.sh.pathEnv()) catch null;
        if (resolved) |path| {
            ctx.outFmt("{s}\n", .{path});
        } else {
            ctx.errFmt("wsh: which: {s}: not found\n", .{name});
            status = 1;
        }
    }
    return status;
}

fn builtinRead(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: read: expected a variable name\n");
        return 1;
    }
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.sh.gpa);
    while (true) {
        const c = sys.readByte(ctx.stdin) orelse break;
        if (c == '\n') break;
        buf.append(ctx.sh.gpa, c) catch return 1;
    }
    const text = std.mem.trim(u8, buf.items, " \t\r");
    ctx.sh.setVar(ctx.argv[1], .{ .string = text }) catch return 1;
    return 0;
}

// --- test ------------------------------------------------------------------

fn testExpr(args: []const []const u8, pos: *usize) ?bool {
    if (pos.* >= args.len) return null;
    const arg = args[pos.*];
    pos.* += 1;

    if (std.mem.eql(u8, arg, "!")) {
        const inner = testExpr(args, pos) orelse return null;
        return !inner;
    }

    if (arg.len == 2 and arg[0] == '-') {
        const target = if (pos.* < args.len) args[pos.*] else return null;
        pos.* += 1;
        return switch (arg[1]) {
            'e' => pathExists(target),
            'f' => fileKind(target) == .file,
            'd' => fileKind(target) == .dir,
            'L', 'h' => fileKind(target) == .symlink,
            'z' => target.len == 0,
            'n' => target.len != 0,
            'r', 'w' => pathExists(target),
            else => null,
        };
    }

    if (pos.* < args.len) {
        const op = args[pos.*];
        if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) {
            pos.* += 1;
            const rhs = if (pos.* < args.len) args[pos.*] else return null;
            pos.* += 1;
            return std.mem.eql(u8, arg, rhs);
        }
        if (std.mem.eql(u8, op, "!=")) {
            pos.* += 1;
            const rhs = if (pos.* < args.len) args[pos.*] else return null;
            pos.* += 1;
            return !std.mem.eql(u8, arg, rhs);
        }
        if (std.mem.eql(u8, op, "-eq") or std.mem.eql(u8, op, "-ne") or
            std.mem.eql(u8, op, "-lt") or std.mem.eql(u8, op, "-le") or
            std.mem.eql(u8, op, "-gt") or std.mem.eql(u8, op, "-ge"))
        {
            pos.* += 1;
            const rhs_text = if (pos.* < args.len) args[pos.*] else return null;
            pos.* += 1;
            const lhs = std.fmt.parseInt(i64, arg, 10) catch return null;
            const rhs = std.fmt.parseInt(i64, rhs_text, 10) catch return null;
            if (std.mem.eql(u8, op, "-eq")) return lhs == rhs;
            if (std.mem.eql(u8, op, "-ne")) return lhs != rhs;
            if (std.mem.eql(u8, op, "-lt")) return lhs < rhs;
            if (std.mem.eql(u8, op, "-le")) return lhs <= rhs;
            if (std.mem.eql(u8, op, "-gt")) return lhs > rhs;
            return lhs >= rhs;
        }
    }

    // A bare word is true when non-empty.
    return arg.len != 0;
}

fn builtinTest(ctx: Ctx) u8 {
    // `testExpr` walks `ctx.argv[1..]`, so its cursor starts at zero.
    var pos: usize = 0;
    const result = testExpr(ctx.argv[1..], &pos) orelse {
        ctx.err("wsh: test: malformed expression\n");
        return 2;
    };
    return if (result) 0 else 1;
}

fn pathExists(path: []const u8) bool {
    var buf: [linux.PATH_MAX]u8 = undefined;
    if (path.len + 1 > buf.len) return false;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return fs.exists(buf[0..path.len :0]);
}

fn fileKind(path: []const u8) ?fs.Kind {
    var buf: [linux.PATH_MAX]u8 = undefined;
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return fs.kind(buf[0..path.len :0]);
}

fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const table = [_]Builtin{
    .{ .name = "cd", .summary = "change the working directory", .run = builtinCd },
    .{ .name = "pwd", .summary = "print the working directory", .run = builtinPwd },
    .{ .name = "echo", .summary = "print arguments", .run = builtinEcho },
    .{ .name = "print", .summary = "print arguments", .run = builtinPrint },
    .{ .name = "exit", .summary = "exit the shell", .run = builtinExit },
    .{ .name = "export", .summary = "set an environment variable", .run = builtinExport },
    .{ .name = "unset", .summary = "remove a variable", .run = builtinUnset },
    .{ .name = "set", .summary = "list or set shell variables", .run = builtinSet },
    .{ .name = "alias", .summary = "define or list aliases", .run = builtinAlias },
    .{ .name = "unalias", .summary = "remove an alias", .run = builtinUnalias },
    .{ .name = "jobs", .summary = "list background jobs", .run = builtinJobs },
    .{ .name = "wait", .summary = "wait for background jobs", .run = builtinWait },
    .{ .name = "fg", .summary = "bring a job to the foreground", .run = builtinFg },
    .{ .name = "bg", .summary = "resume a job in the background", .run = builtinBg },
    .{ .name = "history", .summary = "show command history", .run = builtinHistory },
    .{ .name = "which", .summary = "locate a command", .run = builtinWhich },
    .{ .name = "read", .summary = "read a line into a variable", .run = builtinRead },
    .{ .name = "test", .summary = "evaluate a condition", .run = builtinTest },
    .{ .name = "true", .summary = "return success", .run = builtinTrue },
    .{ .name = "false", .summary = "return failure", .run = builtinFalse },
    .{ .name = "clear", .summary = "clear the screen", .run = builtinClear },
};

test "echo joins its arguments" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const argv = [_][]const u8{ "echo", "hello", "world" };
    const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = -1 };
    try std.testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
}

test "test builtin" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const argv = [_][]const u8{ "test", "-d", "." };
        const ctx = Ctx{ .sh = &sh, .argv = &argv };
        try std.testing.expectEqual(@as(u8, 0), builtinTest(ctx));
    }
    {
        const argv = [_][]const u8{ "test", "-f", "." };
        const ctx = Ctx{ .sh = &sh, .argv = &argv };
        try std.testing.expectEqual(@as(u8, 1), builtinTest(ctx));
    }
    {
        const argv = [_][]const u8{ "test", "a", "=", "a" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv };
        try std.testing.expectEqual(@as(u8, 0), builtinTest(ctx));
    }
    {
        const argv = [_][]const u8{ "test", "2", "-lt", "10" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv };
        try std.testing.expectEqual(@as(u8, 0), builtinTest(ctx));
    }
}
