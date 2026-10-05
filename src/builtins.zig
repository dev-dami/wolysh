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
const cd = @import("builtins/cd.zig");
const history_builtin = @import("builtins/history.zig");
const import_env = @import("builtins/import_env.zig");
const complete_builtin = @import("builtins/complete.zig");
const printf_builtin = @import("builtins/printf.zig");
const read_builtin = @import("builtins/read.zig");
const describe_builtin = @import("builtins/describe.zig");
const jobctl_builtin = @import("builtins/jobctl.zig");
const getopts_builtin = @import("builtins/getopts.zig");
const help_builtin = @import("builtins/help.zig");
const process_builtin = @import("builtins/process.zig");
const dirstack_builtin = @import("builtins/dirstack.zig");
const exports_builtin = @import("builtins/exports.zig");
const test_builtin = @import("builtins/test.zig");

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

// --- environment and variables ---------------------------------------------

const UnsetMode = enum {
    /// No option: a variable, or else a function of that name (bash).
    either,
    variable,
    function,
};

/// `unset [-v|-f] [--] NAME...`.
fn builtinUnset(ctx: Ctx) u8 {
    var mode: UnsetMode = .either;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |flag| {
            switch (flag) {
                'v' => mode = .variable,
                'f' => mode = .function,
                else => {
                    ctx.errFmt("wsh: unset: -{c}: invalid option\nunset: usage: unset [-f] [-v] [name ...]\n", .{flag});
                    return 2;
                },
            }
        }
    }
    var status: u8 = 0;
    for (ctx.argv[index..]) |name| {
        const function_only = validName(name) and !ctx.sh.hasVar(name) and
            ctx.sh.getEnv(name) == null and ctx.sh.getFunc(name) != null;
        const ok = switch (mode) {
            .variable => unsetVariable(ctx, name),
            .function => unsetFunction(ctx, name),
            .either => if (function_only) unsetFunction(ctx, name) else unsetVariable(ctx, name),
        };
        if (!ok) status = 1;
    }
    return status;
}

/// Removes a variable from the shell and the environment alike; an unset
/// name is not an error.
fn unsetVariable(ctx: Ctx, name: []const u8) bool {
    if (!validName(name)) {
        ctx.errFmt("wsh: unset: `{s}': not a valid identifier\n", .{name});
        return false;
    }
    if (ctx.sh.isReadonly(name)) {
        ctx.errFmt("wsh: unset: {s}: cannot unset: readonly variable\n", .{name});
        return false;
    }
    _ = ctx.sh.unsetVar(name);
    _ = ctx.sh.unsetEnv(name);
    return true;
}

fn unsetFunction(ctx: Ctx, name: []const u8) bool {
    if (ctx.sh.funcs.fetchRemove(name)) |kv| {
        ctx.sh.gpa.free(kv.key);
        ctx.sh.gpa.free(kv.value);
    }
    return true;
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

fn builtinAlias(ctx: Ctx) u8 {
    if (ctx.argv.len >= 2 and std.mem.eql(u8, ctx.argv[1], "-p")) {
        if (exports_builtin.listAliases(ctx) != 0) return 1;
        if (ctx.argv.len == 2) return 0;
        var rest = ctx;
        rest.argv = ctx.argv[1..];
        return builtinAlias(rest);
    }
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
    if (ctx.argv.len >= 2 and std.mem.eql(u8, ctx.argv[1], "-a")) {
        var it = ctx.sh.aliases.iterator();
        while (it.next()) |entry| {
            ctx.sh.gpa.free(entry.key_ptr.*);
            ctx.sh.gpa.free(entry.value_ptr.*);
        }
        ctx.sh.aliases.clearRetainingCapacity();
        return 0;
    }
    if (ctx.argv.len < 2) {
        ctx.err("wsh: unalias: expected a name\n");
        return 1;
    }
    var status: u8 = 0;
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        if (ctx.sh.aliases.fetchRemove(ctx.argv[i])) |kv| {
            ctx.sh.gpa.free(kv.key);
            ctx.sh.gpa.free(kv.value);
        } else {
            ctx.errFmt("wsh: unalias: {s}: not found\n", .{ctx.argv[i]});
            status = 1;
        }
    }
    return status;
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
    return switch (ctx.sh.jobs.lookup(text)) {
        .found => |job| job,
        .none, .ambiguous => null,
    };
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

const kill_usage = "wsh: kill: usage: kill [-s sigspec | -n signum | -sigspec] pid | jobspec ... or kill -l [sigspec]\n";

/// `kill [-s SIG | -n NUM | -SIG] TARGET...` and `kill -l|-L [SIG...]`. One
/// signal option ends option parsing, so `kill -9 -123` signals group 123.
/// Succeeds when at least one signal was delivered, as in bash.
fn builtinKill(ctx: Ctx) u8 {
    var sig: u32 = @intFromEnum(linux.SIG.TERM);
    var index: usize = 1;
    if (index < ctx.argv.len) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "-L")) return listSignals(ctx, ctx.argv[index + 1 ..]);
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
        } else if (std.mem.eql(u8, arg, "-s") or std.mem.eql(u8, arg, "-n")) {
            const spec = ctx.arg(index + 1) orelse {
                ctx.errFmt("wsh: kill: {s}: option requires an argument\n", .{arg});
                return 1;
            };
            sig = signalNumber(spec) orelse return invalidSignal(ctx, spec);
            index += 2;
        } else if (arg.len >= 2 and arg[0] == '-') {
            sig = signalNumber(arg[1..]) orelse return invalidSignal(ctx, arg[1..]);
            index += 1;
            if (ctx.arg(index)) |next| {
                if (std.mem.eql(u8, next, "--")) index += 1;
            }
        }
    }

    if (index >= ctx.argv.len) {
        ctx.err(kill_usage);
        return 2;
    }

    var delivered = false;
    for (ctx.argv[index..]) |target| {
        if (target.len != 0 and target[0] == '%') {
            const job = resolveJob(ctx, target) orelse {
                ctx.errFmt("wsh: kill: {s}: no such job\n", .{target});
                continue;
            };
            const err = proc.sendSignal(-job.pgid, sig);
            if (err == .SUCCESS) {
                delivered = true;
            } else {
                ctx.errFmt("wsh: kill: {s}: {s}\n", .{ target, proc.errorText(err) });
            }
            continue;
        }
        const pid = std.fmt.parseInt(i32, target, 10) catch {
            ctx.errFmt("wsh: kill: `{s}': not a pid or valid job spec\n", .{target});
            continue;
        };
        const err = proc.sendSignal(pid, sig);
        if (err == .SUCCESS) {
            delivered = true;
        } else {
            ctx.errFmt("wsh: kill: ({d}) - {s}\n", .{ pid, proc.errorText(err) });
        }
    }
    return if (delivered) 0 else 1;
}

fn invalidSignal(ctx: Ctx, spec: []const u8) u8 {
    ctx.errFmt("wsh: kill: {s}: invalid signal specification\n", .{spec});
    return 1;
}

/// `kill -l`: every signal as bash lays it out, five to a line. With
/// operands, a number (or an exit status above 128) prints its name and a
/// name prints its number.
fn listSignals(ctx: Ctx, specs: []const []const u8) u8 {
    var name_buf: [16]u8 = undefined;
    if (specs.len == 0) {
        var out = sys.StringBuilder.init(ctx.sh.gpa);
        defer out.deinit();
        var column: usize = 0;
        var n: u32 = 1;
        while (n <= Shell.max_signal) : (n += 1) {
            const name = signalLabel(n, &name_buf) orelse continue;
            out.print("{d: >2}) SIG{s}", .{ n, name }) catch return 1;
            column += 1;
            out.append(if (column % 5 == 0) "\n" else "\t") catch return 1;
        }
        if (column % 5 != 0) out.append("\n") catch return 1;
        ctx.out(out.items());
        return 0;
    }
    var status: u8 = 0;
    for (specs) |spec| {
        if (std.fmt.parseInt(u32, spec, 10)) |number| {
            if (number == 0) {
                ctx.out("EXIT\n");
                continue;
            }
            if (signalLabel(if (number > 128) number - 128 else number, &name_buf)) |name| {
                ctx.outFmt("{s}\n", .{name});
                continue;
            }
        } else |_| {
            if (signalNumber(spec)) |n| {
                ctx.outFmt("{d}\n", .{n});
                continue;
            }
        }
        _ = invalidSignal(ctx, spec);
        status = 1;
    }
    return status;
}

/// `KILL`, `SIGKILL`, `kill`, `9`, `RTMIN+1`: a signal number, 0 included.
fn signalNumber(spec: []const u8) ?u32 {
    if (spec.len != 0 and std.ascii.isDigit(spec[0])) {
        const n = std.fmt.parseInt(u32, spec, 10) catch return null;
        return if (n <= Shell.max_signal) n else null;
    }
    var upper_buf: [16]u8 = undefined;
    if (spec.len > upper_buf.len) return null;
    const upper = std.ascii.upperString(&upper_buf, spec);
    const wanted = if (std.mem.startsWith(u8, upper, "SIG")) upper[3..] else upper;
    var name_buf: [16]u8 = undefined;
    var n: u32 = 1;
    while (n <= Shell.max_signal) : (n += 1) {
        const name = signalLabel(n, &name_buf) orelse continue;
        if (std.mem.eql(u8, name, wanted)) return n;
    }
    return null;
}

/// Linux's name for signal `n` without the `SIG` prefix, numbering the
/// real-time signals the way bash and glibc do. Null for 32 and 33, which
/// glibc keeps for itself, and for anything out of range.
fn signalLabel(n: u32, buf: *[16]u8) ?[]const u8 {
    const named = [_][]const u8{
        "HUP",  "INT",    "QUIT", "ILL",   "TRAP", "ABRT", "BUS",  "FPE",
        "KILL", "USR1",   "SEGV", "USR2",  "PIPE", "ALRM", "TERM", "STKFLT",
        "CHLD", "CONT",   "STOP", "TSTP",  "TTIN", "TTOU", "URG",  "XCPU",
        "XFSZ", "VTALRM", "PROF", "WINCH", "IO",   "PWR",  "SYS",
    };
    const rtmin = 34;
    const rtmax = Shell.max_signal;
    if (n >= 1 and n <= named.len) return named[n - 1];
    if (n < rtmin or n > rtmax) return null;
    if (n == rtmin) return "RTMIN";
    if (n == rtmax) return "RTMAX";
    if (n - rtmin <= 15) return std.fmt.bufPrint(buf, "RTMIN+{d}", .{n - rtmin}) catch null;
    return std.fmt.bufPrint(buf, "RTMAX-{d}", .{rtmax - n}) catch null;
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

/// Forks and execs `argv` through `path_env`, waiting for it like a
/// foreground job. `command NAME` and the function-less path use this.
pub fn runExternal(ctx: Ctx, argv: []const []const u8, path_env: []const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Like a plain command: `execve` failures are reported by the child.
    const resolved = (proc.locate(arena, argv[0], path_env) catch null) orelse {
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

// --- exec -------------------------------------------------------------------

fn builtinExec(ctx: Ctx) u8 {
    if (ctx.argv.len < 2) return 0;

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const name = ctx.argv[1];
    const resolved = (proc.locate(arena, name, ctx.sh.pathEnv()) catch null) orelse {
        ctx.errFmt("wsh: exec: {s}: not found\n", .{name});
        return markExecFailure(ctx, 127);
    };
    const path = arena.dupeZ(u8, resolved) catch return 127;
    const argv = proc.buildArgv(arena, ctx.argv[1..]) catch return 127;
    const envp = ctx.sh.buildEnvp(arena) catch return 127;

    // Children get the default dispositions back; exec does not fork.
    proc.resetSignals();
    const err = linux.errno(linux.execve(path.ptr, argv, envp));

    if (err == .NOEXEC) {
        const script_argv = arena.alloc([]const u8, ctx.argv.len + 1) catch return 127;
        script_argv[0] = "/bin/sh";
        script_argv[1] = resolved;
        for (ctx.argv[2..], 0..) |argument, index| script_argv[index + 2] = argument;
        const shell_argv = proc.buildArgv(arena, script_argv) catch return 127;
        _ = linux.execve("/bin/sh", shell_argv, envp);
    }

    // Still here: an interactive shell carries on with its own dispositions.
    if (ctx.sh.interactive) proc.shellSignals(&ctx.sh.interrupted);
    const buf = arena.alloc(u8, path.len + 512) catch return 127;
    const failure = proc.describeExecFailure(buf, path, err);
    ctx.err(failure.text);
    return markExecFailure(ctx, failure.status);
}

/// A failed `exec` is fatal to a non-interactive shell, as POSIX requires.
fn markExecFailure(ctx: Ctx, status: u8) u8 {
    if (!ctx.sh.interactive) {
        ctx.sh.should_exit = true;
        ctx.sh.exit_code = status;
    }
    return status;
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
    .{ .name = "cd", .summary = "change the working directory", .run = cd.builtinCd },
    .{ .name = "pwd", .summary = "print the working directory", .run = cd.builtinPwd },
    .{ .name = "pushd", .summary = "push a directory onto the stack", .run = dirstack_builtin.pushd },
    .{ .name = "popd", .summary = "pop a directory off the stack", .run = dirstack_builtin.popd },
    .{ .name = "dirs", .summary = "print the directory stack", .run = dirstack_builtin.dirs },
    .{ .name = "echo", .summary = "print arguments", .run = builtinEcho },
    .{ .name = "print", .summary = "print arguments", .run = builtinPrint },
    .{ .name = "printf", .summary = "format and print arguments", .run = printf_builtin.run },
    .{ .name = "exit", .summary = "exit the shell", .run = builtinExit },
    .{ .name = "export", .summary = "set an environment variable", .run = exports_builtin.exportBuiltin },
    .{ .name = "import-env", .summary = "import the environment a bash script exports", .run = import_env.run },
    .{ .name = "unset", .summary = "remove a variable", .run = builtinUnset },
    .{ .name = "set", .summary = "list or set shell variables", .run = builtinSet },
    .{ .name = "local", .summary = "declare a function-local variable", .run = builtinLocal },
    .{ .name = "readonly", .summary = "mark variables readonly", .run = exports_builtin.readonlyBuiltin },
    .{ .name = "alias", .summary = "define or list aliases", .run = builtinAlias },
    .{ .name = "unalias", .summary = "remove an alias", .run = builtinUnalias },
    .{ .name = "jobs", .summary = "list background jobs", .run = jobctl_builtin.jobsBuiltin },
    .{ .name = "wait", .summary = "wait for background jobs", .run = builtinWait },
    .{ .name = "parallel", .summary = "run commands with bounded concurrency", .run = builtinParallel },
    .{ .name = "fg", .summary = "bring a job to the foreground", .run = builtinFg },
    .{ .name = "bg", .summary = "resume a job in the background", .run = builtinBg },
    .{ .name = "kill", .summary = "send a signal to a process or job", .run = builtinKill },
    .{ .name = "trap", .summary = "set or clear signal handlers", .run = builtinTrap },
    .{ .name = "history", .summary = "show command history", .run = history_builtin.run },
    .{ .name = "which", .summary = "locate a command", .run = builtinWhich },
    .{ .name = "type", .summary = "describe how a name would be resolved", .run = describe_builtin.typeBuiltin },
    .{ .name = "command", .summary = "run a command bypassing functions", .run = describe_builtin.commandBuiltin },
    .{ .name = "builtin", .summary = "run a shell builtin directly", .run = builtinBuiltin },
    .{ .name = "read", .summary = "read a line into variables", .run = read_builtin.read },
    .{ .name = "shift", .summary = "shift positional parameters", .run = builtinShift },
    .{ .name = "umask", .summary = "get or set the file-creation mask", .run = process_builtin.umask },
    .{ .name = "exec", .summary = "replace the shell with a command", .run = builtinExec },
    .{ .name = "test", .summary = "evaluate a condition", .run = test_builtin.run },
    .{ .name = "[", .summary = "evaluate a condition", .run = test_builtin.runBracket },
    .{ .name = "true", .summary = "return success", .run = builtinTrue },
    .{ .name = "false", .summary = "return failure", .run = builtinFalse },
    .{ .name = "clear", .summary = "clear the screen", .run = builtinClear },
    .{ .name = "complete", .summary = "define how arguments of a command complete", .run = complete_builtin.runComplete },
    .{ .name = "compgen", .summary = "print completion candidates", .run = complete_builtin.runCompgen },
    .{ .name = "mapfile", .summary = "read lines into an array", .run = read_builtin.mapfile },
    .{ .name = "readarray", .summary = "read lines into an array", .run = read_builtin.mapfile },
    .{ .name = "hash", .summary = "check where commands resolve in PATH", .run = describe_builtin.hashBuiltin },
    .{ .name = "disown", .summary = "remove jobs from the job table", .run = jobctl_builtin.disownBuiltin },
    .{ .name = "getopts", .summary = "parse positional options", .run = getopts_builtin.run },
    .{ .name = "help", .summary = "describe builtins and the language", .run = help_builtin.run },
    .{ .name = "ulimit", .summary = "get or set resource limits", .run = process_builtin.ulimit },
    .{ .name = "times", .summary = "print shell and child CPU times", .run = process_builtin.times },
    .{ .name = "logout", .summary = "exit a login shell", .run = process_builtin.logout },
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

test "builtin runs a shell builtin directly" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

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

test "kill validates signals and targets" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    const bad_signal = [_][]const u8{ "kill", "-s", "NOPE" };
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &bad_signal, .stderr = -1 }));

    // A missing operand is a usage error, as in bash.
    const no_target = [_][]const u8{"kill"};
    try testing.expectEqual(@as(u8, 2), builtinKill(Ctx{ .sh = &sh, .argv = &no_target, .stderr = -1 }));

    const no_such_job = [_][]const u8{ "kill", "-TERM", "%9" };
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &no_such_job, .stderr = -1 }));

    // A failed kill(2) is reported, not swallowed.
    const cap = try Capture.open();
    const no_such_process = [_][]const u8{ "kill", "2147483646" };
    try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &no_such_process, .stderr = cap.write_fd }));
    const err = try cap.finish(testing.allocator);
    defer testing.allocator.free(err);
    try testing.expectEqualStrings("wsh: kill: (2147483646) - No such process\n", err);
}

test "kill -l names and numbers signals" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "kill", "-l", "9", "137", "SIGTERM", "rtmin+1", "0" };
        try testing.expectEqual(@as(u8, 0), builtinKill(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("KILL\nKILL\n15\n35\nEXIT\n", out);
    }
    {
        const cap = try Capture.open();
        const argv = [_][]const u8{ "kill", "-L" };
        try testing.expectEqual(@as(u8, 0), builtinKill(Ctx{ .sh = &sh, .argv = &argv, .stdout = cap.write_fd }));
        const out = try cap.finish(testing.allocator);
        defer testing.allocator.free(out);
        try testing.expect(std.mem.startsWith(u8, out, " 1) SIGHUP\t 2) SIGINT\t 3) SIGQUIT\t 4) SIGILL\t 5) SIGTRAP\n"));
        try testing.expect(std.mem.indexOf(u8, out, "31) SIGSYS\t34) SIGRTMIN\t") != null);
        try testing.expect(std.mem.endsWith(u8, out, "63) SIGRTMAX-1\t64) SIGRTMAX\t\n"));
    }
    {
        const argv = [_][]const u8{ "kill", "-l", "200" };
        try testing.expectEqual(@as(u8, 1), builtinKill(Ctx{ .sh = &sh, .argv = &argv, .stdout = -1, .stderr = -1 }));
    }
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
        try testing.expectEqual(@as(u8, 0), exports_builtin.readonlyBuiltin(Ctx{ .sh = &sh, .argv = &argv, .stderr = -1 }));
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
