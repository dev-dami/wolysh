//! `getopts optstring name [args]`: POSIX option parsing for scripts.

const std = @import("std");
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;

/// Position inside a bundle such as `-abc` between calls. bash keeps the same
/// state in globals; it is only trusted while `OPTIND` and the argument still
/// match what the previous call left, so `OPTIND=1` restarts the scan.
const Progress = struct {
    sh: ?*const Shell = null,
    optind: usize = 0,
    /// Index of the next character in the current argument; 0 when the next
    /// call starts on a fresh argument.
    pos: usize = 0,
    arg_hash: u64 = 0,
};

var progress: Progress = .{};

pub fn run(ctx: Ctx) u8 {
    if (ctx.argv.len < 3) {
        ctx.err("wsh: getopts: usage: getopts optstring name [arg ...]\n");
        return 2;
    }
    var optstring = ctx.argv[1];
    const name = ctx.argv[2];
    if (!builtins.validName(name)) {
        ctx.errFmt("wsh: getopts: `{s}': not a valid identifier\n", .{name});
        return 1;
    }
    const silent = optstring.len != 0 and optstring[0] == ':';
    if (silent) optstring = optstring[1..];
    const report = !silent and optErr(ctx.sh);
    const args = if (ctx.argv.len > 3) ctx.argv[3..] else ctx.sh.positional;

    var optind = readOptind(ctx.sh);
    var pos: usize = 0;
    if (progress.sh == ctx.sh and progress.optind == optind and progress.pos != 0 and
        optind - 1 < args.len and std.hash.Wyhash.hash(0, args[optind - 1]) == progress.arg_hash)
    {
        pos = progress.pos;
    }

    if (pos == 0) {
        if (optind - 1 >= args.len) return finish(ctx, name, @min(optind, args.len + 1));
        const word = args[optind - 1];
        if (std.mem.eql(u8, word, "--")) return finish(ctx, name, optind + 1);
        if (word.len < 2 or word[0] != '-') return finish(ctx, name, optind);
        pos = 1;
    }

    const word = args[optind - 1];
    const c = word[pos];
    pos += 1;
    if (pos >= word.len) {
        optind += 1;
        pos = 0;
    }

    var letter = [1]u8{c};
    const at = if (c == ':') null else std.mem.indexOfScalar(u8, optstring, c);
    var result: []const u8 = &letter;
    var optarg: ?[]const u8 = null;
    if (at == null) {
        if (report) ctx.errFmt("{s}: illegal option -- {c}\n", .{ scriptName(ctx.sh), c });
        result = "?";
        if (silent) optarg = &letter;
    } else if (at.? + 1 < optstring.len and optstring[at.? + 1] == ':') {
        if (pos != 0) {
            optarg = word[pos..];
            optind += 1;
            pos = 0;
        } else if (optind - 1 < args.len) {
            optarg = args[optind - 1];
            optind += 1;
        } else {
            if (report) ctx.errFmt("{s}: option requires an argument -- {c}\n", .{ scriptName(ctx.sh), c });
            result = if (silent) ":" else "?";
            if (silent) optarg = &letter;
        }
    }

    if (!setOptind(ctx, optind)) return 1;
    if (optarg) |text| {
        ctx.sh.assignVar("OPTARG", .{ .string = text }) catch return failAssign(ctx, "OPTARG");
    } else {
        _ = ctx.sh.unsetVar("OPTARG");
    }
    ctx.sh.assignVar(name, .{ .string = result }) catch return failAssign(ctx, name);
    progress = .{
        .sh = ctx.sh,
        .optind = optind,
        .pos = pos,
        .arg_hash = if (pos != 0) std.hash.Wyhash.hash(0, word) else 0,
    };
    return 0;
}

/// The end of the options: NAME becomes `?` and the status is 1.
fn finish(ctx: Ctx, name: []const u8, optind: usize) u8 {
    progress = .{ .sh = ctx.sh, .optind = optind };
    if (!setOptind(ctx, optind)) return 1;
    _ = ctx.sh.unsetVar("OPTARG");
    ctx.sh.assignVar(name, .{ .string = "?" }) catch return failAssign(ctx, name);
    return 1;
}

fn setOptind(ctx: Ctx, optind: usize) bool {
    var buf: [24]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}", .{optind}) catch unreachable;
    ctx.sh.assignVar("OPTIND", .{ .string = text }) catch {
        _ = failAssign(ctx, "OPTIND");
        return false;
    };
    return true;
}

fn failAssign(ctx: Ctx, name: []const u8) u8 {
    ctx.errFmt("wsh: getopts: {s}: readonly variable\n", .{name});
    return 1;
}

fn variableText(sh: *Shell, name: []const u8, buf: []u8) ?[]const u8 {
    if (sh.getVar(name)) |v| {
        return switch (v) {
            .string => |s| s,
            .int => |n| std.fmt.bufPrint(buf, "{d}", .{n}) catch null,
            else => null,
        };
    }
    return sh.getEnv(name);
}

/// `OPTIND`, defaulting to 1 like bash when it is unset, empty or invalid.
fn readOptind(sh: *Shell) usize {
    var buf: [24]u8 = undefined;
    const text = variableText(sh, "OPTIND", &buf) orelse return 1;
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, text, " \t"), 10) catch return 1;
    return @max(n, 1);
}

/// `OPTERR=0` silences diagnostics.
fn optErr(sh: *Shell) bool {
    var buf: [24]u8 = undefined;
    const text = variableText(sh, "OPTERR", &buf) orelse return true;
    const n = std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t"), 10) catch return false;
    return n != 0;
}

fn scriptName(sh: *const Shell) []const u8 {
    return if (sh.script_name.len != 0) sh.script_name else "wsh";
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn call(sh: *Shell, argv: []const []const u8) u8 {
    return run(.{ .sh = sh, .argv = argv, .stderr = -1 });
}

fn expectVar(sh: *Shell, name: []const u8, expected: ?[]const u8) !void {
    if (expected) |text| {
        try testing.expectEqualStrings(text, sh.getVar(name).?.string);
    } else {
        try testing.expect(sh.getVar(name) == null);
    }
}

test "getopts walks bundles, arguments and the end of options" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    sh.positional = &.{ "-ac", "-bval", "-b", "next", "rest" };
    const argv = [_][]const u8{ "getopts", "ab:c", "opt" };

    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "opt", "a");
    try expectVar(&sh, "OPTIND", "1");
    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "opt", "c");
    try expectVar(&sh, "OPTIND", "2");
    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "OPTARG", "val");
    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "OPTARG", "next");
    try expectVar(&sh, "OPTIND", "5");
    try testing.expectEqual(@as(u8, 1), call(&sh, &argv));
    try expectVar(&sh, "opt", "?");
    try expectVar(&sh, "OPTARG", null);
    try expectVar(&sh, "OPTIND", "5");

    // Resetting OPTIND starts over.
    try sh.setVar("OPTIND", .{ .string = "1" });
    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "opt", "a");
}

test "getopts silent mode reports unknown and missing options" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    const argv = [_][]const u8{ "getopts", ":ab:", "opt", "-x", "-b" };

    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "opt", "?");
    try expectVar(&sh, "OPTARG", "x");
    try testing.expectEqual(@as(u8, 0), call(&sh, &argv));
    try expectVar(&sh, "opt", ":");
    try expectVar(&sh, "OPTARG", "b");
    try expectVar(&sh, "OPTIND", "3");

    try sh.setVar("OPTIND", .{ .string = "1" });
    const loud = [_][]const u8{ "getopts", "ab:", "opt", "-b" };
    try testing.expectEqual(@as(u8, 0), call(&sh, &loud));
    try expectVar(&sh, "opt", "?");
    try expectVar(&sh, "OPTARG", null);

    try testing.expectEqual(@as(u8, 2), call(&sh, &.{ "getopts", "ab" }));
    try testing.expectEqual(@as(u8, 1), call(&sh, &.{ "getopts", "ab", "1x", "-a" }));
}
