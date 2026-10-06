//! `cd` and `pwd`. The working directory is logical by default, as in bash:
//! see `Shell.changeDir`.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");

const Ctx = builtins.Ctx;

/// `cd [-L|-P] [dir]`. No operand means `$HOME` and `-` means `$OLDPWD`; a
/// relative name not starting with `.` or `..` is looked up through
/// `$CDPATH` first. The new directory is printed after `cd -` and after a
/// `CDPATH` match.
pub fn builtinCd(ctx: Ctx) u8 {
    var physical = false;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |flag| {
            switch (flag) {
                'L' => physical = false,
                'P' => physical = true,
                else => {
                    ctx.errFmt("wsh: cd: -{c}: invalid option\ncd: usage: cd [-L|-P] [dir]\n", .{flag});
                    return 2;
                },
            }
        }
    }
    const operands = ctx.argv[index..];
    if (operands.len > 1) {
        ctx.err("wsh: cd: too many arguments\n");
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var announce = false;
    var target: []const u8 = undefined;
    if (operands.len == 0) {
        target = variable(ctx, arena, "HOME") orelse {
            ctx.err("wsh: cd: HOME not set\n");
            return 1;
        };
    } else if (std.mem.eql(u8, operands[0], "-")) {
        target = variable(ctx, arena, "OLDPWD") orelse {
            ctx.err("wsh: cd: OLDPWD not set\n");
            return 1;
        };
        announce = true;
    } else {
        target = operands[0];
    }
    if (target.len == 0) {
        ctx.err("wsh: cd: null directory\n");
        return 1;
    }

    if (searchesCdpath(target)) {
        if (variable(ctx, arena, "CDPATH")) |cdpath| {
            var it = std.mem.splitScalar(u8, cdpath, ':');
            while (it.next()) |entry| {
                // An empty entry is the current directory, which bash does
                // not announce.
                const candidate = if (entry.len == 0)
                    target
                else
                    std.fmt.allocPrint(arena, "{s}/{s}", .{ std.mem.trimEnd(u8, entry, "/"), target }) catch return 1;
                const err = ctx.sh.changeDir(candidate, physical) catch return outOfMemory(ctx);
                if (err == .SUCCESS) return finish(ctx, announce or entry.len != 0);
            }
        }
    }

    const err = ctx.sh.changeDir(target, physical) catch return outOfMemory(ctx);
    if (err != .SUCCESS) {
        ctx.err("wsh: cd: ");
        ctx.err(target);
        ctx.err(": ");
        ctx.err(proc.errorText(err));
        ctx.err("\n");
        return 1;
    }
    return finish(ctx, announce);
}

fn finish(ctx: Ctx, announce: bool) u8 {
    if (announce) {
        ctx.out(ctx.sh.cwd);
        ctx.out("\n");
    }
    return 0;
}

fn outOfMemory(ctx: Ctx) u8 {
    ctx.err("wsh: cd: out of memory\n");
    return 1;
}

/// POSIX: `CDPATH` applies unless the operand starts with `/`, `.` or `..`.
fn searchesCdpath(target: []const u8) bool {
    if (target[0] == '/') return false;
    const first = target[0 .. std.mem.indexOfScalar(u8, target, '/') orelse target.len];
    return !std.mem.eql(u8, first, ".") and !std.mem.eql(u8, first, "..");
}

/// A shell variable shadows the environment, as in `$NAME` expansion. The
/// copy outlives `changeDir` rewriting `OLDPWD`.
fn variable(ctx: Ctx, arena: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (ctx.sh.getVar(name)) |v| return v.renderAlloc(arena) catch null;
    const text = ctx.sh.getEnv(name) orelse return null;
    return arena.dupe(u8, text) catch null;
}

/// `pwd [-L|-P]`: the logical directory by default, the resolved one with
/// `-P`. Operands are ignored, as in bash.
pub fn builtinPwd(ctx: Ctx) u8 {
    var physical = false;
    for (ctx.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..]) |flag| {
            switch (flag) {
                'L' => physical = false,
                'P' => physical = true,
                else => {
                    ctx.errFmt("wsh: pwd: -{c}: invalid option\npwd: usage: pwd [-LP]\n", .{flag});
                    return 2;
                },
            }
        }
    }
    if (!physical) {
        ctx.out(ctx.sh.cwd);
        ctx.out("\n");
        return 0;
    }
    var buf: [linux.PATH_MAX]u8 = undefined;
    const rc = linux.getcwd(&buf, buf.len);
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        ctx.errFmt("wsh: pwd: error retrieving current directory: {s}\n", .{proc.errorText(err)});
        return 1;
    }
    const n: usize = @intCast(rc);
    ctx.out(buf[0..if (n > 0 and buf[n - 1] == 0) n - 1 else n]);
    ctx.out("\n");
    return 0;
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;

test "CDPATH applies only to plain relative names" {
    try testing.expect(searchesCdpath("src"));
    try testing.expect(searchesCdpath("src/deep"));
    try testing.expect(searchesCdpath(".hidden"));
    try testing.expect(!searchesCdpath("/tmp"));
    try testing.expect(!searchesCdpath("."));
    try testing.expect(!searchesCdpath("./src"));
    try testing.expect(!searchesCdpath("../up"));
}

test "logical paths drop dot components and step back textually" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    testing.allocator.free(sh.cwd);
    sh.cwd = try testing.allocator.dupe(u8, "/usr/lib");
    try testing.expectEqualStrings("/usr", (try sh.logicalPath(arena, "..")).?);
    try testing.expectEqualStrings("/usr/lib/x/y", (try sh.logicalPath(arena, "./x//y/")).?);
    try testing.expectEqualStrings("/", (try sh.logicalPath(arena, "../../..")).?);
    try testing.expectEqualStrings("/tmp", (try sh.logicalPath(arena, "/tmp/./")).?);
    // A missing directory cannot be stepped out of.
    try testing.expect(try sh.logicalPath(arena, "definitely-missing-dir/..") == null);
}
