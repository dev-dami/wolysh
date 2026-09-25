//! Glob matching for wolysh.
//!
//! Patterns are matched against directory entries, so `*.rs` never needs the
//! directory to be read twice for a plain `*`. Matching is escape-aware: the
//! expander backslash-escapes every metacharacter that came from a quoted
//! context, which is how `"$dir"/*.rs` globs while `"$dir/*.rs"` does not.

const std = @import("std");
const fs = @import("fs.zig");

const max_segments = 64;

fn isMeta(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '*', '?', '[' => return true,
            else => {},
        }
    }
    return false;
}

/// True if the pattern needs globbing at all.
pub fn hasMeta(s: []const u8) bool {
    return isMeta(s);
}

const BracketResult = struct { matched: bool, next: usize };

fn matchBracket(pat: []const u8, start: usize, ch: u8) ?BracketResult {
    var i = start + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) {
            return .{ .matched = matched != negate, .next = i + 1 };
        }
        first = false;
        var lo = pat[i];
        if (lo == '\\' and i + 1 < pat.len) {
            i += 1;
            lo = pat[i];
        }
        if (i + 2 < pat.len and pat[i + 1] == '-' and pat[i + 2] != ']') {
            const hi = pat[i + 2];
            if (ch >= lo and ch <= hi) matched = true;
            i += 3;
            continue;
        }
        if (ch == lo) matched = true;
        i += 1;
    }
    return null;
}

fn matchFrom(pat: []const u8, pi_in: usize, name: []const u8, ni_in: usize) bool {
    var pi = pi_in;
    var ni = ni_in;
    while (pi < pat.len) {
        switch (pat[pi]) {
            '*' => {
                var p = pi + 1;
                while (p < pat.len and pat[p] == '*') p += 1;
                if (p == pat.len) {
                    // A trailing star consumes the rest, but never a separator.
                    return std.mem.indexOfScalar(u8, name[ni..], '/') == null;
                }
                var k = ni;
                while (k <= name.len) : (k += 1) {
                    if (k > ni and name[k - 1] == '/') break;
                    if (matchFrom(pat, p, name, k)) return true;
                }
                return false;
            },
            '?' => {
                if (ni >= name.len or name[ni] == '/') return false;
                pi += 1;
                ni += 1;
            },
            '[' => {
                const res = matchBracket(pat, pi, if (ni < name.len) name[ni] else 0);
                if (res) |r| {
                    if (!r.matched) return false;
                    pi = r.next;
                    ni += 1;
                } else {
                    if (ni >= name.len or name[ni] != '[') return false;
                    pi += 1;
                    ni += 1;
                }
            },
            '\\' => {
                if (pi + 1 < pat.len) {
                    if (ni >= name.len or name[ni] != pat[pi + 1]) return false;
                    pi += 2;
                    ni += 1;
                } else {
                    if (ni >= name.len or name[ni] != '\\') return false;
                    pi += 1;
                    ni += 1;
                }
            },
            else => {
                if (ni >= name.len or name[ni] != pat[pi]) return false;
                pi += 1;
                ni += 1;
            },
        }
    }
    return ni == name.len;
}

/// Escape-aware wildcard match of a single path segment.
pub fn matchSegment(pat: []const u8, name: []const u8) bool {
    return matchFrom(pat, 0, name, 0);
}

/// Removes backslash escapes, allocating the result in `allocator`.
pub fn unescape(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
        }
        try out.append(allocator, s[i]);
    }
    return out.toOwnedSlice(allocator);
}

fn joinPath(allocator: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (base.len == 0) return allocator.dupe(u8, name);
    if (base.len == 1 and base[0] == '/') return std.fmt.allocPrint(allocator, "/{s}", .{name});
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, name });
}

const Ctx = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    found: bool = false,
};

fn walk(ctx: *Ctx, base: []const u8, segs: []const []const u8, si: usize) !void {
    const seg = segs[si];
    const last = si + 1 == segs.len;

    // Fast path: a literal segment needs no directory listing.
    if (!isMeta(seg)) {
        const name = try unescape(ctx.arena, seg);
        const full = try joinPath(ctx.arena, base, name);
        const z = try ctx.arena.dupeZ(u8, full);
        if (last) {
            if (fs.exists(z)) {
                try ctx.out.append(ctx.arena, full);
                ctx.found = true;
            }
        } else if (fs.isDir(z)) {
            try walk(ctx, full, segs, si + 1);
        }
        return;
    }

    const dir_path = if (base.len == 0) "." else base;
    const dir_z = try ctx.arena.dupeZ(u8, dir_path);
    var dir = fs.openDir(dir_z) orelse return;
    defer dir.close();

    const allow_hidden = seg.len > 0 and seg[0] == '.';
    while (dir.next()) |entry| {
        if (!allow_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (!matchSegment(seg, entry.name)) continue;
        const full = try joinPath(ctx.arena, base, entry.name);
        if (last) {
            try ctx.out.append(ctx.arena, full);
            ctx.found = true;
        } else {
            const is_dir = entry.kind == .dir or
                (entry.kind == .unknown and fs.isDir(try ctx.arena.dupeZ(u8, full)));
            if (is_dir) try walk(ctx, full, segs, si + 1);
        }
    }
}

/// Expands `pattern`, appending matches to `out`. Returns true when at least
/// one path matched; when nothing matches the caller keeps the literal word,
/// which is what bash does.
pub fn glob(arena: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) !bool {
    if (!isMeta(pattern)) return false;

    const start_index = out.items.len;

    var absolute = false;
    var rest = pattern;
    if (rest.len > 0 and rest[0] == '/') {
        absolute = true;
        rest = rest[1..];
    }
    if (rest.len == 0) return false;

    var segs: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (segs.items.len == max_segments) return false;
        try segs.append(arena, seg);
    }
    if (segs.items.len == 0) return false;

    var ctx = Ctx{ .arena = arena, .out = out };
    try walk(&ctx, if (absolute) "/" else "", segs.items, 0);

    if (!ctx.found) {
        out.items.len = start_index;
        return false;
    }
    std.mem.sort([]const u8, out.items[start_index..], {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return true;
}

test "segment matching" {
    try std.testing.expect(matchSegment("*.rs", "main.rs"));
    try std.testing.expect(!matchSegment("*.rs", "main.zig"));
    try std.testing.expect(matchSegment("ma?n.rs", "main.rs"));
    try std.testing.expect(matchSegment("[abc]*", "beta"));
    try std.testing.expect(!matchSegment("[!abc]*", "beta"));
    try std.testing.expect(matchSegment("[a-c]x", "bx"));
    try std.testing.expect(matchSegment("\\*", "*"));
    try std.testing.expect(!matchSegment("\\*", "x"));
    try std.testing.expect(matchSegment("*", "anything"));
    try std.testing.expect(matchSegment("src/*", "src/lib.zig"));
    try std.testing.expect(!matchSegment("src/*", "src/sub/lib.zig"));
}

test "glob against the source directory" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList([]const u8) = .empty;
    const found = try glob(arena, "src/*.zig", &out);
    try std.testing.expect(found);
    var saw_lexer = false;
    for (out.items) |p| {
        if (std.mem.eql(u8, p, "src/lexer.zig")) saw_lexer = true;
    }
    try std.testing.expect(saw_lexer);
}
