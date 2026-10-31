//! `shopt`: the bash-style switches wsh implements, backed by `Shell.options`.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");
const set_builtin = @import("set.zig");

const Options = shellmod.Options;

/// Every name `shopt` accepts, in the order it lists them.
pub const names = [_][]const u8{
    "autocd",               "assoc_expand_once", "cdable_vars",          "cdspell",
    "checkhash",            "checkjobs",         "checkwinsize",         "cmdhist",
    "compat31",             "compat32",          "compat40",             "compat41",
    "compat42",             "compat43",          "compat44",             "complete_fullquote",
    "direxpand",            "dirspell",          "dotglob",              "execfail",
    "expand_aliases",       "extdebug",          "extglob",              "extquote",
    "failglob",             "force_fignore",     "globasciiranges",      "globskipdots",
    "globstar",             "gnu_errfmt",        "histappend",           "histreedit",
    "histverify",           "hostcomplete",      "huponexit",            "inherit_errexit",
    "interactive_comments", "lastpipe",          "lithist",              "localvar_inherit",
    "localvar_unset",       "login_shell",       "mailwarn",             "no_empty_cmd_completion",
    "nocaseglob",           "nocasematch",       "noexpand_translation", "nullglob",
    "patsub_replacement",   "progcomp",          "progcomp_alias",       "promptvars",
    "restricted_shell",     "shift_verbose",     "sourcepath",           "varredir_close",
    "xpg_echo",
};

fn flag(options: *Options, name: []const u8) ?*bool {
    inline for (names) |known| {
        if (std.mem.eql(u8, name, known)) return &@field(options, known);
    }
    return null;
}

/// `shopt -o` shows the `set -o` options: `set -o name` / `set +o name` for `-p`.
fn showSetOption(ctx: builtins.Ctx, name: []const u8, on: bool, as_command: bool) void {
    if (as_command) {
        ctx.outFmt("set {s}o {s}\n", .{ if (on) "-" else "+", name });
    } else {
        ctx.outFmt("{s:<15}\t{s}\n", .{ name, if (on) "on" else "off" });
    }
}

fn show(ctx: builtins.Ctx, name: []const u8, on: bool, as_command: bool) void {
    if (as_command) {
        ctx.outFmt("shopt {s} {s}\n", .{ if (on) "-s" else "-u", name });
    } else {
        ctx.outFmt("{s:<15}\t{s}\n", .{ name, if (on) "on" else "off" });
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
    var set_options = false;
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
                'o' => set_options = true,
                else => {
                    ctx.errFmt("wsh: shopt: -{c}: invalid option\n", .{c});
                    ctx.err("shopt: usage: shopt [-pqsu] [-o] [optname ...]\n");
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
    if (set_options) return runSetOptions(ctx, requested, set, unset, as_command, quiet);
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

/// `shopt -o`: the same listing, setting and querying, over the `set -o` options.
fn runSetOptions(ctx: builtins.Ctx, requested: []const []const u8, set: bool, unset: bool, as_command: bool, quiet: bool) u8 {
    const options = &ctx.sh.options;
    if (requested.len == 0) {
        var i: usize = 0;
        while (i < set_builtin.option_count) : (i += 1) {
            const on = set_builtin.get(options, i);
            if ((set and !on) or (unset and on)) continue;
            if (!quiet) showSetOption(ctx, set_builtin.optionName(i), on, as_command);
        }
        return 0;
    }

    var status: u8 = 0;
    for (requested) |name| {
        const found = set_builtin.byName(name) orelse {
            ctx.errFmt("wsh: shopt: {s}: invalid option name\n", .{name});
            status = 1;
            continue;
        };
        if (set or unset) {
            set_builtin.put(options, found, set);
        } else {
            const on = set_builtin.get(options, found);
            if (!on) status = 1;
            if (!quiet) showSetOption(ctx, name, on, as_command);
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
    try testing.expectEqualStrings("nullglob       \ton\n", result.text);

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
