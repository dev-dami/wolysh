//! The directory stack: `pushd`, `popd` and `dirs`.
//!
//! Entry 0 of the stack, as the user sees it, is the current directory; the
//! rest live in `Shell.dir_stack`, most recent first.

const std = @import("std");
const builtins = @import("../builtins.zig");
const fs = @import("../fs.zig");

const Ctx = builtins.Ctx;
const Allocator = std.mem.Allocator;

/// A `+N` / `-N` operand: N counts from the left (0 is the current
/// directory) or from the right.
const Index = struct {
    from_right: bool,
    n: usize,
    text: []const u8,

    fn parse(text: []const u8) ?Index {
        if (text.len < 2 or (text[0] != '+' and text[0] != '-')) return null;
        const n = std.fmt.parseInt(usize, text[1..], 10) catch return null;
        return .{ .from_right = text[0] == '-', .n = n, .text = text };
    }

    /// Position in the full stack of `len` entries, or null when out of range.
    fn resolve(self: Index, len: usize) ?usize {
        if (self.n >= len) return null;
        return if (self.from_right) len - 1 - self.n else self.n;
    }
};

fn stackLen(ctx: Ctx) usize {
    return ctx.sh.dir_stack.items.len + 1;
}

fn entry(ctx: Ctx, index: usize) []const u8 {
    return if (index == 0) ctx.sh.cwd else ctx.sh.dir_stack.items[index - 1];
}

const Style = enum { line, per_line, numbered };

fn print(ctx: Ctx, style: Style, long: bool) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    for (0..stackLen(ctx)) |i| {
        const path = entry(ctx, i);
        const shown = if (long) path else ctx.sh.shortenHome(arena, path) catch path;
        switch (style) {
            .line => {
                if (i != 0) out.append(arena, ' ') catch return 1;
                out.appendSlice(arena, shown) catch return 1;
            },
            .per_line => out.print(arena, "{s}\n", .{shown}) catch return 1,
            .numbered => out.print(arena, "{d: >2}  {s}\n", .{ i, shown }) catch return 1,
        }
    }
    if (style == .line) out.append(arena, '\n') catch return 1;
    ctx.out(out.items);
    return 0;
}

/// Changes to `path`, reporting failures the way bash does.
fn changeTo(ctx: Ctx, builtin: []const u8, path: []const u8) bool {
    var buf: [std.os.linux.PATH_MAX]u8 = undefined;
    if (path.len >= buf.len) {
        ctx.errFmt("wsh: {s}: {s}: File name too long\n", .{ builtin, path });
        return false;
    }
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const z = buf[0..path.len :0];
    const found = fs.kindFollow(z);
    const reason: ?[]const u8 = if (found == null)
        "No such file or directory"
    else if (found.? != .dir)
        "Not a directory"
    else
        null;
    if (reason) |text| {
        ctx.errFmt("wsh: {s}: {s}: {s}\n", .{ builtin, path, text });
        return false;
    }
    const previous = ctx.sh.gpa.dupe(u8, ctx.sh.cwd) catch return false;
    defer ctx.sh.gpa.free(previous);
    const changed = ctx.sh.setCwd(z) catch false;
    if (!changed) {
        ctx.errFmt("wsh: {s}: {s}: Permission denied\n", .{ builtin, path });
        return false;
    }
    ctx.sh.setEnv("OLDPWD", previous) catch {};
    return true;
}

/// Makes stack entry `index` the current directory by rotating the stack.
fn rotate(ctx: Ctx, index: usize) u8 {
    if (index == 0) return print(ctx, .line, false);
    const gpa = ctx.sh.gpa;
    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(gpa);
    full.append(gpa, gpa.dupe(u8, ctx.sh.cwd) catch return 1) catch return 1;
    full.appendSlice(gpa, ctx.sh.dir_stack.items) catch return 1;

    const target = gpa.dupe(u8, full.items[index]) catch return 1;
    defer gpa.free(target);
    if (!changeTo(ctx, "pushd", target)) {
        gpa.free(full.items[0]);
        return 1;
    }
    // The new current directory leaves the stack; everything else rotates.
    gpa.free(full.items[index]);
    ctx.sh.dir_stack.clearRetainingCapacity();
    for (1..full.items.len) |offset| {
        const i = (index + offset) % full.items.len;
        ctx.sh.dir_stack.append(gpa, full.items[i]) catch return 1;
    }
    return print(ctx, .line, false);
}

pub fn pushd(ctx: Ctx) u8 {
    var no_cd = false;
    var operand: ?[]const u8 = null;
    for (ctx.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-n")) {
            no_cd = true;
        } else if (operand != null) {
            ctx.err("wsh: pushd: too many arguments\n");
            return 1;
        } else {
            operand = arg;
        }
    }

    const target = operand orelse {
        if (no_cd) {
            ctx.err("wsh: pushd: -n needs a directory operand\n");
            return 2;
        }
        if (ctx.sh.dir_stack.items.len == 0) {
            ctx.err("wsh: pushd: no other directory\n");
            return 1;
        }
        return rotate(ctx, 1);
    };

    if (Index.parse(target)) |index| {
        if (no_cd) {
            ctx.err("wsh: pushd: -n needs a directory operand\n");
            return 2;
        }
        if (ctx.sh.dir_stack.items.len == 0) {
            ctx.err("wsh: pushd: directory stack empty\n");
            return 1;
        }
        const at = index.resolve(stackLen(ctx)) orelse {
            ctx.errFmt("wsh: pushd: {s}: directory stack index out of range\n", .{index.text});
            return 1;
        };
        return rotate(ctx, at);
    }
    if (target.len > 1 and target[0] == '-') {
        ctx.errFmt("wsh: pushd: {s}: invalid option\n", .{target});
        ctx.err("wsh: pushd: usage: pushd [-n] [+N | -N | dir]\n");
        return 2;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const dir = ctx.sh.tildeExpand(arena_state.allocator(), target) catch target;
    const gpa = ctx.sh.gpa;
    if (no_cd) {
        const owned = gpa.dupe(u8, dir) catch return 1;
        ctx.sh.dir_stack.insert(gpa, 0, owned) catch {
            gpa.free(owned);
            return 1;
        };
        return print(ctx, .line, false);
    }
    const previous = gpa.dupe(u8, ctx.sh.cwd) catch return 1;
    if (!changeTo(ctx, "pushd", dir)) {
        gpa.free(previous);
        return 1;
    }
    ctx.sh.dir_stack.insert(gpa, 0, previous) catch {
        gpa.free(previous);
        return 1;
    };
    return print(ctx, .line, false);
}

pub fn popd(ctx: Ctx) u8 {
    var no_cd = false;
    var index: ?Index = null;
    for (ctx.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-n")) {
            no_cd = true;
        } else if (Index.parse(arg)) |parsed| {
            index = parsed;
        } else {
            ctx.errFmt("wsh: popd: {s}: invalid argument\n", .{arg});
            ctx.err("wsh: popd: usage: popd [-n] [+N | -N]\n");
            return 2;
        }
    }
    const stack = &ctx.sh.dir_stack;
    if (stack.items.len == 0) {
        ctx.err("wsh: popd: directory stack empty\n");
        return 1;
    }
    const at = if (index) |i| i.resolve(stackLen(ctx)) orelse {
        ctx.errFmt("wsh: popd: {s}: directory stack index out of range\n", .{i.text});
        return 1;
    } else 0;

    const gpa = ctx.sh.gpa;
    if (at == 0) {
        // Leave the current directory for the next entry, which then stops
        // being a stack entry of its own.
        if (!no_cd and !changeTo(ctx, "popd", stack.items[0])) return 1;
        gpa.free(stack.orderedRemove(0));
    } else {
        gpa.free(stack.orderedRemove(at - 1));
    }
    return print(ctx, .line, false);
}

pub fn dirs(ctx: Ctx) u8 {
    var style = Style.line;
    var long = false;
    var index: ?Index = null;
    for (ctx.argv[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-c")) {
            for (ctx.sh.dir_stack.items) |dir| ctx.sh.gpa.free(dir);
            ctx.sh.dir_stack.clearRetainingCapacity();
            return 0;
        } else if (std.mem.eql(u8, arg, "-l")) {
            long = true;
        } else if (std.mem.eql(u8, arg, "-p")) {
            if (style == .line) style = .per_line;
        } else if (std.mem.eql(u8, arg, "-v")) {
            style = .numbered;
        } else if (Index.parse(arg)) |parsed| {
            index = parsed;
        } else {
            ctx.errFmt("wsh: dirs: {s}: invalid number\n", .{arg});
            ctx.err("wsh: dirs: usage: dirs [-clpv] [+N] [-N]\n");
            return 2;
        }
    }
    if (index) |i| {
        const at = i.resolve(stackLen(ctx)) orelse {
            ctx.errFmt("wsh: dirs: {s}: directory stack index out of range\n", .{i.text[1..]});
            return 1;
        };
        var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
        defer arena_state.deinit();
        const path = entry(ctx, at);
        const shown = if (long) path else ctx.sh.shortenHome(arena_state.allocator(), path) catch path;
        if (style == .numbered) {
            ctx.outFmt("{d: >2}  {s}\n", .{ at, shown });
        } else {
            ctx.outFmt("{s}\n", .{shown});
        }
        return 0;
    }
    return print(ctx, style, long);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const shellmod = @import("../shell.zig");
const linux = std.os.linux;

fn capture(sh: *shellmod.Shell, run: *const fn (Ctx) u8, argv: []const []const u8, status: *u8) ![]u8 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    status.* = run(.{ .sh = sh, .argv = argv, .stdout = fds[1], .stderr = -1 });
    _ = linux.close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const rc = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        try out.appendSlice(testing.allocator, buf[0..rc]);
    }
    _ = linux.close(fds[0]);
    return out.toOwnedSlice(testing.allocator);
}

test "pushd rotates, popd removes by index and dirs formats the stack" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    const original = (try fs.getCwd(testing.allocator)) orelse return error.SkipZigTest;
    defer testing.allocator.free(original);
    const original_z = try testing.allocator.dupeZ(u8, original);
    defer testing.allocator.free(original_z);
    defer _ = fs.chdir(original_z);
    try sh.updateCwd();
    try sh.setEnv("HOME", "/nonexistent-home");
    var status: u8 = undefined;

    for ([_][]const u8{ "/", "/usr", "/tmp" }) |dir| {
        const out = try capture(&sh, pushd, &.{ "pushd", dir }, &status);
        testing.allocator.free(out);
        try testing.expectEqual(@as(u8, 0), status);
    }
    {
        const out = try capture(&sh, dirs, &.{ "dirs", "-v" }, &status);
        defer testing.allocator.free(out);
        const expected = try std.fmt.allocPrint(testing.allocator, " 0  /tmp\n 1  /usr\n 2  /\n 3  {s}\n", .{original});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, out);
    }
    {
        const out = try capture(&sh, pushd, &.{ "pushd", "+2" }, &status);
        defer testing.allocator.free(out);
        const expected = try std.fmt.allocPrint(testing.allocator, "/ {s} /tmp /usr\n", .{original});
        defer testing.allocator.free(expected);
        try testing.expectEqualStrings(expected, out);
        try testing.expectEqualStrings("/", sh.cwd);
    }
    {
        const out = try capture(&sh, popd, &.{ "popd", "+1" }, &status);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("/ /tmp /usr\n", out);
    }
    {
        const out = try capture(&sh, popd, &.{"popd"}, &status);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("/tmp /usr\n", out);
        try testing.expectEqualStrings("/tmp", sh.cwd);
    }
    {
        const out = try capture(&sh, dirs, &.{ "dirs", "-1" }, &status);
        defer testing.allocator.free(out);
        try testing.expectEqualStrings("/tmp\n", out);
    }
    try testing.expectEqual(@as(u8, 1), pushd(.{ .sh = &sh, .argv = &.{ "pushd", "+5" }, .stdout = -1, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), pushd(.{ .sh = &sh, .argv = &.{ "pushd", "/nonexistent-dir-xyz" }, .stdout = -1, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 2), dirs(.{ .sh = &sh, .argv = &.{ "dirs", "-x" }, .stdout = -1, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 0), dirs(.{ .sh = &sh, .argv = &.{ "dirs", "-c" } }));
    try testing.expectEqual(@as(u8, 1), popd(.{ .sh = &sh, .argv = &.{"popd"}, .stdout = -1, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), pushd(.{ .sh = &sh, .argv = &.{"pushd"}, .stdout = -1, .stderr = -1 }));
}
