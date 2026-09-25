//! Persistent, searchable command history.

const std = @import("std");
const fs = @import("fs.zig");

pub const History = struct {
    entries: std.ArrayList([]u8) = .empty,
    /// Most recent first? No: oldest first, like a shell history file.
    limit: usize = 5000,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        self.entries.deinit(allocator);
    }

    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const History, index: usize) []const u8 {
        return self.entries.items[index];
    }

    /// Appends a line, skipping blanks and immediate duplicates.
    pub fn add(self: *History, allocator: std.mem.Allocator, line: []const u8) !void {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.entries.items.len > 0) {
            const last = self.entries.items[self.entries.items.len - 1];
            if (std.mem.eql(u8, last, trimmed)) return;
        }
        try self.entries.append(allocator, try allocator.dupe(u8, trimmed));
        while (self.entries.items.len > self.limit) {
            allocator.free(self.entries.items[0]);
            _ = self.entries.orderedRemove(0);
        }
    }

    /// Loads a history file, oldest entry first. Unreadable files are ignored.
    pub fn load(self: *History, allocator: std.mem.Allocator, path: []const u8) !void {
        const z = try allocator.dupeZ(u8, path);
        defer allocator.free(z);
        const data = (try fs.readFileAlloc(allocator, z, 1 << 20)) orelse return;
        defer allocator.free(data);

        var lines = std.mem.splitScalar(u8, data, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            try self.add(allocator, line);
        }
    }

    /// Rewrites the history file, keeping only the newest `limit` entries.
    pub fn save(self: *History, allocator: std.mem.Allocator, path: []const u8) void {
        const z = allocator.dupeZ(u8, path) catch return;
        defer allocator.free(z);

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (self.entries.items) |entry| {
            out.appendSlice(allocator, entry) catch return;
            out.append(allocator, '\n') catch return;
        }
        _ = fs.writeFile(z, out.items);
    }

    /// Index of the newest entry at or before `before` that starts with
    /// `prefix`, or null. Used for prefix history search.
    pub fn searchBackward(self: *const History, before: usize, prefix: []const u8) ?usize {
        if (self.entries.items.len == 0) return null;
        var i = @min(before, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            if (prefix.len == 0 or std.mem.startsWith(u8, self.entries.items[i], prefix)) return i;
        }
        return null;
    }

    /// Index of the newest entry that *contains* `needle`.
    pub fn searchBackwardContains(self: *const History, before: usize, needle: []const u8) ?usize {
        if (self.entries.items.len == 0) return null;
        var i = @min(before, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            if (needle.len == 0 or std.mem.indexOf(u8, self.entries.items[i], needle) != null) return i;
        }
        return null;
    }
};

test "history add, dedupe and search" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);

    try h.add(a, "ls -la");
    try h.add(a, "ls -la"); // duplicate is ignored
    try h.add(a, "");
    try h.add(a, "git status");
    try std.testing.expectEqual(@as(usize, 2), h.count());

    try std.testing.expectEqual(@as(?usize, 1), h.searchBackward(h.count(), "git"));
    try std.testing.expectEqual(@as(?usize, 0), h.searchBackward(h.count(), "ls"));
    try std.testing.expectEqual(@as(?usize, null), h.searchBackward(h.count(), "cargo"));
}
