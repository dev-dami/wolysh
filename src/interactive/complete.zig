//! Tab completion: commands, files, directories and variables.

const std = @import("std");
const linux = std.os.linux;
const shellmod = @import("../shell.zig");
const builtins = @import("../builtins.zig");
const fs = @import("../fs.zig");

const Shell = shellmod.Shell;

pub const Result = struct {
    /// Offset in the line where the replacement begins.
    start: usize,
    /// Complete replacement words, in the order they should be shown.
    items: []const []const u8,
};

const separators = " \t|&;<>()";

fn isSeparator(c: u8) bool {
    return std.mem.indexOfScalar(u8, separators, c) != null;
}

/// Start of the whitespace-delimited word containing `cursor`.
fn wordStart(line: []const u8, cursor: usize) usize {
    var i = cursor;
    while (i > 0) : (i -= 1) {
        if (isSeparator(line[i - 1])) return i;
    }
    return 0;
}

/// True when the word starting at `start` occupies a command position, which is
/// what decides between command-name and path completion.
fn isCommandPosition(line: []const u8, start: usize) bool {
    var i = start;
    while (i > 0) {
        i -= 1;
        const c = line[i];
        if (c == ' ' or c == '\t') continue;
        return c == '|' or c == ';' or c == '&' or c == '(';
    }
    return true;
}

pub fn complete(sh: *Shell, arena: std.mem.Allocator, line: []const u8, cursor: usize) !Result {
    const start = wordStart(line, cursor);
    const word = line[0..cursor][start..];

    var items: std.ArrayList([]const u8) = .empty;

    if (word.len > 0 and word[0] == '$') {
        try completeVariables(sh, arena, word[1..], &items);
        sortItems(items.items);
        return .{ .start = start, .items = try items.toOwnedSlice(arena) };
    }

    if (isCommandPosition(line, start)) {
        try completeCommands(sh, arena, word, &items);
    }
    try completePaths(sh, arena, word, &items);

    sortItems(items.items);
    return .{ .start = start, .items = try items.toOwnedSlice(arena) };
}

fn sortItems(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

/// Escapes a path so it can be typed back into a command line.
fn quote(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            ' ', '\t', '"', '\'', '$', '*', '?', '[', ']', '\\', '(', ')', '{', '}',
            '&', '|', ';', '<', '>', '#', '!', '~', '`',
            => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            else => try out.append(arena, c),
        }
    }
    return out.toOwnedSlice(arena);
}

/// True when the word already opens a quote, in which case escaping would
/// corrupt it and the plain text is used instead.
fn alreadyQuoted(base: []const u8) bool {
    return base.len > 0 and (base[0] == '"' or base[0] == '\'');
}

fn completeVariables(sh: *Shell, arena: std.mem.Allocator, prefix: []const u8, items: *std.ArrayList([]const u8)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(sh.gpa);
    try sh.varNames(&names);
    try sh.envNames(&names);

    var seen: std.StringHashMap(void) = .init(sh.gpa);
    defer seen.deinit();

    for (names.items) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        if (seen.contains(name)) continue;
        try seen.put(name, {});
        try items.append(arena, try std.fmt.allocPrint(arena, "${s} ", .{name}));
    }
}

fn completeCommands(sh: *Shell, arena: std.mem.Allocator, prefix: []const u8, items: *std.ArrayList([]const u8)) !void {
    var seen: std.StringHashMap(void) = .init(sh.gpa);
    defer seen.deinit();

    for (builtins.all()) |b| {
        if (!std.mem.startsWith(u8, b.name, prefix)) continue;
        try seen.put(b.name, {});
        try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{b.name}));
    }

    var func_it = sh.funcs.keyIterator();
    while (func_it.next()) |name| {
        if (!std.mem.startsWith(u8, name.*, prefix)) continue;
        if (seen.contains(name.*)) continue;
        try seen.put(name.*, {});
        try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{name.*}));
    }

    var alias_it = sh.aliases.keyIterator();
    while (alias_it.next()) |name| {
        if (!std.mem.startsWith(u8, name.*, prefix)) continue;
        if (seen.contains(name.*)) continue;
        try seen.put(name.*, {});
        try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{name.*}));
    }

    if (prefix.len == 0) return;

    // Executables on PATH.
    var dirs = std.mem.splitScalar(u8, sh.pathEnv(), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 > linux.PATH_MAX) continue;
        var buf: [linux.PATH_MAX]u8 = undefined;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = 0;
        var handle = fs.openDir(buf[0..dir.len :0]) orelse continue;
        defer handle.close();

        while (handle.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (entry.kind != .file and entry.kind != .unknown) continue;
            if (seen.contains(entry.name)) continue;
            const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, entry.name });
            const z = try arena.dupeZ(u8, full);
            if (!fs.isExecutable(z)) continue;
            try seen.put(entry.name, {});
            try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{entry.name}));
        }
    }
}

fn completePaths(sh: *Shell, arena: std.mem.Allocator, word: []const u8, items: *std.ArrayList([]const u8)) !void {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |s| word[0 .. s + 1] else "";
    const base = if (slash) |s| word[s + 1 ..] else word;

    const expanded_dir = if (dir_part.len == 0)
        try arena.dupe(u8, ".")
    else
        try sh.tildeExpand(arena, dir_part);
    if (expanded_dir.len + 1 > linux.PATH_MAX) return;

    var buf: [linux.PATH_MAX]u8 = undefined;
    @memcpy(buf[0..expanded_dir.len], expanded_dir);
    buf[expanded_dir.len] = 0;

    var handle = fs.openDir(buf[0..expanded_dir.len :0]) orelse return;
    defer handle.close();

    const allow_hidden = base.len > 0 and base[0] == '.';
    const quoted = alreadyQuoted(base);

    while (handle.next()) |entry| {
        if (!allow_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (!std.mem.startsWith(u8, entry.name, base)) continue;

        const is_dir = entry.kind == .dir;
        const name = if (quoted) try arena.dupe(u8, entry.name) else try quote(arena, entry.name);
        const suffix: []const u8 = if (is_dir) "/" else " ";
        try items.append(arena, try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ dir_part, name, suffix }));
    }
}

/// Longest prefix shared by every candidate. The editor inserts this before
/// deciding whether the completion is unambiguous.
pub fn commonPrefix(items: []const []const u8) usize {
    if (items.len == 0) return 0;
    var len = items[0].len;
    for (items[1..]) |item| {
        var i: usize = 0;
        const limit = @min(len, item.len);
        while (i < limit and items[0][i] == item[i]) i += 1;
        len = i;
        if (len == 0) break;
    }
    return len;
}

test "completion finds files and commands" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A command position completes against PATH, so `echo` must appear.
    const commands = try complete(&sh, arena, "ech", 3);
    var found_echo = false;
    for (commands.items) |item| {
        if (std.mem.startsWith(u8, item, "echo")) found_echo = true;
    }
    try std.testing.expect(found_echo);

    // A path position completes against the filesystem.
    const paths = try complete(&sh, arena, "src/lex", 7);
    try std.testing.expect(paths.items.len >= 1);
    try std.testing.expectEqualStrings("src/lexer.zig ", paths.items[0]);
}

test "completion of variables" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.setVar("greeting", .{ .string = "hi" });

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const res = try complete(&sh, arena_state.allocator(), "echo $gree", 10);
    try std.testing.expectEqualStrings("$greeting ", res.items[0]);
}

test "common prefix" {
    const items = [_][]const u8{ "src/main.zig", "src/main_test.zig" };
    try std.testing.expectEqual(@as(usize, 9), commonPrefix(&items));
}

test "word boundaries and command detection" {
    try std.testing.expectEqual(@as(usize, 4), wordStart("ls -la", 6));
    try std.testing.expect(isCommandPosition("ls -la", 0));
    try std.testing.expect(!isCommandPosition("ls -la", 3));
    try std.testing.expect(isCommandPosition("ls | gr", 5));
}
