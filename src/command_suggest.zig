//! Ranked, bounded suggestions for command names that were not found.

const std = @import("std");
const linux = std.os.linux;
const shellmod = @import("shell.zig");
const builtins = @import("builtins.zig");
const fs = @import("fs.zig");
const fuzzy = @import("fuzzy.zig");
const command_cache = @import("command_cache.zig");

const Shell = shellmod.Shell;

pub const Match = command_cache.Match;

const max_matches = 3;

const Search = struct {
    arena: std.mem.Allocator,
    query: []const u8,
    matches: [max_matches]Match = undefined,
    len: usize = 0,

    fn consider(self: *Search, name: []const u8) !void {
        const score = fuzzy.distance(self.query, name) orelse return;
        try self.considerScored(name, score);
    }

    fn considerScored(self: *Search, name: []const u8, score: u8) !void {
        if (score == 0) return;

        var index: usize = 0;
        while (index < self.len) : (index += 1) {
            const existing = self.matches[index];
            if (std.mem.eql(u8, existing.name, name)) return;
            if (score < existing.distance or
                (score == existing.distance and std.mem.lessThan(u8, name, existing.name))) break;
        }
        if (index == max_matches) return;

        const next_len = @min(self.len + 1, max_matches);
        var move = next_len;
        while (move > index + 1) : (move -= 1) self.matches[move - 1] = self.matches[move - 2];
        self.matches[index] = .{ .name = try self.arena.dupe(u8, name), .distance = score };
        self.len = next_len;
    }
};

pub fn find(sh: *Shell, arena: std.mem.Allocator, query: []const u8) ![]const Match {
    if (query.len == 0 or query.len > 255) return &.{};

    var search = Search{ .arena = arena, .query = query };
    for (builtins.all()) |builtin| try search.consider(builtin.name);

    var functions = sh.funcs.keyIterator();
    while (functions.next()) |name| try search.consider(name.*);

    var aliases = sh.aliases.keyIterator();
    while (aliases.next()) |name| try search.consider(name.*);

    var dirs = std.mem.splitScalar(u8, sh.pathEnv(), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 > linux.PATH_MAX) continue;
        var dir_z: [linux.PATH_MAX]u8 = undefined;
        @memcpy(dir_z[0..dir.len], dir);
        dir_z[dir.len] = 0;
        var handle = fs.openDir(dir_z[0..dir.len :0]) orelse continue;
        {
            defer handle.close();
            while (handle.next()) |entry| {
                if (entry.kind != .file and entry.kind != .unknown and entry.kind != .symlink) continue;
                const score = fuzzy.distance(query, entry.name) orelse continue;

                const full_len = dir.len + 1 + entry.name.len;
                if (full_len + 1 > linux.PATH_MAX) continue;
                var full: [linux.PATH_MAX]u8 = undefined;
                @memcpy(full[0..dir.len], dir);
                full[dir.len] = '/';
                @memcpy(full[dir.len + 1 .. full_len], entry.name);
                full[full_len] = 0;
                if (!fs.isExecutable(full[0..full_len :0])) continue;
                try search.considerScored(entry.name, score);
            }
        }
    }

    return try arena.dupe(Match, search.matches[0..search.len]);
}

test "suggestions rank builtins and aliases" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.setAlias("wolysh_test_alias", "echo sample");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const matches = try find(&sh, arena_state.allocator(), "echp");
    try std.testing.expect(matches.len > 0);
    try std.testing.expectEqualStrings("echo", matches[0].name);

    const alias_matches = try find(&sh, arena_state.allocator(), "wolysh_test_aliaz");
    try std.testing.expect(alias_matches.len > 0);
    try std.testing.expectEqualStrings("wolysh_test_alias", alias_matches[0].name);
}
