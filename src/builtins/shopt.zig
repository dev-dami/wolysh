//! `shopt`: the bash-style switches wsh implements, backed by `Shell.options`.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Options = shellmod.Options;

/// Every name `shopt` accepts, in the order it lists them.
const names = [_][]const u8{ "dotglob", "extglob", "failglob", "globstar", "nocaseglob", "nocasematch", "nullglob" };

fn flag(options: *Options, name: []const u8) ?*bool {
    inline for (names) |known| {
        if (std.mem.eql(u8, name, known)) return &@field(options, known);
    }
    return null;
}

fn show(ctx: builtins.Ctx, name: []const u8, on: bool, as_command: bool) void {
    if (as_command) {
        ctx.outFmt("shopt {s} {s}\n", .{ if (on) "-s" else "-u", name });
    } else {
        ctx.outFmt("{s:<20}\t{s}\n", .{ name, if (on) "on" else "off" });
    }
}

/// `shopt [-pqsu] [name ...]`: with names, set (`-s`), unset (`-u`) or report
/// them; without, list every option (only the enabled or disabled ones with
/// `-s`/`-u`). `-p` prints reusable `shopt` commands and `-q` prints nothing.
pub fn run(ctx: builtins.Ctx) u8 {
    var set = false;
    var unset = false;
    var as_command = false;
    var quiet = false;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |c| {
            switch (c) {
                's' => set = true,
                'u' => unset = true,
                'p' => as_command = true,
                'q' => quiet = true,
                'o' => {
                    ctx.err("wsh: shopt: -o: not supported; use set -o\n");
                    return 2;
                },
                else => {
                    ctx.errFmt("wsh: shopt: -{c}: invalid option\n", .{c});
                    ctx.err("shopt: usage: shopt [-pqsu] [optname ...]\n");
                    return 2;
                },
            }
        }
    }
    if (set and unset) {
        ctx.err("wsh: shopt: cannot set and unset shell options simultaneously\n");
        return 1;
    }

    const options = &ctx.sh.options;
    const requested = ctx.argv[index..];
    if (requested.len == 0) {
        for (names) |name| {
            const on = flag(options, name).?.*;
            if ((set and !on) or (unset and on)) continue;
            if (!quiet) show(ctx, name, on, as_command);
        }
        return 0;
    }

    var status: u8 = 0;
    for (requested) |name| {
        const target = flag(options, name) orelse {
            ctx.errFmt("wsh: shopt: {s}: invalid shell option name\n", .{name});
            status = 1;
            continue;
        };
        if (set) {
            target.* = true;
        } else if (unset) {
            target.* = false;
        } else {
            if (!target.*) status = 1;
            if (!quiet) show(ctx, name, target.*, as_command);
        }
    }
    return status;
}

const testing = std.testing;

fn runCaptured(sh: *shellmod.Shell, argv: []const []const u8, out: *[512]u8) !struct { status: u8, text: []const u8 } {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(fds[0]);
    const status = run(.{ .sh = sh, .argv = argv, .stdout = fds[1], .stderr = fds[1] });
    _ = linux.close(fds[1]);
    const n = sys.readAll(fds[0], out);
    return .{ .status = status, .text = out[0..n] };
}

test "shopt sets, reports and rejects options" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var buf: [512]u8 = undefined;

    var result = try runCaptured(&sh, &.{ "shopt", "-s", "nullglob", "dotglob" }, &buf);
    try testing.expectEqual(@as(u8, 0), result.status);
    try testing.expect(sh.options.nullglob and sh.options.dotglob);

    result = try runCaptured(&sh, &.{ "shopt", "nullglob" }, &buf);
    try testing.expectEqual(@as(u8, 0), result.status);
    try testing.expectEqualStrings("nullglob            \ton\n", result.text);

    result = try runCaptured(&sh, &.{ "shopt", "-p", "failglob" }, &buf);
    try testing.expectEqual(@as(u8, 1), result.status);
    try testing.expectEqualStrings("shopt -u failglob\n", result.text);

    result = try runCaptured(&sh, &.{ "shopt", "-qu", "globstar" }, &buf);
    try testing.expectEqual(@as(u8, 0), result.status);
    try testing.expect(!sh.options.globstar);

    result = try runCaptured(&sh, &.{ "shopt", "-q", "globstar" }, &buf);
    try testing.expectEqual(@as(u8, 1), result.status);
    try testing.expectEqualStrings("", result.text);

    result = try runCaptured(&sh, &.{ "shopt", "-s", "bogus" }, &buf);
    try testing.expectEqual(@as(u8, 1), result.status);
    try testing.expectEqualStrings("wsh: shopt: bogus: invalid shell option name\n", result.text);

    result = try runCaptured(&sh, &.{ "shopt", "-su", "nullglob" }, &buf);
    try testing.expectEqual(@as(u8, 1), result.status);
}
