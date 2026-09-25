//! Bounded in-memory cache of failed command names and their suggestions.

const std = @import("std");

pub const Match = struct {
    name: []const u8,
    distance: u8,
};

pub const Entry = struct {
    command: []u8,
    matches: []Match,
    last_used: u64,
};

const max_entries = 64;
const max_matches = 3;
const max_command_len = 255;

pub const Cache = struct {
    entries: std.ArrayList(Entry) = .empty,
    clock: u64 = 0,

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| freeEntry(allocator, entry);
        self.entries.deinit(allocator);
    }

    pub fn lookup(self: *Cache, command: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (!std.mem.eql(u8, entry.command, command)) continue;
            entry.last_used = self.tick();
            return entry;
        }
        return null;
    }

    pub fn correction(self: *Cache, prefix: []const u8) ?[]const u8 {
        if (prefix.len == 0) return null;
        var newest: ?*Entry = null;
        for (self.entries.items) |*entry| {
            if (entry.matches.len == 0 or !std.mem.startsWith(u8, entry.command, prefix)) continue;
            if (newest == null or entry.last_used > newest.?.last_used) newest = entry;
        }
        const entry = newest orelse return null;
        entry.last_used = self.tick();
        return entry.matches[0].name;
    }

    pub fn remember(self: *Cache, allocator: std.mem.Allocator, command: []const u8, matches: []const Match) !void {
        if (command.len == 0 or command.len > max_command_len) return;

        var copied_matches: std.ArrayList(Match) = .empty;
        errdefer {
            for (copied_matches.items) |match| allocator.free(match.name);
            copied_matches.deinit(allocator);
        }
        for (matches[0..@min(matches.len, max_matches)]) |match| {
            try copied_matches.append(allocator, .{
                .name = try allocator.dupe(u8, match.name),
                .distance = match.distance,
            });
        }
        const owned_matches = try copied_matches.toOwnedSlice(allocator);
        errdefer {
            for (owned_matches) |match| allocator.free(match.name);
            allocator.free(owned_matches);
        }
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);

        const entry = Entry{
            .command = owned_command,
            .matches = owned_matches,
            .last_used = self.tick(),
        };

        for (self.entries.items, 0..) |existing, index| {
            if (!std.mem.eql(u8, existing.command, command)) continue;
            freeEntry(allocator, existing);
            self.entries.items[index] = entry;
            return;
        }

        if (self.entries.items.len < max_entries) {
            try self.entries.append(allocator, entry);
            return;
        }

        var oldest_index: usize = 0;
        for (self.entries.items[1..], 1..) |existing, index| {
            if (existing.last_used < self.entries.items[oldest_index].last_used) oldest_index = index;
        }
        freeEntry(allocator, self.entries.items[oldest_index]);
        self.entries.items[oldest_index] = entry;
    }

    fn tick(self: *Cache) u64 {
        self.clock +%= 1;
        return self.clock;
    }
};

fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    allocator.free(entry.command);
    for (entry.matches) |match| allocator.free(match.name);
    allocator.free(entry.matches);
}

test "cache stores, reuses, and prefixes corrections" {
    var cache = Cache{};
    defer cache.deinit(std.testing.allocator);

    const candidate = [_]Match{.{ .name = "git", .distance = 1 }};
    try cache.remember(std.testing.allocator, "gti", &candidate);
    try std.testing.expectEqualStrings("git", cache.lookup("gti").?.matches[0].name);
    try std.testing.expectEqualStrings("git", cache.correction("gt").?);

    try cache.remember(std.testing.allocator, "unknown", &.{});
    try std.testing.expectEqual(@as(usize, 0), cache.lookup("unknown").?.matches.len);
}

test "cache evicts the least recently used failure at its bound" {
    var cache = Cache{};
    defer cache.deinit(std.testing.allocator);

    for (0..max_entries) |index| {
        const command = try std.fmt.allocPrint(std.testing.allocator, "miss-{d}", .{index});
        defer std.testing.allocator.free(command);
        try cache.remember(std.testing.allocator, command, &.{});
    }

    _ = cache.lookup("miss-0");
    const next_command = try std.fmt.allocPrint(std.testing.allocator, "miss-{d}", .{max_entries});
    defer std.testing.allocator.free(next_command);
    try cache.remember(std.testing.allocator, next_command, &.{});

    try std.testing.expect(cache.lookup("miss-0") != null);
    try std.testing.expect(cache.lookup("miss-1") == null);
}
