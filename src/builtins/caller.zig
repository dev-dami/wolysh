//! `caller [expr]`: where the current function was called from.

const std = @import("std");
const builtins = @import("../builtins.zig");

const Ctx = builtins.Ctx;

/// Without an argument prints `line file` for the innermost call; with `N`
/// prints `line subroutine file` for the call N levels up. Fails outside a
/// function or when N is deeper than the call stack.
pub fn run(ctx: Ctx) u8 {
    const frames = ctx.sh.call_frames.items;
    var args = ctx.argv[1..];
    if (args.len > 0 and std.mem.eql(u8, args[0], "--")) args = args[1..];
    if (args.len > 1) {
        ctx.err("wsh: caller: too many arguments\n");
        return 2;
    }

    var level: usize = 0;
    if (args.len == 1) {
        level = std.fmt.parseInt(usize, args[0], 10) catch {
            ctx.errFmt("wsh: caller: {s}: invalid number\n", .{args[0]});
            return 2;
        };
    }
    if (level >= frames.len) return 1;

    // Frame 0 is the innermost call; the subroutine that made it is the next
    // frame out, or "main" at the top level.
    const frame = frames[frames.len - 1 - level];
    const parent: []const u8 = if (level + 1 < frames.len) frames[frames.len - 2 - level].name else "main";
    if (args.len == 0) {
        ctx.outFmt("{d} {s}\n", .{ frame.call_line, ctx.sh.script_name });
    } else {
        ctx.outFmt("{d} {s} {s}\n", .{ frame.call_line, parent, ctx.sh.script_name });
    }
    return 0;
}
