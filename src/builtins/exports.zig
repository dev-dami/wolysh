//! `export`, `readonly` and the reusable listings they and `alias -p` print.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const printf = @import("printf.zig");

const Ctx = builtins.Ctx;
const Allocator = std.mem.Allocator;

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn sortedKeys(arena: Allocator, iterator: anytype) Allocator.Error![][]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = iterator;
    while (it.next()) |key| try names.append(arena, key.*);
    std.mem.sort([]const u8, names.items, {}, lessThan);
    return names.items;
}

/// Quotes a value the way `declare -p` does: double quotes with `"`, `\`,
/// `$` and backquote escaped, or `$'...'` when it holds control characters.
fn writeDeclareValue(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    if (printf.needsAnsiQuote(text)) return printf.ansiQuote(arena, out, text);
    try out.append(arena, '"');
    for (text) |c| {
        if (c == '"' or c == '\\' or c == '$' or c == '`') try out.append(arena, '\\');
        try out.append(arena, c);
    }
    try out.append(arena, '"');
}

/// Text of a shell variable or, failing that, an environment entry.
fn valueOf(ctx: Ctx, arena: Allocator, name: []const u8) Allocator.Error!?[]const u8 {
    if (ctx.sh.getVar(name)) |v| {
        return switch (v) {
            .string => |s| s,
            else => v.renderAlloc(arena) catch return error.OutOfMemory,
        };
    }
    return ctx.sh.getEnv(name);
}

fn writeDeclare(arena: Allocator, out: *std.ArrayList(u8), flags: []const u8, name: []const u8, text: ?[]const u8) Allocator.Error!void {
    try out.print(arena, "declare {s} {s}", .{ flags, name });
    if (text) |t| {
        try out.append(arena, '=');
        try writeDeclareValue(arena, out, t);
    }
    try out.append(arena, '\n');
}

fn listExports(ctx: Ctx) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const names = sortedKeys(arena, ctx.sh.env.keyIterator()) catch return 1;
    for (names) |name| {
        const flags = if (ctx.sh.isReadonly(name)) "-rx" else "-x";
        writeDeclare(arena, &out, flags, name, ctx.sh.getEnv(name)) catch return 1;
    }
    ctx.out(out.items);
    return 0;
}

fn listReadonly(ctx: Ctx) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const names = sortedKeys(arena, ctx.sh.readonly.keyIterator()) catch return 1;
    for (names) |name| {
        const flags = if (ctx.sh.getEnv(name) != null) "-rx" else "-r";
        const text = valueOf(ctx, arena, name) catch return 1;
        writeDeclare(arena, &out, flags, name, text) catch return 1;
    }
    ctx.out(out.items);
    return 0;
}

/// `alias -p`: every alias as a reusable `alias name='value'` line.
pub fn listAliases(ctx: Ctx) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(u8) = .empty;
    const names = sortedKeys(arena, ctx.sh.aliases.keyIterator()) catch return 1;
    for (names) |name| writeAlias(arena, &out, name, ctx.sh.getAlias(name).?) catch return 1;
    ctx.out(out.items);
    return 0;
}

/// `alias name='value'`, with embedded single quotes written as `'\''`.
pub fn writeAlias(arena: Allocator, out: *std.ArrayList(u8), name: []const u8, text: []const u8) Allocator.Error!void {
    try out.print(arena, "alias {s}='", .{name});
    for (text) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.appendSlice(arena, "'\n");
}

const Mode = struct {
    list: bool = false,
    remove: bool = false,
};

/// Parses `-p`, `-n` and `--`; reports anything else. Returns null after an
/// error.
fn parseMode(ctx: Ctx, parser: *options.Parser, usage: []const u8) ?Mode {
    var mode = Mode{};
    while (true) {
        switch (parser.next()) {
            .end => return mode,
            .invalid, .missing => |c| {
                if (c == 'f') {
                    ctx.errFmt("wsh: {s}: -f: function attributes are not supported\n", .{ctx.argv[0]});
                } else {
                    ctx.errFmt("wsh: {s}: -{c}: invalid option\n", .{ ctx.argv[0], c });
                }
                ctx.err(usage);
                return null;
            },
            .option => |c| switch (c) {
                'p' => mode.list = true,
                'n' => mode.remove = true,
                else => unreachable,
            },
        }
    }
}

pub fn exportBuiltin(ctx: Ctx) u8 {
    var parser = options.Parser.init(ctx.argv, "pn");
    const mode = parseMode(ctx, &parser, "wsh: export: usage: export [-n] [name[=value] ...] or export -p\n") orelse return 2;
    const specs = parser.rest();
    if (specs.len == 0) return if (mode.remove) 0 else listExports(ctx);

    var status: u8 = 0;
    for (specs) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, '=');
        const name = if (at) |i| spec[0..i] else spec;
        if (!builtins.validName(name)) {
            ctx.errFmt("wsh: export: `{s}': not a valid identifier\n", .{spec});
            status = 1;
            continue;
        }
        if (ctx.sh.isReadonly(name) and (at != null or mode.remove)) {
            ctx.errFmt("wsh: export: {s}: readonly variable\n", .{name});
            status = 1;
            continue;
        }
        if (mode.remove) {
            // `export -n` keeps the value as a plain shell variable.
            if (at) |i| {
                ctx.sh.setVar(name, .{ .string = spec[i + 1 ..] }) catch return 1;
            } else if (ctx.sh.getVar(name) == null) {
                if (ctx.sh.getEnv(name)) |text| ctx.sh.setVar(name, .{ .string = text }) catch return 1;
            }
            _ = ctx.sh.unsetEnv(name);
            continue;
        }
        if (at) |i| {
            ctx.sh.setEnv(name, spec[i + 1 ..]) catch return 1;
        } else if (ctx.sh.getVar(name)) |v| {
            // `export NAME` promotes an existing variable.
            const text = v.renderAlloc(ctx.sh.gpa) catch return 1;
            defer ctx.sh.gpa.free(text);
            ctx.sh.setEnv(name, text) catch return 1;
        }
    }
    return status;
}

pub fn readonlyBuiltin(ctx: Ctx) u8 {
    var parser = options.Parser.init(ctx.argv, "p");
    _ = parseMode(ctx, &parser, "wsh: readonly: usage: readonly [name[=value] ...] or readonly -p\n") orelse return 2;
    const specs = parser.rest();
    if (specs.len == 0) return listReadonly(ctx);

    var status: u8 = 0;
    for (specs) |spec| {
        const at = std.mem.indexOfScalar(u8, spec, '=');
        const name = if (at) |i| spec[0..i] else spec;
        if (!builtins.validName(name)) {
            ctx.errFmt("wsh: readonly: `{s}': not a valid identifier\n", .{spec});
            status = 1;
            continue;
        }
        if (at) |i| {
            if (ctx.sh.isReadonly(name)) {
                ctx.errFmt("wsh: readonly: {s}: readonly variable\n", .{name});
                status = 1;
                continue;
            }
            ctx.sh.setVar(name, .{ .string = spec[i + 1 ..] }) catch return 1;
        }
        ctx.sh.markReadonly(name) catch return 1;
    }
    return status;
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const shellmod = @import("../shell.zig");
const linux = std.os.linux;

fn capture(sh: *shellmod.Shell, run: *const fn (Ctx) u8, argv: []const []const u8) ![]u8 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    _ = run(.{ .sh = sh, .argv = argv, .stdout = fds[1], .stderr = -1 });
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

test "export -p and -n" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setEnv("B", "x\"y$z`w\\v");
    try sh.setEnv("A", "a\nb");

    const listing = try capture(&sh, exportBuiltin, &.{ "export", "-p" });
    defer testing.allocator.free(listing);
    try testing.expectEqualStrings("declare -x A=$'a\\nb'\ndeclare -x B=\"x\\\"y\\$z\\`w\\\\v\"\n", listing);

    try testing.expectEqual(@as(u8, 0), exportBuiltin(.{ .sh = &sh, .argv = &.{ "export", "-n", "B" } }));
    try testing.expect(sh.getEnv("B") == null);
    try testing.expectEqualStrings("x\"y$z`w\\v", sh.getVar("B").?.string);
    try testing.expectEqual(@as(u8, 2), exportBuiltin(.{ .sh = &sh, .argv = &.{ "export", "-f", "fn" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), exportBuiltin(.{ .sh = &sh, .argv = &.{ "export", "1x=2" }, .stderr = -1 }));
}

test "readonly -p and alias listings" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    try testing.expectEqual(@as(u8, 0), readonlyBuiltin(.{ .sh = &sh, .argv = &.{ "readonly", "R1=1", "R2" } }));
    try testing.expectEqual(@as(u8, 0), readonlyBuiltin(.{ .sh = &sh, .argv = &.{ "readonly", "R1" } }));
    try testing.expectEqual(@as(u8, 1), readonlyBuiltin(.{ .sh = &sh, .argv = &.{ "readonly", "R1=2" }, .stderr = -1 }));
    const listing = try capture(&sh, readonlyBuiltin, &.{ "readonly", "-p" });
    defer testing.allocator.free(listing);
    try testing.expectEqualStrings("declare -r R1=\"1\"\ndeclare -r R2\n", listing);

    try sh.setAlias("b", "ls");
    try sh.setAlias("a", "echo it's");
    const aliases = try capture(&sh, listAliases, &.{ "alias", "-p" });
    defer testing.allocator.free(aliases);
    try testing.expectEqualStrings("alias a='echo it'\\''s'\nalias b='ls'\n", aliases);
}
