//! Entry points for `run`, `session` and `--daemon`: the `wsh run ...` fast
//! path, which starts before any shell set-up, and the shell builtins.

const std = @import("std");
const fs = @import("../fs.zig");
const Shell = @import("../shell.zig").Shell;
const state = @import("state.zig");
const runs = @import("runs.zig");
const sessions = @import("sessions.zig");
const daemon = @import("daemon.zig");

/// True when `wsh ARG ...` is one of these commands rather than a script.
pub fn isCommand(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "run") or std.mem.eql(u8, arg, "session");
}

/// `wsh run ...`, `wsh session ...` and `wsh --daemon`, without a shell.
pub fn main(gpa: std.mem.Allocator, args: []const [:0]const u8, envp: [*:null]const ?[*:0]const u8) u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = arena.alloc([]const u8, args.len) catch return 1;
    for (args, argv) |arg, *slot| slot.* = arg;
    const cwd = (fs.getCwd(arena) catch null) orelse "/";
    const ctx = state.Context{ .gpa = gpa, .arena = arena, .envp = envp, .cwd = cwd };
    if (std.mem.eql(u8, argv[0], "--daemon")) return daemon.main(ctx);
    if (std.mem.eql(u8, argv[0], "run")) return runs.command(ctx, argv);
    return sessions.command(ctx, argv);
}

/// The `run` and `session` builtins. A run started here inherits the shell's
/// functions and variables.
pub fn builtin(sh: *Shell, argv: []const []const u8, stdio: [3]i32, run_source: ?state.RunSource) u8 {
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const envp = sh.buildEnvp(arena) catch return 1;
    const ctx = state.Context{
        .gpa = sh.gpa,
        .arena = arena,
        .stdin = stdio[0],
        .stdout = stdio[1],
        .stderr = stdio[2],
        .envp = envp,
        .cwd = sh.cwd,
        .sh = sh,
        .run_source = run_source,
    };
    if (std.mem.eql(u8, argv[0], "run")) return runs.command(ctx, argv);
    return sessions.command(ctx, argv);
}
