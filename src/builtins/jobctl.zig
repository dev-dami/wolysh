//! `jobs` and `disown`.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const jobs = @import("../jobs.zig");
const sys = @import("../sys.zig");

const Ctx = builtins.Ctx;
const Job = jobs.Job;

/// The pid `jobs -l`/`-p` report: the process group leader, or the last
/// process when the job shares the shell's own group.
fn leaderPid(ctx: Ctx, job: *const Job) i32 {
    const own_group = sys.getpgid(0) orelse ctx.sh.shell_pgid;
    if (job.pgid > 0 and job.pgid != own_group) return job.pgid;
    return job.last_pid;
}

fn marker(ctx: Ctx, job: *const Job) u8 {
    if (ctx.sh.jobs.current() == job) return '+';
    if (ctx.sh.jobs.previous() == job) return '-';
    return ' ';
}

const Select = struct {
    running: bool = false,
    stopped: bool = false,
    changed: bool = false,

    fn wants(self: Select, job: *const Job) bool {
        if (self.changed and job.notified) return false;
        if (self.running or self.stopped) {
            return (self.running and job.state == .running) or (self.stopped and job.state == .stopped);
        }
        return true;
    }
};

const Format = enum { normal, long, pids };

fn show(ctx: Ctx, job: *Job, format: Format) void {
    switch (format) {
        .pids => ctx.outFmt("{d}\n", .{leaderPid(ctx, job)}),
        .long => ctx.outFmt("[{d}] {c} {d} {s}  {s}\n", .{ job.id, marker(ctx, job), leaderPid(ctx, job), job.state.label(), job.command }),
        .normal => ctx.outFmt("[{d}] {c} {s}  {s}\n", .{ job.id, marker(ctx, job), job.state.label(), job.command }),
    }
    job.notified = job.notified or job.state == .done;
}

pub fn jobsBuiltin(ctx: Ctx) u8 {
    var format = Format.normal;
    var select = Select{};
    var parser = options.Parser.init(ctx.argv, "lnprs");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: jobs: -{c}: invalid option\n", .{c});
                ctx.err("wsh: jobs: usage: jobs [-lnprs] [jobspec ...]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'l' => format = .long,
                'p' => format = .pids,
                'n' => select.changed = true,
                'r' => select.running = true,
                's' => select.stopped = true,
                else => unreachable,
            },
        }
    }

    ctx.sh.reapJobs();
    var status: u8 = 0;
    const specs = parser.rest();
    if (specs.len == 0) {
        for (ctx.sh.jobs.jobs.items) |*job| {
            if (select.wants(job)) show(ctx, job, format);
        }
    } else {
        for (specs) |spec| {
            const job = find(ctx, "jobs", spec) orelse {
                status = 1;
                continue;
            };
            if (select.wants(job)) show(ctx, job, format);
        }
    }
    ctx.sh.jobs.sweep(ctx.sh.gpa);
    return status;
}

/// Resolves a job spec or a pid, reporting failures.
fn find(ctx: Ctx, builtin: []const u8, spec: []const u8) ?*Job {
    if (spec.len != 0 and spec[0] != '%') {
        if (std.fmt.parseInt(i32, spec, 10)) |pid| {
            for (ctx.sh.jobs.jobs.items) |*job| {
                if (job.last_pid == pid or job.pgid == pid) return job;
                if (std.mem.indexOfScalar(i32, job.pids, pid) != null) return job;
            }
            ctx.errFmt("wsh: {s}: {s}: no such job\n", .{ builtin, spec });
            return null;
        } else |_| {}
    }
    return switch (ctx.sh.jobs.lookup(spec)) {
        .found => |job| job,
        .ambiguous => {
            ctx.errFmt("wsh: {s}: {s}: ambiguous job spec\n", .{ builtin, spec });
            return null;
        },
        .none => {
            ctx.errFmt("wsh: {s}: {s}: no such job\n", .{ builtin, spec });
            return null;
        },
    };
}

pub fn disownBuiltin(ctx: Ctx) u8 {
    var keep = false;
    var every = false;
    var running_only = false;
    var parser = options.Parser.init(ctx.argv, "ahr");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: disown: -{c}: invalid option\n", .{c});
                ctx.err("wsh: disown: usage: disown [-h] [-ar] [jobspec ... | pid ...]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'a' => every = true,
                'h' => keep = true,
                'r' => running_only = true,
                else => unreachable,
            },
        }
    }

    ctx.sh.reapJobs();
    const specs = parser.rest();
    var targets: std.ArrayList(u32) = .empty;
    defer targets.deinit(ctx.sh.gpa);
    var status: u8 = 0;

    if (specs.len == 0 and (every or running_only)) {
        for (ctx.sh.jobs.jobs.items) |job| {
            if (running_only and job.state != .running) continue;
            targets.append(ctx.sh.gpa, job.id) catch return 1;
        }
    } else if (specs.len == 0) {
        const job = ctx.sh.jobs.current() orelse {
            ctx.err("wsh: disown: current: no such job\n");
            return 1;
        };
        targets.append(ctx.sh.gpa, job.id) catch return 1;
    } else {
        for (specs) |spec| {
            const job = find(ctx, "disown", spec) orelse {
                status = 1;
                continue;
            };
            if (running_only and job.state != .running) continue;
            targets.append(ctx.sh.gpa, job.id) catch return 1;
        }
    }

    for (targets.items) |id| {
        const job = ctx.sh.jobs.findById(id) orelse continue;
        if (keep) {
            job.no_hup = true;
        } else {
            ctx.sh.jobs.removeAt(ctx.sh.gpa, ctx.sh.jobs.indexOf(job).?);
        }
    }
    return status;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const shellmod = @import("../shell.zig");

test "disown removes or marks jobs and reports unknown specs" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    // Pids that are not our children, so reaping leaves the jobs running.
    _ = try sh.jobs.add(testing.allocator, 0, &.{999991}, "sleep 5", false);
    _ = try sh.jobs.add(testing.allocator, 0, &.{999992}, "sleep 6", false);
    _ = try sh.jobs.add(testing.allocator, 0, &.{999993}, "vim", false);

    try testing.expectEqual(@as(u8, 0), disownBuiltin(.{ .sh = &sh, .argv = &.{ "disown", "-h", "%2" }, .stderr = -1 }));
    try testing.expect(sh.jobs.findById(2).?.no_hup);
    try testing.expectEqual(@as(u8, 0), disownBuiltin(.{ .sh = &sh, .argv = &.{ "disown", "%1" }, .stderr = -1 }));
    try testing.expect(sh.jobs.findById(1) == null);
    try testing.expectEqual(@as(u8, 1), disownBuiltin(.{ .sh = &sh, .argv = &.{ "disown", "%7" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 0), disownBuiltin(.{ .sh = &sh, .argv = &.{"disown"}, .stderr = -1 }));
    try testing.expect(sh.jobs.findById(3) == null);
    try testing.expectEqual(@as(u8, 0), disownBuiltin(.{ .sh = &sh, .argv = &.{ "disown", "-a" }, .stderr = -1 }));
    try testing.expectEqual(@as(usize, 0), sh.jobs.count());
    try testing.expectEqual(@as(u8, 1), disownBuiltin(.{ .sh = &sh, .argv = &.{"disown"}, .stderr = -1 }));
}
