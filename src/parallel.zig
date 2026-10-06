//! Native bounded command scheduling with optional machine-readable results.

const std = @import("std");
const linux = std.os.linux;
const parser = @import("parser.zig");
const proc = @import("proc.zig");
const Shell = @import("shell.zig").Shell;
const strict = @import("strict.zig");
const sys = @import("sys.zig");

const RunSource = *const fn (*Shell, []const u8) u8;
const Options = struct {
    jobs: ?usize = null,
    fail_fast: bool = false,
    report: ?[]const u8 = null,
    commands: []const []const u8 = &.{},
};

const usage = "usage: parallel [-j N|--jobs N] [--fail-fast] [--report file] [--] 'command'...\n";

fn parseOptions(argv: []const []const u8) !Options {
    var options = Options{};
    var index: usize = 1;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--fail-fast")) {
            options.fail_fast = true;
        } else if (std.mem.eql(u8, arg, "-j") or std.mem.eql(u8, arg, "--jobs")) {
            index += 1;
            if (index == argv.len) return error.InvalidOptions;
            options.jobs = std.fmt.parseInt(usize, argv[index], 10) catch return error.InvalidOptions;
            if (options.jobs.? == 0) return error.InvalidOptions;
        } else if (std.mem.eql(u8, arg, "--report")) {
            index += 1;
            if (index == argv.len or argv[index].len == 0) return error.InvalidOptions;
            options.report = argv[index];
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.InvalidOptions;
        } else break;
    }
    options.commands = argv[index..];
    if (options.commands.len == 0) return error.InvalidOptions;
    return options;
}

const Worker = struct { pid: i32, index: usize, started_ns: u64 };
const Payload = struct {
    sh: *Shell,
    options: Options,
    workers: []Worker,
    report_fd: ?i32,
    run_source: RunSource,
};

fn now() ?u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return null;
    return @as(u64, @intCast(time.sec)) * std.time.ns_per_s + @as(u64, @intCast(time.nsec));
}

fn writeResult(payload: *Payload, index: usize, pid: ?i32, status: ?u8, elapsed_ms: u64) bool {
    const fd = payload.report_fd orelse return true;
    var output: std.Io.Writer.Allocating = .init(payload.sh.gpa);
    defer output.deinit();
    std.json.Stringify.value(.{
        .event = if (status != null) "completed" else "skipped",
        .index = index + 1,
        .command = payload.options.commands[index],
        .pid = pid,
        .status = status,
        .elapsed_ms = elapsed_ms,
    }, .{}, &output.writer) catch return false;
    output.writer.writeByte('\n') catch return false;
    return sys.writeAll(fd, output.writer.buffered()) == .ok;
}

fn worker(payload: *Payload, index: usize) noreturn {
    if (payload.report_fd) |fd| sys.closeFd(fd);
    const sh = payload.sh;
    sh.jobs = .{};
    sh.pid = sys.getpid();
    sh.interactive = false;
    sh.last_bg_pid = 0;
    sh.should_exit = false;
    sh.return_pending = false;
    sh.break_pending = false;
    sh.continue_pending = false;
    strict.enterSubshell(sh);
    strict.exitChild(sh, payload.run_source(sh, payload.options.commands[index]));
}

fn schedule(ctx: *anyopaque) noreturn {
    const payload: *Payload = @ptrCast(@alignCast(ctx));
    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.jobs = .{};

    var next: usize = 0;
    var active: usize = 0;
    var failed_index: usize = payload.options.commands.len;
    var result: u8 = 0;
    var fatal = false;
    var halt = false;

    while (next < payload.options.commands.len or active != 0) {
        while (!halt and next < payload.options.commands.len and active < payload.workers.len) {
            const started = now() orelse {
                sys.writeStr(2, "wsh: parallel: cannot read monotonic clock\n");
                fatal = true;
                halt = true;
                break;
            };
            const rc = linux.fork();
            if (linux.errno(rc) != .SUCCESS) {
                sys.writeStr(2, "wsh: parallel: cannot fork worker\n");
                fatal = true;
                halt = true;
                break;
            }
            const pid: i32 = @intCast(rc);
            if (pid == 0) worker(payload, next);
            payload.workers[active] = .{ .pid = pid, .index = next, .started_ns = started };
            active += 1;
            next += 1;
        }
        if (active == 0) break;

        const event = proc.waitAny(0) orelse {
            sys.writeStr(2, "wsh: parallel: cannot wait for worker\n");
            linux.exit(1);
        };
        for (payload.workers[0..active], 0..) |item, slot| {
            if (item.pid != event.pid) continue;
            const status = event.status.exitCode();
            if (status != 0) {
                if (item.index < failed_index) {
                    failed_index = item.index;
                    result = status;
                }
                if (payload.options.fail_fast) halt = true;
            }
            const finished = now();
            if (finished == null or !writeResult(payload, item.index, item.pid, status, (finished.? - item.started_ns) / std.time.ns_per_ms)) {
                sys.writeStr(2, "wsh: parallel: cannot write task result\n");
                fatal = true;
                halt = true;
            }
            active -= 1;
            payload.workers[slot] = payload.workers[active];
            break;
        }
    }
    while (next < payload.options.commands.len) : (next += 1) {
        if (!writeResult(payload, next, null, null, 0)) {
            sys.writeStr(2, "wsh: parallel: cannot write skipped task result\n");
            fatal = true;
            break;
        }
    }
    linux.exit(if (fatal) 1 else result);
}

pub fn run(sh: *Shell, argv: []const []const u8, run_source: RunSource) u8 {
    if (argv.len == 2 and std.mem.eql(u8, argv[1], "--help")) {
        sys.writeStr(sh.default_out, usage);
        return 0;
    }
    var options = parseOptions(argv) catch {
        sys.writeStr(sh.default_err, usage);
        return 2;
    };
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for (options.commands) |source| {
        var p = parser.Parser.init(arena, source);
        _ = p.parseProgram() catch {
            var buffer: [512]u8 = undefined;
            sys.writeStr(sh.default_err, "wsh: parallel: ");
            sys.writeStr(sh.default_err, p.message(&buffer));
            sys.writeStr(sh.default_err, "\n");
            return 2;
        };
        _ = arena_state.reset(.retain_capacity);
    }
    if (options.jobs == null) {
        options.jobs = std.Thread.getCpuCount() catch {
            sys.writeStr(sh.default_err, "wsh: parallel: cannot determine CPU count; use -j N\n");
            return 1;
        };
    }
    const workers = arena.alloc(Worker, @min(options.jobs.?, options.commands.len)) catch return 1;
    const report_fd: ?i32 = if (options.report) |path| blk: {
        const z = arena.dupeZ(u8, path) catch return 1;
        break :blk sys.openWrite(z, false) orelse {
            sys.writeStr(sh.default_err, "wsh: parallel: cannot open report file\n");
            return 1;
        };
    } else null;
    defer if (report_fd) |fd| sys.closeFd(fd);

    var payload = Payload{ .sh = sh, .options = options, .workers = workers, .report_fd = report_fd, .run_source = run_source };
    const stage = proc.Stage{
        .child_fn = schedule,
        .child_ctx = &payload,
        .stdio = .{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err },
    };
    const launched = proc.launch(arena, &.{stage}, .{ .new_group = sh.job_control }) catch {
        sys.writeStr(sh.default_err, "wsh: parallel: cannot launch scheduler\n");
        return 1;
    };
    const job = sh.jobs.add(sh.gpa, launched.pgid, launched.pids, "parallel", true) catch {
        proc.signalProcess(launched.pids[0], .KILL);
        _ = proc.waitPid(launched.pids[0], 0);
        return 1;
    };
    const outcome = sh.waitForeground(job);
    if (outcome.stopped) {
        job.state = .stopped;
        job.foreground = false;
    } else if (sh.jobs.indexOf(job)) |index| sh.jobs.removeAt(sh.gpa, index);
    return outcome.status;
}

test "parallel requires positive concurrency and commands" {
    const testing = std.testing;
    try testing.expectError(error.InvalidOptions, parseOptions(&.{"parallel"}));
    try testing.expectError(error.InvalidOptions, parseOptions(&.{ "parallel", "-j", "0", "echo hi" }));
    try testing.expectError(error.InvalidOptions, parseOptions(&.{ "parallel", "--report" }));
    try testing.expectError(error.InvalidOptions, parseOptions(&.{ "parallel", "--unknown", "echo hi" }));
    const options = try parseOptions(&.{ "parallel", "-j", "2", "--fail-fast", "--", "echo hi" });
    try testing.expectEqual(@as(usize, 2), options.jobs.?);
    try testing.expect(options.fail_fast);
    try testing.expectEqual(@as(usize, 1), options.commands.len);
}
