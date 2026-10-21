//! Fuzzy matching: bounded command-name edit distance with a cheap
//! character-signature filter, and an fzf-style subsequence scorer for
//! picking the best lines of a large text.

const std = @import("std");
const Allocator = std.mem.Allocator;

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

// --- subsequence scoring ----------------------------------------------------
//
// The scoring scheme is fzf's: every matched character earns `score_match`,
// gaps cost `score_gap_start` then `score_gap_extension` per character, and a
// character earns a bonus for starting a word (after whitespace, a delimiter
// or punctuation, or a lower-to-upper or letter-to-digit change). A run of
// consecutive matches keeps the bonus its first character earned, so matching
// a whole word at a boundary beats picking letters out of the middle of
// several words. The first pattern character's bonus counts double.

const score_match: i32 = 16;
const score_gap_start: i32 = -3;
const score_gap_extension: i32 = -1;
const bonus_boundary: i32 = score_match / 2;
const bonus_non_word: i32 = score_match / 2;
const bonus_camel123: i32 = bonus_boundary + score_gap_extension;
const bonus_consecutive: i32 = -(score_gap_start + score_gap_extension);
const bonus_first_char_multiplier: i32 = 2;
const bonus_boundary_white: i32 = bonus_boundary + 2;
const bonus_boundary_delimiter: i32 = bonus_boundary + 1;

/// Ordered as in fzf: everything after `non_word` counts as part of a word.
const CharClass = enum(u3) { white, non_word, delimiter, lower, upper, letter, number };

const char_classes: [256]CharClass = blk: {
    var table: [256]CharClass = undefined;
    for (&table, 0..) |*class, byte| {
        class.* = switch (byte) {
            'a'...'z' => .lower,
            'A'...'Z' => .upper,
            '0'...'9' => .number,
            ' ', '\t', '\n', '\r', 0x0b, 0x0c => .white,
            '/', ',', ':', ';', '|' => .delimiter,
            // UTF-8 lead and continuation bytes: part of a word.
            0x80...0xff => .letter,
            else => .non_word,
        };
    }
    break :blk table;
};

fn bonusFor(prev: CharClass, class: CharClass) i32 {
    if (@intFromEnum(class) > @intFromEnum(CharClass.non_word)) {
        switch (prev) {
            .white => return bonus_boundary_white,
            .delimiter => return bonus_boundary_delimiter,
            .non_word => return bonus_boundary,
            else => {},
        }
    }
    if ((prev == .lower and class == .upper) or (prev != .number and class == .number)) return bonus_camel123;
    return switch (class) {
        .non_word, .delimiter => bonus_non_word,
        .white => bonus_boundary_white,
        else => 0,
    };
}

inline fn fold(byte: u8, case_sensitive: bool) u8 {
    return if (case_sensitive) byte else std.ascii.toLower(byte);
}

/// Index of the first byte at or after `from` that equals `wanted`, ignoring
/// ASCII case when `wanted` is a lowercase letter. Sixteen bytes at a time.
pub fn indexOfFolded(text: []const u8, from: usize, wanted: u8) ?usize {
    if (!std.ascii.isLower(wanted)) return std.mem.indexOfScalarPos(u8, text, from, wanted);
    // Setting bit 5 maps only `A`-`Z` onto `a`-`z` among the bytes that can
    // then equal a lowercase letter.
    const V = @Vector(16, u8);
    var i = from;
    while (i + 16 <= text.len) : (i += 16) {
        const v: V = text[i..][0..16].*;
        const hits: u16 = @bitCast((v | @as(V, @splat(0x20))) == @as(V, @splat(wanted)));
        if (hits != 0) return i + @ctz(hits);
    }
    while (i < text.len) : (i += 1) {
        if (text[i] | 0x20 == wanted) return i;
    }
    return null;
}

/// True when `query` has an ASCII uppercase letter, which makes a smart-case
/// search case-sensitive.
pub fn hasUpper(query: []const u8) bool {
    for (query) |byte| {
        if (std.ascii.isUpper(byte)) return true;
    }
    return false;
}

/// Above this many matrix cells (pattern length times the matched window)
/// scoring falls back to a greedy linear pass, as fzf does.
const max_cells = 64 * 1024;

/// Scores patterns against text, reusing its matrices so that scoring every
/// line of a large file allocates only when a line needs a bigger matrix than
/// any before it.
pub const Matcher = struct {
    allocator: Allocator,
    score: std.ArrayList(i32) = .empty,
    run: std.ArrayList(u16) = .empty,
    bonus: std.ArrayList(i32) = .empty,
    first: std.ArrayList(usize) = .empty,

    pub fn init(allocator: Allocator) Matcher {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Matcher) void {
        self.score.deinit(self.allocator);
        self.run.deinit(self.allocator);
        self.bonus.deinit(self.allocator);
        self.first.deinit(self.allocator);
    }

    /// The best score of `pattern` as a subsequence of `text`, or null when
    /// it is not one. Without `case_sensitive`, `pattern` must already be
    /// lowercase and ASCII letters in `text` match either case. When
    /// `positions` is given, the byte index in `text` of every matched
    /// pattern character is appended to it in increasing order.
    pub fn match(
        self: *Matcher,
        text: []const u8,
        pattern: []const u8,
        case_sensitive: bool,
        positions: ?*std.ArrayList(u32),
    ) Allocator.Error!?i32 {
        const m = pattern.len;
        if (m == 0) return 0;
        if (m > text.len) return null;

        // Phase 1: the earliest position of each pattern character, which
        // also proves the pattern is a subsequence at all.
        try self.first.resize(self.allocator, m);
        const first = self.first.items;
        var at: usize = 0;
        for (pattern, 0..) |wanted, index| {
            at = (if (case_sensitive) std.mem.indexOfScalarPos(u8, text, at, wanted) else indexOfFolded(text, at, wanted)) orelse return null;
            first[index] = at;
            at += 1;
        }
        // The window ends at the last occurrence of the final character.
        var last = text.len - 1;
        while (fold(text[last], case_sensitive) != pattern[m - 1]) last -= 1;

        const start = first[0];
        const width = last - start + 1;
        if (m * width > max_cells) return try self.greedy(text, pattern, case_sensitive, positions);
        return try self.optimal(text, pattern, case_sensitive, start, width, positions);
    }

    /// fzf's "v2" algorithm: a Smith-Waterman style matrix over the window
    /// `text[start..][0..width]`, then a backtrace for the positions.
    fn optimal(
        self: *Matcher,
        text: []const u8,
        pattern: []const u8,
        case_sensitive: bool,
        start: usize,
        width: usize,
        positions: ?*std.ArrayList(u32),
    ) Allocator.Error!i32 {
        const m = pattern.len;
        const cells = m * width;
        try self.score.resize(self.allocator, cells);
        try self.run.resize(self.allocator, cells);
        try self.bonus.resize(self.allocator, width);
        const h = self.score.items;
        const c = self.run.items;
        const b = self.bonus.items;
        @memset(h, 0);
        @memset(c, 0);
        const first = self.first.items;

        // Row 0, and the per-column bonus.
        var max_score: i32 = 0;
        var max_pos: usize = start;
        var prev_class: CharClass = if (start == 0) .white else char_classes[text[start - 1]];
        var prev_h: i32 = 0;
        var in_gap = false;
        for (0..width) |off| {
            const byte = text[start + off];
            const class = char_classes[byte];
            b[off] = bonusFor(prev_class, class);
            prev_class = class;
            if (fold(byte, case_sensitive) == pattern[0]) {
                const s = score_match + b[off] * bonus_first_char_multiplier;
                h[off] = s;
                c[off] = 1;
                if (m == 1 and s > max_score) {
                    max_score = s;
                    max_pos = start + off;
                }
                in_gap = false;
            } else {
                h[off] = @max(prev_h + (if (in_gap) score_gap_extension else score_gap_start), 0);
                in_gap = true;
            }
            prev_h = h[off];
        }

        // The remaining rows. A cell is the best score of the pattern so far
        // with its last character at or before this column.
        var row_index: usize = 1;
        while (row_index < m) : (row_index += 1) {
            const row = row_index * width;
            const from = first[row_index] - start;
            in_gap = false;
            h[row + from - 1] = 0;
            for (from..width) |off| {
                const s2 = h[row + off - 1] + (if (in_gap) score_gap_extension else score_gap_start);
                var s1: i32 = 0;
                var consecutive: u16 = 0;
                if (fold(text[start + off], case_sensitive) == pattern[row_index]) {
                    s1 = h[row - width + off - 1] + score_match;
                    var bonus = b[off];
                    consecutive = c[row - width + off - 1] + 1;
                    if (consecutive > 1) {
                        const run_bonus = b[off + 1 - consecutive];
                        // A stronger boundary starts a new run instead.
                        if (bonus >= bonus_boundary and bonus > run_bonus) {
                            consecutive = 1;
                        } else {
                            bonus = @max(bonus, @max(bonus_consecutive, run_bonus));
                        }
                    }
                    if (s1 + bonus < s2) {
                        s1 += b[off];
                        consecutive = 0;
                    } else {
                        s1 += bonus;
                    }
                }
                c[row + off] = consecutive;
                in_gap = s1 < s2;
                const s = @max(@max(s1, s2), 0);
                if (row_index == m - 1 and s > max_score) {
                    max_score = s;
                    max_pos = start + off;
                }
                h[row + off] = s;
            }
        }

        if (positions) |out| {
            const base = out.items.len;
            var i = m - 1;
            var j = max_pos;
            var prefer_match = true;
            while (true) {
                const row = i * width;
                const col = j - start;
                const s = h[row + col];
                const diagonal = if (i > 0 and j >= first[i]) h[row - width + col - 1] else 0;
                const left = if (j > first[i]) h[row + col - 1] else 0;
                if (s > diagonal and (s > left or (s == left and prefer_match))) {
                    try out.append(self.allocator, @intCast(j));
                    if (i == 0) break;
                    i -= 1;
                }
                prefer_match = c[row + col] > 1 or (row + width + col + 1 < cells and c[row + width + col + 1] > 0);
                j -= 1;
            }
            std.mem.reverse(u32, out.items[base..]);
        }
        return max_score;
    }

    /// fzf's "v1" algorithm for windows too large for the matrix: the
    /// earliest end of a greedy forward match, the latest start that still
    /// reaches it, then one scoring pass over that span.
    fn greedy(
        self: *Matcher,
        text: []const u8,
        pattern: []const u8,
        case_sensitive: bool,
        positions: ?*std.ArrayList(u32),
    ) Allocator.Error!i32 {
        const end = self.first.items[pattern.len - 1];
        var begin = end;
        var index = pattern.len;
        while (true) {
            if (fold(text[begin], case_sensitive) == pattern[index - 1]) {
                index -= 1;
                if (index == 0) break;
            }
            begin -= 1;
        }

        var score: i32 = 0;
        var pattern_index: usize = 0;
        var in_gap = false;
        var consecutive: usize = 0;
        var first_bonus: i32 = 0;
        var prev_class: CharClass = if (begin == 0) .white else char_classes[text[begin - 1]];
        for (begin..end + 1) |at| {
            const class = char_classes[text[at]];
            if (pattern_index < pattern.len and fold(text[at], case_sensitive) == pattern[pattern_index]) {
                if (positions) |out| try out.append(self.allocator, @intCast(at));
                score += score_match;
                var bonus = bonusFor(prev_class, class);
                if (consecutive == 0) {
                    first_bonus = bonus;
                } else {
                    if (bonus >= bonus_boundary and bonus > first_bonus) first_bonus = bonus;
                    bonus = @max(bonus, @max(first_bonus, bonus_consecutive));
                }
                score += if (pattern_index == 0) bonus * bonus_first_char_multiplier else bonus;
                in_gap = false;
                consecutive += 1;
                pattern_index += 1;
            } else {
                score += if (in_gap) score_gap_extension else score_gap_start;
                in_gap = true;
                consecutive = 0;
                first_bonus = 0;
            }
            prev_class = class;
        }
        return score;
    }
};

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

fn expectPositions(pattern: []const u8, text: []const u8, case_sensitive: bool, want: []const u32) !void {
    var matcher = Matcher.init(std.testing.allocator);
    defer matcher.deinit();
    var positions: std.ArrayList(u32) = .empty;
    defer positions.deinit(std.testing.allocator);
    _ = (try matcher.match(text, pattern, case_sensitive, &positions)) orelse return error.TestExpectedMatch;
    try std.testing.expectEqualSlices(u32, want, positions.items);
}

fn scoreOf(pattern: []const u8, text: []const u8) !?i32 {
    var matcher = Matcher.init(std.testing.allocator);
    defer matcher.deinit();
    return matcher.match(text, pattern, false, null);
}

test "subsequence scoring prefers consecutive characters at word starts" {
    // A whole word after a space beats letters spread over three words.
    try expectPositions("abc", "a_b_c abc", false, &.{ 6, 7, 8 });
    // CamelCase humps count as word starts.
    try expectPositions("fb", "xfooBar", false, &.{ 1, 4 });
    try expectPositions("rs", "src/parser.rs", false, &.{ 11, 12 });
    try std.testing.expect((try scoreOf("conn", "connection refused")).? > (try scoreOf("conn", "recon nection")).?);
    try std.testing.expect((try scoreOf("err", "error: x")).? > (try scoreOf("err", "the terror")).?);
    try std.testing.expectEqual(@as(?i32, null), try scoreOf("xyz", "x y"));
    try std.testing.expectEqual(@as(?i32, 0), try scoreOf("", "anything"));
}

test "matching ignores case only when asked" {
    try expectPositions("fb", "FooBar", false, &.{ 0, 3 });
    var matcher = Matcher.init(std.testing.allocator);
    defer matcher.deinit();
    try std.testing.expectEqual(@as(?i32, null), try matcher.match("FooBar", "fb", true, null));
    try std.testing.expect(hasUpper("Foo"));
    try std.testing.expect(!hasUpper("foo 42"));
    try std.testing.expectEqual(@as(?usize, 3), indexOfFolded("xyzFOOBAR", 0, 'f'));
    try std.testing.expectEqual(@as(?usize, 20), indexOfFolded("." ** 20 ++ "Q", 2, 'q'));
    try std.testing.expectEqual(@as(?usize, null), indexOfFolded("@@@", 0, '`'));
}

test "very long lines fall back to a linear match" {
    const text = "a" ++ "x" ** 40_000 ++ "b";
    try expectPositions("ab", text, false, &.{ 0, 40_001 });
}
