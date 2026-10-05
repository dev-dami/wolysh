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
const parallel = @import("parallel.zig");
const complete_builtin = @import("builtins/complete.zig");

const Shell = shellmod.Shell;

pub const Ctx = struct {
    sh: *Shell,
    /// Expanded arguments; `argv[0]` is the builtin name.
    argv: []const []const u8,
    stdin: i32 = 0,
    stdout: i32 = 1,
    stderr: i32 = 2,
    run_source: ?*const fn (*Shell, []const u8) u8 = null,

    pub fn arg(self: Ctx, index: usize) ?[]const u8 {
        if (index >= self.argv.len) return null;
        return self.argv[index];
    }

    pub fn out(self: Ctx, bytes: []const u8) void {
        sys.writeStr(self.stdout, bytes);
    }

    pub fn err(self: Ctx, bytes: []const u8) void {
        sys.writeStr(self.stderr, bytes);
    }

    pub fn errFmt(self: Ctx, comptime fmt: []const u8, args: anytype) void {
        var buf: [512]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.err(text);
    }

    pub fn outFmt(self: Ctx, comptime fmt: []const u8, args: anytype) void {
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

fn validEchoFlags(flags: []const u8) bool {
    for (flags) |c| {
        if (c != 'n' and c != 'e' and c != 'E') return false;
    }
    return true;
}

fn builtinEcho(ctx: Ctx) u8 {
    var newline = true;
    var escapes = false;

    // Leading flags only; `echo -- -n` still prints the literal argument.
    var start: usize = 1;
    while (start < ctx.argv.len) {
        const arg = ctx.argv[start];
        if (std.mem.eql(u8, arg, "--")) {
            start += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-' or !validEchoFlags(arg[1..])) break;
        for (arg[1..]) |c| {
            switch (c) {
                'n' => newline = false,
                'e' => escapes = true,
                'E' => escapes = false,
                else => {},
            }
        }
        start += 1;
    }

    var i = start;
    while (i < ctx.argv.len) : (i += 1) {
        if (i != start) ctx.out(" ");
        if (escapes) {
            if (writeEscaped(ctx, ctx.argv[i])) return 0;
        } else {
            ctx.out(ctx.argv[i]);
        }
    }
    if (newline) ctx.out("\n");
    return 0;
}

/// Writes `text`, expanding backslash escapes. Returns true when `\c` asked
/// for the rest of the output to be suppressed.
fn writeEscaped(ctx: Ctx, text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            ctx.out(text[i .. i + 1]);
            i += 1;
            continue;
        }
        i += 1;
        switch (text[i]) {
            'a' => ctx.out("\x07"),
            'b' => ctx.out("\x08"),
            'e' => ctx.out("\x1b"),
            'f' => ctx.out("\x0c"),
            'n' => ctx.out("\n"),
            'r' => ctx.out("\r"),
            't' => ctx.out("\t"),
            'v' => ctx.out("\x0b"),
            '\\' => ctx.out("\\"),
            '0'...'7' => {
                var octal: u32 = 0;
                var digits: usize = 0;
                if (text[i] == '0') i += 1;
                while (digits < 3 and i < text.len and text[i] >= '0' and text[i] <= '7') {
                    octal = octal * 8 + (text[i] - '0');
                    i += 1;
                    digits += 1;
                }
                var byte: [1]u8 = .{@intCast(octal & 0xff)};
                ctx.out(&byte);
                i -= 1;
            },
            'c' => return true,
            else => {
                ctx.out("\\");
                ctx.out(text[i .. i + 1]);
            },
        }
        i += 1;
    }
    return false;
}

fn builtinPrint(ctx: Ctx) u8 {
    // `print` is the scripting-language spelling: it also renders non-string
    // values, but by the time a builtin runs everything is already a string.
    return builtinEcho(ctx);
}

fn builtinPrintf(ctx: Ctx) u8 {
    const format = ctx.arg(1) orelse {
        ctx.err("wsh: printf: expected a format string\n");
        return 2;
    };
    const args = ctx.argv[2..];

    var out = sys.StringBuilder.init(ctx.sh.gpa);
    defer out.deinit();

    // POSIX reuses the format until the arguments are exhausted; a pass that
    // consumes nothing ends the loop, so a format without conversions prints
    // exactly once.
    var index: usize = 0;
    var first = true;
    while (first or index < args.len) {
        first = false;
        const before = index;
        printfOnce(&out, format, args, &index);
        if (index == before) break;
    }

    sys.writeStr(ctx.stdout, out.items());
    return 0;
}

fn printfOnce(out: *sys.StringBuilder, format: []const u8, args: []const []const u8, index: *usize) void {
    var i: usize = 0;
    while (i < format.len) : (i += 1) {
        const c = format[i];
        if (c == '\\') {
            const escape: u8 = if (i + 1 < format.len) format[i + 1] else 0;
            i += 1;
            switch (escape) {
                'a' => out.append("\x07") catch return,
                'b' => out.append("\x08") catch return,
                'e' => out.append("\x1b") catch return,
                'f' => out.append("\x0c") catch return,
                'n' => out.append("\n") catch return,
                'r' => out.append("\r") catch return,
                't' => out.append("\t") catch return,
                'v' => out.append("\x0b") catch return,
                '\\' => out.append("\\") catch return,
                '0'...'7' => {
                    var octal: u32 = 0;
                    var digits: usize = 0;
                    if (format[i] == '0') i += 1;
                    while (digits < 3 and i < format.len and format[i] >= '0' and format[i] <= '7') {
                        octal = octal * 8 + (format[i] - '0');
                        i += 1;
                        digits += 1;
                    }
                    i -= 1;
                    out.appendByte(@intCast(octal & 0xff)) catch return;
                },
                0 => {
                    out.append("\\") catch return;
                    return;
                },
                else => {
                    out.append("\\") catch return;
                    out.append(format[i .. i + 1]) catch return;
                },
            }
            continue;
        }
        if (c != '%' or i + 1 >= format.len) {
            out.appendByte(c) catch return;
            continue;
        }
        i += 1;
        switch (format[i]) {
            '%' => out.append("%") catch return,
            's' => out.append(nextArg(args, index)) catch return,
            'd', 'i' => {
                const text = nextArg(args, index);
                const n = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch 0;
                out.print("{d}", .{n}) catch return;
            },
            'c' => {
                const text = nextArg(args, index);
                if (text.len != 0) out.appendByte(text[0]) catch return;
            },
            else => {
                out.append("%") catch return;
                out.appendByte(format[i]) catch return;
            },
        }
    }
}

fn nextArg(args: []const []const u8, index: *usize) []const u8 {
    if (index.* >= args.len) {
        index.* += 1;
        return "";
    }
    const text = args[index.*];
    index.* += 1;
    return text;
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

fn builtinNoop(_: Ctx) u8 {
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

fn builtinPushd(ctx: Ctx) u8 {
    const target = ctx.arg(1) orelse {
        if (!(ctx.sh.swapDirs() catch return 1)) {
            ctx.err("wsh: pushd: directory stack empty\n");
            return 1;
        }
        return printDirs(ctx);
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const dest = ctx.sh.tildeExpand(arena, target) catch target;
    const z = arena.dupeZ(u8, dest) catch return 1;
    if (!fs.isDir(z)) {
        ctx.errFmt("wsh: pushd: {s}: not a directory\n", .{dest});
        return 1;
    }
    if (!(ctx.sh.pushDir(z) catch return 1)) {
        ctx.errFmt("wsh: pushd: {s}: cannot change directory\n", .{dest});
        return 1;
    }
    return printDirs(ctx);
}

fn builtinPopd(ctx: Ctx) u8 {
    if (!(ctx.sh.popDir() catch return 1)) {
        ctx.err("wsh: popd: directory stack empty\n");
        return 1;
    }
    return printDirs(ctx);
}

fn builtinDirs(ctx: Ctx) u8 {
    return printDirs(ctx);
}

fn printDirs(ctx: Ctx) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out = sys.StringBuilder.init(ctx.sh.gpa);
    defer out.deinit();

    out.append(ctx.sh.shortenHome(arena, ctx.sh.cwd) catch ctx.sh.cwd) catch return 1;
    for (ctx.sh.dir_stack.items) |dir| {
        out.append(" ") catch return 1;
        out.append(ctx.sh.shortenHome(arena, dir) catch dir) catch return 1;
    }
    out.append("\n") catch return 1;
    sys.writeStr(ctx.stdout, out.items());
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
    var status: u8 = 0;
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const spec = ctx.argv[i];
        if (std.mem.indexOfScalar(u8, spec, '=')) |at| {
            const name = spec[0..at];
            if (!validName(name)) {
                ctx.errFmt("wsh: export: '{s}' is not a valid name\n", .{name});
                status = 1;
                continue;
            }
            if (ctx.sh.isReadonly(name)) {
                ctx.errFmt("wsh: export: {s}: readonly variable\n", .{name});
                status = 1;
                continue;
            }
            ctx.sh.setEnv(name, spec[at + 1 ..]) catch return 1;
        } else {
            // `export NAME` promotes an existing variable.
            if (ctx.sh.isReadonly(spec)) {
                ctx.errFmt("wsh: export: {s}: readonly variable\n", .{spec});
                status = 1;
                continue;
            }
            if (ctx.sh.getVar(spec)) |v| {
                const text = v.renderAlloc(ctx.sh.gpa) catch return 1;
                defer ctx.sh.gpa.free(text);
                ctx.sh.setEnv(spec, text) catch return 1;
            }
        }
    }
    return status;
}

fn builtinUnset(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: unset: expected a name\n");
        return 1;
    }
    var status: u8 = 0;
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const name = ctx.argv[i];
        if (ctx.sh.isReadonly(name)) {
            ctx.errFmt("wsh: unset: {s}: readonly variable\n", .{name});
            status = 1;
            continue;
        }
        if (!ctx.sh.unsetVar(name)) _ = ctx.sh.unsetEnv(name);
    }
    return status;
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
    ctx.sh.assignVar(ctx.argv[1], .{ .string = ctx.argv[2] }) catch {
        ctx.errFmt("wsh: set: {s}: readonly variable\n", .{ctx.argv[1]});
        return 1;
    };
    return 0;
}

fn builtinLocal(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: local: expected a name\n");
        return 1;
    }
    var status: u8 = 0;
    for (ctx.argv[1..]) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, '=');
        const name = if (at) |i| spec[0..i] else spec;
        if (!validName(name)) {
            ctx.errFmt("wsh: local: '{s}' is not a valid name\n", .{name});
            status = 1;
            continue;
        }
        if (ctx.sh.isReadonly(name)) {
            ctx.errFmt("wsh: local: {s}: readonly variable\n", .{name});
            status = 1;
            continue;
        }
        const text = if (at) |i| spec[i + 1 ..] else "";
        ctx.sh.setLocal(name, .{ .string = text }) catch {
            ctx.errFmt("wsh: local: {s}: readonly variable\n", .{name});
            return 1;
        };
    }
    return status;
}

fn builtinReadonly(ctx: Ctx) u8 {
    if (ctx.argv.len == 1) {
        var it = ctx.sh.readonly.iterator();
        while (it.next()) |entry| ctx.outFmt("readonly {s}\n", .{entry.key_ptr.*});
        return 0;
    }
    var status: u8 = 0;
    for (ctx.argv[1..]) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, '=');
        const name = if (at) |i| spec[0..i] else spec;
        if (!validName(name)) {
            ctx.errFmt("wsh: readonly: '{s}' is not a valid name\n", .{name});
            status = 1;
            continue;
        }
        if (ctx.sh.isReadonly(name)) {
            ctx.errFmt("wsh: readonly: {s}: readonly variable\n", .{name});
            status = 1;
            continue;
        }
        if (at) |i| ctx.sh.setVar(name, .{ .string = spec[i + 1 ..] }) catch return 1;
        ctx.sh.markReadonly(name) catch return 1;
    }
    return status;
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

fn isDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

/// The job that owns `pid`, if any.
fn jobForPid(ctx: Ctx, pid: i32) ?*jobs.Job {
    for (ctx.sh.jobs.jobs.items) |*job| {
        if (job.last_pid == pid) return job;
        for (job.pids) |candidate| {
            if (candidate == pid) return job;
        }
    }
    return null;
}

fn finishJob(ctx: Ctx, job: *jobs.Job) u8 {
    if (job.state == .done) {
        job.notified = true;
        return job.status;
    }
    const outcome = ctx.sh.waitForeground(job);
    job.state = if (outcome.stopped) .stopped else .done;
    job.status = outcome.status;
    job.notified = !outcome.stopped;
    return outcome.status;
}

fn builtinWait(ctx: Ctx) u8 {
    ctx.sh.reapJobs();

    var next = false;
    var index: usize = 1;
    if (ctx.arg(1)) |first| {
        if (std.mem.eql(u8, first, "-n")) {
            next = true;
            index = 2;
        }
    }

    if (next) {
        var selected: std.ArrayList(u32) = .empty;
        const arena = ctx.sh.scratch();
        for (ctx.argv[index..]) |spec| {
            const job = if (isDigits(spec)) blk: {
                const number = std.fmt.parseInt(i32, spec, 10) catch break :blk null;
                if (number <= 0) break :blk null;
                break :blk jobForPid(ctx, number) orelse ctx.sh.jobs.findById(@intCast(number));
            } else resolveJob(ctx, spec);
            if (job == null) {
                ctx.errFmt("wsh: wait: {s}: no such job\n", .{spec});
                return 127;
            }
            selected.append(arena, job.?.id) catch return 1;
        }
        while (true) {
            ctx.sh.reapJobs();
            var running = false;
            for (ctx.sh.jobs.jobs.items) |*job| {
                if (selected.items.len != 0 and std.mem.indexOfScalar(u32, selected.items, job.id) == null) continue;
                if (job.state == .running) running = true;
                if (job.state != .done) continue;
                const status = job.status;
                const job_index = ctx.sh.jobs.indexOf(job).?;
                ctx.sh.jobs.removeAt(ctx.sh.gpa, job_index);
                return status;
            }
            if (!running or !ctx.sh.waitJobEvent()) return 127;
        }
    }

    if (index >= ctx.argv.len) {
        for (ctx.sh.jobs.jobs.items) |*job| {
            _ = finishJob(ctx, job);
        }
        ctx.sh.jobs.sweep(ctx.sh.gpa);
        return 0;
    }

    var status: u8 = 0;
    while (index < ctx.argv.len) : (index += 1) {
        const spec = ctx.argv[index];

        // A bare number is a job id, a pid belonging to a job, or a raw pid.
        if (isDigits(spec)) {
            const number = std.fmt.parseInt(i32, spec, 10) catch {
                ctx.errFmt("wsh: wait: {s}: no such job\n", .{spec});
                status = 127;
                continue;
            };
            if (number <= 0) {
                ctx.errFmt("wsh: wait: {s}: not a child of this shell\n", .{spec});
                status = 127;
                continue;
            }
            if (ctx.sh.jobs.findById(@intCast(number))) |job| {
                status = finishJob(ctx, job);
                continue;
            }
            if (jobForPid(ctx, number)) |job| {
                status = finishJob(ctx, job);
                continue;
            }
            if (proc.waitPid(number, 0)) |st| {
                status = st.exitCode();
            } else {
                ctx.errFmt("wsh: wait: {s}: not a child of this shell\n", .{spec});
                status = 127;
            }
            continue;
        }

        const job = resolveJob(ctx, spec) orelse {
            ctx.errFmt("wsh: wait: {s}: no such job\n", .{spec});
            status = 127;
            continue;
        };
        status = finishJob(ctx, job);
    }
    ctx.sh.jobs.sweep(ctx.sh.gpa);
    return status;
}

// --- signals ---------------------------------------------------------------

fn builtinKill(ctx: Ctx) u8 {
    var sig: linux.SIG = .TERM;
    // `kill -0` / `kill -s 0` only tests that the target exists.
    var probe = false;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "-s")) {
            index += 1;
            if (index >= ctx.argv.len) {
                ctx.err("wsh: kill: -s needs a signal\n");
                return 1;
            }
            if (std.mem.eql(u8, ctx.argv[index], "0")) {
                probe = true;
                continue;
            }
            sig = proc.signalFromName(ctx.argv[index]) orelse {
                ctx.errFmt("wsh: kill: {s}: invalid signal\n", .{ctx.argv[index]});
                return 1;
            };
            continue;
        }
        if (std.mem.eql(u8, arg, "-0")) {
            probe = true;
            continue;
        }
        sig = proc.signalFromName(arg[1..]) orelse {
            ctx.errFmt("wsh: kill: {s}: invalid signal\n", .{arg});
            return 1;
        };
    }

    if (index >= ctx.argv.len) {
        ctx.err("wsh: kill: expected a pid or job\n");
        return 1;
    }

    var status: u8 = 0;
    while (index < ctx.argv.len) : (index += 1) {
        const target = ctx.argv[index];
        if (target.len != 0 and target[0] == '%') {
            const job = resolveJob(ctx, target) orelse {
                ctx.errFmt("wsh: kill: {s}: no such job\n", .{target});
                status = 1;
                continue;
            };
            if (!probe) proc.signalGroup(job.pgid, sig);
            continue;
        }
        const pid = std.fmt.parseInt(i32, target, 10) catch {
            ctx.errFmt("wsh: kill: {s}: invalid pid\n", .{target});
            status = 1;
            continue;
        };
        if (probe) {
            if (!proc.probeProcess(pid)) {
                ctx.errFmt("wsh: kill: {s}: no such process\n", .{target});
                status = 1;
            }
            continue;
        }
        proc.signalProcess(pid, sig);
    }
    return status;
}

fn builtinTrap(ctx: Ctx) u8 {
    if (ctx.argv.len == 1) return listTraps(ctx, &.{});

    var index: usize = 1;
    if (std.mem.eql(u8, ctx.argv[index], "-p")) {
        index += 1;
        return listTraps(ctx, ctx.argv[index..]);
    }
    if (std.mem.eql(u8, ctx.argv[index], "-")) {
        index += 1;
        return resetTraps(ctx, ctx.argv[index..]);
    }
    // A single bare signal resets that handler, like `trap - INT`. With two or
    // more operands the first is the handler and the rest are the signals.
    if (index + 1 == ctx.argv.len and allSignals(ctx.argv[index..])) return resetTraps(ctx, ctx.argv[index..]);
    if (index + 1 >= ctx.argv.len) {
        ctx.err("wsh: trap: expected a signal\n");
        return 1;
    }
    return setTraps(ctx, ctx.argv[index], ctx.argv[index + 1 ..]);
}

fn allSignals(tokens: []const []const u8) bool {
    if (tokens.len == 0) return false;
    for (tokens) |token| {
        if (proc.signalFromName(token) == null) return false;
    }
    return true;
}

fn listTraps(ctx: Ctx, tokens: []const []const u8) u8 {
    if (tokens.len == 0) {
        var sig: u32 = 1;
        while (sig <= Shell.max_signal) : (sig += 1) {
            if (ctx.sh.getTrap(sig)) |handler| printTrap(ctx, sig, handler);
        }
        return 0;
    }
    var status: u8 = 0;
    for (tokens) |token| {
        const sig = proc.signalFromName(token) orelse {
            ctx.errFmt("wsh: trap: {s}: invalid signal\n", .{token});
            status = 1;
            continue;
        };
        const number = @intFromEnum(sig);
        if (ctx.sh.getTrap(number)) |handler| printTrap(ctx, number, handler);
    }
    return status;
}

fn printTrap(ctx: Ctx, sig: u32, handler: []const u8) void {
    ctx.outFmt("trap -- '{s}' {s}\n", .{ handler, proc.signalName(sig) });
}

fn setTraps(ctx: Ctx, handler: []const u8, tokens: []const []const u8) u8 {
    var status: u8 = 0;
    for (tokens) |token| {
        const sig = proc.signalFromName(token) orelse {
            ctx.errFmt("wsh: trap: {s}: invalid signal\n", .{token});
            status = 1;
            continue;
        };
        if (proc.isUncatchable(sig)) {
            ctx.errFmt("wsh: trap: {s}: cannot be caught\n", .{token});
            status = 1;
            continue;
        }
        ctx.sh.setTrap(@intFromEnum(sig), handler) catch return 1;
        if (handler.len == 0) {
            proc.installHandler(sig, linux.SIG.IGN);
        } else {
            proc.installHandler(sig, shellmod.trapHandler);
        }
    }
    return status;
}

fn resetTraps(ctx: Ctx, tokens: []const []const u8) u8 {
    if (tokens.len == 0) {
        ctx.err("wsh: trap: expected a signal\n");
        return 1;
    }
    var status: u8 = 0;
    for (tokens) |token| {
        const sig = proc.signalFromName(token) orelse {
            ctx.errFmt("wsh: trap: {s}: invalid signal\n", .{token});
            status = 1;
            continue;
        };
        _ = ctx.sh.clearTrap(@intFromEnum(sig));
        proc.installHandler(sig, linux.SIG.DFL);
    }
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

/// Classifies `name` the way `type` (verbose) or `command -v` (terse) does.
fn describe(ctx: Ctx, name: []const u8, verbose: bool) u8 {
    if (ctx.sh.getFunc(name) != null) {
        if (verbose) {
            ctx.outFmt("{s} is a shell function\n", .{name});
        } else {
            ctx.outFmt("{s}\n", .{name});
        }
        return 0;
    }
    if (ctx.sh.getAlias(name)) |text| {
        if (verbose) {
            ctx.outFmt("{s} is aliased to `{s}'\n", .{ name, text });
        } else {
            ctx.outFmt("{s}\n", .{name});
        }
        return 0;
    }
    if (lookup(name) != null) {
        if (verbose) {
            ctx.outFmt("{s} is a shell builtin\n", .{name});
        } else {
            ctx.outFmt("{s}\n", .{name});
        }
        return 0;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const resolved = proc.resolve(arena, name, ctx.sh.pathEnv()) catch null;
    if (resolved) |path| {
        if (verbose) {
            ctx.outFmt("{s} is {s}\n", .{ name, path });
        } else {
            ctx.outFmt("{s}\n", .{path});
        }
        return 0;
    }

    if (verbose) ctx.errFmt("wsh: type: {s}: not found\n", .{name});
    return 1;
}

fn builtinType(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: type: expected a name\n");
        return 1;
    }
    var status: u8 = 0;
    for (ctx.argv[1..]) |name| {
        if (describe(ctx, name, true) != 0) status = 1;
    }
    return status;
}

fn builtinCommand(ctx: Ctx) u8 {
    var index: usize = 1;
    var terse = false;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "-v")) {
            terse = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        break;
    }
    if (index >= ctx.argv.len) return 0;

    if (terse) {
        var status: u8 = 0;
        for (ctx.argv[index..]) |name| {
            if (describe(ctx, name, false) != 0) status = 1;
        }
        return status;
    }

    const call = ctx.argv[index..];
    if (lookup(call[0])) |b| {
        const inner = Ctx{
            .sh = ctx.sh,
            .argv = call,
            .stdin = ctx.stdin,
            .stdout = ctx.stdout,
            .stderr = ctx.stderr,
            .run_source = ctx.run_source,
        };
        return b.run(inner);
    }
    return runExternal(ctx, call);
}

fn builtinBuiltin(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) {
        ctx.err("wsh: builtin: expected a builtin name\n");
        return 1;
    }
    const b = lookup(ctx.argv[1]) orelse {
        ctx.errFmt("wsh: builtin: {s}: not a shell builtin\n", .{ctx.argv[1]});
        return 1;
    };
    const inner = Ctx{
        .sh = ctx.sh,
        .argv = ctx.argv[1..],
        .stdin = ctx.stdin,
        .stdout = ctx.stdout,
        .stderr = ctx.stderr,
        .run_source = ctx.run_source,
    };
    return b.run(inner);
}

fn builtinParallel(ctx: Ctx) u8 {
    const run_source = ctx.run_source orelse {
        ctx.err("wsh: parallel: executor unavailable\n");
        return 1;
    };
    return parallel.run(ctx.sh, ctx.argv, run_source);
}

/// Forks and execs `argv` through `PATH`, waiting for it like a foreground
/// job. `command NAME` and the function-less path use this.
fn runExternal(ctx: Ctx, argv: []const []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const resolved = (proc.resolve(arena, argv[0], ctx.sh.pathEnv()) catch null) orelse {
        ctx.errFmt("wsh: {s}: command not found\n", .{argv[0]});
        return 127;
    };

    const exec = arena.create(proc.Exec) catch return 1;
    exec.* = .{
        .path = (arena.dupeZ(u8, resolved) catch return 1).ptr,
        .argv = proc.buildArgv(arena, argv) catch return 1,
        .envp = ctx.sh.buildEnvp(arena) catch return 1,
    };

    const stage = proc.Stage{
        .exec = exec,
        .stdio = .{ .in = ctx.stdin, .out = ctx.stdout, .err = ctx.stderr },
    };
    const launched = proc.launch(arena, &.{stage}, .{ .new_group = ctx.sh.job_control }) catch return 1;
    const job = ctx.sh.jobs.add(ctx.sh.gpa, launched.pgid, launched.pids, argv[0], true) catch return 1;
    const outcome = ctx.sh.waitForeground(job);
    if (ctx.sh.jobs.indexOf(job)) |idx| ctx.sh.jobs.removeAt(ctx.sh.gpa, idx);
    return outcome.status;
}

// --- positional parameters --------------------------------------------------

fn builtinShift(ctx: Ctx) u8 {
    var count: usize = 1;
    if (ctx.arg(1)) |text| {
        count = std.fmt.parseInt(usize, text, 10) catch {
            ctx.errFmt("wsh: shift: {s}: numeric argument required\n", .{text});
            return 1;
        };
    }
    if (count > ctx.sh.positional.len) {
        ctx.err("wsh: shift: not enough positional parameters\n");
        return 1;
    }
    ctx.sh.positional = ctx.sh.positional[count..];
    return 0;
}

// --- umask ------------------------------------------------------------------

fn builtinUmask(ctx: Ctx) u8 {
    if (ctx.arg(1)) |text| {
        const mode = std.fmt.parseInt(u32, text, 8) catch {
            ctx.errFmt("wsh: umask: {s}: invalid octal mode\n", .{text});
            return 1;
        };
        _ = sys.umask(mode);
        return 0;
    }
    // There is no way to read the mask without setting it, so restore it.
    const current = sys.umask(0);
    _ = sys.umask(current);
    ctx.outFmt("{o:0>3}\n", .{current});
    return 0;
}

// --- exec -------------------------------------------------------------------

fn builtinExec(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) return 0;

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = ctx.argv[1];
    const resolved = (proc.resolve(arena, name, ctx.sh.pathEnv()) catch null) orelse {
        ctx.errFmt("wsh: exec: {s}: command not found\n", .{name});
        return markExecFailure(ctx);
    };
    const path = arena.dupeZ(u8, resolved) catch return 127;
    const argv = proc.buildArgv(arena, ctx.argv[1..]) catch return 127;
    const envp = ctx.sh.buildEnvp(arena) catch return 127;

    // Children get the default dispositions back; exec does not fork.
    proc.resetSignals();
    const rc = linux.execve(path.ptr, argv, envp);

    if (linux.errno(rc) == .NOEXEC) {
        const script_argv = arena.alloc([]const u8, ctx.argv.len + 1) catch return 127;
        script_argv[0] = "/bin/sh";
        script_argv[1] = resolved;
        for (ctx.argv[2..], 0..) |argument, index| script_argv[index + 2] = argument;
        const shell_argv = proc.buildArgv(arena, script_argv) catch return 127;
        _ = linux.execve("/bin/sh", shell_argv, envp);
    }

    ctx.errFmt("wsh: exec: {s}: cannot execute\n", .{name});
    return markExecFailure(ctx);
}

/// A failed `exec` is fatal to a non-interactive shell, as POSIX requires.
fn markExecFailure(ctx: Ctx) u8 {
    if (!ctx.sh.interactive) {
        ctx.sh.should_exit = true;
        ctx.sh.exit_code = 127;
    }
    return 127;
}

// --- read -------------------------------------------------------------------

/// Copies the current `IFS` into `buf`: the value must survive the assignments
/// `read` performs, which would otherwise reallocate it underneath us.
fn readIfs(sh: *Shell, buf: []u8) []const u8 {
    const v = sh.getVar("IFS") orelse return " \t\n";
    if (std.meta.activeTag(v) != .string) return " \t\n";
    if (v.string.len > buf.len) return " \t\n";
    @memcpy(buf[0..v.string.len], v.string);
    return buf[0..v.string.len];
}

fn isIfsWhitespace(c: u8, ifs: []const u8) bool {
    if (c != ' ' and c != '\t' and c != '\n') return false;
    return std.mem.indexOfScalar(u8, ifs, c) != null;
}

fn isIfsChar(c: u8, ifs: []const u8) bool {
    return std.mem.indexOfScalar(u8, ifs, c) != null;
}

/// Pulls one field out of `line`, the way the shell splits unquoted words:
/// runs of IFS whitespace delimit, a non-whitespace IFS character delimits on
/// its own and can leave an empty field. The final field keeps the rest of the
/// line with its trailing IFS whitespace removed.
fn nextField(line: []const u8, pos: *usize, ifs: []const u8, last: bool) ?[]const u8 {
    while (pos.* < line.len and isIfsWhitespace(line[pos.*], ifs)) pos.* += 1;
    if (pos.* >= line.len) return null;

    const start = pos.*;
    if (last) {
        var end = line.len;
        while (end > start and isIfsWhitespace(line[end - 1], ifs)) end -= 1;
        pos.* = line.len;
        return line[start..end];
    }

    var field: []const u8 = "";
    if (!isIfsChar(line[pos.*], ifs)) {
        while (pos.* < line.len and !isIfsChar(line[pos.*], ifs)) pos.* += 1;
        field = line[start..pos.*];
    }

    // Consume the delimiter: IFS whitespace, then one non-whitespace IFS
    // character with any whitespace that follows it.
    while (pos.* < line.len and isIfsWhitespace(line[pos.*], ifs)) pos.* += 1;
    if (pos.* < line.len and isIfsChar(line[pos.*], ifs) and !isIfsWhitespace(line[pos.*], ifs)) {
        pos.* += 1;
        while (pos.* < line.len and isIfsWhitespace(line[pos.*], ifs)) pos.* += 1;
    }
    return field;
}

fn builtinRead(ctx: Ctx) u8 {
    var raw = false;
    var prompt: ?[]const u8 = null;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        if (std.mem.eql(u8, arg, "-r")) {
            raw = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            index += 1;
            if (index >= ctx.argv.len) {
                ctx.err("wsh: read: -p needs a prompt\n");
                return 2;
            }
            prompt = ctx.argv[index];
        } else {
            ctx.errFmt("wsh: read: {s}: invalid option\n", .{arg});
            return 2;
        }
    }

    if (index >= ctx.argv.len) {
        ctx.err("wsh: read: expected a variable name\n");
        return 2;
    }
    const names = ctx.argv[index..];
    for (names) |name| {
        if (!validName(name)) {
            ctx.errFmt("wsh: read: '{s}' is not a valid name\n", .{name});
            return 2;
        }
        if (ctx.sh.isReadonly(name)) {
            ctx.errFmt("wsh: read: {s}: readonly variable\n", .{name});
            return 1;
        }
    }

    if (prompt) |text| ctx.err(text);

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.sh.gpa);

    while (true) {
        const c = sys.readByte(ctx.stdin) orelse break;
        if (!raw and c == '\\') {
            const escaped = sys.readByte(ctx.stdin) orelse break;
            // Without -r, a trailing backslash continues onto the next line.
            if (escaped == '\n') continue;
            buf.append(ctx.sh.gpa, escaped) catch return 1;
            continue;
        }
        if (c == '\n') break;
        buf.append(ctx.sh.gpa, c) catch return 1;
    }

    const line = std.mem.trimEnd(u8, buf.items, "\r");
    var ifs_buf: [64]u8 = undefined;
    const ifs = readIfs(ctx.sh, &ifs_buf);
    var pos: usize = 0;
    for (names, 0..) |name, i| {
        const last = i + 1 == names.len;
        const field = nextField(line, &pos, ifs, last) orelse "";
        ctx.sh.assignVar(name, .{ .string = field }) catch return 1;
    }
    return 0;
}

// --- test ------------------------------------------------------------------

const TestParser = struct {
    args: []const []const u8,
    pos: usize = 0,

    fn peek(self: *TestParser) ?[]const u8 {
        if (self.pos >= self.args.len) return null;
        return self.args[self.pos];
    }

    fn next(self: *TestParser) ?[]const u8 {
        const text = self.peek() orelse return null;
        self.pos += 1;
        return text;
    }

    /// `-o` binds loosest, then `-a`, then `!`, as POSIX specifies.
    fn parseOr(self: *TestParser) ?bool {
        var acc = self.parseAnd() orelse return null;
        while (self.peek()) |tok| {
            if (!std.mem.eql(u8, tok, "-o")) break;
            _ = self.next();
            const rhs = self.parseAnd() orelse return null;
            acc = acc or rhs;
        }
        return acc;
    }

    fn parseAnd(self: *TestParser) ?bool {
        var acc = self.parseNot() orelse return null;
        while (self.peek()) |tok| {
            if (!std.mem.eql(u8, tok, "-a")) break;
            _ = self.next();
            const rhs = self.parseNot() orelse return null;
            acc = acc and rhs;
        }
        return acc;
    }

    fn parseNot(self: *TestParser) ?bool {
        if (self.peek()) |tok| {
            if (std.mem.eql(u8, tok, "!")) {
                _ = self.next();
                const inner = self.parseNot() orelse return null;
                return !inner;
            }
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *TestParser) ?bool {
        const tok = self.next() orelse return null;

        if (std.mem.eql(u8, tok, "(")) {
            const inner = self.parseOr() orelse return null;
            const close = self.next() orelse return null;
            if (!std.mem.eql(u8, close, ")")) return null;
            return inner;
        }

        // A binary comparison wins when the next token is an operator, so an
        // operand that happens to look like a unary flag (`test -n = -n`) is
        // still compared rather than read as a flag.
        if (self.peek()) |op| {
            if (isBinaryOp(op)) {
                _ = self.next();
                const rhs = self.next() orelse return null;
                return binaryTest(tok, op, rhs);
            }
        }

        if (isUnaryOp(tok)) {
            const operand = self.next() orelse return null;
            return unaryTest(tok, operand);
        }

        // A bare word is true when non-empty.
        return tok.len != 0;
    }
};

fn isUnaryOp(tok: []const u8) bool {
    if (tok.len != 2 or tok[0] != '-') return false;
    return switch (tok[1]) {
        'e', 'f', 'd', 'L', 'h', 'r', 'w', 'x', 's', 'z', 'n', 't' => true,
        else => false,
    };
}

fn isBinaryOp(tok: []const u8) bool {
    return std.mem.eql(u8, tok, "=") or std.mem.eql(u8, tok, "==") or
        std.mem.eql(u8, tok, "!=") or std.mem.eql(u8, tok, "-eq") or
        std.mem.eql(u8, tok, "-ne") or std.mem.eql(u8, tok, "-lt") or
        std.mem.eql(u8, tok, "-le") or std.mem.eql(u8, tok, "-gt") or
        std.mem.eql(u8, tok, "-ge");
}

fn unaryTest(op: []const u8, operand: []const u8) ?bool {
    switch (op[1]) {
        'z' => return operand.len == 0,
        'n' => return operand.len != 0,
        't' => {
            const fd = std.fmt.parseInt(i32, operand, 10) catch return false;
            return sys.isTty(fd);
        },
        else => {},
    }

    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = cstr(&buf, operand) orelse return null;
    return switch (op[1]) {
        'e' => fs.exists(z),
        'f' => fs.kind(z) == .file,
        'd' => fs.kind(z) == .dir,
        'L', 'h' => fs.kind(z) == .symlink,
        'r' => sys.canAccess(z, 4),
        'w' => sys.canAccess(z, 2),
        'x' => sys.canAccess(z, 1),
        's' => if (sys.fileSize(z)) |size| size > 0 else false,
        else => null,
    };
}

fn binaryTest(lhs: []const u8, op: []const u8, rhs: []const u8) ?bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, lhs, rhs);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, lhs, rhs);

    const left = std.fmt.parseInt(i64, lhs, 10) catch return null;
    const right = std.fmt.parseInt(i64, rhs, 10) catch return null;
    if (std.mem.eql(u8, op, "-eq")) return left == right;
    if (std.mem.eql(u8, op, "-ne")) return left != right;
    if (std.mem.eql(u8, op, "-lt")) return left < right;
    if (std.mem.eql(u8, op, "-le")) return left <= right;
    if (std.mem.eql(u8, op, "-gt")) return left > right;
    return left >= right;
}

fn builtinTest(ctx: Ctx) u8 {
    return runTest(ctx, false);
}

fn builtinBracket(ctx: Ctx) u8 {
    return runTest(ctx, true);
}

fn runTest(ctx: Ctx, bracket: bool) u8 {
    var args = ctx.argv[1..];
    if (bracket) {
        if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
            ctx.err("wsh: [: missing `]'\n");
            return 2;
        }
        args = args[0 .. args.len - 1];
    }

    // POSIX: no arguments is false, one argument is "is it non-empty".
    if (args.len == 0) return 1;
    if (args.len == 1) return if (args[0].len != 0) 0 else 1;

    var parser = TestParser{ .args = args };
    const result = parser.parseOr() orelse {
        ctx.err("wsh: test: malformed expression\n");
        return 2;
    };
    if (parser.pos != args.len) {
        ctx.err("wsh: test: malformed expression\n");
        return 2;
    }
    return if (result) 0 else 1;
}

fn cstr(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len + 1 > buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

pub fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

const table = [_]Builtin{
    .{ .name = ":", .summary = "do nothing successfully", .run = builtinNoop },
    .{ .name = "cd", .summary = "change the working directory", .run = builtinCd },
    .{ .name = "pwd", .summary = "print the working directory", .run = builtinPwd },
    .{ .name = "pushd", .summary = "push a directory onto the stack", .run = builtinPushd },
    .{ .name = "popd", .summary = "pop a directory off the stack", .run = builtinPopd },
    .{ .name = "dirs", .summary = "print the directory stack", .run = builtinDirs },
    .{ .name = "echo", .summary = "print arguments", .run = builtinEcho },
    .{ .name = "print", .summary = "print arguments", .run = builtinPrint },
    .{ .name = "printf", .summary = "format and print arguments", .run = builtinPrintf },
    .{ .name = "exit", .summary = "exit the shell", .run = builtinExit },
    .{ .name = "export", .summary = "set an environment variable", .run = builtinExport },
    .{ .name = "unset", .summary = "remove a variable", .run = builtinUnset },
    .{ .name = "set", .summary = "list or set shell variables", .run = builtinSet },
    .{ .name = "local", .summary = "declare a function-local variable", .run = builtinLocal },
    .{ .name = "readonly", .summary = "mark variables readonly", .run = builtinReadonly },
    .{ .name = "alias", .summary = "define or list aliases", .run = builtinAlias },
    .{ .name = "unalias", .summary = "remove an alias", .run = builtinUnalias },
    .{ .name = "jobs", .summary = "list background jobs", .run = builtinJobs },
    .{ .name = "wait", .summary = "wait for background jobs", .run = builtinWait },
    .{ .name = "parallel", .summary = "run commands with bounded concurrency", .run = builtinParallel },
    .{ .name = "fg", .summary = "bring a job to the foreground", .run = builtinFg },
    .{ .name = "bg", .summary = "resume a job in the background", .run = builtinBg },
    .{ .name = "kill", .summary = "send a signal to a process or job", .run = builtinKill },
    .{ .name = "trap", .summary = "set or clear signal handlers", .run = builtinTrap },
    .{ .name = "history", .summary = "show command history", .run = builtinHistory },
    .{ .name = "which", .summary = "locate a command", .run = builtinWhich },
    .{ .name = "type", .summary = "describe how a name would be resolved", .run = builtinType },
    .{ .name = "command", .summary = "run a command bypassing functions", .run = builtinCommand },
    .{ .name = "builtin", .summary = "run a shell builtin directly", .run = builtinBuiltin },
    .{ .name = "read", .summary = "read a line into variables", .run = builtinRead },
    .{ .name = "shift", .summary = "shift positional parameters", .run = builtinShift },
    .{ .name = "umask", .summary = "get or set the file-creation mask", .run = builtinUmask },
    .{ .name = "exec", .summary = "replace the shell with a command", .run = builtinExec },
    .{ .name = "test", .summary = "evaluate a condition", .run = builtinTest },
    .{ .name = "[", .summary = "evaluate a condition", .run = builtinBracket },
    .{ .name = "true", .summary = "return success", .run = builtinTrue },
    .{ .name = "false", .summary = "return failure", .run = builtinFalse },
    .{ .name = "clear", .summary = "clear the screen", .run = builtinClear },
    .{ .name = "complete", .summary = "define how arguments of a command complete", .run = complete_builtin.runComplete },
    .{ .name = "compgen", .summary = "print completion candidates", .run = complete_builtin.runCompgen },
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

/// Captures a builtin's stdout through a pipe.
const Capture = struct {
    read_fd: i32,
    write_fd: i32,

    fn open() !Capture {
        var fds: [2]i32 = undefined;
        if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
        return .{ .read_fd = fds[0], .write_fd = fds[1] };
    }

    fn finish(self: Capture, allocator: std.mem.Allocator) ![]u8 {
        _ = linux.close(self.write_fd);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        var buf: [4096]u8 = undefined;
        while (true) {
            const n = sys.readSome(self.read_fd, &buf) orelse break;
            if (n == 0) break;
            try out.appendSlice(allocator, buf[0..n]);
        }
        _ = linux.close(self.read_fd);
        return out.toOwnedSlice(allocator);
    }
};

/// Fills a pipe with `input` and returns its read end.
fn inputPipe(input: []const u8) !i32 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    if (input.len != 0) _ = linux.write(fds[1], input.ptr, input.len);
    _ = linux.close(fds[1]);
    return fds[0];
}

var trap_hits: usize = 0;

fn testTrapRunner(_: *Shell, _: []const u8) u8 {
    trap_hits += 1;
    return 0;
}

test "echo joins its arguments" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const argv = [_][]const u8{ "echo", "hello", "world" };
    const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = -1 };
    try std.testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
}

test "echo bundles flags and expands escapes" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "echo", "-ne", "a\\tb" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd };
        try testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a\tb", out);
    }
    {
        // `-x` is not a flag, so the whole word is printed literally.
        const cap = try Capture.open();
        const argv = [_][]const u8{ "echo", "-n", "-x" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd };
        try testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("-x", out);
    }
    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "echo", "-nE", "a\\tb", "c" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd };
        try testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("a\\tb c", out);
    }
    {
        // `\c` suppresses the rest of the output, including the newline.
        const cap = try Capture.open();
        const argv = [_][]const u8{ "echo", "-e", "stop\\chere" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd };
        try testing.expectEqual(@as(u8, 0), builtinEcho(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("stop", out);
    }
}

test "printf formats, escapes and reuses its format" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const cap = try Capture.open();
    {
        const argv = [_][]const u8{ "printf", "%s=%d\\n", "a", "3" };
        try testing.expectEqual(@as(u8, 0), builtinPrintf(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
    }
    {
        const argv = [_][]const u8{ "printf", "%s\\n", "x", "y" };
        try testing.expectEqual(@as(u8, 0), builtinPrintf(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
    }
    {
        const argv = [_][]const u8{ "printf", "%c%%", "Z" };
        try testing.expectEqual(@as(u8, 0), builtinPrintf(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
    }
    {
        // No conversions: the format is printed once even with extra arguments.
        const argv = [_][]const u8{ "printf", "hi\\n", "a", "b" };
        try testing.expectEqual(@as(u8, 0), builtinPrintf(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
    }
    const out = try cap.finish(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("a=3\nx\ny\nZ%hi\n", out);
}

test "wait with no jobs succeeds and rejects unknown specs" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const none = [_][]const u8{"wait"};
    try testing.expectEqual(@as(u8, 0), builtinWait(Ctx{ .sh = &sh, .argv = &none, .stderr = -1 }));

    // With nothing running `wait -n` reports 127, like the reference shells.
    const next = [_][]const u8{ "wait", "-n" };
    try testing.expectEqual(@as(u8, 127), builtinWait(Ctx{ .sh = &sh, .argv = &next, .stderr = -1 }));

    const missing = [_][]const u8{ "wait", "%9" };
    try testing.expectEqual(@as(u8, 127), builtinWait(Ctx{ .sh = &sh, .argv = &missing, .stderr = -1 }));

    const bogus_pid = [_][]const u8{ "wait", "2147483" };
    try testing.expectEqual(@as(u8, 127), builtinWait(Ctx{ .sh = &sh, .argv = &bogus_pid, .stderr = -1 }));

    // Out-of-range and group-wide numbers must never reach `waitpid(0, ...)`.
    const huge = [_][]const u8{ "wait", "99999999999" };
    try testing.expectEqual(@as(u8, 127), builtinWait(Ctx{ .sh = &sh, .argv = &huge, .stderr = -1 }));

    const zero = [_][]const u8{ "wait", "0" };
    try testing.expectEqual(@as(u8, 127), builtinWait(Ctx{ .sh = &sh, .argv = &zero, .stderr = -1 }));
}

test "wait blocks on a named job and reports its status" {
    for ([_]bool{ false, true }) |pre_reap| {
        var sh = try Shell.initBare(std.testing.allocator);
        defer sh.deinit();

        var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const exec = try arena.create(proc.Exec);
        exec.* = .{
            .path = "/bin/sh",
            .argv = try proc.buildArgv(arena, &.{ "sh", "-c", "exit 7" }),
            .envp = try proc.buildArgv(arena, &.{"PATH=/usr/bin:/bin"}),
        };
        const launched = try proc.launch(arena, &.{.{ .exec = exec }}, .{ .new_group = false });
        _ = try sh.jobs.add(testing.allocator, launched.pgid, launched.pids, "sh -c exit 7", false);

        if (pre_reap) {
            while (sh.jobs.findById(1).?.state != .done) {
                try testing.expect(sh.waitJobEvent());
            }
        }
        const argv = [_][]const u8{ "wait", "%1" };
        try testing.expectEqual(@as(u8, 7), builtinWait(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expectEqual(@as(usize, 0), sh.jobs.count());
    }
}

test "read splits on IFS, honours -r and prompts" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const fd = try inputPipe("one two three\n");
        const argv = [_][]const u8{ "read", "a", "b" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("one", sh.getVar("a").?.string);
        try testing.expectEqualStrings("two three", sh.getVar("b").?.string);
    }
    {
        // A single name still receives the trimmed line.
        const fd = try inputPipe("  hello  \n");
        const argv = [_][]const u8{ "read", "line" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("hello", sh.getVar("line").?.string);
    }
    {
        // Three names, but only two fields: the extra name is emptied.
        const fd = try inputPipe("x y\n");
        const argv = [_][]const u8{ "read", "p", "q", "r" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("x", sh.getVar("p").?.string);
        try testing.expectEqualStrings("y", sh.getVar("q").?.string);
        try testing.expectEqualStrings("", sh.getVar("r").?.string);
    }
    {
        // Without -r a backslash escapes; with -r it is literal.
        const fd = try inputPipe("a\\b\n");
        const argv = [_][]const u8{ "read", "cooked" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("ab", sh.getVar("cooked").?.string);
    }
    {
        const fd = try inputPipe("a\\b\n");
        const argv = [_][]const u8{ "read", "-r", "raw" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("a\\b", sh.getVar("raw").?.string);
    }
    {
        // A trailing backslash continues onto the next line.
        const fd = try inputPipe("one \\\ntwo\n");
        const argv = [_][]const u8{ "read", "joined" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("one two", sh.getVar("joined").?.string);
    }
    {
        // A non-whitespace IFS character delimits on its own, so `a::b`
        // yields an empty middle field.
        try sh.setVar("IFS", .{ .string = ":" });
        const fd = try inputPipe("a::b\n");
        const argv = [_][]const u8{ "read", "x", "y", "z" };
        try testing.expectEqual(@as(u8, 0), builtinRead(Ctx{ .sh = &sh, .argv = &argv, .stdin = fd }));
        _ = linux.close(fd);
        try testing.expectEqualStrings("a", sh.getVar("x").?.string);
        try testing.expectEqualStrings("", sh.getVar("y").?.string);
        try testing.expectEqualStrings("b", sh.getVar("z").?.string);
        _ = sh.unsetVar("IFS");
    }
    {
        const cap = try Capture.open();
        const fd = try inputPipe("value\n");
        const argv = [_][]const u8{ "read", "-p", "prompt> ", "answer" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdin = fd, .stderr = cap.write_fd };
        try testing.expectEqual(@as(u8, 0), builtinRead(ctx));
        _ = linux.close(fd);
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("prompt> ", out);
        try testing.expectEqualStrings("value", sh.getVar("answer").?.string);
    }
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

test "test groups, negates and brackets" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const cases = [_]struct { argv: []const []const u8, want: u8 }{
        .{ .argv = &.{ "[", "a", "=", "a", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-f", ".", "]" }, .want = 1 },
        .{ .argv = &.{ "[", "-d", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-e", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-z", "", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-n", "x", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-x", "/bin/sh", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "!", "-f", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "test", "a", "=", "a", "-a", "b", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "a", "=", "b", "-a", "b", "=", "b" }, .want = 1 },
        .{ .argv = &.{ "test", "a", "=", "b", "-o", "b", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "!", "a", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "a", ")", "-a", "c", "=", "c" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "b", "-o", "c", "=", "c", ")" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "b", ")", "-o", "c", "=", "c" }, .want = 0 },
        .{ .argv = &.{ "test", "3", "-ge", "3" }, .want = 0 },
        .{ .argv = &.{ "test", "3", "-ne", "3" }, .want = 1 },
    };
    for (cases) |case| {
        const ctx = Ctx{ .sh = &sh, .argv = case.argv, .stderr = -1 };
        const status = if (std.mem.eql(u8, case.argv[0], "[")) builtinBracket(ctx) else builtinTest(ctx);
        try testing.expectEqual(case.want, status);
    }

    const missing = [_][]const u8{ "[", "a", "=", "a" };
    try testing.expectEqual(@as(u8, 2), builtinBracket(Ctx{ .sh = &sh, .argv = &missing, .stderr = -1 }));

    // POSIX: one argument is true when it is non-empty.
    const single = [_][]const u8{ "test", "-f" };
    try testing.expectEqual(@as(u8, 0), builtinTest(Ctx{ .sh = &sh, .argv = &single, .stderr = -1 }));
    const empty = [_][]const u8{ "test", "" };
    try testing.expectEqual(@as(u8, 1), builtinTest(Ctx{ .sh = &sh, .argv = &empty, .stderr = -1 }));

    // An unclosed group is a syntax error.
    const unclosed = [_][]const u8{ "test", "(", "a", "=", "a" };
    try testing.expectEqual(@as(u8, 2), builtinTest(Ctx{ .sh = &sh, .argv = &unclosed, .stderr = -1 }));
}

test "type and command -v classify names" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.setAlias("ll", "echo listed");
    try sh.defineFunc("greet", "fn greet() {\n}\n");

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "type", "echo", "ll", "greet", "sh" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd, .stderr = -1 };
        try testing.expectEqual(@as(u8, 0), builtinType(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "echo is a shell builtin\n") != null);
        try testing.expect(std.mem.indexOf(u8, out, "ll is aliased to `echo listed'\n") != null);
        try testing.expect(std.mem.indexOf(u8, out, "greet is a shell function\n") != null);
        try testing.expect(std.mem.indexOf(u8, out, "sh is /") != null);
    }
    {
        const argv = [_][]const u8{ "type", "definitely-not-real-xyz" };
        try testing.expectEqual(@as(u8, 1), builtinType(Ctx{ .sh = &sh, .argv = &argv, .stdout = -1, .stderr = -1 }));
    }
    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "command", "-v", "echo" };
        try testing.expectEqual(@as(u8, 0), builtinCommand(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd, .stderr = -1 }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("echo\n", out);
    }
    {
        // A missing name prints nothing and reports failure.
        const argv = [_][]const u8{ "command", "-v", "definitely-not-real-xyz" };
        try testing.expectEqual(@as(u8, 1), builtinCommand(Ctx{ .sh = &sh, .argv = &argv, .stdout = -1, .stderr = -1 }));
    }
}

test "command and builtin run builtins, exec routes through PATH" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "command", "echo", "hi" };
        try testing.expectEqual(@as(u8, 0), builtinCommand(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("hi\n", out);
    }
    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "builtin", "echo", "hi" };
        try testing.expectEqual(@as(u8, 0), builtinBuiltin(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("hi\n", out);
    }
    {
        const argv = [_][]const u8{ "builtin", "definitely-not-real-xyz" };
        try testing.expectEqual(@as(u8, 1), builtinBuiltin(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
    }
    {
        // `command` on an external goes through PATH and its status is kept.
        const argv = [_][]const u8{ "command", "sh", "-c", "exit 5" };
        try testing.expectEqual(@as(u8, 5), builtinCommand(Ctx{ .sh = &sh, .argv = &argv }));
    }
}

test "shift moves positional parameters" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    sh.positional = &.{ "a", "b", "c" };

    const one = [_][]const u8{"shift"};
    try testing.expectEqual(@as(u8, 0), builtinShift(Ctx{ .sh = &sh, .argv = &one, .stderr = -1 }));
    try testing.expectEqual(@as(usize, 2), sh.positional.len);
    try testing.expectEqualStrings("b", sh.positional[0]);

    const two = [_][]const u8{ "shift", "2" };
    try testing.expectEqual(@as(u8, 0), builtinShift(Ctx{ .sh = &sh, .argv = &two, .stderr = -1 }));
    try testing.expectEqual(@as(usize, 0), sh.positional.len);

    const too_many = [_][]const u8{ "shift", "5" };
    try testing.expectEqual(@as(u8, 1), builtinShift(Ctx{ .sh = &sh, .argv = &too_many, .stderr = -1 }));

    const not_a_number = [_][]const u8{ "shift", "x" };
    try testing.expectEqual(@as(u8, 1), builtinShift(Ctx{ .sh = &sh, .argv = &not_a_number, .stderr = -1 }));
}

test "umask round trips" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const original = sys.umask(0);
    _ = sys.umask(original);
    defer _ = sys.umask(original);

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{"umask"};
        try testing.expectEqual(@as(u8, 0), builtinUmask(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        const parsed = try std.fmt.parseInt(u32, std.mem.trimEnd(u8, out, "\n"), 8);
        try testing.expectEqual(original, parsed);
    }
    {
        const argv = [_][]const u8{ "umask", "077" };
        try testing.expectEqual(@as(u8, 0), builtinUmask(Ctx{ .sh = &sh, .argv = &argv }));
        _ = sys.umask(0o077);
        try testing.expectEqual(@as(u32, 0o077), sys.umask(0));
    }
    {
        const argv = [_][]const u8{ "umask", "abc" };
        try testing.expectEqual(@as(u8, 1), builtinUmask(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
    }
}

test "pushd, dirs and popd walk a directory stack" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const original = (try fs.getCwd(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(original);
    const original_z = try testing.allocator.dupeZ(u8, original);
    defer testing.allocator.free(original_z);
    defer _ = fs.chdir(original_z);

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "pushd", "/" };
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd, .stderr = -1 };
        try testing.expectEqual(@as(u8, 0), builtinPushd(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        var expected: [linux.PATH_MAX + 3]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "/ {s}\n", .{original});
        try testing.expectEqualStrings(text, out);
        try testing.expectEqual(@as(usize, 1), sh.dir_stack.items.len);
    }
    {
        const cap = try Capture.open();
        const argv = [_][]const u8{"popd"};
        const ctx = Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd, .stderr = -1 };
        try testing.expectEqual(@as(u8, 0), builtinPopd(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        var expected: [linux.PATH_MAX + 2]u8 = undefined;
        const text = try std.fmt.bufPrint(&expected, "{s}\n", .{original});
        try testing.expectEqualStrings(text, out);
        try testing.expectEqual(@as(usize, 0), sh.dir_stack.items.len);
    }
    {
        const argv = [_][]const u8{"popd"};
        try testing.expectEqual(@as(u8, 1), builtinPopd(Ctx{ .sh = &sh, .argv = &argv, .stdout = -1, .stderr = -1 }));
    }
    {
        const argv = [_][]const u8{"dirs"};
        const cap = try Capture.open();
        try testing.expectEqual(@as(u8, 0), builtinDirs(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expect(out.len > 1);
        try testing.expectEqual(@as(u8, '\n'), out[out.len - 1]);
    }
}

test "kill validates signals and targets" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const bad_signal = [_][]const u8{ "kill", "-s", "NOPE" };
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &bad_signal, .stderr = -1 }));

    const no_target = [_][]const u8{"kill"};
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &no_target, .stderr = -1 }));

    const no_such_job = [_][]const u8{ "kill", "-TERM", "%9" };
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &no_such_job, .stderr = -1 }));
}

test "trap stores, lists and clears handlers" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const argv = [_][]const u8{ "trap", "echo interrupted", "INT" };
        try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expectEqualStrings("echo interrupted", sh.getTrap(2).?);
    }
    {
        const argv = [_][]const u8{ "trap", "x", "KILL" };
        try testing.expectEqual(@as(u8, 1), builtinTrap(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
    }
    {
        const argv = [_][]const u8{ "trap", "-", "INT" };
        try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expect(sh.getTrap(2) == null);
    }
    {
        const cap = try Capture.open();
        const set = [_][]const u8{ "trap", "handler", "TERM" };
        try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &set, .stderr = -1 }));
        const listing = [_][]const u8{"trap"};
        const ctx = Ctx{ .sh = &sh, .argv = &listing, .stdout = cap.write_fd, .stderr = -1 };
        try testing.expectEqual(@as(u8, 0), builtinTrap(ctx));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("trap -- 'handler' TERM\n", out);

        const reset = [_][]const u8{ "trap", "-", "TERM" };
        try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &reset, .stderr = -1 }));
        try testing.expect(sh.getTrap(15) == null);
    }
}

test "a trapped signal is installed and its handler runs" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    trap_hits = 0;
    sh.trap_runner = testTrapRunner;

    const argv = [_][]const u8{ "trap", "note", "USR1" };
    try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
    try testing.expectEqualStrings("note", sh.getTrap(10).?);

    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
    sh.runPendingTraps();
    try testing.expectEqual(@as(usize, 1), trap_hits);

    // An empty handler ignores the signal instead of running code.
    const ignore = [_][]const u8{ "trap", "", "USR1" };
    try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &ignore, .stderr = -1 }));
    _ = linux.kill(linux.getpid(), linux.SIG.USR1);
    sh.runPendingTraps();
    try testing.expectEqual(@as(usize, 1), trap_hits);

    const reset = [_][]const u8{ "trap", "-", "USR1" };
    try testing.expectEqual(@as(u8, 0), builtinTrap(Ctx{ .sh = &sh, .argv = &reset, .stderr = -1 }));
    try testing.expect(sh.getTrap(10) == null);
}

test "local and readonly builtins" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const argv = [_][]const u8{ "readonly", "PI=3" };
        try testing.expectEqual(@as(u8, 0), builtinReadonly(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expectEqualStrings("3", sh.getVar("PI").?.string);
        try testing.expect(sh.isReadonly("PI"));
    }
    {
        const argv = [_][]const u8{ "set", "PI", "4" };
        try testing.expectEqual(@as(u8, 1), builtinSet(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expectEqualStrings("3", sh.getVar("PI").?.string);
    }
    {
        const argv = [_][]const u8{ "unset", "PI" };
        try testing.expectEqual(@as(u8, 1), builtinUnset(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
        try testing.expect(sh.getVar("PI") != null);
    }

    try sh.setVar("outer", .{ .string = "one" });
    try sh.beginScope();
    {
        const argv = [_][]const u8{ "local", "outer=two", "fresh=3" };
        try testing.expectEqual(@as(u8, 0), builtinLocal(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
    }
    try testing.expectEqualStrings("two", sh.getVar("outer").?.string);
    try testing.expectEqualStrings("3", sh.getVar("fresh").?.string);
    sh.endScope();
    try testing.expectEqualStrings("one", sh.getVar("outer").?.string);
    try testing.expect(sh.getVar("fresh") == null);
}

test "colon, exec and clear are well behaved" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const colon = [_][]const u8{ ":", "ignored" };
    try testing.expectEqual(@as(u8, 0), builtinNoop(Ctx{ .sh = &sh, .argv = &colon }));

    const no_args = [_][]const u8{"exec"};
    try testing.expectEqual(@as(u8, 0), builtinExec(Ctx{ .sh = &sh, .argv = &no_args, .stderr = -1 }));

    const missing = [_][]const u8{ "exec", "definitely-not-a-real-binary-xyz" };
    try testing.expectEqual(@as(u8, 127), builtinExec(Ctx{ .sh = &sh, .argv = &missing, .stderr = -1 }));
}
