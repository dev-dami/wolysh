//! Glob matching for wolysh.
//!
//! Patterns are matched against directory entries, so `*.rs` never needs the
//! directory to be read twice for a plain `*`. Matching is escape-aware: the
//! expander backslash-escapes every metacharacter that came from a quoted
//! context, which is how `"$dir"/*.rs` globs while `"$dir/*.rs"` does not.
//!
//! The matcher understands `*`, `?`, bracket expressions (ranges, `[!...]`,
//! `[^...]` and POSIX classes such as `[[:alpha:]]`) and, when enabled, the
//! extended forms `?( )`, `*( )`, `+( )`, `@( )` and `!( )`. Filename generation
//! adds `**` (globstar), dotglob and case-insensitive matching on top.

const std = @import("std");
const linux = std.os.linux;
const fs = @import("fs.zig");

const max_segments = 64;

/// Pattern-matching switches. The defaults are what `case`, `[[ ]]` and
/// `${var#pattern}` use: case-sensitive, extended patterns on.
pub const MatchOptions = struct {
    nocase: bool = false,
    extglob: bool = true,
};

/// Filename-generation switches, mirroring the `shopt` glob options.
pub const Options = struct {
    dotglob: bool = false,
    nocase: bool = false,
    globstar: bool = true,
    extglob: bool = true,

    fn matching(self: Options) MatchOptions {
        return .{ .nocase = self.nocase, .extglob = self.extglob };
    }
};

fn isExtOpener(c: u8) bool {
    return c == '?' or c == '*' or c == '+' or c == '@' or c == '!';
}

/// True if the pattern needs globbing at all, with extended patterns on.
pub fn hasMeta(s: []const u8) bool {
    return hasMetaOpts(s, true);
}

/// True if the pattern has a live metacharacter. A `[` counts only when a `]`
/// follows it, so `[` (the test command) and `[ab` stay plain words.
pub fn hasMetaOpts(s: []const u8, extglob: bool) bool {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '\\' => i += 1,
            '*', '?' => return true,
            '[' => if (std.mem.indexOfScalarPos(u8, s, i + 1, ']') != null) return true,
            '+', '@', '!' => if (extglob and i + 1 < s.len and s[i + 1] == '(') return true,
            else => {},
        }
    }
    return false;
}

fn charEq(a: u8, b: u8, nocase: bool) bool {
    if (a == b) return true;
    return nocase and std.ascii.toLower(a) == std.ascii.toLower(b);
}

fn inRange(c: u8, lo: u8, hi: u8, nocase: bool) bool {
    if (c >= lo and c <= hi) return true;
    if (!nocase) return false;
    const l = std.ascii.toLower(c);
    const u = std.ascii.toUpper(c);
    return (l >= lo and l <= hi) or (u >= lo and u <= hi);
}

/// A POSIX character class, or null when the name is not one.
fn classMatches(name: []const u8, c: u8, nocase: bool) ?bool {
    const eql = std.mem.eql;
    if (eql(u8, name, "alpha")) return std.ascii.isAlphabetic(c);
    if (eql(u8, name, "digit")) return std.ascii.isDigit(c);
    if (eql(u8, name, "alnum")) return std.ascii.isAlphanumeric(c);
    if (eql(u8, name, "upper")) return std.ascii.isUpper(c) or (nocase and std.ascii.isLower(c));
    if (eql(u8, name, "lower")) return std.ascii.isLower(c) or (nocase and std.ascii.isUpper(c));
    if (eql(u8, name, "space")) return std.ascii.isWhitespace(c);
    if (eql(u8, name, "blank")) return c == ' ' or c == '\t';
    if (eql(u8, name, "punct")) return std.ascii.isPunctuation(c);
    if (eql(u8, name, "print")) return std.ascii.isPrint(c);
    if (eql(u8, name, "graph")) return std.ascii.isGraphical(c);
    if (eql(u8, name, "cntrl")) return std.ascii.isControl(c);
    if (eql(u8, name, "xdigit")) return std.ascii.isHex(c);
    if (eql(u8, name, "word")) return std.ascii.isAlphanumeric(c) or c == '_';
    return null;
}

const BracketChar = struct { c: u8, next: usize };

fn bracketChar(pat: []const u8, i: usize) BracketChar {
    if (pat[i] == '\\' and i + 1 < pat.len) return .{ .c = pat[i + 1], .next = i + 2 };
    return .{ .c = pat[i], .next = i + 1 };
}

const BracketResult = struct { matched: bool, next: usize };

/// Matches `ch` against the bracket expression opening at `start`. Returns null
/// when the bracket is unterminated, in which case `[` is an ordinary character.
fn matchBracket(pat: []const u8, start: usize, ch: u8, nocase: bool) ?BracketResult {
    var i = start + 1;
    var negate = false;
    if (i < pat.len and (pat[i] == '!' or pat[i] == '^')) {
        negate = true;
        i += 1;
    }
    var matched = false;
    // An unknown class (`[[:bogus:]]`) makes the whole expression match nothing.
    var valid = true;
    var first = true;
    while (i < pat.len) {
        if (pat[i] == ']' and !first) {
            return .{ .matched = valid and (matched != negate), .next = i + 1 };
        }
        first = false;
        if (pat[i] == '[' and i + 1 < pat.len and (pat[i + 1] == ':' or pat[i + 1] == '=' or pat[i + 1] == '.')) {
            const kind = pat[i + 1];
            if (std.mem.indexOfPos(u8, pat, i + 2, &.{ kind, ']' })) |end| {
                const body = pat[i + 2 .. end];
                if (kind == ':') {
                    if (classMatches(body, ch, nocase)) |hit| {
                        if (hit) matched = true;
                    } else valid = false;
                } else if (body.len == 1) {
                    // `[=c=]` and `[.c.]`: the C locale has single-character
                    // equivalence classes and collating elements only.
                    if (charEq(ch, body[0], nocase)) matched = true;
                } else valid = false;
                i = end + 2;
                continue;
            }
        }
        const lo = bracketChar(pat, i);
        if (lo.next + 1 < pat.len and pat[lo.next] == '-' and pat[lo.next + 1] != ']') {
            const hi = bracketChar(pat, lo.next + 1);
            if (inRange(ch, lo.c, hi.c, nocase)) matched = true;
            i = hi.next;
            continue;
        }
        if (charEq(ch, lo.c, nocase)) matched = true;
        i = lo.next;
    }
    return null;
}

/// The `)` closing the extended-pattern group whose `(` is at `open`.
fn groupEnd(pat: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < pat.len) : (i += 1) {
        switch (pat[i]) {
            '\\' => i += 1,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// True when `text` matches one of the `|`-separated alternatives in `body`.
fn matchAlternatives(body: []const u8, text: []const u8, opts: MatchOptions) bool {
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < body.len) : (i += 1) {
        switch (body[i]) {
            '\\' => i += 1,
            '(' => depth += 1,
            ')' => depth -|= 1,
            '|' => if (depth == 0) {
                if (matchFrom(body[start..i], 0, text, 0, opts)) return true;
                start = i + 1;
            },
            else => {},
        }
    }
    return matchFrom(body[start..], 0, text, 0, opts);
}

/// Zero or more repetitions of the group, then the rest of the pattern.
fn matchRepeat(body: []const u8, pat: []const u8, after: usize, name: []const u8, ni: usize, opts: MatchOptions) bool {
    if (matchFrom(pat, after, name, ni, opts)) return true;
    // Each repetition must consume input, or `*(a|)` would recurse forever.
    var k = ni + 1;
    while (k <= name.len) : (k += 1) {
        if (matchAlternatives(body, name[ni..k], opts) and matchRepeat(body, pat, after, name, k, opts)) return true;
    }
    return false;
}

fn matchGroup(kind: u8, body: []const u8, pat: []const u8, after: usize, name: []const u8, ni: usize, opts: MatchOptions) bool {
    switch (kind) {
        '@', '?' => {
            if (kind == '?' and matchFrom(pat, after, name, ni, opts)) return true;
            var k = ni;
            while (k <= name.len) : (k += 1) {
                if (matchAlternatives(body, name[ni..k], opts) and matchFrom(pat, after, name, k, opts)) return true;
            }
            return false;
        },
        '*' => return matchRepeat(body, pat, after, name, ni, opts),
        '+' => {
            var k = ni;
            while (k <= name.len) : (k += 1) {
                if (matchAlternatives(body, name[ni..k], opts) and matchRepeat(body, pat, after, name, k, opts)) return true;
            }
            return false;
        },
        '!' => {
            var k = ni;
            while (k <= name.len) : (k += 1) {
                if (!matchAlternatives(body, name[ni..k], opts) and matchFrom(pat, after, name, k, opts)) return true;
            }
            return false;
        },
        else => unreachable,
    }
}

fn matchFrom(pat: []const u8, pi_in: usize, name: []const u8, ni_in: usize, opts: MatchOptions) bool {
    var pi = pi_in;
    var ni = ni_in;
    while (pi < pat.len) {
        const c = pat[pi];
        if (opts.extglob and isExtOpener(c) and pi + 1 < pat.len and pat[pi + 1] == '(') {
            if (groupEnd(pat, pi + 1)) |close| {
                return matchGroup(c, pat[pi + 2 .. close], pat, close + 1, name, ni, opts);
            }
        }
        switch (c) {
            '*' => {
                var p = pi + 1;
                while (p < pat.len and pat[p] == '*' and
                    !(opts.extglob and p + 1 < pat.len and pat[p + 1] == '(')) p += 1;
                if (p == pat.len) return true;
                var k = ni;
                while (k <= name.len) : (k += 1) {
                    if (matchFrom(pat, p, name, k, opts)) return true;
                }
                return false;
            },
            '?' => {
                if (ni >= name.len) return false;
                pi += 1;
                ni += 1;
            },
            '[' => {
                if (matchBracket(pat, pi, if (ni < name.len) name[ni] else 0, opts.nocase)) |r| {
                    if (ni >= name.len or !r.matched) return false;
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
                    if (ni >= name.len or !charEq(name[ni], pat[pi + 1], opts.nocase)) return false;
                    pi += 2;
                    ni += 1;
                } else {
                    if (ni >= name.len or name[ni] != '\\') return false;
                    pi += 1;
                    ni += 1;
                }
            },
            else => {
                if (ni >= name.len or !charEq(name[ni], c, opts.nocase)) return false;
                pi += 1;
                ni += 1;
            },
        }
    }
    return ni == name.len;
}

/// Escape-aware match of a whole string against a pattern, with extended
/// patterns on. `*` and `?` match `/` too, as in `case` and `[[ ]]`.
pub fn matchSegment(pat: []const u8, name: []const u8) bool {
    return matchFrom(pat, 0, name, 0, .{});
}

/// `matchSegment` with explicit switches (`nocasematch`, `extglob`).
pub fn matchSegmentWith(pat: []const u8, name: []const u8, opts: MatchOptions) bool {
    return matchFrom(pat, 0, name, 0, opts);
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

const WalkError = std.mem.Allocator.Error;

/// A directory that is not a symlink; `**` never recurses through links.
fn isRealDir(arena: std.mem.Allocator, full: []const u8, kind: fs.Kind) WalkError!bool {
    if (kind == .dir) return true;
    if (kind != .unknown) return false;
    const z = try arena.dupeZ(u8, full);
    var st: linux.Statx = undefined;
    const rc = linux.statx(linux.AT.FDCWD, z.ptr, linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true }, &st);
    if (linux.errno(rc) != .SUCCESS) return false;
    return st.mode & linux.S.IFMT == linux.S.IFDIR;
}

/// A directory, following symlinks.
fn isDirFollow(arena: std.mem.Allocator, full: []const u8, kind: fs.Kind) WalkError!bool {
    if (kind == .dir) return true;
    if (kind != .unknown and kind != .symlink) return false;
    return fs.isDir(try arena.dupeZ(u8, full));
}

const Ctx = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList([]const u8),
    opts: Options,
    /// The pattern ended in `/`: only directories match, printed with it.
    dir_only: bool,
};

const Listed = struct { name: []const u8, kind: fs.Kind };

/// Reads a directory up front so recursion never holds more than one
/// descriptor open.
fn listDir(ctx: *Ctx, base: []const u8) WalkError![]Listed {
    const dir_z = try ctx.arena.dupeZ(u8, if (base.len == 0) "." else base);
    var dir = fs.openDir(dir_z) orelse return &.{};
    defer dir.close();
    var entries: std.ArrayList(Listed) = .empty;
    while (dir.next()) |entry| {
        try entries.append(ctx.arena, .{ .name = try ctx.arena.dupe(u8, entry.name), .kind = entry.kind });
    }
    return entries.items;
}

fn hiddenAllowed(ctx: *const Ctx, seg: []const u8, name: []const u8) bool {
    if (name.len == 0 or name[0] != '.') return true;
    return ctx.opts.dotglob or (seg.len > 0 and seg[0] == '.');
}

fn emit(ctx: *Ctx, full: []const u8, kind: fs.Kind) WalkError!void {
    if (!ctx.dir_only) return ctx.out.append(ctx.arena, full);
    if (!try isDirFollow(ctx.arena, full, kind)) return;
    try ctx.out.append(ctx.arena, try std.fmt.allocPrint(ctx.arena, "{s}/", .{full}));
}

fn walk(ctx: *Ctx, base: []const u8, segs: []const []const u8, si: usize) WalkError!void {
    const seg = segs[si];
    const last = si + 1 == segs.len;

    if (ctx.opts.globstar and std.mem.eql(u8, seg, "**")) return walkGlobstar(ctx, base, segs, si);

    // Fast path: a literal segment needs no directory listing.
    if (!hasMetaOpts(seg, ctx.opts.extglob)) {
        const name = try unescape(ctx.arena, seg);
        const full = try joinPath(ctx.arena, base, name);
        const z = try ctx.arena.dupeZ(u8, full);
        if (last) {
            if (fs.exists(z)) try emit(ctx, full, .unknown);
        } else if (fs.isDir(z)) {
            try walk(ctx, full, segs, si + 1);
        }
        return;
    }

    for (try listDir(ctx, base)) |entry| {
        if (!hiddenAllowed(ctx, seg, entry.name)) continue;
        if (!matchFrom(seg, 0, entry.name, 0, ctx.opts.matching())) continue;
        const full = try joinPath(ctx.arena, base, entry.name);
        if (last) {
            try emit(ctx, full, entry.kind);
        } else if (try isDirFollow(ctx.arena, full, entry.kind)) {
            try walk(ctx, full, segs, si + 1);
        }
    }
}

/// `**`: zero or more directories. As the last segment it lists everything
/// beneath `base`, which itself counts as the zero-directory match.
fn walkGlobstar(ctx: *Ctx, base: []const u8, segs: []const []const u8, si: usize) WalkError!void {
    if (si + 1 == segs.len) {
        if (base.len != 0) {
            const self_match = if (base.len == 1 and base[0] == '/') base else try std.fmt.allocPrint(ctx.arena, "{s}/", .{base});
            try ctx.out.append(ctx.arena, self_match);
        }
        return listTree(ctx, base);
    }
    try walk(ctx, base, segs, si + 1);
    try descend(ctx, base, segs, si);
}

fn descend(ctx: *Ctx, base: []const u8, segs: []const []const u8, si: usize) WalkError!void {
    for (try listDir(ctx, base)) |entry| {
        if (!hiddenAllowed(ctx, "", entry.name)) continue;
        const full = try joinPath(ctx.arena, base, entry.name);
        if (!try isRealDir(ctx.arena, full, entry.kind)) continue;
        try walk(ctx, full, segs, si + 1);
        try descend(ctx, full, segs, si);
    }
}

fn listTree(ctx: *Ctx, base: []const u8) WalkError!void {
    for (try listDir(ctx, base)) |entry| {
        if (!hiddenAllowed(ctx, "", entry.name)) continue;
        const full = try joinPath(ctx.arena, base, entry.name);
        try emit(ctx, full, entry.kind);
        if (try isRealDir(ctx.arena, full, entry.kind)) try listTree(ctx, full);
    }
}

/// Splits on `/`, except inside an extended-pattern group.
fn splitSegments(arena: std.mem.Allocator, rest: []const u8, extglob: bool, segs: *std.ArrayList([]const u8)) WalkError!bool {
    var depth: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const c = rest[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (extglob and c == '(' and (depth > 0 or (i > 0 and isExtOpener(rest[i - 1])))) {
            depth += 1;
        } else if (c == ')' and depth > 0) {
            depth -= 1;
        } else if (c == '/' and depth == 0) {
            if (!try appendSegment(arena, segs, rest[start..i])) return false;
            start = i + 1;
        }
    }
    return appendSegment(arena, segs, rest[start..]);
}

fn appendSegment(arena: std.mem.Allocator, segs: *std.ArrayList([]const u8), seg: []const u8) WalkError!bool {
    if (seg.len == 0) return true;
    if (segs.items.len == max_segments) return false;
    try segs.append(arena, seg);
    return true;
}

/// Expands `pattern` with the default options. See `globWith`.
pub fn glob(arena: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8)) !bool {
    return globWith(arena, pattern, out, .{});
}

/// Expands `pattern`, appending matches to `out` in byte order (bash in the C
/// locale). Returns true when at least one path matched; otherwise `out` is
/// left untouched and the caller decides between the literal word, nullglob
/// and failglob.
pub fn globWith(arena: std.mem.Allocator, pattern: []const u8, out: *std.ArrayList([]const u8), opts: Options) !bool {
    if (!hasMetaOpts(pattern, opts.extglob)) return false;

    const start_index = out.items.len;

    var absolute = false;
    var rest = pattern;
    if (rest.len > 0 and rest[0] == '/') {
        absolute = true;
        rest = rest[1..];
    }
    var dir_only = false;
    while (rest.len > 0 and rest[rest.len - 1] == '/' and !(rest.len > 1 and rest[rest.len - 2] == '\\')) {
        dir_only = true;
        rest = rest[0 .. rest.len - 1];
    }
    if (rest.len == 0) return false;

    var segs: std.ArrayList([]const u8) = .empty;
    if (!try splitSegments(arena, rest, opts.extglob, &segs)) return false;
    if (segs.items.len == 0) return false;

    var ctx = Ctx{ .arena = arena, .out = out, .opts = opts, .dir_only = dir_only };
    try walk(&ctx, if (absolute) "/" else "", segs.items, 0);

    if (out.items.len == start_index) return false;
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
    try std.testing.expect(!matchSegment("[^abc]*", "beta"));
    try std.testing.expect(matchSegment("[a-c]x", "bx"));
    try std.testing.expect(matchSegment("\\*", "*"));
    try std.testing.expect(!matchSegment("\\*", "x"));
    try std.testing.expect(matchSegment("*", "anything"));
    try std.testing.expect(matchSegment("src/*", "src/lib.zig"));
    // Pattern matching (case, [[ ]]) lets `*` cross `/`.
    try std.testing.expect(matchSegment("src/*", "src/sub/lib.zig"));
}

test "bracket expressions" {
    try std.testing.expect(matchSegment("[[:alpha:]]*", "abc"));
    try std.testing.expect(!matchSegment("[[:alpha:]]*", "1bc"));
    try std.testing.expect(matchSegment("[[:digit:][:upper:]]", "Q"));
    try std.testing.expect(matchSegment("[![:space:]]", "x"));
    try std.testing.expect(!matchSegment("[![:space:]]", " "));
    try std.testing.expect(!matchSegment("[[:bogus:]]", "a"));
    try std.testing.expect(matchSegment("[]a]", "]"));
    try std.testing.expect(matchSegment("[a-]", "-"));
    try std.testing.expect(matchSegment("[ab", "[ab"));
    try std.testing.expect(matchSegment("[\\]]", "]"));
    try std.testing.expect(matchSegment("[[=e=]]", "e"));
    try std.testing.expect(matchSegmentWith("[A-Z]x", "bX", .{ .nocase = true }));
    try std.testing.expect(!matchSegment("[A-Z]x", "bx"));
}

test "extended patterns" {
    try std.testing.expect(matchSegment("@(a|b).c", "b.c"));
    try std.testing.expect(!matchSegment("@(a|b).c", "ab.c"));
    try std.testing.expect(matchSegment("?(x)y", "y"));
    try std.testing.expect(matchSegment("?(x)y", "xy"));
    try std.testing.expect(!matchSegment("?(x)y", "xxy"));
    try std.testing.expect(matchSegment("*(ab)c", "ababc"));
    try std.testing.expect(matchSegment("*(ab)c", "c"));
    try std.testing.expect(!matchSegment("+(ab)c", "c"));
    try std.testing.expect(matchSegment("+(ab|x)c", "abxc"));
    try std.testing.expect(matchSegment("!(*.zig)", "main.rs"));
    try std.testing.expect(!matchSegment("!(*.zig)", "main.zig"));
    try std.testing.expect(matchSegment("!(foo)*", "foobar"));
    try std.testing.expect(matchSegment("@(a|@(b|c))", "c"));
    try std.testing.expect(matchSegment("*(a|)", "aa"));
    try std.testing.expect(!matchSegmentWith("@(a|b)", "a", .{ .extglob = false }));
    try std.testing.expect(matchSegmentWith("@(a|b)", "@(a|b)", .{ .extglob = false }));
    try std.testing.expect(!matchSegment("@\\(a\\)", "a"));
}

test "metacharacter detection" {
    try std.testing.expect(hasMeta("*.zig"));
    try std.testing.expect(!hasMeta("["));
    try std.testing.expect(!hasMeta("[ab"));
    try std.testing.expect(hasMeta("[ab]"));
    try std.testing.expect(hasMeta("@(a)"));
    try std.testing.expect(!hasMetaOpts("@(a)", false));
    try std.testing.expect(!hasMeta("\\*"));
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

    out.clearRetainingCapacity();
    try std.testing.expect(try glob(arena, "src/**/redirect.zig", &out));
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqualStrings("src/executor/redirect.zig", out.items[0]);

    out.clearRetainingCapacity();
    try std.testing.expect(try glob(arena, "src/*/", &out));
    for (out.items) |p| try std.testing.expect(std.mem.endsWith(u8, p, "/"));

    out.clearRetainingCapacity();
    try std.testing.expect(try globWith(arena, "SRC/LEXER.ZI?", &out, .{ .nocase = true }) == false);
    try std.testing.expect(try globWith(arena, "src/LEXER.ZI?", &out, .{ .nocase = true }));
    try std.testing.expectEqualStrings("src/lexer.zig", out.items[0]);
}
