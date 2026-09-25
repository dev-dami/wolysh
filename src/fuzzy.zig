//! Bounded command-name matching with a cheap character-signature filter.

const std = @import("std");

pub fn distance(query: []const u8, candidate: []const u8) ?u8 {
    const longest = @max(query.len, candidate.len);
    if (longest == 0 or longest > 255) return null;

    const limit: u8 = if (longest <= 4) 1 else 2;
    const max_distance: usize = limit;
    if (@max(query.len, candidate.len) - @min(query.len, candidate.len) > max_distance) return null;

    // Overlap is necessary within these edit bounds; collisions only add checks.
    if (query.len >= 2 and candidate.len >= 2 and
        bloomSignature(query) & bloomSignature(candidate) == 0) return null;

    return boundedDistance(query, candidate, limit);
}

fn bloomSignature(text: []const u8) u64 {
    var bits: u64 = 0;
    for (text) |byte| {
        const first: u6 = @truncate(byte);
        const second: u6 = @truncate(@as(u16, byte) * 17 + 7);
        bits |= (@as(u64, 1) << first) | (@as(u64, 1) << second);
    }
    return bits;
}

fn boundedDistance(query: []const u8, candidate: []const u8, limit: u8) ?u8 {
    const sentinel = limit + 1;
    var older: [256]u8 = undefined;
    var previous: [256]u8 = undefined;
    var current: [256]u8 = undefined;

    @memset(previous[0 .. candidate.len + 1], sentinel);
    const max_distance: usize = limit;
    for (0..@min(candidate.len, max_distance) + 1) |column| previous[column] = @intCast(column);

    for (query, 1..) |query_byte, row| {
        @memset(current[0 .. candidate.len + 1], sentinel);
        if (row <= max_distance) current[0] = @intCast(row);

        const first_column = if (row > max_distance) row - max_distance else 1;
        const last_column = @min(candidate.len, row + max_distance);
        if (first_column <= last_column) {
            for (first_column..last_column + 1) |column| {
                const substitution: u8 = if (query_byte == candidate[column - 1]) 0 else 1;
                var best = @min(previous[column] + 1, @min(current[column - 1] + 1, previous[column - 1] + substitution));

                if (row > 1 and column > 1 and
                    query_byte == candidate[column - 2] and query[row - 2] == candidate[column - 1])
                {
                    best = @min(best, older[column - 2] + 1);
                }
                current[column] = best;
            }
        }

        var row_min = current[0];
        for (current[1 .. candidate.len + 1]) |value| row_min = @min(row_min, value);
        if (row_min > limit) return null;

        older = previous;
        previous = current;
    }

    return if (previous[candidate.len] <= limit) previous[candidate.len] else null;
}

test "fuzzy distance handles substitutions, deletions, and transpositions" {
    try std.testing.expectEqual(@as(?u8, 1), distance("la", "ls"));
    try std.testing.expectEqual(@as(?u8, 1), distance("lh", "ls"));
    try std.testing.expectEqual(@as(?u8, 1), distance("gti", "git"));
    try std.testing.expectEqual(@as(?u8, 1), distance("pythn", "python"));
    try std.testing.expectEqual(@as(?u8, null), distance("zzzz", "ls"));
}

test "Bloom prefilter retains plausible short and long matches" {
    try std.testing.expectEqual(@as(?u8, 1), distance("x", "l"));
    try std.testing.expectEqual(@as(?u8, 1), distance("buld", "build"));
    try std.testing.expectEqual(@as(?u8, null), distance("abcd", "wxyz"));
}
