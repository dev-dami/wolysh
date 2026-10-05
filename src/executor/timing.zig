//! The `time` keyword: elapsed and CPU time of a pipeline, reported on
//! standard error in bash's formats. CPU time is the shell's own usage plus
//! that of the children it reaped, so builtins, functions and compound
//! commands are measured as well as external programs.

const std = @import("std");
const linux = std.os.linux;
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

/// bash's default `TIMEFORMAT`.
const default_format = "\nreal\t%3lR\nuser\t%3lU\nsys\t%3lS";
const posix_format = "real %2R\nuser %2U\nsys %2S";

/// Nanosecond readings taken before and after the timed pipeline.
pub const Snapshot = struct {
    real: i128,
    user: i128,
    sys: i128,

    pub fn take() Snapshot {
        var now: linux.timespec = undefined;
        if (linux.errno(linux.clock_gettime(.MONOTONIC, &now)) != .SUCCESS) now = .{ .sec = 0, .nsec = 0 };
        const own = usage(linux.rusage.SELF);
        const children = usage(linux.rusage.CHILDREN);
        return .{
            .real = @as(i128, now.sec) * std.time.ns_per_s + now.nsec,
            .user = nanos(own.utime) + nanos(children.utime),
            .sys = nanos(own.stime) + nanos(children.stime),
        };
    }
};

fn usage(who: i32) linux.rusage {
    var out = std.mem.zeroes(linux.rusage);
    _ = linux.getrusage(who, &out);
    return out;
}

fn nanos(tv: linux.timeval) i128 {
    return @as(i128, tv.sec) * std.time.ns_per_s + @as(i128, tv.usec) * std.time.ns_per_us;
}

/// Prints the time spent since `start`. `TIMEFORMAT` overrides the default
/// layout (an empty value prints nothing); `time -p` always uses POSIX's.
pub fn report(sh: *Shell, start: Snapshot, posix: bool) void {
    const end = Snapshot.take();
    const spent = Snapshot{
        .real = @max(0, end.real - start.real),
        .user = @max(0, end.user - start.user),
        .sys = @max(0, end.sys - start.sys),
    };
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const format = if (posix) posix_format else timeFormat(sh, arena) orelse default_format;
    if (format.len == 0) return;
    var out: std.ArrayList(u8) = .empty;
    render(arena, &out, format, spent) catch return;
    out.append(arena, '\n') catch return;
    sys.writeStr(sh.default_err, out.items);
}

fn timeFormat(sh: *Shell, arena: std.mem.Allocator) ?[]const u8 {
    if (sh.getVar("TIMEFORMAT")) |v| return v.renderAlloc(arena) catch null;
    return sh.getEnv("TIMEFORMAT");
}

/// Expands `%[p][l]R|U|S`, `%[p]P` and `%%`; anything else is copied.
fn render(arena: std.mem.Allocator, out: *std.ArrayList(u8), format: []const u8, spent: Snapshot) !void {
    var i: usize = 0;
    while (i < format.len) {
        const c = format[i];
        if (c != '%' or i + 1 >= format.len) {
            try out.append(arena, c);
            i += 1;
            continue;
        }
        if (format[i + 1] == '%') {
            try out.append(arena, '%');
            i += 2;
            continue;
        }
        var j = i + 1;
        var precision: u8 = 3;
        if (j < format.len and std.ascii.isDigit(format[j])) {
            precision = @min(format[j] - '0', 3);
            j += 1;
        }
        var long = false;
        if (j < format.len and format[j] == 'l') {
            long = true;
            j += 1;
        }
        if (j >= format.len) {
            try out.appendSlice(arena, format[i..]);
            break;
        }
        const value: i128 = switch (format[j]) {
            'R' => spent.real,
            'U' => spent.user,
            'S' => spent.sys,
            'P' => {
                const cpu = spent.user + spent.sys;
                const hundredths: u64 = if (spent.real > 0) @intCast(@divTrunc(cpu * 10000, spent.real)) else 0;
                try out.print(arena, "{d}.{d:0>2}", .{ hundredths / 100, hundredths % 100 });
                i = j + 1;
                continue;
            },
            else => {
                try out.appendSlice(arena, format[i .. j + 1]);
                i = j + 1;
                continue;
            },
        };
        try writeSeconds(arena, out, value, precision, long);
        i = j + 1;
    }
}

/// `12.345` or, in the long form, `0m12.345s`; the fraction is truncated
/// to `precision` digits like bash does.
fn writeSeconds(arena: std.mem.Allocator, out: *std.ArrayList(u8), ns: i128, precision: u8, long: bool) !void {
    const millis = @divTrunc(ns, std.time.ns_per_ms);
    var seconds = @divTrunc(millis, 1000);
    const fraction = @mod(millis, 1000);
    if (long) {
        try out.print(arena, "{d}m", .{@divTrunc(seconds, 60)});
        seconds = @mod(seconds, 60);
    }
    try out.print(arena, "{d}", .{seconds});
    if (precision > 0) {
        var digits: [3]u8 = undefined;
        _ = std.fmt.bufPrint(&digits, "{d:0>3}", .{@as(u64, @intCast(fraction))}) catch unreachable;
        try out.append(arena, '.');
        try out.appendSlice(arena, digits[0..precision]);
    }
    if (long) try out.append(arena, 's');
}

test "time formats follow bash" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const spent = Snapshot{ .real = 61_234_567_890, .user = 5_000_000, .sys = 120_000_000 };

    var out: std.ArrayList(u8) = .empty;
    try render(arena, &out, default_format, spent);
    try std.testing.expectEqualStrings("\nreal\t1m1.234s\nuser\t0m0.005s\nsys\t0m0.120s", out.items);

    out.clearRetainingCapacity();
    try render(arena, &out, posix_format, spent);
    try std.testing.expectEqualStrings("real 61.23\nuser 0.00\nsys 0.12", out.items);

    out.clearRetainingCapacity();
    try render(arena, &out, "%0R|%1U|%%|%P|%x", spent);
    try std.testing.expectEqualStrings("61|0.0|%|0.20|%x", out.items);
}
