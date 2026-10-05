//! `set`: shell options, the positional parameters and the variable listing.

const std = @import("std");
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const quote = @import("../quote.zig");
const value = @import("../value.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;
const Options = shellmod.Options;

const usage = "wsh: set: usage: set [-aefuxCEH] [-o option-name] [--] [-] [arg ...]\n";

const Option = struct {
    name: []const u8,
    letter: u8 = 0,
    field: []const u8,
    /// `emacs` is the inverse of `vi`.
    inverted: bool = false,
};

/// Alphabetical, the order `set -o` lists them in.
const options = [_]Option{
    .{ .name = "allexport", .letter = 'a', .field = "allexport" },
    .{ .name = "emacs", .field = "vi", .inverted = true },
    .{ .name = "errexit", .letter = 'e', .field = "errexit" },
    .{ .name = "errtrace", .letter = 'E', .field = "errtrace" },
    .{ .name = "histexpand", .letter = 'H', .field = "histexpand" },
    .{ .name = "ignoreeof", .field = "ignoreeof" },
    .{ .name = "noclobber", .letter = 'C', .field = "noclobber" },
    .{ .name = "noglob", .letter = 'f', .field = "noglob" },
    .{ .name = "nounset", .letter = 'u', .field = "nounset" },
    .{ .name = "pipefail", .field = "pipefail" },
    .{ .name = "vi", .field = "vi" },
    .{ .name = "xtrace", .letter = 'x', .field = "xtrace" },
};

fn get(opts: *const Options, index: usize) bool {
    inline for (options, 0..) |option, i| {
        if (i == index) return @field(opts, option.field) != option.inverted;
    }
    unreachable;
}

fn put(opts: *Options, index: usize, on: bool) void {
    inline for (options, 0..) |option, i| {
        if (i == index) @field(opts, option.field) = on != option.inverted;
    }
}

fn byName(name: []const u8) ?usize {
    for (options, 0..) |option, index| {
        if (std.mem.eql(u8, option.name, name)) return index;
    }
    return null;
}

fn byLetter(letter: u8) ?usize {
    for (options, 0..) |option, index| {
        if (option.letter == letter) return index;
    }
    return null;
}

pub fn run(ctx: Ctx) u8 {
    const args = ctx.argv[1..];
    if (args.len == 0) return listVariables(ctx);

    var index: usize = 0;
    while (index < args.len) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--")) return replacePositional(ctx, args[index + 1 ..]);
        if (std.mem.eql(u8, arg, "-")) {
            // `set -` ends the options and turns tracing off; with nothing
            // after it the positional parameters are left alone.
            ctx.sh.options.xtrace = false;
            if (index + 1 == args.len) return 0;
            return replacePositional(ctx, args[index + 1 ..]);
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) return replacePositional(ctx, args[index..]);

        const on = arg[0] == '-';
        var next = index + 1;
        for (arg[1..]) |letter| {
            if (letter == 'o') {
                if (next == args.len) {
                    listOptions(ctx, on);
                    continue;
                }
                const name = args[next];
                next += 1;
                const option = byName(name) orelse {
                    ctx.errFmt("wsh: set: {s}: invalid option name\n", .{name});
                    return 2;
                };
                put(&ctx.sh.options, option, on);
                continue;
            }
            const option = byLetter(letter) orelse {
                ctx.errFmt("wsh: set: {c}{c}: invalid option\n", .{ arg[0], letter });
                ctx.err(usage);
                return 2;
            };
            put(&ctx.sh.options, option, on);
        }
        index = next;
    }
    return 0;
}

fn replacePositional(ctx: Ctx, args: []const []const u8) u8 {
    ctx.sh.setPositional(args) catch {
        ctx.err("wsh: set: out of memory\n");
        return 1;
    };
    return 0;
}

/// `set -o` prints a table; `set +o` prints commands that restore the
/// current settings.
fn listOptions(ctx: Ctx, table: bool) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(ctx.sh.gpa);
    for (options, 0..) |option, index| {
        const on = get(&ctx.sh.options, index);
        var buf: [64]u8 = undefined;
        const line = if (table)
            std.fmt.bufPrint(&buf, "{s:<15}\t{s}\n", .{ option.name, if (on) "on" else "off" })
        else
            std.fmt.bufPrint(&buf, "set {c}o {s}\n", .{ @as(u8, if (on) '-' else '+'), option.name });
        out.appendSlice(ctx.sh.gpa, line catch continue) catch return;
    }
    ctx.out(out.items);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

/// Bare `set`: every shell and environment variable as `NAME=value`, sorted
/// and quoted so the output can be read back.
fn listVariables(ctx: Ctx) u8 {
    const sh = ctx.sh;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(sh.gpa);
    sh.varNames(&names) catch return outOfMemory(ctx);
    var env_it = sh.env.iterator();
    while (env_it.next()) |entry| {
        if (!sh.hasVar(entry.key_ptr.*)) names.append(sh.gpa, entry.key_ptr.*) catch return outOfMemory(ctx);
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(sh.gpa);
    for (names.items) |name| {
        appendVariable(sh, &out, name) catch return outOfMemory(ctx);
    }
    ctx.out(out.items);
    return 0;
}

fn appendVariable(sh: *Shell, out: *std.ArrayList(u8), name: []const u8) !void {
    const gpa = sh.gpa;
    try out.appendSlice(gpa, name);
    try out.append(gpa, '=');
    if (sh.getVar(name)) |v| {
        switch (v) {
            .list => |items| {
                // bash's array form: NAME=([0]="a" [1]="b")
                try out.append(gpa, '(');
                for (items, 0..) |item, index| {
                    if (index != 0) try out.append(gpa, ' ');
                    const text = try item.renderAlloc(gpa);
                    defer gpa.free(text);
                    var buf: [24]u8 = undefined;
                    try out.appendSlice(gpa, try std.fmt.bufPrint(&buf, "[{d}]=", .{index}));
                    try quote.appendDouble(out, gpa, text);
                }
                try out.append(gpa, ')');
            },
            else => {
                const text = try v.renderAlloc(gpa);
                defer gpa.free(text);
                if (text.len != 0) try quote.appendWord(out, gpa, text);
            },
        }
    } else if (sh.getEnv(name)) |text| {
        if (text.len != 0) try quote.appendWord(out, gpa, text);
    }
    try out.append(gpa, '\n');
}

fn outOfMemory(ctx: Ctx) u8 {
    ctx.err("wsh: set: out of memory\n");
    return 1;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

fn runSet(sh: *Shell, argv: []const []const u8) u8 {
    return run(Ctx{ .sh = sh, .argv = argv, .stdout = -1, .stderr = -1 });
}

test "set flags, -o names and combined forms" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-euo", "pipefail" }));
    try testing.expect(sh.options.errexit and sh.options.nounset and sh.options.pipefail);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "+eu", "-xC", "+o", "pipefail" }));
    try testing.expect(!sh.options.errexit and !sh.options.nounset and !sh.options.pipefail);
    try testing.expect(sh.options.xtrace and sh.options.noclobber);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-o", "vi" }));
    try testing.expect(sh.options.vi);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-o", "emacs" }));
    try testing.expect(!sh.options.vi);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-" }));
    try testing.expect(!sh.options.xtrace);

    try testing.expectEqual(@as(u8, 2), runSet(&sh, &.{ "set", "-Q" }));
    try testing.expectEqual(@as(u8, 2), runSet(&sh, &.{ "set", "-o", "nosuch" }));
}

test "set replaces the positional parameters" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "--", "a", "-b" }));
    try testing.expectEqual(@as(usize, 2), sh.positional.len);
    try testing.expectEqualStrings("-b", sh.positional[1]);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-e", "x", "-u" }));
    try testing.expect(sh.options.errexit and !sh.options.nounset);
    try testing.expectEqualStrings("-u", sh.positional[1]);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "-o", "pipefail", "rest" }));
    try testing.expectEqualStrings("rest", sh.positional[0]);
    try testing.expectEqual(@as(u8, 0), runSet(&sh, &.{ "set", "--" }));
    try testing.expectEqual(@as(usize, 0), sh.positional.len);
}

test "bare set lists variables quoted" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setVar("plain", .{ .string = "word" });
    try sh.setVar("spaced", .{ .string = "a b" });
    try sh.setVar("empty", .{ .string = "" });
    try sh.setEnv("ENV_ONLY", "it's");
    try sh.setVar("list", .{ .list = &.{ .{ .int = 0 }, .{ .string = "x y" } } });

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    for ([_][]const u8{ "ENV_ONLY", "empty", "list", "plain", "spaced" }) |name| try appendVariable(&sh, &out, name);
    try testing.expectEqualStrings(
        "ENV_ONLY='it'\\''s'\nempty=\nlist=([0]=\"0\" [1]=\"x y\")\nplain=word\nspaced='a b'\n",
        out.items,
    );
}
