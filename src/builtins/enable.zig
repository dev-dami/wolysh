//! `enable`: turn builtins on and off, and list them.
//!
//! A disabled builtin is skipped by the lookup, so the command of the same
//! name found on `PATH` runs instead.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");

const Ctx = builtins.Ctx;

const usage = "wsh: enable: usage: enable [-a] [-dnps] [-f filename] [name ...]\n";

/// The POSIX special builtins, for `enable -s`.
const special = [_][]const u8{
    ":",      "break",    "continue", "eval", "exec",  "exit",
    "export", "readonly", "return",   "set",  "shift", "source",
    "times",  "trap",     "unset",    ".",
};

fn isSpecial(name: []const u8) bool {
    for (special) |entry| {
        if (std.mem.eql(u8, entry, name)) return true;
    }
    return false;
}

pub fn run(ctx: Ctx) u8 {
    var disable = false;
    var print = false;
    var all = false;
    var only_special = false;
    var parser = options.Parser.init(ctx.argv, "adnpsf:");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: enable: -{c}: invalid option\n", .{c});
                ctx.err(usage);
                return 2;
            },
            .option => |c| switch (c) {
                'a' => all = true,
                'n' => disable = true,
                'p' => print = true,
                's' => only_special = true,
                'd', 'f' => {
                    ctx.err("wsh: enable: dynamically loaded builtins are not available\n");
                    return 1;
                },
                else => unreachable,
            },
        }
    }

    const names = parser.rest();
    if (names.len == 0 or print) return list(ctx, disable, all, only_special);

    var status: u8 = 0;
    for (names) |name| {
        if (!builtins.setEnabled(name, !disable)) {
            ctx.errFmt("wsh: enable: {s}: not a shell builtin\n", .{name});
            status = 1;
        }
    }
    return status;
}

/// Lists enabled builtins as `enable name`, disabled ones as `enable -n name`.
/// With `-n` only the disabled ones, with `-a` both.
fn list(ctx: Ctx, disabled_only: bool, all: bool, only_special: bool) u8 {
    for (builtins.all()) |b| {
        if (only_special and !isSpecial(b.name)) continue;
        const enabled = builtins.isEnabled(b.name);
        if (!all and enabled == disabled_only) continue;
        ctx.outFmt("enable {s}{s}\n", .{ if (enabled) "" else "-n ", b.name });
    }
    return 0;
}
