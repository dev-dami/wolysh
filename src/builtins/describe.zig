//! Command lookup builtins: `type`, `command` and `hash`.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const proc = @import("../proc.zig");

const Ctx = builtins.Ctx;
const Allocator = std.mem.Allocator;

/// Reserved words of the language, including the POSIX ones.
pub const keywords = [_][]const u8{
    "let",    "if",     "else", "for",  "while", "fn",       "return", "alias", "env",
    "break",  "continue", "then", "elif", "fi",    "do",       "done",   "case",  "esac",
    "until",  "function", "select", "time", "in",  "[[",       "]]",     "{",     "}",
    "!",
};

/// Builtins the executor handles itself rather than through the table.
const executor_builtins = [_][]const u8{ "source", ".", "eval" };

/// `command -p` searches this instead of `PATH` (glibc's `_CS_PATH`).
const standard_path = "/bin:/usr/bin";

pub fn isKeyword(name: []const u8) bool {
    for (keywords) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return false;
}

pub fn isBuiltinName(name: []const u8) bool {
    for (executor_builtins) |word| {
        if (std.mem.eql(u8, word, name)) return true;
    }
    return builtins.lookup(name) != null;
}

const Kind = enum {
    alias,
    keyword,
    builtin,
    function,
    file,
};

const Match = struct {
    kind: Kind,
    /// The alias text, function source or file path.
    detail: []const u8 = "",
};

const Lookup = struct {
    /// Report every match instead of the first.
    all: bool = false,
    functions: bool = true,
    /// Only search `PATH`.
    path_only: bool = false,
    path: ?[]const u8 = null,
};

/// Every way `name` resolves, in the order the shell tries them: aliases and
/// keywords first, then builtins, functions and `PATH`.
fn resolve(ctx: Ctx, arena: Allocator, name: []const u8, how: Lookup) Allocator.Error![]const Match {
    var matches: std.ArrayList(Match) = .empty;
    if (!how.path_only) {
        if (ctx.sh.getAlias(name)) |text| try matches.append(arena, .{ .kind = .alias, .detail = text });
        if (isKeyword(name)) try matches.append(arena, .{ .kind = .keyword });
        if (isBuiltinName(name)) try matches.append(arena, .{ .kind = .builtin });
        if (how.functions) {
            if (ctx.sh.getFunc(name)) |source| try matches.append(arena, .{ .kind = .function, .detail = source });
        }
        if (matches.items.len != 0 and !how.all) return matches.items;
    }

    const path_env = how.path orelse ctx.sh.pathEnv();
    if (std.mem.indexOfScalar(u8, name, '/') != null) {
        if (proc.resolve(arena, name, path_env) catch null) |path| try matches.append(arena, .{ .kind = .file, .detail = path });
        return matches.items;
    }
    var dirs = std.mem.splitScalar(u8, path_env, ':');
    while (dirs.next()) |dir| {
        // Execution skips empty PATH entries too (see `proc.resolve`).
        if (dir.len == 0) continue;
        const candidate = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        if (proc.resolve(arena, candidate, "") catch null) |path| {
            try matches.append(arena, .{ .kind = .file, .detail = path });
            if (!how.all) break;
        }
    }
    return matches.items;
}

fn writeAliasDefinition(ctx: Ctx, name: []const u8, text: []const u8) void {
    ctx.outFmt("alias {s}='", .{name});
    var rest = text;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |at| {
        ctx.out(rest[0..at]);
        ctx.out("'\\''");
        rest = rest[at + 1 ..];
    }
    ctx.out(rest);
    ctx.out("'\n");
}

fn writeVerbose(ctx: Ctx, name: []const u8, match: Match) void {
    switch (match.kind) {
        .alias => ctx.outFmt("{s} is aliased to `{s}'\n", .{ name, match.detail }),
        .keyword => ctx.outFmt("{s} is a shell keyword\n", .{name}),
        .builtin => ctx.outFmt("{s} is a shell builtin\n", .{name}),
        .function => {
            ctx.outFmt("{s} is a function\n", .{name});
            ctx.out(match.detail);
            if (match.detail.len == 0 or match.detail[match.detail.len - 1] != '\n') ctx.out("\n");
        },
        .file => ctx.outFmt("{s} is {s}\n", .{ name, match.detail }),
    }
}

// --- type --------------------------------------------------------------------

pub fn typeBuiltin(ctx: Ctx) u8 {
    var how = Lookup{};
    var terse = false;
    var path_if_file = false;
    var parser = options.Parser.init(ctx.argv, "afptP");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: type: -{c}: invalid option\n", .{c});
                ctx.err("wsh: type: usage: type [-afptP] name [name ...]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'a' => how.all = true,
                'f' => how.functions = false,
                'p' => path_if_file = true,
                't' => terse = true,
                'P' => how.path_only = true,
                else => unreachable,
            },
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var status: u8 = 0;
    for (parser.rest()) |name| {
        const matches = resolve(ctx, arena, name, how) catch return 1;
        if (matches.len == 0) {
            if (!terse and !path_if_file and !how.path_only) ctx.errFmt("wsh: type: {s}: not found\n", .{name});
            status = 1;
            continue;
        }
        for (matches) |match| {
            if (how.path_only or path_if_file) {
                // `-p` prints a path only when the name would run a file.
                if (match.kind == .file) ctx.outFmt("{s}\n", .{match.detail});
                if (!how.all) break;
                continue;
            }
            if (terse) {
                ctx.outFmt("{s}\n", .{@tagName(match.kind)});
            } else {
                writeVerbose(ctx, name, match);
            }
        }
    }
    return status;
}

// --- command -----------------------------------------------------------------

pub fn commandBuiltin(ctx: Ctx) u8 {
    var use_standard_path = false;
    var terse = false;
    var verbose = false;
    var parser = options.Parser.init(ctx.argv, "pvV");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: command: -{c}: invalid option\n", .{c});
                ctx.err("wsh: command: usage: command [-pVv] command [arg ...]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'p' => use_standard_path = true,
                'v' => terse = true,
                'V' => verbose = true,
                else => unreachable,
            },
        }
    }
    const operands = parser.rest();
    if (operands.len == 0) return 0;
    const path: ?[]const u8 = if (use_standard_path) standard_path else null;

    if (terse or verbose) {
        var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var found = false;
        for (operands) |name| {
            const matches = resolve(ctx, arena, name, .{ .path = path }) catch return 1;
            if (matches.len == 0) {
                if (verbose) ctx.errFmt("wsh: command: {s}: not found\n", .{name});
                continue;
            }
            found = true;
            const match = matches[0];
            if (verbose) {
                writeVerbose(ctx, name, match);
            } else switch (match.kind) {
                .alias => writeAliasDefinition(ctx, name, match.detail),
                .file => ctx.outFmt("{s}\n", .{match.detail}),
                else => ctx.outFmt("{s}\n", .{name}),
            }
        }
        return if (found) 0 else 1;
    }

    if (builtins.lookup(operands[0])) |b| {
        var inner = ctx;
        inner.argv = operands;
        return b.run(inner);
    }
    return builtins.runExternal(ctx, operands, path orelse ctx.sh.pathEnv());
}

// --- hash --------------------------------------------------------------------

const hash_usage = "wsh: hash: usage: hash [-lr] [-p pathname] [-dt] [name ...]\n";

/// wsh keeps no table of command locations: every command searches `PATH`
/// when it runs. `hash` therefore validates names and reports where they
/// resolve, `-r` has nothing to forget, and `-p` (which would pin a name to a
/// path) is refused instead of being silently ignored.
pub fn hashBuiltin(ctx: Ctx) u8 {
    var report = false;
    var forget = false;
    var parser = options.Parser.init(ctx.argv, "dlp:rt");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid => |c| {
                ctx.errFmt("wsh: hash: -{c}: invalid option\n", .{c});
                ctx.err(hash_usage);
                return 2;
            },
            .missing => |c| {
                ctx.errFmt("wsh: hash: -{c}: option requires an argument\n", .{c});
                ctx.err(hash_usage);
                return 2;
            },
            .option => |c| switch (c) {
                'd' => forget = true,
                'l', 'r' => {},
                'p' => {
                    ctx.err("wsh: hash: -p: wsh does not cache command paths; every command is looked up in PATH when it runs\n");
                    return 1;
                },
                't' => report = true,
                else => unreachable,
            },
        }
    }
    const names = parser.rest();
    if (names.len == 0) {
        if (report or forget) {
            ctx.errFmt("wsh: hash: -{c}: option requires an argument\n", .{@as(u8, if (report) 't' else 'd')});
            return 1;
        }
        ctx.out("hash: hash table empty\n");
        return 0;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var status: u8 = 0;
    for (names) |name| {
        if (forget) {
            // Nothing is ever remembered, so there is nothing to forget.
            ctx.errFmt("wsh: hash: {s}: not found\n", .{name});
            status = 1;
            continue;
        }
        if (!report and std.mem.indexOfScalar(u8, name, '/') == null and (isBuiltinName(name) or ctx.sh.getFunc(name) != null)) continue;
        const path = (proc.resolve(arena, name, ctx.sh.pathEnv()) catch null) orelse {
            ctx.errFmt("wsh: hash: {s}: not found\n", .{name});
            status = 1;
            continue;
        };
        if (!report) continue;
        if (names.len > 1) {
            ctx.outFmt("{s}\t{s}\n", .{ name, path });
        } else {
            ctx.outFmt("{s}\n", .{path});
        }
    }
    return status;
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

test "type classifies aliases, keywords, functions, builtins and files" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setAlias("ll", "echo listed");
    try sh.defineFunc("greet", "fn greet() {\n}\n");
    try sh.setEnv("PATH", "/usr/bin:/bin");
    var status: u8 = undefined;

    const verbose = try capture(&sh, typeBuiltin, &.{ "type", "echo", "ll", "greet", "if", "sh" }, &status);
    defer testing.allocator.free(verbose);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expect(std.mem.indexOf(u8, verbose, "echo is a shell builtin\n") != null);
    try testing.expect(std.mem.indexOf(u8, verbose, "ll is aliased to `echo listed'\n") != null);
    try testing.expect(std.mem.indexOf(u8, verbose, "greet is a function\nfn greet() {\n}\n") != null);
    try testing.expect(std.mem.indexOf(u8, verbose, "if is a shell keyword\n") != null);
    try testing.expect(std.mem.indexOf(u8, verbose, "sh is /") != null);

    const terse = try capture(&sh, typeBuiltin, &.{ "type", "-t", "ll", "if", "greet", "cd", "sh", "nope-xyz" }, &status);
    defer testing.allocator.free(terse);
    try testing.expectEqual(@as(u8, 1), status);
    try testing.expectEqualStrings("alias\nkeyword\nfunction\nbuiltin\nfile\n", terse);

    const path = try capture(&sh, typeBuiltin, &.{ "type", "-p", "echo" }, &status);
    defer testing.allocator.free(path);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expectEqualStrings("", path);
}

test "command -v, -V and -p" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setAlias("ll", "ls -l 'x'");
    try sh.setEnv("PATH", "/nonexistent");
    var status: u8 = undefined;

    const terse = try capture(&sh, commandBuiltin, &.{ "command", "-v", "ll", "echo", "nope-xyz" }, &status);
    defer testing.allocator.free(terse);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expectEqualStrings("alias ll='ls -l '\\''x'\\'''\necho\n", terse);

    const standard = try capture(&sh, commandBuiltin, &.{ "command", "-pv", "sh" }, &status);
    defer testing.allocator.free(standard);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expectEqualStrings("/bin/sh\n", standard);

    const missing = try capture(&sh, commandBuiltin, &.{ "command", "-V", "nope-xyz" }, &status);
    defer testing.allocator.free(missing);
    try testing.expectEqual(@as(u8, 1), status);

    // `command` runs builtins directly and externals through PATH.
    const ran = try capture(&sh, commandBuiltin, &.{ "command", "echo", "hi" }, &status);
    defer testing.allocator.free(ran);
    try testing.expectEqualStrings("hi\n", ran);
    try testing.expectEqual(@as(u8, 5), commandBuiltin(.{ .sh = &sh, .argv = &.{ "command", "-p", "sh", "-c", "exit 5" } }));
}

test "hash validates names without caching" {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setEnv("PATH", "/usr/bin:/bin");
    var status: u8 = undefined;

    const listing = try capture(&sh, hashBuiltin, &.{"hash"}, &status);
    defer testing.allocator.free(listing);
    try testing.expectEqualStrings("hash: hash table empty\n", listing);

    const where = try capture(&sh, hashBuiltin, &.{ "hash", "-t", "sh" }, &status);
    defer testing.allocator.free(where);
    try testing.expectEqual(@as(u8, 0), status);
    try testing.expect(std.mem.endsWith(u8, where, "/sh\n"));

    try testing.expectEqual(@as(u8, 0), hashBuiltin(.{ .sh = &sh, .argv = &.{ "hash", "-r", "sh", "echo" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), hashBuiltin(.{ .sh = &sh, .argv = &.{ "hash", "nope-xyz" }, .stderr = -1 }));
    try testing.expectEqual(@as(u8, 1), hashBuiltin(.{ .sh = &sh, .argv = &.{ "hash", "-p", "/bin/sh", "x" }, .stderr = -1 }));
}
