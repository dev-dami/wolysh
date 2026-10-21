//! Small questions about large command output: "which tests failed", "show
//! me the errors", "find the line about `connection refused`", answered
//! within a byte budget so an agent does not have to read the whole log.
//!
//! Everything here is a pure function of a byte slice: no shell state, no
//! I/O. Each query is one forward pass that splits lines 64 bytes at a time
//! with vector compares and allocates only for what it keeps, so a file of
//! hundreds of megabytes costs about as much as reading it. The recognisers
//! are prefix and suffix checks, not regexes; `grep` with `.regex` uses the
//! linear-time matcher in `regex.zig` (whose back-reference fallback gives up
//! after a fixed amount of work).
//!
//! Lines end at `\n`; a `\r` before it is dropped. Matching always looks at a
//! line as a terminal would show it: ANSI escape sequences removed and, for a
//! line redrawn with bare carriage returns (progress bars), only its last
//! segment. Output shows the same cleaned text unless a caller asks for raw
//! lines.

const std = @import("std");
const fuzzy = @import("fuzzy.zig");
const regex = @import("regex.zig");

const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Error = Allocator.Error || Writer.Error;

// --- lines -------------------------------------------------------------------

pub const Line = struct {
    /// One-based line number.
    number: u64,
    /// Offset of the line's first byte.
    start: usize,
    /// Offset just past its content, before `\r\n` or `\n`.
    end: usize,
    /// Offset of the following line (or the end of the text).
    next: usize,
    /// No escape or carriage return inside, so cleaning cannot change it.
    /// False only means "look closer".
    plain: bool = false,

    pub fn bytes(self: Line, text: []const u8) []const u8 {
        return text[self.start..self.end];
    }
};

// Lines are split 64 bytes at a time: one vector comparison per byte value
// gives a bit mask of the newlines in a block, and others the bytes that make
// a line need cleaning, so a line costs a few bit operations rather than a
// scan of its own.
const block_len = 64;
const Block = @Vector(block_len, u8);

const Masks = struct { newlines: u64, specials: u64 };

/// Newlines, and escapes or carriage returns that do not end a CRLF line, in
/// the 64 bytes at `base` (zero past the end of `text`). A carriage return in
/// the last position might end a CRLF line too, but its newline is in the
/// next block, so it counts: the cleaner then looks closer.
fn blockMasks(text: []const u8, base: usize) Masks {
    var padded: [block_len]u8 = undefined;
    const bytes: *const [block_len]u8 = if (base + block_len <= text.len) text[base..][0..block_len] else blk: {
        @memset(&padded, 0);
        @memcpy(padded[0 .. text.len - base], text[base..]);
        break :blk &padded;
    };
    const v: Block = bytes.*;
    const newlines: u64 = @bitCast(v == @as(Block, @splat('\n')));
    const escapes: u64 = @bitCast(v == @as(Block, @splat(0x1b)));
    const returns: u64 = @bitCast(v == @as(Block, @splat('\r')));
    return .{ .newlines = newlines, .specials = escapes | (returns & ~(newlines >> 1)) };
}

pub const LineIterator = struct {
    text: []const u8,
    pos: usize = 0,
    /// Number of the line most recently returned.
    number: u64 = 0,
    /// The block whose masks are loaded.
    base: usize = no_block,
    masks: Masks = .{ .newlines = 0, .specials = 0 },

    const no_block = std.math.maxInt(usize);

    pub fn init(text: []const u8) LineIterator {
        return .{ .text = text };
    }

    /// Resumes at `offset`, which must start a line numbered `number + 1`.
    pub fn initAt(text: []const u8, offset: usize, number: u64) LineIterator {
        return .{ .text = text, .pos = offset, .number = number };
    }

    /// The next line, or null at the end of the text.
    pub fn next(self: *LineIterator) ?Line {
        const len = self.text.len;
        if (self.pos >= len) return null;
        const start = self.pos;
        var plain = true;
        var newline: ?usize = null;
        var base = start - start % block_len;
        while (base < len) : (base += block_len) {
            if (self.base != base) {
                self.masks = blockMasks(self.text, base);
                self.base = base;
            }
            const live: u64 = if (start > base) ~@as(u64, 0) << @intCast(start - base) else ~@as(u64, 0);
            const found = self.masks.newlines & live;
            if (found != 0) {
                const at = @ctz(found);
                const before = (@as(u64, 1) << @intCast(at)) - 1;
                if (self.masks.specials & live & before != 0) plain = false;
                newline = base + at;
                break;
            }
            if (self.masks.specials & live != 0) plain = false;
        }
        var end = newline orelse len;
        self.pos = if (newline) |at| at + 1 else len;
        if (end > start and self.text[end - 1] == '\r') end -= 1;
        self.number += 1;
        return .{ .number = self.number, .start = start, .end = end, .next = self.pos, .plain = plain };
    }
};

/// Number of lines; a final line without a newline counts.
pub fn countLines(text: []const u8) u64 {
    var count: u64 = 0;
    var base: usize = 0;
    while (base < text.len) : (base += block_len) count += @popCount(blockMasks(text, base).newlines);
    return if (text.len > 0 and text[text.len - 1] != '\n') count + 1 else count;
}

/// The line numbered `number` (one-based), or null past the end.
pub fn lineAt(text: []const u8, number: u64) ?Line {
    if (number == 0) return null;
    // Skip whole blocks by counting their newlines.
    var wanted = number - 1;
    var start: usize = 0;
    var base: usize = 0;
    while (wanted > 0) : (base += block_len) {
        if (base >= text.len) return null;
        var newlines = blockMasks(text, base).newlines;
        const count = @popCount(newlines);
        if (count < wanted) {
            wanted -= count;
            continue;
        }
        while (wanted > 1) : (wanted -= 1) newlines &= newlines - 1;
        start = base + @ctz(newlines) + 1;
        break;
    }
    var it = LineIterator.initAt(text, start, number - 1);
    return it.next();
}

/// `line` with up to `before` lines in front of it and `after` behind it, in
/// order.
pub fn context(arena: Allocator, text: []const u8, line: Line, before: usize, after: usize) Allocator.Error![]Line {
    var lines: std.ArrayList(Line) = .empty;
    // Walk back over the newlines that end the preceding lines.
    var first = line.start;
    var number = line.number;
    var taken: usize = 0;
    while (taken < before and first > 0) : (taken += 1) {
        const prev_end = first - 1; // the `\n` ending the previous line
        first = if (std.mem.lastIndexOfScalar(u8, text[0..prev_end], '\n')) |at| at + 1 else 0;
        number -= 1;
    }
    var it = LineIterator.initAt(text, first, number - 1);
    const last = line.number + after;
    while (it.next()) |l| {
        try lines.append(arena, l);
        if (l.number >= last) break;
    }
    return lines.toOwnedSlice(arena);
}

// --- cleaning ----------------------------------------------------------------

/// Turns a raw line into what a terminal would show: ANSI escape sequences
/// removed and, for a line redrawn with carriage returns, its last non-empty
/// segment. Lines with neither come back unchanged without copying; the
/// others are rebuilt in one buffer that each call reuses, so the result is
/// only valid until the next call.
pub const Cleaner = struct {
    allocator: Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(allocator: Allocator) Cleaner {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Cleaner) void {
        self.buf.deinit(self.allocator);
    }

    /// `line` of `text` as a terminal would show it.
    pub fn cleanLine(self: *Cleaner, text: []const u8, line: Line) Allocator.Error![]const u8 {
        const raw = line.bytes(text);
        return if (line.plain) raw else self.clean(raw);
    }

    /// `line` (without its terminator) as a terminal would show it.
    pub fn clean(self: *Cleaner, line: []const u8) Allocator.Error![]const u8 {
        if (std.mem.indexOfScalar(u8, line, 0x1b) == null and std.mem.indexOfScalar(u8, line, '\r') == null) return line;
        self.buf.clearRetainingCapacity();
        try self.buf.ensureTotalCapacity(self.allocator, line.len);
        var segment: usize = 0;
        var previous: ?[2]usize = null;
        var i: usize = 0;
        while (i < line.len) {
            // Copy the run up to the next escape or carriage return at once.
            var stop = i;
            while (stop < line.len and line[stop] != 0x1b and line[stop] != '\r') stop += 1;
            self.buf.appendSliceAssumeCapacity(line[i..stop]);
            i = stop;
            if (i == line.len) break;
            if (line[i] == 0x1b) {
                i = skipEscape(line, i);
            } else {
                if (self.buf.items.len > segment) {
                    previous = .{ segment, self.buf.items.len };
                    segment = self.buf.items.len;
                }
                i += 1;
            }
        }
        const items = self.buf.items;
        if (items.len > segment) return items[segment..];
        if (previous) |span| return items[span[0]..span[1]];
        return items[0..0];
    }
};

/// Index just past the escape sequence starting at `line[at]` (an ESC).
fn skipEscape(line: []const u8, at: usize) usize {
    if (at + 1 >= line.len) return line.len;
    var i = at + 2;
    switch (line[at + 1]) {
        // CSI: parameters, intermediates, one final byte.
        '[' => {
            while (i < line.len and line[i] >= 0x30 and line[i] <= 0x3f) i += 1;
            while (i < line.len and line[i] >= 0x20 and line[i] <= 0x2f) i += 1;
            if (i < line.len and line[i] >= 0x40 and line[i] <= 0x7e) i += 1;
            return i;
        },
        // OSC, DCS, APC, PM, SOS: up to BEL or ST (`ESC \`).
        ']', 'P', '_', '^', 'X' => {
            while (i < line.len) : (i += 1) {
                if (line[i] == 0x07) return i + 1;
                if (line[i] == 0x1b and i + 1 < line.len and line[i + 1] == '\\') return i + 2;
            }
            return line.len;
        },
        // Character set designations take one more byte.
        '(', ')', '*', '+', '-', '.', '/', '#', '%' => return @min(i + 1, line.len),
        else => return i,
    }
}

/// `line` without ANSI escapes or carriage-return redraws, allocated in
/// `arena`.
pub fn cleanAlloc(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    var cleaner = Cleaner.init(arena);
    const cleaned = try cleaner.clean(line);
    return if (cleaned.ptr == line.ptr) line else arena.dupe(u8, cleaned);
}

// --- classification ------------------------------------------------------------

/// How much a line matters to someone skimming output, in increasing order.
pub const Kind = enum(u3) {
    plain,
    warning,
    /// Counts and totals ("3 passed; 0 failed", "Ran 12 tests").
    summary,
    failure,
    @"error",

    /// Errors and failures: the lines a summary must keep.
    pub fn important(self: Kind) bool {
        return self == .failure or self == .@"error";
    }
};

const word_byte: [256]bool = blk: {
    var table = [_]bool{false} ** 256;
    for (0..256) |byte| table[byte] = std.ascii.isAlphanumeric(byte) or byte == '_' or byte >= 0x80;
    break :blk table;
};

/// The first two letters (lowercase) of every keyword `keywordAt` knows,
/// as bit `second - 'a'` of entry `first - 'a'`.
const keyword_pairs: [26]u32 = blk: {
    var table = [_]u32{0} ** 26;
    const words = [_][]const u8{
        "error",    "exception", "exit",  "fail", "fatal",     "panic", "pass", "traceback", "warn",
        "segfault", "summary",   "abort", "not",  "undefined", "core",  "ran",
    };
    for (words) |word| table[word[0] - 'a'] |= @as(u32, 1) << (word[1] - 'a');
    break :blk table;
};

const Lane = @Vector(16, u8);

/// Bit i set where `pred` holds for byte i of the 16 bytes.
inline fn laneMask(pred: @Vector(16, bool)) u16 {
    return @bitCast(pred);
}

/// Classifies one cleaned line by the words in it: errors, panics, failures,
/// warnings, and test summaries. A keyword must start a word (or a CamelCase
/// part, so `TypeError` counts) and must not run on into lowercase letters
/// (so `failover` does not). A count of zero ("0 failed", "errors=0", "no
/// warnings") makes a summary instead. Constant work per byte; no allocation.
pub fn classify(line: []const u8) Kind {
    if (isPassLine(line)) return .plain;
    var kind: Kind = markerKind(line);
    if (line.len < 16) {
        for (0..line.len) |at| {
            const byte = line[at];
            if (!std.ascii.isAlphabetic(byte)) continue;
            if (at > 0) {
                const prev = line[at - 1];
                if (word_byte[prev] and !(std.ascii.isLower(prev) and std.ascii.isUpper(byte))) continue;
            }
            if (keywordAt(line, at)) |found| kind = higher(kind, found);
        }
        return kind;
    }
    // Word starts are found sixteen bytes at a time; only those whose first
    // two letters begin some keyword are looked at more closely. The last
    // window overlaps the one before it rather than reading past the line.
    var done: usize = 0;
    while (done < line.len) {
        const window = @min(done, line.len - 16);
        const v: Lane = line[window..][0..16].*;
        const lower = laneMask(v >= @as(Lane, @splat('a'))) & laneMask(v <= @as(Lane, @splat('z')));
        const upper = laneMask(v >= @as(Lane, @splat('A'))) & laneMask(v <= @as(Lane, @splat('Z')));
        const digit = laneMask(v >= @as(Lane, @splat('0'))) & laneMask(v <= @as(Lane, @splat('9')));
        const word = lower | upper | digit | laneMask(v == @as(Lane, @splat('_'))) | laneMask(v >= @as(Lane, @splat(0x80)));
        const before: u8 = if (window > 0) line[window - 1] else ' ';
        const prev_word = (word << 1) | @intFromBool(word_byte[before]);
        const prev_lower = (lower << 1) | @intFromBool(std.ascii.isLower(before));
        // A letter after a non-word byte, or an uppercase letter after a
        // lowercase one (`TypeError`); bytes an earlier window covered are
        // skipped.
        var starts = (lower | upper) & (~prev_word | (upper & prev_lower));
        starts &= ~@as(u16, 0) << @intCast(done - window);
        while (starts != 0) : (starts &= starts - 1) {
            const at = window + @ctz(starts);
            if (at + 1 >= line.len) break;
            const first = (line[at] | 0x20) - 'a';
            const second = line[at + 1] | 0x20;
            if (second < 'a' or second > 'z' or keyword_pairs[first] & (@as(u32, 1) << @intCast(second - 'a')) == 0) continue;
            const found = keywordAt(line, at) orelse continue;
            kind = higher(kind, found);
            if (kind == .@"error") return kind;
        }
        done = window + 16;
    }
    return kind;
}

fn higher(a: Kind, b: Kind) Kind {
    return if (@intFromEnum(b) > @intFromEnum(a)) b else a;
}

/// Lines that report a pass, which can contain alarming words in test names
/// (`test parser::error_recovery ... ok`).
fn isPassLine(line: []const u8) bool {
    if (endsWith(line, " ... ok") or endsWith(line, " ... ignored") or
        endsWith(line, "...OK") or endsWith(line, "...SKIP")) return true;
    const t = trimLeft(line);
    if (startsWith(t, "--- PASS") or startsWith(t, "--- SKIP") or
        startsWith(t, "=== RUN") or startsWith(t, "✓ ") or
        startsWith(t, "✔ ") or startsWith(t, "PASS ")) return true;
    if (endsWith(t, "%]") and (find(t, " PASSED") != null or find(t, " SKIPPED") != null)) return true;
    return false;
}

/// Failure marks that test runners put in front of a test name.
fn markerKind(line: []const u8) Kind {
    const t = trimLeft(line);
    const marks = [_][]const u8{ "✕ ", "✗ ", "✘ ", "× " };
    inline for (marks) |mark| {
        if (startsWith(t, mark)) return .failure;
    }
    if (startsWith(t, "● ") and !startsWith(t, "● Console")) return .failure;
    return .plain;
}

/// The keyword starting at `line[at]`, if any.
fn keywordAt(line: []const u8, at: usize) ?Kind {
    const rest = line[at..];
    switch (std.ascii.toLower(line[at])) {
        'e' => {
            if (wordWith(line, at, "error", &.{ "s", "" })) |end| return zeroed(line, at, end, .@"error");
            if (wordWith(line, at, "exception", &.{ "s", "" }) != null) return .@"error";
            if (std.ascii.startsWithIgnoreCase(rest, "exit")) return exitStatusKind(line, at);
        },
        'f' => {
            if (wordWith(line, at, "fail", &.{ "ures", "ure", "ing", "ed", "s", "" })) |end| return zeroed(line, at, end, .failure);
            if (wordWith(line, at, "fatal", &.{""}) != null) return .@"error";
        },
        'p' => {
            if (wordWith(line, at, "panic", &.{ "ked", "s", "" }) != null) return .@"error";
            if (wordWith(line, at, "pass", &.{ "ed", "ing" }) != null and countBefore(line, at)) return .summary;
        },
        't' => if (wordWith(line, at, "traceback", &.{""}) != null) return .@"error",
        'w' => if (wordWith(line, at, "warn", &.{ "ings", "ing", "s", "" })) |end| return zeroed(line, at, end, .warning),
        's' => {
            if (std.ascii.startsWithIgnoreCase(rest, "segmentation fault") or wordWith(line, at, "segfault", &.{ "ed", "" }) != null) return .@"error";
            if (wordWith(line, at, "summary", &.{""}) != null) return .summary;
        },
        'a' => if (wordWith(line, at, "abort", &.{ "ed", "" }) != null) return .@"error",
        'n' => if (startsWith(rest, "not ok ")) return .failure,
        'u' => if (std.ascii.startsWithIgnoreCase(rest, "undefined reference")) return .@"error",
        'c' => if (std.ascii.startsWithIgnoreCase(rest, "core dumped")) return .@"error",
        'r' => if (startsWith(rest, "Ran ") and rest.len > 4 and std.ascii.isDigit(rest[4])) return .summary,
        else => {},
    }
    return null;
}

/// When `line[at..]` is `word` plus one of `suffixes` (case-insensitively)
/// and not followed by a lowercase letter or `_`, the index just past it.
fn wordWith(line: []const u8, at: usize, word: []const u8, suffixes: []const []const u8) ?usize {
    const rest = line[at..];
    if (!std.ascii.startsWithIgnoreCase(rest, word)) return null;
    for (suffixes) |suffix| {
        if (!std.ascii.startsWithIgnoreCase(rest[word.len..], suffix)) continue;
        const end = at + word.len + suffix.len;
        if (end < line.len and (std.ascii.isLower(line[end]) or line[end] == '_')) continue;
        return end;
    }
    return null;
}

/// `kind`, or `.summary` when the keyword at `line[at..end]` is counted as
/// zero: "0 failed", "no errors", "Failures: 0", "errors=0".
fn zeroed(line: []const u8, at: usize, end: usize, kind: Kind) Kind {
    if (at >= 2 and line[at - 1] == ' ' and line[at - 2] == '0' and (at < 3 or !std.ascii.isDigit(line[at - 3]))) return .summary;
    if (at >= 3 and std.ascii.eqlIgnoreCase(line[at - 3 .. at], "no ") and (at < 4 or !word_byte[line[at - 4]])) return .summary;
    var i = end;
    if (i < line.len and (line[i] == ':' or line[i] == '=')) i += 1;
    while (i < line.len and line[i] == ' ') i += 1;
    if (i > end and i < line.len and line[i] == '0') {
        const after = if (i + 1 < line.len) line[i + 1] else ' ';
        if (!std.ascii.isDigit(after) and after != 'x') return .summary;
    }
    return kind;
}

/// "N passed", "N passing": a count right before the word.
fn countBefore(line: []const u8, at: usize) bool {
    return at >= 2 and line[at - 1] == ' ' and std.ascii.isDigit(line[at - 2]);
}

/// "exit status 1", "exit code: 2", "exited with code 0", "returned non-zero
/// exit status 1": an error unless the status is 0.
fn exitStatusKind(line: []const u8, at: usize) ?Kind {
    var i = at + 4;
    if (std.ascii.startsWithIgnoreCase(line[i..], "ed with")) i += 7;
    if (std.ascii.startsWithIgnoreCase(line[i..], " code")) {
        i += 5;
    } else if (std.ascii.startsWithIgnoreCase(line[i..], " status")) {
        i += 7;
    } else return null;
    if (i < line.len and (line[i] == ':' or line[i] == '=')) i += 1;
    while (i < line.len and line[i] == ' ') i += 1;
    const digits_start = i;
    var value: u64 = 0;
    while (i < line.len and std.ascii.isDigit(line[i])) : (i += 1) value = value *| 10 +| (line[i] - '0');
    if (i == digits_start) return null;
    return if (value == 0) .summary else .@"error";
}

/// `std.mem.startsWith` for a literal prefix, unrolled: the recognizers
/// make a dozen such checks per line and nearly all fail on the first byte.
inline fn startsWith(s: []const u8, comptime prefix: []const u8) bool {
    if (s.len < prefix.len) return false;
    inline for (prefix, 0..) |byte, i| {
        if (s[i] != byte) return false;
    }
    return true;
}

inline fn endsWith(s: []const u8, comptime suffix: []const u8) bool {
    if (s.len < suffix.len) return false;
    const tail = s[s.len - suffix.len ..];
    inline for (0..suffix.len) |k| {
        // From the end, where lines differ first.
        const i = suffix.len - 1 - k;
        if (tail[i] != suffix[i]) return false;
    }
    return true;
}

// `std.mem.trim` looks each byte up in its strip set with `indexOfScalar`,
// a call per byte; these run on every line, so they compare directly.

fn trimLeft(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t')) i += 1;
    return s[i..];
}

fn trim(s: []const u8) []const u8 {
    const left = trimLeft(s);
    var end = left.len;
    while (end > 0 and (left[end - 1] == ' ' or left[end - 1] == '\t')) end -= 1;
    return left[0..end];
}

// --- JSON ----------------------------------------------------------------------

/// Writes `s` as a JSON string. Invalid UTF-8 becomes U+FFFD, so the output
/// is always valid JSON whatever the input bytes were.
pub fn writeJsonString(w: *Writer, s: []const u8) Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try w.writeAll("\\\""),
                '\\' => try w.writeAll("\\\\"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                0x08 => try w.writeAll("\\b"),
                0x0c => try w.writeAll("\\f"),
                0...0x07, 0x0b, 0x0e...0x1f, 0x7f => try w.print("\\u{x:0>4}", .{byte}),
                else => try w.writeByte(byte),
            }
            i += 1;
            continue;
        }
        const n = utf8Length(s[i..]);
        if (n == 0) {
            try w.writeAll("\u{fffd}");
            i += 1;
        } else {
            try w.writeAll(s[i .. i + n]);
            i += n;
        }
    }
    try w.writeByte('"');
}

/// Bytes `writeJsonString` writes for `s`.
pub fn jsonStringLen(s: []const u8) usize {
    var total: usize = 2;
    var i: usize = 0;
    while (i < s.len) {
        const byte = s[i];
        if (byte < 0x80) {
            total += switch (byte) {
                '"', '\\', '\n', '\r', '\t', 0x08, 0x0c => 2,
                0...0x07, 0x0b, 0x0e...0x1f, 0x7f => 6,
                else => 1,
            };
            i += 1;
            continue;
        }
        const n = utf8Length(s[i..]);
        if (n == 0) {
            total += 3;
            i += 1;
        } else {
            total += n;
            i += n;
        }
    }
    return total;
}

/// Length of the valid UTF-8 sequence at the start of `s`, or 0.
fn utf8Length(s: []const u8) usize {
    const n = std.unicode.utf8ByteSequenceLength(s[0]) catch return 0;
    if (n > s.len) return 0;
    _ = std.unicode.utf8Decode(s[0..n]) catch return 0;
    return n;
}

/// The longest prefix of `s` no longer than `max` that does not split a
/// UTF-8 sequence.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var cut = max;
    while (cut > 0 and (s[cut] & 0xc0) == 0x80) cut -= 1;
    return s[0..cut];
}

/// `n` with thousands separators: 1203331 is "1,203,331".
pub fn writeGrouped(w: *Writer, n: u64) Writer.Error!void {
    var digits: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    for (text, 0..) |digit, i| {
        if (i != 0 and (text.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(digit);
    }
}

fn digitCount(n: u64) usize {
    var count: usize = 1;
    var rest = n;
    while (rest >= 10) : (rest /= 10) count += 1;
    return count;
}

// --- budget --------------------------------------------------------------------

pub const Format = enum { text, json };

pub const BudgetOptions = struct {
    format: Format = .text,
    /// Show lines as they were, escapes and all; matching still ignores them.
    raw: bool = false,
    /// Leading and trailing lines worth keeping for orientation.
    head: usize = 3,
    tail: usize = 5,
    /// Lines kept around each error or failure, when there is room.
    context_before: usize = 2,
    context_after: usize = 2,
    /// Longer lines are cut, with a note of how much was dropped.
    max_line_bytes: usize = 512,
};

/// Priority tiers of the candidate lines, highest first.
const tier_important = 0;
const tier_summary = 1;
const tier_context = 2;
const tier_warning = 3;
const tier_count = 4;

const max_context = 16;

/// Candidate lines of one priority: the first `cap` and, once more arrive,
/// the last `cap`. Selection takes lines alternately from both ends, so
/// nothing in between could be chosen anyway.
const Tier = struct {
    first: std.ArrayList(Line) = .empty,
    /// Ring of the latest lines past `first`, allocated on overflow.
    last: []Line = &.{},
    overflow: u64 = 0,

    fn keep(self: *Tier, arena: Allocator, line: Line, cap: usize) Allocator.Error!void {
        if (self.first.items.len < cap) return self.first.append(arena, line);
        if (self.last.len == 0) self.last = try arena.alloc(Line, cap);
        self.last[@intCast(self.overflow % self.last.len)] = line;
        self.overflow += 1;
    }

    /// The kept lines, in order.
    fn lines(self: *const Tier, arena: Allocator) Allocator.Error![]const Line {
        if (self.overflow == 0) return self.first.items;
        const n: usize = @intCast(@min(self.overflow, self.last.len));
        const all = try arena.alloc(Line, self.first.items.len + n);
        @memcpy(all[0..self.first.items.len], self.first.items);
        const oldest = self.overflow - n;
        for (0..n) |k| all[self.first.items.len + k] = self.last[@intCast((oldest + k) % self.last.len)];
        return all;
    }
};

/// A summary of `text` that never exceeds `max_bytes`. If the whole text
/// fits it is returned as is (cleaned unless `options.raw`). Otherwise the
/// result keeps, in original order and as room allows: the first and last
/// lines, the last few and first few lines, error and failure lines, summary
/// lines, a little context around the errors, then warnings. Each run of
/// dropped lines becomes one marker naming its exact line range and size,
/// `[… 9,812 lines (1,203,331 bytes) elided; lines 41–9852 …]`, so the
/// caller can ask for exactly that range. Among equally important lines the
/// first and last are taken before the ones in the middle, so both the first
/// error and the closing summary survive a small budget. With `.json` the result is JSON lines,
/// `{"type":"line","line":N,"text":"…"}` and
/// `{"type":"elided","from":A,"to":B,"lines":K,"bytes":X}`, and the budget
/// covers that encoding.
pub fn budget(arena: Allocator, text: []const u8, max_bytes: usize, options: BudgetOptions) Error![]u8 {
    var b = try Budgeter.init(arena, text, max_bytes, options);
    try b.scan();
    var out: Writer.Allocating = .init(arena);
    if (b.whole_cost <= max_bytes) {
        try b.renderAll(&out.writer);
    } else {
        try b.select();
        try b.renderSelected(&out.writer);
    }
    var result = out.written();
    if (result.len > max_bytes) {
        // Only when not even one elision marker fits.
        result = result[0..if (options.format == .json) 0 else utf8Prefix(result, max_bytes).len];
    }
    return result;
}

const Budgeter = struct {
    arena: Allocator,
    text: []const u8,
    max_bytes: usize,
    options: BudgetOptions,
    max_line: usize,
    cleaner: Cleaner,

    tiers: [tier_count]Tier = .{ .{}, .{}, .{}, .{} },
    head: std.ArrayList(Line) = .empty,
    /// Ring of the last `options.tail` lines.
    tail: []Line,
    tail_count: u64 = 0,
    first: ?Line = null,
    last: ?Line = null,
    total_lines: u64 = 0,
    whole_cost: usize = 0,

    selected: std.ArrayList(Line) = .empty,
    chosen: std.DynamicBitSetUnmanaged = .{},
    used: usize = 0,
    marker_max: usize = 0,

    fn init(arena: Allocator, text: []const u8, max_bytes: usize, options: BudgetOptions) Allocator.Error!Budgeter {
        var opts = options;
        opts.context_before = @min(opts.context_before, max_context);
        return .{
            .arena = arena,
            .text = text,
            .max_bytes = max_bytes,
            .options = opts,
            .max_line = @min(options.max_line_bytes, @max(80, max_bytes / 4)),
            .cleaner = Cleaner.init(arena),
            .tail = try arena.alloc(Line, options.tail),
        };
    }

    fn scan(self: *Budgeter) Error!void {
        // A tier never needs more lines than could fit: each costs at least
        // two bytes. Later lines of a full tier would lose to earlier ones.
        const cap = self.max_bytes / 2 + 1;
        // Ring of the last `context_before` non-blank lines.
        var before: [max_context]Line = undefined;
        var before_start: usize = 0;
        var before_len: usize = 0;
        var pending_after: usize = 0;
        var it = LineIterator.init(self.text);
        while (it.next()) |line| {
            const raw = line.bytes(self.text);
            const cleaned = try self.cleaner.cleanLine(self.text, line);
            const shown = if (self.options.raw) raw else cleaned;
            self.whole_cost +|= self.lineCost(line.number, shown, false);
            if (self.first == null) self.first = line;
            self.last = line;
            // Blank lines are never worth a byte on their own; they only
            // show up to fill a gap that a marker would cost more to describe.
            if (trim(cleaned).len == 0) continue;
            if (line.number <= self.options.head) try self.head.append(self.arena, line);
            if (self.tail.len != 0) self.tail[@intCast(self.tail_count % self.tail.len)] = line;
            self.tail_count += 1;

            const kind = classify(cleaned);
            if (kind.important()) {
                try self.keep(tier_important, line, cap);
                for (0..before_len) |k| try self.keep(tier_context, before[(before_start + k) % max_context], cap);
                pending_after = self.options.context_after;
            } else {
                if (kind == .summary) try self.keep(tier_summary, line, cap);
                if (kind == .warning) try self.keep(tier_warning, line, cap);
                if (pending_after > 0) {
                    try self.keep(tier_context, line, cap);
                    pending_after -= 1;
                }
            }
            if (self.options.context_before > 0) {
                if (before_len == self.options.context_before) {
                    before[(before_start + before_len) % max_context] = line;
                    before_start = (before_start + 1) % max_context;
                } else {
                    before[(before_start + before_len) % max_context] = line;
                    before_len += 1;
                }
            }
        }
        self.total_lines = it.number;
    }

    fn keep(self: *Budgeter, tier: usize, line: Line, cap: usize) Allocator.Error!void {
        try self.tiers[tier].keep(self.arena, line, cap);
    }

    /// Bytes one shown line costs; `cut` applies the long-line limit.
    fn lineCost(self: *const Budgeter, number: u64, shown: []const u8, cut: bool) usize {
        var len = shown.len;
        var suffix: usize = 0;
        if (cut and shown.len > self.max_line) {
            len = utf8Prefix(shown, self.max_line).len;
            suffix = cutSuffixLen(shown.len - len);
        }
        return switch (self.options.format) {
            .text => len + suffix + 1,
            .json => blk: {
                const body = if (cut and suffix != 0) jsonStringLen(utf8Prefix(shown, self.max_line)) + suffix else jsonStringLen(shown);
                break :blk "{\"type\":\"line\",\"line\":".len + digitCount(number) + ",\"text\":".len + body + "}\n".len;
            },
        };
    }

    fn shownText(self: *Budgeter, line: Line) Allocator.Error![]const u8 {
        const raw = line.bytes(self.text);
        return if (self.options.raw) raw else self.cleaner.cleanLine(self.text, line);
    }

    fn select(self: *Budgeter) Error!void {
        const n = self.total_lines;
        self.chosen = try std.DynamicBitSetUnmanaged.initEmpty(self.arena, @intCast(n + 2));
        // Virtual lines 0 and n+1 bound the text, so a gap at either end
        // still costs one marker.
        self.chosen.set(0);
        self.chosen.set(@intCast(n + 1));
        self.marker_max = try self.markerBound();
        self.used = self.marker_max;

        if (self.first) |line| _ = try self.tryAdd(line);
        if (self.last) |line| _ = try self.tryAdd(line);
        // Orientation lines first, but with at most a third of the budget,
        // so they cannot crowd out the errors.
        try self.addEdges(self.max_bytes / 3);
        try self.addTier(tier_important);
        try self.addTier(tier_summary);
        try self.addEdges(self.max_bytes);
        try self.addTier(tier_context);
        try self.addTier(tier_warning);
        try self.fillShortGaps();
    }

    /// The tier's lines alternately from the front and the back.
    fn addTier(self: *Budgeter, tier: usize) Error!void {
        const lines = try self.tiers[tier].lines(self.arena);
        var front: usize = 0;
        var back = lines.len;
        while (front < back) {
            _ = try self.tryAdd(lines[front]);
            front += 1;
            if (front == back) break;
            back -= 1;
            _ = try self.tryAdd(lines[back]);
        }
    }

    /// A gap of a few short lines can cost less shown than described: two
    /// blank lines are two bytes, their marker about sixty. Such gaps are
    /// filled in, which only ever lowers the total.
    fn fillShortGaps(self: *Budgeter) Error!void {
        const kept = try self.arena.dupe(Line, self.selected.items);
        std.mem.sort(Line, kept, {}, lessByNumber);
        var prev_number: u64 = 0;
        var prev_next: usize = 0;
        for (0..kept.len + 1) |i| {
            const number = if (i < kept.len) kept[i].number else self.total_lines + 1;
            const gap = number - prev_number - 1;
            if (gap >= 1 and gap <= 4) {
                var cost: usize = 0;
                var it = LineIterator.initAt(self.text, prev_next, prev_number);
                for (0..@intCast(gap)) |_| cost += self.lineCost(it.number + 1, try self.shownText(it.next().?), true);
                if (cost <= self.marker_max) {
                    it = LineIterator.initAt(self.text, prev_next, prev_number);
                    for (0..@intCast(gap)) |_| {
                        const line = it.next().?;
                        self.chosen.set(@intCast(line.number));
                        try self.selected.append(self.arena, line);
                    }
                    self.used = self.used + cost - self.marker_max;
                }
            }
            if (i < kept.len) {
                prev_number = kept[i].number;
                prev_next = kept[i].next;
            }
        }
    }

    /// The tail (newest first), then the head, while `used` stays within `limit`.
    fn addEdges(self: *Budgeter, limit: usize) Error!void {
        const kept = @min(self.tail_count, self.tail.len);
        var i: u64 = 0;
        while (i < kept) : (i += 1) {
            const slot = (self.tail_count - 1 - i) % self.tail.len;
            if (!try self.addEdge(self.tail[@intCast(slot)], limit)) break;
        }
        for (self.head.items) |line| {
            if (!try self.addEdge(line, limit)) break;
        }
    }

    /// False once `line` would take `used` past `limit`; edges stop there
    /// so that they stay contiguous.
    fn addEdge(self: *Budgeter, line: Line, limit: usize) Error!bool {
        if (self.chosen.isSet(@intCast(line.number))) return true;
        if (self.used + self.lineCost(line.number, try self.shownText(line), true) > limit) return false;
        _ = try self.tryAdd(line);
        return true;
    }

    /// Selects `line` if its cost, including any change in the number of
    /// markers, still fits.
    fn tryAdd(self: *Budgeter, line: Line) Error!bool {
        const index: usize = @intCast(line.number);
        if (self.chosen.isSet(index)) return true;
        const cost = self.lineCost(line.number, try self.shownText(line), true);
        const left = self.chosen.isSet(index - 1);
        const right = self.chosen.isSet(index + 1);
        // Taking a line out of the middle of a gap splits it in two; taking
        // the only line of a gap removes its marker.
        var next = self.used + cost;
        if (!left and !right) next += self.marker_max;
        if (left and right) next -= self.marker_max;
        if (next > self.max_bytes) return false;
        self.chosen.set(index);
        self.used = next;
        try self.selected.append(self.arena, line);
        return true;
    }

    /// The longest a marker can be: every number at its largest.
    fn markerBound(self: *Budgeter) Writer.Error!usize {
        var buf: [256]u8 = undefined;
        var w: Writer = .fixed(&buf);
        try self.writeMarker(&w, 1, @max(self.total_lines, 2), self.text.len);
        // The `from` field takes the largest line number too.
        return w.end + digitCount(self.total_lines);
    }

    fn writeMarker(self: *const Budgeter, w: *Writer, from: u64, to: u64, bytes: usize) Writer.Error!void {
        const count = to - from + 1;
        switch (self.options.format) {
            .text => {
                try w.writeAll("[… ");
                try writeGrouped(w, count);
                try w.writeAll(if (count == 1) " line (" else " lines (");
                try writeGrouped(w, bytes);
                try w.writeAll(if (bytes == 1) " byte) elided; " else " bytes) elided; ");
                if (count == 1) {
                    try w.print("line {d} …]\n", .{from});
                } else {
                    try w.print("lines {d}–{d} …]\n", .{ from, to });
                }
            },
            .json => try w.print("{{\"type\":\"elided\",\"from\":{d},\"to\":{d},\"lines\":{d},\"bytes\":{d}}}\n", .{ from, to, count, bytes }),
        }
    }

    fn writeLine(self: *Budgeter, w: *Writer, line: Line, cut: bool) Error!void {
        const shown = try self.shownText(line);
        const head = if (cut) utf8Prefix(shown, self.max_line) else shown;
        const dropped = shown.len - head.len;
        switch (self.options.format) {
            .text => {
                try w.writeAll(head);
                if (dropped != 0) try writeCutSuffix(w, dropped);
                try w.writeByte('\n');
            },
            .json => {
                try w.print("{{\"type\":\"line\",\"line\":{d},\"text\":", .{line.number});
                if (dropped == 0) {
                    try writeJsonString(w, head);
                } else {
                    // The suffix is plain ASCII plus U+2026, so it needs no
                    // escaping; splice it inside the closing quote.
                    var buf: [64]u8 = undefined;
                    var sw: Writer = .fixed(&buf);
                    try writeCutSuffix(&sw, dropped);
                    var tmp: Writer.Allocating = .init(self.arena);
                    try writeJsonString(&tmp.writer, head);
                    const quoted = tmp.written();
                    try w.writeAll(quoted[0 .. quoted.len - 1]);
                    try w.writeAll(sw.buffered());
                    try w.writeByte('"');
                }
                try w.writeAll("}\n");
            },
        }
    }

    fn renderAll(self: *Budgeter, w: *Writer) Error!void {
        var it = LineIterator.init(self.text);
        while (it.next()) |line| try self.writeLine(w, line, false);
    }

    fn renderSelected(self: *Budgeter, w: *Writer) Error!void {
        const lines = self.selected.items;
        std.mem.sort(Line, lines, {}, lessByNumber);
        var prev_number: u64 = 0;
        var prev_next: usize = 0;
        for (lines) |line| {
            if (line.number > prev_number + 1) try self.writeMarker(w, prev_number + 1, line.number - 1, line.start - prev_next);
            try self.writeLine(w, line, true);
            prev_number = line.number;
            prev_next = line.next;
        }
        if (prev_number < self.total_lines) try self.writeMarker(w, prev_number + 1, self.total_lines, self.text.len - prev_next);
    }
};

fn lessByNumber(_: void, a: Line, b: Line) bool {
    return a.number < b.number;
}

fn cutSuffixLen(dropped: usize) usize {
    // " … [+N bytes]"
    return " … [+".len + digitCount(dropped) + " bytes]".len;
}

fn writeCutSuffix(w: *Writer, dropped: usize) Writer.Error!void {
    try w.print(" … [+{d} bytes]", .{dropped});
}

// --- fuzzy find ------------------------------------------------------------------

pub const FindMatch = struct {
    line: Line,
    /// The cleaned line, which `positions` index.
    text: []const u8,
    score: i32,
    /// Byte offsets in `text` of the matched query characters, ascending.
    positions: []const u32,
};

pub const FindResult = struct {
    /// Best first; equal scores keep their original order.
    matches: []const FindMatch,
    /// How many lines matched at all.
    total: u64,
};

/// The `limit` lines that best match `query`, scored like fzf: every
/// space-separated term must appear in the line as a subsequence, scores add
/// up, and consecutive characters and word starts score higher. Smart case:
/// case-insensitive unless the query has an uppercase letter.
pub fn fuzzyFind(arena: Allocator, text: []const u8, query: []const u8, limit: usize) Allocator.Error!FindResult {
    const case_sensitive = fuzzy.hasUpper(query);
    var terms: std.ArrayList([]const u8) = .empty;
    var words = std.mem.tokenizeScalar(u8, query, ' ');
    while (words.next()) |word| {
        try terms.append(arena, if (case_sensitive) word else try std.ascii.allocLowerString(arena, word));
    }
    if (terms.items.len == 0) return .{ .matches = &.{}, .total = 0 };

    const Candidate = struct { score: i32, line: Line };
    const Queue = std.PriorityQueue(Candidate, void, struct {
        // Worst first: lower score, then the later line.
        fn order(_: void, a: Candidate, b: Candidate) std.math.Order {
            if (a.score != b.score) return std.math.order(a.score, b.score);
            return std.math.order(b.line.number, a.line.number);
        }
    }.order);
    var best: Queue = .empty;
    var matcher = fuzzy.Matcher.init(arena);
    var cleaner = Cleaner.init(arena);
    var total: u64 = 0;

    var it = LineIterator.init(text);
    lines: while (it.next()) |line| {
        const cleaned = try cleaner.cleanLine(text, line);
        var score: i32 = 0;
        for (terms.items) |term| {
            score += (try matcher.match(cleaned, term, case_sensitive, null)) orelse continue :lines;
        }
        total += 1;
        if (limit == 0) continue;
        const candidate = Candidate{ .score = score, .line = line };
        if (best.count() < limit) {
            try best.push(arena, candidate);
        } else if (best.peek().?.score < score) {
            // Equal scores never displace: the earlier line already won.
            _ = best.pop();
            try best.push(arena, candidate);
        }
    }

    const winners = try arena.alloc(FindMatch, best.count());
    var index = winners.len;
    while (best.pop()) |candidate| {
        index -= 1;
        const cleaned = try cleanAlloc(arena, candidate.line.bytes(text));
        var positions: std.ArrayList(u32) = .empty;
        for (terms.items) |term| _ = try matcher.match(cleaned, term, case_sensitive, &positions);
        std.mem.sort(u32, positions.items, {}, std.sort.asc(u32));
        winners[index] = .{
            .line = candidate.line,
            .text = cleaned,
            .score = candidate.score,
            .positions = dedupeSorted(positions.items),
        };
    }
    return .{ .matches = winners, .total = total };
}

fn dedupeSorted(items: []u32) []u32 {
    if (items.len == 0) return items;
    var kept: usize = 1;
    for (items[1..]) |item| {
        if (item != items[kept - 1]) {
            items[kept] = item;
            kept += 1;
        }
    }
    return items[0..kept];
}

// --- grep ------------------------------------------------------------------------

pub const GrepOptions = struct {
    /// Treat the pattern as a POSIX extended regex (see `regex.zig`).
    regex: bool = false,
    ignore_case: bool = false,
    /// Matches kept; later ones are only counted.
    limit: usize = 100,
};

pub const Span = struct { start: u32, end: u32 };

pub const GrepMatch = struct {
    line: Line,
    /// The cleaned line, which `spans` index.
    text: []const u8,
    spans: []const Span,
};

pub const GrepResult = struct {
    /// In line order.
    matches: []const GrepMatch,
    /// How many lines matched at all.
    total: u64,
};

/// Lines containing `pattern`, as a substring or a regex, with the matched
/// spans. A substring search reports every occurrence on a line; a regex
/// reports its leftmost-longest match.
pub fn grep(arena: Allocator, text: []const u8, pattern: []const u8, options: GrepOptions) (Allocator.Error || regex.Error)!GrepResult {
    var compiled: ?regex.Regex = null;
    // The regex matcher allocates per call; a scratch arena reset for every
    // line keeps a large input from accumulating that.
    var scratch_state = std.heap.ArenaAllocator.init(arena);
    defer scratch_state.deinit();
    if (options.regex) {
        compiled = try regex.compileOptions(arena, pattern, .{ .icase = options.ignore_case });
        compiled.?.allocator = scratch_state.allocator();
    }
    const needle = if (options.ignore_case and !options.regex) try std.ascii.allocLowerString(arena, pattern) else pattern;

    var matches: std.ArrayList(GrepMatch) = .empty;
    var spans: std.ArrayList(Span) = .empty;
    var cleaner = Cleaner.init(arena);
    var total: u64 = 0;
    // A plain line reads the same raw and cleaned, so one search through the
    // whole text finds the next plain line worth looking at; the lines in
    // between cost only their splitting.
    const skip_ahead = !options.regex and needle.len != 0 and std.mem.indexOfAny(u8, needle, "\r\n") == null;
    var next_hit: ?usize = if (skip_ahead) findSubstring(text, needle, 0, options.ignore_case) else null;
    var it = LineIterator.init(text);
    while (it.next()) |line| {
        if (skip_ahead and line.plain) {
            if (next_hit) |hit| {
                if (hit < line.start) next_hit = findSubstring(text, needle, line.start, options.ignore_case);
            }
            const hit = next_hit orelse continue;
            if (hit >= line.end) continue;
        }
        const cleaned = try cleaner.cleanLine(text, line);
        spans.clearRetainingCapacity();
        if (compiled) |*re| {
            _ = scratch_state.reset(.retain_capacity);
            const found = (try re.match(cleaned)) orelse continue;
            const whole = found.groups[0] orelse continue;
            try spans.append(arena, .{ .start = @intCast(whole.start), .end = @intCast(whole.end) });
        } else {
            if (needle.len == 0) {
                try spans.append(arena, .{ .start = 0, .end = 0 });
            } else {
                var from: usize = 0;
                while (findSubstring(cleaned, needle, from, options.ignore_case)) |at| {
                    try spans.append(arena, .{ .start = @intCast(at), .end = @intCast(at + needle.len) });
                    from = at + needle.len;
                }
            }
            if (spans.items.len == 0) continue;
        }
        total += 1;
        if (matches.items.len < options.limit) {
            try matches.append(arena, .{
                .line = line,
                .text = if (cleaned.ptr == line.bytes(text).ptr) cleaned else try arena.dupe(u8, cleaned),
                .spans = try arena.dupe(Span, spans.items),
            });
        }
    }
    return .{ .matches = matches.items, .total = total };
}

/// Rough frequency of each byte in program output, higher for more common:
/// spaces and lowercase letters in English order, then digits and the usual
/// punctuation, uppercase letters, and everything else.
const byte_frequency: [256]u8 = blk: {
    var table = [_]u8{1} ** 256;
    for ("etaoinsrhldcumfpgwybvkxjqz", 0..) |letter, rank| {
        table[letter] = 200 - rank * 6;
        table[std.ascii.toUpper(letter)] = 60 - rank * 2;
    }
    for ("0123456789") |digit| table[digit] = 120;
    for ("_:./-=,()[]'\"") |punct| table[punct] = 90;
    table[' '] = 255;
    break :blk table;
};

/// Next index of `needle` in `hay` at or after `from`; with `ignore_case`,
/// `needle` must be lowercase. The scan is a vectorised search for the
/// needle's rarest byte, so a long text is mostly skipped over, and each
/// candidate is checked in full.
fn findSubstring(hay: []const u8, needle: []const u8, from: usize, ignore_case: bool) ?usize {
    if (needle.len > hay.len) return null;
    const last = hay.len - needle.len;
    var anchor: usize = 0;
    for (needle, 0..) |byte, i| {
        if (byte_frequency[byte] < byte_frequency[needle[anchor]]) anchor = i;
    }
    // The anchor byte of a match starting at `last` sits at `last + anchor`.
    const region = hay[0 .. last + anchor + 1];
    var at = from + anchor;
    while (at < region.len) {
        at = (if (ignore_case) fuzzy.indexOfFolded(region, at, needle[anchor]) else std.mem.indexOfScalarPos(u8, region, at, needle[anchor])) orelse return null;
        const start = at - anchor;
        const candidate = hay[start..][0..needle.len];
        if (if (ignore_case) std.ascii.eqlIgnoreCase(candidate, needle) else std.mem.eql(u8, candidate, needle)) return start;
        at += 1;
    }
    return null;
}

// `std.mem.indexOf` builds a 256-entry skip table on every call once the
// haystack passes 52 bytes, which on millions of short lines costs more than
// the search. These search the way `findSubstring` does.

fn find(hay: []const u8, needle: []const u8) ?usize {
    return findSubstring(hay, needle, 0, false);
}

fn findPos(hay: []const u8, from: usize, needle: []const u8) ?usize {
    return findSubstring(hay, needle, from, false);
}

fn findLast(hay: []const u8, needle: []const u8) ?usize {
    if (needle.len > hay.len) return null;
    var at = hay.len - needle.len + 1;
    while (at > 0) {
        at -= 1;
        if (std.mem.eql(u8, hay[at..][0..needle.len], needle)) return at;
    }
    return null;
}

// --- failures ----------------------------------------------------------------------

pub const Framework = enum { cargo, pytest, go, jest, vitest, zig, unittest, junit, mocha, rspec, generic };
pub const FrameworkSet = std.EnumSet(Framework);

pub const Failure = struct {
    framework: Framework,
    /// The test's name, or for a generic error its location.
    name: []const u8,
    /// One-based line where the failure was first reported.
    line: u64,
    /// `file:line[:column]`, when the output names one.
    location: ?[]const u8 = null,
    /// One line of explanation (the assertion or error message).
    reason: ?[]const u8 = null,
};

pub const Counts = struct {
    passed: ?u64 = null,
    failed: ?u64 = null,
    skipped: ?u64 = null,
};

pub const Report = struct {
    failures: []const Failure,
    /// Failures past `max_failures`, counted but not kept.
    omitted: u64,
    /// Totals from the summaries the frameworks print; null when none did.
    counts: Counts,
    /// Frameworks whose output was recognised.
    frameworks: FrameworkSet,

    pub fn anyFailed(self: Report) bool {
        return self.failures.len != 0 or self.omitted != 0 or (self.counts.failed orelse 0) != 0;
    }

    /// 1 when anything failed, 0 when test output was recognised and nothing
    /// failed, 2 when there was no recognisable test output at all.
    pub fn status(self: Report) u8 {
        if (self.anyFailed()) return 1;
        return if (self.frameworks.count() == 0) 2 else 0;
    }
};

/// More failures than this are counted in `Report.omitted`.
pub const max_failures = 10_000;

/// Reasons and names longer than this are cut.
const max_field = 300;

/// Failed tests and checks, recognised per framework: cargo test, pytest,
/// go test, Jest, Vitest, Zig's test runner and build system, unittest,
/// Maven/Gradle (JUnit), Mocha and RSpec, plus compiler-style errors that
/// name a `file:line` for anything else. One pass; each line costs a few
/// prefix and suffix comparisons, and only failures allocate.
pub fn failures(arena: Allocator, text: []const u8) Allocator.Error!Report {
    var r = Recognizer{ .arena = arena };
    var cleaner = Cleaner.init(arena);
    var it = LineIterator.init(text);
    while (it.next()) |line| {
        const cleaned = try cleaner.cleanLine(text, line);
        try r.feed(line.number, cleaned, classify(cleaned));
    }
    return r.report();
}

pub const Stats = struct {
    lines: u64 = 0,
    bytes: u64 = 0,
    error_lines: u64 = 0,
    failure_lines: u64 = 0,
    warning_lines: u64 = 0,
    first_error: ?u64 = null,
    first_failure: ?u64 = null,
    first_warning: ?u64 = null,
    longest_line: u64 = 0,
    frameworks: FrameworkSet = .initEmpty(),
};

/// Line and byte counts, how many lines `classify` calls errors, failures
/// and warnings (and where each first appears), and the test frameworks
/// whose output appears.
pub fn stats(arena: Allocator, text: []const u8) Allocator.Error!Stats {
    var s = Stats{ .bytes = text.len };
    var r = Recognizer{ .arena = arena };
    var cleaner = Cleaner.init(arena);
    var it = LineIterator.init(text);
    while (it.next()) |line| {
        const cleaned = try cleaner.cleanLine(text, line);
        const kind = classify(cleaned);
        s.longest_line = @max(s.longest_line, line.end - line.start);
        switch (kind) {
            .@"error" => {
                s.error_lines += 1;
                if (s.first_error == null) s.first_error = line.number;
            },
            .failure => {
                s.failure_lines += 1;
                if (s.first_failure == null) s.first_failure = line.number;
            },
            .warning => {
                s.warning_lines += 1;
                if (s.first_warning == null) s.first_warning = line.number;
            },
            else => {},
        }
        try r.feed(line.number, cleaned, kind);
    }
    s.lines = it.number;
    s.frameworks = r.frameworks;
    return s;
}

const Pending = union(enum) {
    /// The next non-blank line explains failure `index`.
    reason: u32,
    /// The next line explains failure `index` if it is a Go log line.
    go_log: u32,
    /// The next line explains failure `index` if it starts with `→`.
    arrow: u32,
    /// A rustc-style error waiting for its `--> file:line:col` line.
    rust_location: struct { message: []const u8, line: u64 },
};

/// The per-framework state machines behind `failures` and `stats`.
const Recognizer = struct {
    arena: Allocator,
    list: std.ArrayList(Failure) = .empty,
    by_name: std.StringHashMapUnmanaged(u32) = .empty,
    omitted: u64 = 0,
    counts: Counts = .{},
    frameworks: FrameworkSet = .initEmpty(),

    pending: ?Pending = null,
    /// Inside cargo's `---- name stdout ----` section for this failure.
    cargo_section: ?u32 = null,
    /// Inside cargo's closing `failures:` list of names.
    cargo_list: bool = false,
    /// `go test -v`: the test whose `=== RUN` came last, and the first log
    /// line each test printed.
    go_current: ?[]const u8 = null,
    go_logs: std.StringHashMapUnmanaged(GoLog) = .empty,
    /// Zig's `N/M name...` header, when its result is still to come.
    zig_name: ?[]const u8 = null,
    zig_message: ?[]const u8 = null,
    zig_line: u64 = 0,
    unittest_ran: ?u64 = null,
    /// Reading the traceback of this unittest failure.
    unittest_failure: ?u32 = null,
    /// Reading a Python traceback outside unittest; its innermost frame.
    traceback: bool = false,
    traceback_location: ?[]const u8 = null,
    /// Mocha's and RSpec's numbered failure details.
    numbered: enum { none, mocha, rspec } = .none,
    numbered_name: std.ArrayList(u8) = .empty,
    numbered_line: u64 = 0,
    numbered_open: bool = false,
    last_jest_suite: ?u32 = null,

    const GoLog = struct { location: []const u8, message: []const u8 };

    fn report(self: *Recognizer) Report {
        return .{
            .failures = self.list.items,
            .omitted = self.omitted,
            .counts = self.counts,
            .frameworks = self.frameworks,
        };
    }

    fn detect(self: *Recognizer, framework: Framework) void {
        self.frameworks.insert(framework);
    }

    fn dupe(self: *Recognizer, s: []const u8) Allocator.Error![]const u8 {
        return self.arena.dupe(u8, utf8Prefix(trim(s), max_field));
    }

    /// Records a failure, or returns the one already recorded under `name`.
    fn add(self: *Recognizer, framework: Framework, name_text: []const u8, line: u64) Allocator.Error!?u32 {
        self.detect(framework);
        const name = utf8Prefix(trim(name_text), max_field);
        if (self.by_name.get(name)) |index| return index;
        if (self.list.items.len >= max_failures) {
            self.omitted += 1;
            return null;
        }
        const owned = try self.arena.dupe(u8, name);
        const index: u32 = @intCast(self.list.items.len);
        try self.list.append(self.arena, .{ .framework = framework, .name = owned, .line = line });
        try self.by_name.put(self.arena, owned, index);
        return index;
    }

    /// Like `add`, for runners that print a short name first (`✕ adds`) and
    /// the full path later (`● sum › adds`): the full name replaces the
    /// short one instead of making a second entry.
    fn addNested(self: *Recognizer, framework: Framework, name_text: []const u8, line: u64) Allocator.Error!?u32 {
        const name = utf8Prefix(trim(name_text), max_field);
        if (self.by_name.get(name) == null) {
            inline for ([_][]const u8{ " › ", " > " }) |separator| {
                var from: usize = 0;
                while (findPos(name, from, separator)) |at| {
                    const suffix = name[at + separator.len ..];
                    if (self.by_name.get(suffix)) |index| {
                        const owned = try self.arena.dupe(u8, name);
                        self.list.items[index].name = owned;
                        try self.by_name.put(self.arena, owned, index);
                        self.detect(framework);
                        return index;
                    }
                    from = at + separator.len;
                }
            }
        }
        return self.add(framework, name, line);
    }

    fn setReason(self: *Recognizer, index: ?u32, reason: []const u8) Allocator.Error!void {
        const i = index orelse return;
        const text = trim(reason);
        if (text.len == 0 or self.list.items[i].reason != null) return;
        self.list.items[i].reason = try self.dupe(text);
    }

    fn setLocation(self: *Recognizer, index: ?u32, location: []const u8) Allocator.Error!void {
        const i = index orelse return;
        self.list.items[i].location = try self.dupe(location);
    }

    fn addCounts(self: *Recognizer, framework: Framework, counts: Counts) void {
        self.detect(framework);
        if (counts.passed) |n| self.counts.passed = (self.counts.passed orelse 0) + n;
        if (counts.failed) |n| self.counts.failed = (self.counts.failed orelse 0) + n;
        if (counts.skipped) |n| self.counts.skipped = (self.counts.skipped orelse 0) + n;
    }

    fn feed(self: *Recognizer, number: u64, line: []const u8, kind: Kind) Allocator.Error!void {
        const t = trimLeft(line);
        if (t.len == 0) {
            self.cargo_list = false;
            if (self.pending) |p| switch (p) {
                .reason => {},
                else => self.pending = null,
            };
            return;
        }
        if (self.pending != null and try self.consumePending(t)) return;
        if (self.unittest_failure != null and try self.unittestTrace(line, t)) return;
        if (self.traceback and try self.pythonTrace(number, line, t)) return;
        if (self.numbered != .none and try self.numberedLine(number, line, t)) return;
        if (self.cargo_list) {
            if (startsWith(line, "    ")) {
                _ = try self.add(.cargo, t, number);
                return;
            }
            self.cargo_list = false;
        }
        if (self.cargo_section) |index| {
            if (startsWith(t, "thread '")) {
                if (find(t, "panicked at ")) |at| {
                    try self.cargoPanic(index, t[at + "panicked at ".len ..]);
                    return;
                }
            }
        }

        // Maven prefixes its lines with a level.
        var body = t;
        var bracketed = false;
        inline for ([_][]const u8{ "[ERROR] ", "[INFO] ", "[WARNING] ", "[WARN] " }) |prefix| {
            if (startsWith(t, prefix)) {
                body = trimLeft(t[prefix.len..]);
                bracketed = true;
                break;
            }
        }
        if (body.len == 0) return;

        if (try self.cargo(number, line, body)) return;
        if (try self.pytest(number, line, body)) return;
        if (try self.goTest(number, line, body)) return;
        if (try self.jest(number, body)) return;
        if (try self.zigTest(number, body)) return;
        if (try self.unittest(number, line)) return;
        if (try self.junit(number, line, body, bracketed)) return;
        if (try self.mochaOrRspec(number, line, body)) return;
        if (kind == .@"error") _ = try self.generic(number, line, t);
    }

    fn consumePending(self: *Recognizer, t: []const u8) Allocator.Error!bool {
        const p = self.pending.?;
        self.pending = null;
        switch (p) {
            .reason => |index| {
                try self.setReason(index, t);
                return true;
            },
            .go_log => |index| {
                const log = parseGoLog(t) orelse return false;
                try self.setLocation(index, log.location);
                try self.setReason(index, log.message);
                return true;
            },
            .arrow => |index| {
                if (!startsWith(t, "→ ")) return false;
                try self.setReason(index, t["→ ".len..]);
                return true;
            },
            .rust_location => |info| {
                if (!startsWith(t, "--> ")) return false;
                const location = trim(t[4..]);
                const index = try self.add(.generic, location, info.line);
                try self.setLocation(index, location);
                try self.setReason(index, info.message);
                return true;
            },
        }
    }

    // cargo test
    fn cargo(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        switch (t[0]) {
            'r' => if (startsWith(t, "running ") and (endsWith(t, " tests") or endsWith(t, " test"))) {
                self.detect(.cargo);
                return true;
            },
            't' => {
                if (startsWith(t, "test result: ")) {
                    self.cargo_section = null;
                    self.addCounts(.cargo, parseCounts(t));
                    return true;
                }
                if (startsWith(line, "test ")) {
                    if (endsWith(line, " ... ok") or endsWith(line, " ... ignored")) {
                        self.detect(.cargo);
                        return true;
                    }
                    const at = find(line, " ... ") orelse return false;
                    const outcome = line[at + 5 ..];
                    if (startsWith(outcome, "FAILED")) {
                        _ = try self.add(.cargo, line[5..at], number);
                    } else if (startsWith(outcome, "ok") or startsWith(outcome, "ignored") or startsWith(outcome, "bench")) {
                        self.detect(.cargo);
                    } else return false;
                    return true;
                }
            },
            '-' => if (startsWith(t, "---- ") and endsWith(t, " ----") and t.len > 10) {
                var name = t[5 .. t.len - 5];
                inline for ([_][]const u8{ " stdout", " stderr" }) |stream| {
                    if (endsWith(name, stream)) name = name[0 .. name.len - stream.len];
                }
                self.cargo_section = try self.add(.cargo, name, number);
                return true;
            },
            'f' => if (std.mem.eql(u8, t, "failures:") and self.frameworks.contains(.cargo)) {
                self.cargo_section = null;
                self.cargo_list = true;
                return true;
            },
            else => {},
        }
        return false;
    }

    /// `thread 'x' panicked at src/lib.rs:6:29:` with the message on the next
    /// line, or the older `panicked at 'message', src/lib.rs:6:29`.
    fn cargoPanic(self: *Recognizer, index: u32, rest: []const u8) Allocator.Error!void {
        if (rest.len > 0 and rest[0] == '\'') {
            if (findLast(rest, "', ")) |close| {
                try self.setReason(index, rest[1..close]);
                try self.setLocation(index, rest[close + 3 ..]);
                return;
            }
        }
        try self.setLocation(index, std.mem.trimEnd(u8, rest, ":"));
        self.pending = .{ .reason = index };
    }

    // pytest
    fn pytest(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        // Each recogniser first rules lines out by their first byte, which
        // settles nearly every line of a long log with one comparison.
        switch (t[0]) {
            'F', 'E', 'P', 'S', 'c', '=', '0'...'9' => {},
            else => if (!endsWith(t, "%]")) return false,
        }
        inline for ([_][]const u8{ "FAILED ", "ERROR " }) |prefix| {
            if (startsWith(line, prefix) and line.len > prefix.len and line[prefix.len] != '(') {
                const rest = line[prefix.len..];
                const dash = find(rest, " - ");
                const index = try self.add(.pytest, if (dash) |at| rest[0..at] else rest, number);
                if (dash) |at| try self.setReason(index, rest[at + 3 ..]);
                return true;
            }
        }
        if (startsWith(t, "collected ") or startsWith(t, "collecting ") or
            startsWith(line, "PASSED ") or startsWith(line, "SKIPPED "))
        {
            self.detect(.pytest);
            return true;
        }
        // Verbose and progress lines end with a percentage.
        if (endsWith(t, "%]")) {
            inline for ([_][]const u8{ " FAILED", " ERROR" }) |word| {
                if (find(t, word)) |at| {
                    if (find(t[0..at], "::") != null) {
                        _ = try self.add(.pytest, t[0..at], number);
                        return true;
                    }
                }
            }
            if (find(t, ".py") != null) {
                self.detect(.pytest);
                return true;
            }
            return false;
        }
        // `==== 2 failed, 1 passed in 0.02s ====`, or the same unframed with -q.
        if (t[0] != '=' and !std.ascii.isDigit(t[0])) return false;
        const inner = std.mem.trim(u8, t, "= ");
        if (inner.len > 0 and isPytestSummary(inner)) {
            self.addCounts(.pytest, parseCounts(inner));
            return true;
        }
        return false;
    }

    // go test
    fn goTest(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        switch (t[0]) {
            '=', '-', 'o', 'F', 'P' => {},
            // Otherwise only the indented log lines of a run already seen.
            else => if (line.len == t.len or !self.frameworks.contains(.go)) return false,
        }
        if (startsWith(t, "=== RUN ")) {
            self.detect(.go);
            self.go_current = try self.arena.dupe(u8, trim(t["=== RUN ".len..]));
            return true;
        }
        if (startsWith(t, "=== PAUSE ") or startsWith(t, "=== CONT ")) return true;
        if (startsWith(t, "--- FAIL: ")) {
            const rest = t["--- FAIL: ".len..];
            const name = if (findLast(rest, " (")) |at| rest[0..at] else rest;
            const index = try self.add(.go, name, number);
            self.addCounts(.go, .{ .failed = 1 });
            if (self.go_logs.get(trim(name))) |log| {
                try self.setLocation(index, log.location);
                try self.setReason(index, log.message);
            } else if (index) |i| {
                self.pending = .{ .go_log = i };
            }
            return true;
        }
        if (startsWith(t, "--- PASS: ")) {
            self.addCounts(.go, .{ .passed = 1 });
            return true;
        }
        if (startsWith(t, "--- SKIP: ")) {
            self.addCounts(.go, .{ .skipped = 1 });
            return true;
        }
        if (startsWith(line, "ok  \t") or startsWith(line, "FAIL\t")) {
            self.detect(.go);
            if (find(line, " [build failed]") orelse find(line, " [setup failed]")) |at| {
                const index = try self.add(.go, line[5..at], number);
                try self.setReason(index, line[at + 2 .. line.len - 1]);
            }
            return true;
        }
        if (self.frameworks.contains(.go)) {
            if (std.mem.eql(u8, line, "PASS") or std.mem.eql(u8, line, "FAIL")) return true;
            if (line.len > t.len) {
                if (parseGoLog(t)) |log| {
                    if (self.go_current) |name| {
                        const entry = try self.go_logs.getOrPut(self.arena, name);
                        if (!entry.found_existing) entry.value_ptr.* = .{
                            .location = try self.dupe(log.location),
                            .message = try self.dupe(log.message),
                        };
                    }
                    return true;
                }
            }
        }
        return false;
    }

    // Jest and Vitest
    fn jest(self: *Recognizer, number: u64, t: []const u8) Allocator.Error!bool {
        switch (t[0]) {
            // `●`, `✕`, `✗` and `❯` start with 0xe2, `×` with 0xc3.
            'P', 'F', 'T', 0xc3, 0xe2 => {},
            else => return false,
        }
        const vitest_seen = self.frameworks.contains(.vitest);
        if (startsWith(t, "PASS ") and looksLikePath(trimLeft(t[5..]))) {
            self.detect(if (vitest_seen) .vitest else .jest);
            return true;
        }
        if (startsWith(t, "FAIL ")) {
            const rest = trimLeft(t[5..]);
            if (rest.len == 0 or rest[0] == '(' or !looksLikePath(rest)) return false;
            if (find(rest, " > ") != null) {
                const index = try self.addNested(.vitest, rest, number);
                if (index) |i| self.pending = .{ .reason = i };
            } else {
                self.last_jest_suite = try self.add(if (vitest_seen) .vitest else .jest, rest, number);
            }
            return true;
        }
        if (startsWith(t, "● ")) {
            const name = t["● ".len..];
            if (startsWith(name, "Console")) return true;
            if (std.mem.eql(u8, trim(name), "Test suite failed to run")) {
                if (self.last_jest_suite) |i| self.pending = .{ .reason = i };
                return true;
            }
            const index = try self.addNested(.jest, name, number);
            if (index) |i| self.pending = .{ .reason = i };
            return true;
        }
        inline for ([_][]const u8{ "✕ ", "✗ " }) |mark| {
            if (startsWith(t, mark)) {
                _ = try self.addNested(.jest, stripDuration(t[mark.len..]), number);
                return true;
            }
        }
        if (startsWith(t, "× ")) {
            const index = try self.addNested(.vitest, stripDuration(t["× ".len..]), number);
            if (index) |i| self.pending = .{ .arrow = i };
            return true;
        }
        if (startsWith(t, "Tests:")) {
            self.addCounts(.jest, parseCounts(t));
            return true;
        }
        if (startsWith(t, "Test Suites:")) {
            self.detect(.jest);
            return true;
        }
        if (startsWith(t, "Tests ") and leadingNumber(trimLeft(t[6..])) != null) {
            self.addCounts(.vitest, parseCounts(t));
            return true;
        }
        if (startsWith(t, "Test Files ") or startsWith(t, "❯ ")) {
            self.detect(.vitest);
            return true;
        }
        return false;
    }

    // Zig: the test runner (`2/3 main.test.fails...FAIL (TestExpectedEqual)`)
    // and the build system (`error: 'main.test.fails' failed:`).
    fn zigTest(self: *Recognizer, number: u64, t: []const u8) Allocator.Error!bool {
        switch (t[0]) {
            '0'...'9', 'F', 'A', 'e', 'B' => {},
            else => return false,
        }
        if (std.ascii.isDigit(t[0])) {
            if (parseZigHeader(t)) |header| {
                self.detect(.zig);
                self.zig_name = null;
                if (std.mem.eql(u8, header.rest, "OK") or std.mem.eql(u8, header.rest, "SKIP")) return true;
                if (startsWith(header.rest, "FAIL (")) {
                    const index = try self.add(.zig, header.name, number);
                    try self.setReason(index, parenthesised(header.rest));
                    return true;
                }
                // The failure message interrupts the header; `FAIL (...)` follows.
                self.zig_name = try self.dupe(header.name);
                self.zig_line = number;
                self.zig_message = if (trim(header.rest).len != 0) try self.dupe(header.rest) else null;
                return true;
            }
            // `1 passed; 1 skipped; 1 failed.`
            if (find(t, " passed; ") != null and endsWith(t, ".")) {
                self.addCounts(.zig, parseCounts(t));
                return true;
            }
        }
        if (startsWith(t, "FAIL (")) {
            const name = self.zig_name orelse return false;
            const index = try self.add(.zig, name, self.zig_line);
            try self.setReason(index, self.zig_message orelse parenthesised(t));
            self.zig_name = null;
            return true;
        }
        if (startsWith(t, "All ") and endsWith(t, " tests passed.")) {
            const n = std.fmt.parseInt(u64, t[4 .. t.len - " tests passed.".len], 10) catch return false;
            self.addCounts(.zig, .{ .passed = n, .failed = 0 });
            return true;
        }
        if (startsWith(t, "error: '")) {
            const rest = t["error: '".len..];
            const close = find(rest, "' failed") orelse return false;
            const index = try self.add(.zig, rest[0..close], number);
            const after = trim(std.mem.trimStart(u8, rest[close + "' failed".len ..], ":"));
            if (after.len != 0) {
                try self.setReason(index, after);
            } else if (index) |i| {
                self.pending = .{ .reason = i };
            }
            return true;
        }
        // `Build Summary: 1/3 steps succeeded (1 failed); 1/3 tests passed (1 skipped, 1 failed)`
        if (startsWith(t, "Build Summary: ")) {
            self.detect(.zig);
            const at = find(t, " tests passed") orelse return true;
            var start = at;
            while (start > 0 and t[start - 1] != ' ' and t[start - 1] != ';') start -= 1;
            const slash = std.mem.indexOfScalar(u8, t[start..at], '/') orelse return true;
            var counts = parseCounts(t[at..]);
            counts.passed = std.fmt.parseInt(u64, t[start .. start + slash], 10) catch null;
            if (counts.failed == null) counts.failed = 0;
            self.addCounts(.zig, counts);
            return true;
        }
        return false;
    }

    // Python's unittest
    fn unittest(self: *Recognizer, number: u64, line: []const u8) Allocator.Error!bool {
        inline for ([_][]const u8{ "FAIL: ", "ERROR: " }) |prefix| {
            if (startsWith(line, prefix) and endsWith(line, ")") and find(line, " (") != null) {
                self.unittest_failure = try self.add(.unittest, line[prefix.len..], number);
                return true;
            }
        }
        inline for ([_][]const u8{ " ... FAIL", " ... ERROR" }) |suffix| {
            if (endsWith(line, suffix)) {
                _ = try self.add(.unittest, line[0 .. line.len - suffix.len], number);
                return true;
            }
        }
        if (endsWith(line, " ... ok") or endsWith(line, " ... expected failure") or
            (startsWith(line, "test") and find(line, " ... skipped") != null))
        {
            self.detect(.unittest);
            return true;
        }
        if (startsWith(line, "Ran ") and find(line, " test") != null) {
            const end = std.mem.indexOfScalarPos(u8, line, 4, ' ') orelse return false;
            self.unittest_ran = std.fmt.parseInt(u64, line[4..end], 10) catch return false;
            self.detect(.unittest);
            return true;
        }
        if (self.unittest_ran) |ran| {
            if (startsWith(line, "FAILED (") or std.mem.eql(u8, line, "OK") or startsWith(line, "OK (")) {
                const failed = keyedCount(line, "failures=") + keyedCount(line, "errors=") + keyedCount(line, "unexpected successes=");
                const skipped = keyedCount(line, "skipped=");
                const expected = keyedCount(line, "expected failures=");
                self.addCounts(.unittest, .{
                    .passed = ran -| (failed + skipped + expected),
                    .failed = failed,
                    .skipped = skipped,
                });
                self.unittest_ran = null;
                return true;
            }
        }
        return false;
    }

    /// Inside a unittest failure: the innermost `File` frame is the
    /// location, the exception line that ends the traceback the reason.
    fn unittestTrace(self: *Recognizer, line: []const u8, t: []const u8) Allocator.Error!bool {
        if (startsWith(line, "===") or startsWith(line, "Ran ")) {
            self.unittest_failure = null;
            return false;
        }
        if (startsWith(t, "File \"")) {
            if (parsePythonFrame(t)) |frame| try self.setLocation(self.unittest_failure, try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ frame.path, frame.line }));
            return true;
        }
        if (line[0] != ' ' and !startsWith(line, "Traceback") and !startsWith(line, "---")) {
            try self.setReason(self.unittest_failure, line);
            self.unittest_failure = null;
        }
        return true;
    }

    /// A Python traceback outside unittest becomes a generic failure at its
    /// innermost frame.
    fn pythonTrace(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        if (startsWith(t, "File \"")) {
            if (parsePythonFrame(t)) |frame| self.traceback_location = try std.fmt.allocPrint(self.arena, "{s}:{s}", .{ frame.path, frame.line });
            return true;
        }
        if (line[0] == ' ' or startsWith(line, "Traceback")) return true;
        self.traceback = false;
        const location = self.traceback_location orelse return false;
        const index = try self.add(.generic, location, number);
        try self.setLocation(index, location);
        try self.setReason(index, line);
        return true;
    }

    // Maven Surefire and Gradle (JUnit)
    fn junit(self: *Recognizer, number: u64, line: []const u8, body: []const u8, bracketed: bool) Allocator.Error!bool {
        if (startsWith(body, "Tests run: ")) {
            self.detect(.junit);
            // Per-class lines carry a time; the totals line does not.
            if (find(body, "Time elapsed") == null) {
                const failed = keyedCount(body, "Failures: ") + keyedCount(body, "Errors: ");
                const skipped = keyedCount(body, "Skipped: ");
                self.addCounts(.junit, .{
                    .passed = keyedCount(body, "Tests run: ") -| (failed + skipped),
                    .failed = failed,
                    .skipped = skipped,
                });
            }
            return true;
        }
        // `... <<< FAILURE!` and `... <<< ERROR!` end their lines.
        if (if (endsWith(body, "!")) find(body, "<<< FAILURE!") orelse find(body, "<<< ERROR!") else null) |marker| {
            var name = body[0..marker];
            if (find(name, "Time elapsed")) |at| name = name[0..at];
            name = std.mem.trimEnd(u8, name, " -");
            const index = try self.add(.junit, name, number);
            if (index) |i| self.pending = .{ .reason = i };
            return true;
        }
        if (!bracketed and line[0] != ' ' and line[0] != '\t' and !startsWith(line, "> ") and
            endsWith(line, "ED") and find(line, " > ") != null)
        {
            if (endsWith(line, " FAILED")) {
                const index = try self.add(.junit, line[0 .. line.len - " FAILED".len], number);
                if (index) |i| self.pending = .{ .reason = i };
                return true;
            }
            if (endsWith(line, " PASSED") or endsWith(line, " SKIPPED")) {
                self.detect(.junit);
                return true;
            }
        }
        // Gradle: `3 tests completed, 1 failed, 1 skipped`
        if (std.ascii.isDigit(body[0]) and find(body, " tests completed") != null) {
            self.addCounts(.junit, parseCounts(body));
            return true;
        }
        return false;
    }

    fn mochaOrRspec(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        switch (t[0]) {
            '0'...'9', 'F', 'r' => {},
            else => return false,
        }
        if (std.ascii.isDigit(t[0])) {
            const n = leadingNumber(t) orelse return false;
            var digits: usize = 0;
            while (digits < t.len and std.ascii.isDigit(t[digits])) digits += 1;
            const word = t[digits..];
            if (startsWith(word, " passing (")) {
                self.addCounts(.mocha, .{ .passed = n });
                return true;
            }
            if (startsWith(word, " failing") and self.frameworks.contains(.mocha)) {
                self.addCounts(.mocha, .{ .failed = n });
                self.numbered = .mocha;
                return true;
            }
            if (startsWith(word, " pending") and self.frameworks.contains(.mocha)) {
                self.addCounts(.mocha, .{ .skipped = n });
                return true;
            }
            if (startsWith(word, " example")) {
                self.addCounts(.rspec, parseCounts(t));
                return true;
            }
            return false;
        }
        if (std.mem.eql(u8, line, "Failures:")) {
            self.detect(.rspec);
            self.numbered = .rspec;
            return true;
        }
        if (startsWith(line, "rspec ")) {
            const hash = find(line, " # ") orelse return false;
            const index = try self.addNested(.rspec, line[hash + 3 ..], number);
            try self.setLocation(index, line["rspec ".len..hash]);
            return true;
        }
        if (startsWith(line, "Finished in ") and self.numbered == .rspec) {
            self.numbered = .none;
            return true;
        }
        return false;
    }

    /// Mocha's `  1) Suite` / `       nested` / `         title:` and RSpec's
    /// `  1) Description`, each followed by the message.
    fn numberedLine(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        if (line[0] == ' ') {
            if (numberedEntry(t)) |title| {
                self.numbered_name.clearRetainingCapacity();
                try self.numbered_name.appendSlice(self.arena, title);
                self.numbered_line = number;
                self.numbered_open = true;
                if (self.numbered == .rspec) return self.closeNumbered();
                if (endsWith(title, ":")) return self.closeNumbered();
                return true;
            }
            if (self.numbered_open and self.numbered == .mocha) {
                try self.numbered_name.append(self.arena, ' ');
                try self.numbered_name.appendSlice(self.arena, trim(t));
                if (endsWith(t, ":")) return self.closeNumbered();
                return true;
            }
        }
        if (line[0] != ' ' and self.numbered == .rspec and !startsWith(line, "rspec ")) {
            if (startsWith(line, "Finished in ") or std.mem.eql(u8, line, "Failed examples:")) self.numbered = .none;
        }
        return false;
    }

    fn closeNumbered(self: *Recognizer) Allocator.Error!bool {
        self.numbered_open = false;
        const framework: Framework = if (self.numbered == .mocha) .mocha else .rspec;
        const name = std.mem.trimEnd(u8, self.numbered_name.items, ":");
        const index = try self.addNested(framework, name, self.numbered_line);
        if (index) |i| self.pending = .{ .reason = i };
        return true;
    }

    /// Compiler-style errors with a location: `src/a.c:10:5: error: ...`,
    /// `src/a.ts(3,5): error TS2322: ...`, rustc's `error[E0308]: ...`
    /// followed by `--> src/main.rs:4:5`, and Python tracebacks.
    fn generic(self: *Recognizer, number: u64, line: []const u8, t: []const u8) Allocator.Error!bool {
        if (startsWith(line, "Traceback (most recent call last)")) {
            self.traceback = true;
            self.traceback_location = null;
            return true;
        }
        if (startsWith(t, "error[") or startsWith(t, "error: ")) {
            self.pending = .{ .rust_location = .{ .message = try self.dupe(t), .line = number } };
            return true;
        }
        inline for ([_][]const u8{ ": error", ": fatal error" }) |marker| {
            if (find(t, marker)) |at| {
                var location = t[0..at];
                var buf: [max_field]u8 = undefined;
                // TypeScript: `path(3,5)`.
                if (endsWith(location, ")")) {
                    if (std.mem.lastIndexOfScalar(u8, location, '(')) |open| {
                        const inside = location[open + 1 .. location.len - 1];
                        if (std.mem.indexOfScalar(u8, inside, ',')) |comma| {
                            location = std.fmt.bufPrint(&buf, "{s}:{s}:{s}", .{ location[0..open], inside[0..comma], inside[comma + 1 ..] }) catch return false;
                        }
                    }
                }
                if (!looksLikeLocation(location)) return false;
                const index = try self.add(.generic, location, number);
                try self.setLocation(index, location);
                try self.setReason(index, t[at + 2 ..]);
                return true;
            }
        }
        return false;
    }
};

/// `N word` pairs anywhere in `text`, mapped onto passed, failed and skipped.
/// A total ("4 total", "3 examples", "3 tests completed") fills in passed
/// when no pass count is given.
fn parseCounts(text: []const u8) Counts {
    var counts = Counts{};
    var total: ?u64 = null;
    var i: usize = 0;
    while (i < text.len) {
        if (!std.ascii.isDigit(text[i]) or (i > 0 and (std.ascii.isAlphanumeric(text[i - 1]) or text[i - 1] == '.' or text[i - 1] == '/'))) {
            i += 1;
            continue;
        }
        var n: u64 = 0;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) n = n *| 10 +| (text[i] - '0');
        if (i >= text.len or text[i] != ' ') continue;
        const word_start = i + 1;
        var end = word_start;
        while (end < text.len and std.ascii.isAlphabetic(text[end])) end += 1;
        const word = text[word_start..end];
        const words = struct {
            const passed = [_][]const u8{ "passed", "passing", "pass" };
            const failed = [_][]const u8{ "failed", "failing", "failures", "failure", "fail", "errors", "error" };
            const skipped = [_][]const u8{ "skipped", "skip", "ignored", "pending", "todo" };
            const totals = [_][]const u8{ "total", "examples", "example", "tests" };
        };
        if (inList(word, &words.passed)) {
            counts.passed = (counts.passed orelse 0) + n;
        } else if (inList(word, &words.failed)) {
            counts.failed = (counts.failed orelse 0) + n;
        } else if (inList(word, &words.skipped)) {
            counts.skipped = (counts.skipped orelse 0) + n;
        } else if (inList(word, &words.totals)) {
            total = n;
        }
        i = end;
    }
    if (counts.passed == null) {
        if (total) |n| counts.passed = n -| ((counts.failed orelse 0) + (counts.skipped orelse 0));
    }
    if (counts.failed == null and (counts.passed != null)) counts.failed = 0;
    return counts;
}

fn inList(word: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

/// pytest's closing line: counts, then ` in 0.02s`.
fn isPytestSummary(inner: []const u8) bool {
    if (startsWith(inner, "no tests ran in ")) return true;
    const at = findLast(inner, " in ") orelse return false;
    if (at == 0 or !std.ascii.isDigit(inner[0])) return false;
    const time = inner[at + 4 ..];
    if (time.len == 0 or !std.ascii.isDigit(time[0])) return false;
    const counts = parseCounts(inner[0..at]);
    return counts.passed != null or counts.failed != null or counts.skipped != null;
}

/// The number after `key` in `text` ("failures=2"), or 0.
fn keyedCount(text: []const u8, key: []const u8) u64 {
    const at = find(text, key) orelse return 0;
    return leadingNumber(text[at + key.len ..]) orelse 0;
}

fn leadingNumber(text: []const u8) ?u64 {
    var end: usize = 0;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    if (end == 0) return null;
    return std.fmt.parseInt(u64, text[0..end], 10) catch null;
}

/// `add_test.go:5: expected 4, got 3`.
fn parseGoLog(t: []const u8) ?struct { location: []const u8, message: []const u8 } {
    const go = find(t, ".go:") orelse return null;
    if (std.mem.indexOfScalar(u8, t[0..go], ' ') != null) return null;
    var i = go + 4;
    const digits = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == digits or !startsWith(t[i..], ": ")) return null;
    return .{ .location = t[0..i], .message = t[i + 2 ..] };
}

/// `  File "/x/test_mod.py", line 5, in test_add`.
fn parsePythonFrame(t: []const u8) ?struct { path: []const u8, line: []const u8 } {
    const rest = t["File \"".len..];
    const close = find(rest, "\", line ") orelse return null;
    const after = rest[close + "\", line ".len ..];
    var end: usize = 0;
    while (end < after.len and std.ascii.isDigit(after[end])) end += 1;
    if (end == 0) return null;
    return .{ .path = rest[0..close], .line = after[0..end] };
}

/// `2/3 main.test.fails...FAIL (TestExpectedEqual)`.
fn parseZigHeader(t: []const u8) ?struct { name: []const u8, rest: []const u8 } {
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == 0 or i >= t.len or t[i] != '/') return null;
    i += 1;
    const total = i;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == total or i >= t.len or t[i] != ' ') return null;
    const name_start = i + 1;
    const dots = findPos(t, name_start, "...") orelse return null;
    return .{ .name = t[name_start..dots], .rest = t[dots + 3 ..] };
}

fn parenthesised(t: []const u8) []const u8 {
    const open = std.mem.indexOfScalar(u8, t, '(') orelse return t;
    const close = std.mem.lastIndexOfScalar(u8, t, ')') orelse return t[open + 1 ..];
    return if (close > open) t[open + 1 .. close] else t[open + 1 ..];
}

/// `  1) Array` → `Array`.
fn numberedEntry(t: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) i += 1;
    if (i == 0 or !startsWith(t[i..], ") ")) return null;
    return trim(t[i + 2 ..]);
}

/// Drops a trailing duration: ` (5 ms)`, ` (5ms)`, ` 15ms`, ` 1.2s`.
fn stripDuration(name: []const u8) []const u8 {
    const t = trim(name);
    if (endsWith(t, ")")) {
        if (findLast(t, " (")) |open| {
            if (isDuration(std.mem.trim(u8, t[open + 2 .. t.len - 1], " "))) return t[0..open];
        }
    }
    if (std.mem.lastIndexOfScalar(u8, t, ' ')) |space| {
        if (isDuration(t[space + 1 ..])) return t[0..space];
    }
    return t;
}

fn isDuration(s: []const u8) bool {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == 0) return false;
    const unit = std.mem.trim(u8, s[i..], " ");
    return std.mem.eql(u8, unit, "ms") or std.mem.eql(u8, unit, "s");
}

/// A test file path: something with a slash or an extension.
fn looksLikePath(s: []const u8) bool {
    const word_end = std.mem.indexOfScalar(u8, s, ' ') orelse s.len;
    const word = s[0..word_end];
    return word.len > 0 and (std.mem.indexOfScalar(u8, word, '/') != null or std.mem.indexOfScalar(u8, word, '.') != null);
}

/// `path:line` or `path:line:column`, without spaces.
fn looksLikeLocation(s: []const u8) bool {
    if (s.len < 3 or std.mem.indexOfAny(u8, s, " \t") != null) return false;
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0) return false;
    const rest = s[colon + 1 ..];
    if (rest.len == 0) return false;
    for (rest) |c| {
        if (!std.ascii.isDigit(c) and c != ':') return false;
    }
    return std.ascii.isDigit(rest[0]);
}

// --- tests -----------------------------------------------------------------------

const testing = std.testing;

fn expectLine(it: *LineIterator, text: []const u8, want: []const u8, plain: bool) !void {
    const line = it.next() orelse return error.TestExpectedLine;
    try testing.expectEqualStrings(want, line.bytes(text));
    try testing.expectEqual(plain, line.plain);
}

test "lines split on LF and CRLF, with or without a final newline" {
    const text = "one\r\ntwo\n\nthree";
    var it = LineIterator.init(text);
    try expectLine(&it, text, "one", true);
    try expectLine(&it, text, "two", true);
    try expectLine(&it, text, "", true);
    try expectLine(&it, text, "three", true);
    try testing.expect(it.next() == null);
    try testing.expectEqual(@as(u64, 4), countLines(text));
    try testing.expectEqual(@as(u64, 2), countLines("a\nb\n"));
    try testing.expectEqual(@as(u64, 0), countLines(""));
    try testing.expectEqualStrings("three", lineAt(text, 4).?.bytes(text));
    try testing.expect(lineAt(text, 5) == null);
    try testing.expect(lineAt(text, 0) == null);
}

test "line splitting agrees with a byte-by-byte split across block boundaries" {
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    var buf: [3000]u8 = undefined;
    for (0..200) |_| {
        const len = random.uintLessThan(usize, buf.len);
        for (buf[0..len]) |*byte| {
            byte.* = switch (random.uintLessThan(u8, 12)) {
                0 => '\n',
                1 => '\r',
                2 => 0x1b,
                else => 'a' + random.uintLessThan(u8, 26),
            };
        }
        const text = buf[0..len];
        var it = LineIterator.init(text);
        var start: usize = 0;
        var number: u64 = 0;
        while (start < text.len) {
            const nl = std.mem.indexOfScalarPos(u8, text, start, '\n');
            var end = nl orelse text.len;
            if (end > start and text[end - 1] == '\r') end -= 1;
            number += 1;
            const line = it.next().?;
            try testing.expectEqual(number, line.number);
            try testing.expectEqual(start, line.start);
            try testing.expectEqual(end, line.end);
            const dirty = std.mem.indexOfAny(u8, text[start..end], "\x1b\r") != null;
            // `plain` may only err on the side of looking closer.
            if (dirty) try testing.expect(!line.plain);
            const at = lineAt(text, number).?;
            try testing.expectEqual(start, at.start);
            start = if (nl) |n| n + 1 else text.len;
        }
        try testing.expect(it.next() == null);
        try testing.expectEqual(number, countLines(text));
    }
}

test "cleaning removes ANSI escapes and keeps the last redraw" {
    var cleaner = Cleaner.init(testing.allocator);
    defer cleaner.deinit();
    try testing.expectEqualStrings("test x ... FAILED", try cleaner.clean("test x ... \x1b[31mFAILED\x1b[0m"));
    try testing.expectEqualStrings("bold title", try cleaner.clean("\x1b[1;4mbold\x1b[22m title\x1b[K"));
    try testing.expectEqualStrings("link", try cleaner.clean("\x1b]8;;http://x\x07link\x1b]8;;\x1b\\"));
    try testing.expectEqualStrings("100%", try cleaner.clean(" 10%\r 50%\r100%"));
    // A redraw that ends by clearing the line still shows its last text.
    try testing.expectEqualStrings("done", try cleaner.clean("done\r\x1b[K"));
    try testing.expectEqualStrings("(B", try cleaner.clean("\x1b(B(B"));
    const plain = "nothing to do";
    try testing.expect((try cleaner.clean(plain)).ptr == plain.ptr);
}

test "classification finds errors, failures, warnings and summaries" {
    const cases = [_]struct { []const u8, Kind }{
        .{ "error[E0308]: mismatched types", .@"error" },
        .{ "src/main.c:10:5: error: expected ';' before '}' token", .@"error" },
        .{ "ValueError: invalid literal for int()", .@"error" },
        .{ "Traceback (most recent call last):", .@"error" },
        .{ "thread 'main' panicked at src/main.rs:2:5:", .@"error" },
        .{ "fatal: not a git repository", .@"error" },
        .{ "Segmentation fault (core dumped)", .@"error" },
        .{ "make: *** [Makefile:3: all] Error 2", .@"error" },
        .{ "Command exited with code 3", .@"error" },
        .{ "subprocess.CalledProcessError: returned non-zero exit status 1.", .@"error" },
        .{ "test tests::it_fails ... FAILED", .failure },
        .{ "--- FAIL: TestAdd (0.00s)", .failure },
        .{ "not ok 3 - parses input", .failure },
        .{ "    ✕ adds 1 + 2 (5 ms)", .failure },
        .{ "  ● sum › adds", .failure },
        .{ "warning: unused variable: `x`", .warning },
        .{ "WARN deprecated flag", .warning },
        .{ "test result: ok. 3 passed; 0 failed; 0 ignored", .summary },
        .{ "Tests run: 3, Failures: 0, Errors: 0, Skipped: 0", .summary },
        .{ "Build finished with no errors", .summary },
        .{ "Ran 12 tests in 0.004s", .summary },
        .{ "exit status 0", .summary },
        .{ "test parser::error_recovery ... ok", .plain },
        .{ "--- PASS: TestErrorPath (0.00s)", .plain },
        .{ "Compiling failover v0.1.0", .plain },
        .{ "   1: core::panicking::panic_fmt", .plain },
        .{ "errno is fine; terrors are not errors_", .plain },
        .{ "everything is fine", .plain },
    };
    for (cases) |case| {
        testing.expectEqual(case[1], classify(case[0])) catch |err| {
            std.debug.print("classify({s})\n", .{case[0]});
            return err;
        };
    }
}

test "JSON strings escape controls and replace invalid UTF-8" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    const input = "a\"b\\c\n\t\x01é\xff\x1b[0m";
    try writeJsonString(&out.writer, input);
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\n\\t\\u0001é\u{fffd}\\u001b[0m\"", out.written());
    try testing.expectEqual(out.written().len, jsonStringLen(input));

    var prng = std.Random.DefaultPrng.init(42);
    var buf: [64]u8 = undefined;
    for (0..500) |_| {
        prng.random().bytes(&buf);
        out.clearRetainingCapacity();
        try writeJsonString(&out.writer, &buf);
        try testing.expectEqual(out.written().len, jsonStringLen(&buf));
        try testing.expect(std.unicode.utf8ValidateSlice(out.written()));
    }
}

/// A cargo-like log: a header, many passing tests, a warning, failures with
/// panics, and a summary. ANSI colour on some lines and a few long lines.
fn sampleLog(allocator: Allocator, tests: usize) ![]u8 {
    var out: Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("   Compiling demo v0.1.0 (/src/demo)\n    Finished `test` profile in 1.2s\n\nrunning tests\n");
    for (0..tests) |i| {
        if (i == tests / 3) try w.writeAll("warning: unused variable: `x`\n");
        if (i == tests / 2 or i == tests - 2) {
            try w.print("test suite::case_{d} ... \x1b[31mFAILED\x1b[0m\n", .{i});
        } else if (i % 7 == 0) {
            try w.print("test suite::case_{d} ... \x1b[32mok\x1b[0m\n", .{i});
        } else {
            try w.print("test suite::case_{d} ... ok\n", .{i});
        }
        if (i % 97 == 0) try w.print("note: {s}\n", .{"x" ** 200});
    }
    try w.writeAll("\nfailures:\n\n");
    try w.print("thread 'suite::case_{d}' panicked at src/lib.rs:9:5:\nconnection refused\n", .{tests / 2});
    try w.print("\ntest result: FAILED. {d} passed; 2 failed; 0 ignored\r\n", .{tests - 2});
    return out.toOwnedSlice();
}

fn parseGroupedNumber(text: []const u8) !u64 {
    var n: u64 = 0;
    for (text) |c| {
        if (c == ',') continue;
        if (!std.ascii.isDigit(c)) return error.NotANumber;
        n = n * 10 + (c - '0');
    }
    return n;
}

/// Checks that every line of a text-format summary is either the next kept
/// line of `text` (cleaned, possibly cut) or a marker whose numbers describe
/// exactly the lines it replaces.
fn verifySummary(text: []const u8, summary: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var expected: u64 = 1;
    var rest = summary;
    while (rest.len != 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.UnterminatedLine;
        const shown = rest[0..nl];
        rest = rest[nl + 1 ..];
        if (std.mem.startsWith(u8, shown, "[… ")) {
            // [… 4 lines (74 bytes) elided; lines 4–7 …]
            var parts = std.mem.tokenizeAny(u8, shown["[… ".len..], " ();–");
            const count = try parseGroupedNumber(parts.next().?);
            _ = parts.next(); // line(s)
            const bytes = try parseGroupedNumber(parts.next().?);
            _ = parts.next(); // byte(s)
            _ = parts.next(); // elided
            _ = parts.next(); // line(s)
            const from = try parseGroupedNumber(parts.next().?);
            const to = if (count == 1) from else try parseGroupedNumber(parts.next().?);
            try testing.expectEqual(expected, from);
            try testing.expectEqual(count, to - from + 1);
            const first = lineAt(text, from).?;
            const after = if (lineAt(text, to + 1)) |l| l.start else text.len;
            try testing.expectEqual(@as(u64, after - first.start), bytes);
            expected = to + 1;
            continue;
        }
        const line = lineAt(text, expected) orelse return error.LinePastEnd;
        const want = try cleanAlloc(arena, line.bytes(text));
        if (std.mem.indexOf(u8, shown, " … [+")) |cut| {
            try testing.expect(std.mem.startsWith(u8, want, shown[0..cut]));
        } else {
            try testing.expectEqualStrings(want, shown);
        }
        expected += 1;
    }
    try testing.expectEqual(countLines(text) + 1, expected);
}

test "budget returns the whole text when it fits" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "one\r\n\x1b[1mtwo\x1b[0m\nthree";
    try testing.expectEqualStrings("one\ntwo\nthree\n", try budget(arena, text, 4096, .{}));
    try testing.expectEqualStrings("one\n\x1b[1mtwo\x1b[0m\nthree\n", try budget(arena, text, 4096, .{ .raw = true }));
    try testing.expectEqualStrings("", try budget(arena, "", 10, .{}));
}

test "budget never exceeds its limit and its markers are exact" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try sampleLog(arena, 3000);
    const limits = [_]usize{ 0, 10, 60, 100, 200, 512, 1000, 1500, 2048, 4096, 10_000, 65_536 };
    for (limits) |limit| {
        const summary = try budget(arena, text, limit, .{});
        try testing.expect(summary.len <= limit);
        if (limit >= 512) try verifySummary(text, summary);

        const json = try budget(arena, text, limit, .{ .format = .json });
        try testing.expect(json.len <= limit);
        var lines = std.mem.tokenizeScalar(u8, json, '\n');
        while (lines.next()) |record| {
            const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, record, .{});
            try testing.expect(parsed.object.get("type") != null);
        }
    }
}

test "budget keeps the first and last lines, failures and the summary" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = try sampleLog(arena, 3000);
    const summary = try budget(arena, text, 2048, .{});
    const wanted = [_][]const u8{
        "   Compiling demo v0.1.0 (/src/demo)\n",
        "test suite::case_1500 ... FAILED\n",
        "test suite::case_2998 ... FAILED\n",
        "thread 'suite::case_1500' panicked at src/lib.rs:9:5:\n",
        "connection refused\n",
        "test result: FAILED. 2998 passed; 2 failed; 0 ignored\n",
    };
    for (wanted) |line| {
        testing.expect(std.mem.indexOf(u8, summary, line) != null) catch |err| {
            std.debug.print("missing {s} in:\n{s}\n", .{ line, summary });
            return err;
        };
    }
    try testing.expect(std.mem.indexOf(u8, summary, "\x1b") == null);
    try testing.expect(std.mem.indexOf(u8, summary, " elided; lines ") != null);
}

test "budget cuts long lines and says how much was cut" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const long = "error: " ++ "y" ** 2000;
    const text = "start\n" ++ ("filler line\n" ** 400) ++ long ++ "\nend\n";
    const summary = try budget(arena, text, 1000, .{});
    try testing.expect(summary.len <= 1000);
    try testing.expect(std.mem.indexOf(u8, summary, " … [+") != null);
    try verifySummary(text, summary);
}

test "fuzzy find ranks word matches first, keeps ties in order, and reports positions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\cargo build finished
        \\error: connection refused by peer
        \\recon nection was re fused
        \\ConnectionRefused (uppercase)
        \\nothing here
        \\error: connection refused by peer
    ;
    const result = try fuzzyFind(arena, text, "connection refused", 10);
    try testing.expectEqual(@as(u64, 4), result.total);
    // Smart case: lowercase matches either case; the exact phrase wins and
    // identical lines keep their order.
    try testing.expectEqual(@as(u64, 2), result.matches[0].line.number);
    try testing.expectEqual(@as(u64, 6), result.matches[1].line.number);
    try testing.expectEqual(@as(u64, 3), result.matches[result.matches.len - 1].line.number);
    try testing.expect(result.matches[0].score > result.matches[result.matches.len - 1].score);
    const first = result.matches[0];
    try testing.expectEqual(@as(usize, "connectionrefused".len), first.positions.len);
    for (first.positions) |pos| try testing.expect(first.text[pos] != ' ');
    try testing.expectEqualStrings("connection", first.text[first.positions[0] .. first.positions[0] + 10]);

    // An uppercase letter makes the search case-sensitive.
    const upper = try fuzzyFind(arena, text, "Refused", 10);
    try testing.expectEqual(@as(u64, 1), upper.total);
    try testing.expectEqual(@as(u64, 4), upper.matches[0].line.number);

    // Every term must match; the limit keeps the best.
    try testing.expectEqual(@as(u64, 0), (try fuzzyFind(arena, text, "connection zebra", 10)).total);
    const best = try fuzzyFind(arena, text, "refused", 1);
    try testing.expectEqual(@as(usize, 1), best.matches.len);
    try testing.expectEqual(@as(u64, 4), best.total);
}

test "fuzzy find matches through ANSI escapes and CRLF" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "plain\r\n\x1b[31mtimeout\x1b[0m after 30s\r\nother\r\n";
    const result = try fuzzyFind(arena, text, "timeout", 5);
    try testing.expectEqual(@as(usize, 1), result.matches.len);
    try testing.expectEqualStrings("timeout after 30s", result.matches[0].text);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6 }, result.matches[0].positions);
}

test "grep finds substrings, ignores case on request, and runs regexes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "abc abc\nABC\n\x1b[1mab\x1b[0mc\nnone\r\nx abc\n";
    const plain = try grep(arena, text, "abc", .{});
    try testing.expectEqual(@as(u64, 3), plain.total);
    try testing.expectEqual(@as(usize, 2), plain.matches[0].spans.len);
    try testing.expectEqual(Span{ .start = 4, .end = 7 }, plain.matches[0].spans[1]);
    try testing.expectEqual(@as(u64, 3), plain.matches[1].line.number);
    try testing.expectEqualStrings("abc", plain.matches[1].text);

    const folded = try grep(arena, text, "ABC", .{ .ignore_case = true, .limit = 2 });
    try testing.expectEqual(@as(u64, 4), folded.total);
    try testing.expectEqual(@as(usize, 2), folded.matches.len);

    const re = try grep(arena, text, "^x a.c$", .{ .regex = true });
    try testing.expectEqual(@as(u64, 1), re.total);
    try testing.expectEqual(@as(u64, 5), re.matches[0].line.number);
    try testing.expectError(error.UnmatchedParen, grep(arena, text, "(", .{ .regex = true }));
}

/// Checks the failures and counts found in `text`; returns the status.
fn expectFailures(text: []const u8, want: []const Failure, counts: Counts) !u8 {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const report = try failures(arena_state.allocator(), text);
    errdefer for (report.failures) |f| std.debug.print("got {s} {s} line {d} at {?s}: {?s}\n", .{ @tagName(f.framework), f.name, f.line, f.location, f.reason });
    try testing.expectEqual(want.len, report.failures.len);
    for (want, report.failures) |w, got| {
        try testing.expectEqual(w.framework, got.framework);
        try testing.expectEqualStrings(w.name, got.name);
        try testing.expectEqual(w.line, got.line);
        if (w.location) |location| try testing.expectEqualStrings(location, got.location orelse "");
        if (w.reason) |reason| try testing.expectEqualStrings(reason, got.reason orelse "");
    }
    try testing.expectEqual(counts, report.counts);
    return report.status();
}

test "cargo test failures, panics and the failures list" {
    const text =
        \\   Compiling rcrate v0.1.0 (/work/rcrate)
        \\    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.89s
        \\     Running unittests src/lib.rs (target/debug/deps/rcrate-597d8a4ee52794e1)
        \\
        \\running 4 tests
        \\test tests::slow ... ignored
        \\test tests::it_works ... ok
        \\test tests::it_fails ... FAILED
        \\test tests::it_panics ... FAILED
        \\
        \\failures:
        \\
        \\---- tests::it_fails stdout ----
        \\
        \\thread 'tests::it_fails' (21935) panicked at src/lib.rs:6:29:
        \\assertion `left == right` failed
        \\  left: 4
        \\ right: 5
        \\note: run with `RUST_BACKTRACE=1` environment variable to display a backtrace
        \\
        \\---- tests::it_panics stdout ----
        \\thread 'tests::it_panics' panicked at 'connection refused by server', src/lib.rs:7:30
        \\
        \\
        \\failures:
        \\    tests::it_fails
        \\    tests::it_panics
        \\    tests::only_listed
        \\
        \\test result: FAILED. 1 passed; 3 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.19s
        \\
        \\error: test failed, to rerun pass `--lib`
    ;
    const status = try expectFailures(text, &.{
        .{ .framework = .cargo, .name = "tests::it_fails", .line = 8, .location = "src/lib.rs:6:29", .reason = "assertion `left == right` failed" },
        .{ .framework = .cargo, .name = "tests::it_panics", .line = 9, .location = "src/lib.rs:7:30", .reason = "connection refused by server" },
        .{ .framework = .cargo, .name = "tests::only_listed", .line = 28 },
    }, .{ .passed = 1, .failed = 3, .skipped = 1 });
    try testing.expectEqual(@as(u8, 1), status);
}

test "pytest summary, verbose and error lines" {
    const text =
        \\============================= test session starts ==============================
        \\collecting ... collected 4 items
        \\
        \\test_mod.py::TestMath::test_add FAILED                                   [ 25%]
        \\test_mod.py::TestMath::test_ok PASSED                                    [ 50%]
        \\test_mod.py::TestMath::test_skip SKIPPED (later)                         [ 75%]
        \\test_db.py::test_connect ERROR                                           [100%]
        \\
        \\=================================== FAILURES ===================================
        \\______________________________ TestMath.test_add _______________________________
        \\E       AssertionError: 2 != 3
        \\test_mod.py:5: AssertionError
        \\=========================== short test summary info ============================
        \\FAILED test_mod.py::TestMath::test_add - AssertionError: 2 != 3
        \\ERROR test_db.py::test_connect - ConnectionRefusedError: [Errno 111] Connection refused
        \\=============== 1 failed, 1 passed, 1 skipped, 1 error in 0.02s ===============
    ;
    _ = try expectFailures(text, &.{
        .{ .framework = .pytest, .name = "test_mod.py::TestMath::test_add", .line = 4, .reason = "AssertionError: 2 != 3" },
        .{ .framework = .pytest, .name = "test_db.py::test_connect", .line = 7, .reason = "ConnectionRefusedError: [Errno 111] Connection refused" },
    }, .{ .passed = 1, .failed = 2, .skipped = 1 });
}

test "go test failures with logs, subtests and build failures" {
    const verbose =
        \\=== RUN   TestAdd
        \\    add_test.go:5: expected 4, got 3
        \\--- FAIL: TestAdd (0.00s)
        \\=== RUN   TestSub
        \\--- PASS: TestSub (0.00s)
        \\=== RUN   TestTable
        \\=== RUN   TestTable/case_1
        \\    add_test.go:9: boom in case 1
        \\=== RUN   TestTable/case_2
        \\--- FAIL: TestTable (0.00s)
        \\    --- FAIL: TestTable/case_1 (0.00s)
        \\    --- PASS: TestTable/case_2 (0.00s)
        \\    --- SKIP: TestTable/case_3 (0.00s)
        \\FAIL
        \\
    ++ "FAIL\texample.com/m\t0.002s\nFAIL\texample.com/broken [build failed]\n";
    _ = try expectFailures(verbose, &.{
        .{ .framework = .go, .name = "TestAdd", .line = 3, .location = "add_test.go:5", .reason = "expected 4, got 3" },
        .{ .framework = .go, .name = "TestTable", .line = 10 },
        .{ .framework = .go, .name = "TestTable/case_1", .line = 11, .location = "add_test.go:9", .reason = "boom in case 1" },
        .{ .framework = .go, .name = "example.com/broken", .line = 16, .reason = "build failed" },
    }, .{ .passed = 2, .failed = 3, .skipped = 1 });

    const quiet =
        \\--- FAIL: TestAdd (0.00s)
        \\    add_test.go:5: expected 4, got 3
        \\FAIL
        \\
    ++ "FAIL\texample.com/m\t0.003s\n";
    _ = try expectFailures(quiet, &.{
        .{ .framework = .go, .name = "TestAdd", .line = 1, .location = "add_test.go:5", .reason = "expected 4, got 3" },
    }, .{ .failed = 1 });
}

test "jest and vitest failures" {
    const jest =
        \\FAIL jt/sum.test.js
        \\  sum
        \\    ✕ adds 1 + 2 to equal 3 (3 ms)
        \\    ✓ works (1 ms)
        \\
        \\  ● sum › adds 1 + 2 to equal 3
        \\
        \\    expect(received).toBe(expected) // Object.is equality
        \\
        \\    Expected: 4
        \\    Received: 3
        \\
        \\PASS jt/ok.test.js
        \\Test Suites: 1 failed, 1 passed, 2 total
        \\Tests:       1 failed, 1 skipped, 2 passed, 4 total
        \\Snapshots:   0 total
    ;
    _ = try expectFailures(jest, &.{
        .{ .framework = .jest, .name = "jt/sum.test.js", .line = 1 },
        .{ .framework = .jest, .name = "sum › adds 1 + 2 to equal 3", .line = 3, .reason = "expect(received).toBe(expected) // Object.is equality" },
    }, .{ .passed = 2, .failed = 1, .skipped = 1 });

    const vitest = "\n \x1b[1m\x1b[46m RUN \x1b[49m\x1b[22m v3.2.7\n\n" ++
        " \x1b[31m❯\x1b[39m sum.test.mjs (3 tests | 1 failed | 1 skipped) 19ms\n" ++
        "\x1b[31m   \x1b[31m×\x1b[31m sum\x1b[2m > \x1b[22madds\x1b[39m\x1b[32m 15\x1b[2mms\x1b[22m\x1b[39m\n" ++
        "\x1b[31m     → expected 3 to be 4 // Object.is equality\x1b[39m\n" ++
        "\x1b[41m\x1b[1m FAIL \x1b[22m\x1b[49m sum.test.mjs\x1b[2m > \x1b[22msum\x1b[2m > \x1b[22madds\n" ++
        "\x1b[31m\x1b[1mAssertionError\x1b[22m: expected 3 to be 4 // Object.is equality\x1b[39m\n" ++
        "\x1b[2m Test Files \x1b[22m \x1b[1m\x1b[31m1 failed\x1b[39m\x1b[22m\x1b[90m (1)\x1b[39m\n" ++
        "\x1b[2m      Tests \x1b[22m \x1b[1m\x1b[31m1 failed\x1b[39m\x1b[22m\x1b[2m | \x1b[22m\x1b[1m\x1b[32m1 passed\x1b[39m\x1b[22m\x1b[2m | \x1b[22m\x1b[33m1 skipped\x1b[39m\x1b[90m (3)\x1b[39m\n";
    _ = try expectFailures(vitest, &.{
        .{ .framework = .vitest, .name = "sum.test.mjs > sum > adds", .line = 5, .reason = "expected 3 to be 4 // Object.is equality" },
    }, .{ .passed = 1, .failed = 1, .skipped = 1 });
}

test "zig test runner and build system failures" {
    const runner =
        \\1/3 main.test.adds...OK
        \\2/3 main.test.fails...expected 5, found 4
        \\FAIL (TestExpectedEqual)
        \\/opt/zig/lib/std/testing.zig:118:17: 0x1233334 in expectEqualInner__anon_43233 (std.zig)
        \\                return error.TestExpectedEqual;
        \\3/3 main.test.skipped...SKIP
        \\4/4 main.test.other...FAIL (TestUnexpectedResult)
        \\1 passed; 1 skipped; 2 failed.
    ;
    _ = try expectFailures(runner, &.{
        .{ .framework = .zig, .name = "main.test.fails", .line = 2, .reason = "expected 5, found 4" },
        .{ .framework = .zig, .name = "main.test.other", .line = 7, .reason = "TestUnexpectedResult" },
    }, .{ .passed = 1, .failed = 2, .skipped = 1 });

    const build =
        \\test
        \\+- run test 1 pass, 1 skip, 1 fail (3 total)
        \\error: 'main.test.fails' failed:
        \\       expected 5, found 4
        \\       /opt/zig/lib/std/testing.zig:118:17: 0x1233334 in expectEqualInner__anon_43225 (std.zig)
        \\failed command: ./.zig-cache/o/1fb98fe5c873579f714d47260228c689/test --seed=0x31374107 --listen=-
        \\
        \\Build Summary: 1/3 steps succeeded (1 failed); 1/3 tests passed (1 skipped, 1 failed)
        \\error: the following build command failed with exit code 1:
    ;
    _ = try expectFailures(build, &.{
        .{ .framework = .zig, .name = "main.test.fails", .line = 3, .reason = "expected 5, found 4" },
    }, .{ .passed = 1, .failed = 1, .skipped = 1 });
}

test "unittest failures take their reason and location from the traceback" {
    const text =
        \\test_add (test_mod.TestMath.test_add) ... FAIL
        \\test_ok (test_mod.TestMath.test_ok) ... ok
        \\test_skip (test_mod.TestMath.test_skip) ... skipped 'later'
        \\
        \\======================================================================
        \\ERROR: test_error (test_mod.TestMath.test_error)
        \\----------------------------------------------------------------------
        \\Traceback (most recent call last):
        \\  File "/work/py/test_mod.py", line 9, in test_error
        \\    raise ConnectionError("connection refused")
        \\ConnectionError: connection refused
        \\
        \\======================================================================
        \\FAIL: test_add (test_mod.TestMath.test_add)
        \\----------------------------------------------------------------------
        \\Traceback (most recent call last):
        \\  File "/work/py/test_mod.py", line 5, in test_add
        \\    self.assertEqual(1 + 1, 3)
        \\    ~~~~~~~~~~~~~~~~^^^^^^^^^^
        \\AssertionError: 2 != 3
        \\
        \\----------------------------------------------------------------------
        \\Ran 4 tests in 0.001s
        \\
        \\FAILED (failures=1, errors=1, skipped=1)
    ;
    _ = try expectFailures(text, &.{
        .{ .framework = .unittest, .name = "test_add (test_mod.TestMath.test_add)", .line = 1, .location = "/work/py/test_mod.py:5", .reason = "AssertionError: 2 != 3" },
        .{ .framework = .unittest, .name = "test_error (test_mod.TestMath.test_error)", .line = 6, .location = "/work/py/test_mod.py:9", .reason = "ConnectionError: connection refused" },
    }, .{ .passed = 1, .failed = 2, .skipped = 1 });
}

test "maven surefire and gradle failures" {
    const maven =
        \\[INFO] -------------------------------------------------------
        \\[INFO]  T E S T S
        \\[INFO] -------------------------------------------------------
        \\[INFO] Running com.example.AppTest
        \\[ERROR] Tests run: 3, Failures: 1, Errors: 1, Skipped: 1, Time elapsed: 0.034 s <<< FAILURE! -- in com.example.AppTest
        \\[ERROR] com.example.AppTest.testAdd -- Time elapsed: 0.005 s <<< FAILURE!
        \\org.opentest4j.AssertionFailedError: expected: <3> but was: <4>
    ++ "\n\tat org.junit.jupiter.api.AssertionFailureBuilder.build(AssertionFailureBuilder.java:151)\n" ++
        \\
        \\[ERROR] testDb(com.example.AppTest)  Time elapsed: 0.001 s  <<< ERROR!
        \\java.net.ConnectException: Connection refused
        \\
        \\[INFO] Results:
        \\[ERROR] Failures:
        \\[ERROR]   AppTest.testAdd:12 expected: <3> but was: <4>
        \\[ERROR] Tests run: 3, Failures: 1, Errors: 1, Skipped: 1
        \\[INFO] BUILD FAILURE
    ;
    _ = try expectFailures(maven, &.{
        .{ .framework = .junit, .name = "com.example.AppTest.testAdd", .line = 6, .reason = "org.opentest4j.AssertionFailedError: expected: <3> but was: <4>" },
        .{ .framework = .junit, .name = "testDb(com.example.AppTest)", .line = 10, .reason = "java.net.ConnectException: Connection refused" },
    }, .{ .passed = 0, .failed = 2, .skipped = 1 });

    const gradle =
        \\> Task :test FAILED
        \\
        \\AppTest > testAdd() FAILED
        \\    org.opentest4j.AssertionFailedError at AppTest.java:12
        \\
        \\AppTest > testOk() PASSED
        \\
        \\3 tests completed, 1 failed, 1 skipped
        \\
        \\FAILURE: Build failed with an exception.
    ;
    _ = try expectFailures(gradle, &.{
        .{ .framework = .junit, .name = "AppTest > testAdd()", .line = 3, .reason = "org.opentest4j.AssertionFailedError at AppTest.java:12" },
    }, .{ .passed = 1, .failed = 1, .skipped = 1 });
}

test "mocha and rspec failures" {
    const mocha =
        \\  Array
        \\    #indexOf()
        \\      ✔ should return -1 when the value is not present
        \\      1) should fail
        \\      - pending one
        \\
        \\
        \\  1 passing (5ms)
        \\  1 pending
        \\  1 failing
        \\
        \\  1) Array
        \\       #indexOf()
        \\         should fail:
        \\
        \\      AssertionError [ERR_ASSERTION]: 1 == 2
        \\      + expected - actual
        \\
        \\      at Context.<anonymous> (mt/array.test.js:5:44)
    ;
    _ = try expectFailures(mocha, &.{
        .{ .framework = .mocha, .name = "Array #indexOf() should fail", .line = 12, .reason = "AssertionError [ERR_ASSERTION]: 1 == 2" },
    }, .{ .passed = 1, .failed = 1, .skipped = 1 });

    const rspec =
        \\F.*
        \\
        \\Failures:
        \\
        \\  1) Calculator adds numbers
        \\     Failure/Error: expect(1 + 1).to eq(3)
        \\
        \\       expected: 3
        \\            got: 2
        \\     # ./spec/calc_spec.rb:4:in `block (2 levels) in <top (required)>'
        \\
        \\Finished in 0.01 seconds (files took 0.1 seconds to load)
        \\3 examples, 1 failure, 1 pending
        \\
        \\Failed examples:
        \\
        \\rspec ./spec/calc_spec.rb:3 # Calculator adds numbers
    ;
    _ = try expectFailures(rspec, &.{
        .{ .framework = .rspec, .name = "Calculator adds numbers", .line = 5, .location = "./spec/calc_spec.rb:3", .reason = "Failure/Error: expect(1 + 1).to eq(3)" },
    }, .{ .passed = 1, .failed = 1, .skipped = 1 });
}

test "compiler errors and tracebacks without a test framework" {
    const text =
        \\   Compiling demo v0.1.0
        \\error[E0308]: mismatched types
        \\ --> src/main.rs:4:5
        \\  |
        \\src/util.c:10:5: error: expected ';' before '}' token
        \\src/app.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.
        \\src/main.zig:3:16: error: use of undeclared identifier 'x'
        \\error: could not compile `demo` (bin "demo") due to 1 previous error
        \\Traceback (most recent call last):
        \\  File "/work/tool.py", line 12, in <module>
        \\    main()
        \\  File "/work/tool.py", line 8, in main
        \\    raise RuntimeError("boom")
        \\RuntimeError: boom
    ;
    const status = try expectFailures(text, &.{
        .{ .framework = .generic, .name = "src/main.rs:4:5", .line = 2, .reason = "error[E0308]: mismatched types" },
        .{ .framework = .generic, .name = "src/util.c:10:5", .line = 5, .reason = "error: expected ';' before '}' token" },
        .{ .framework = .generic, .name = "src/app.ts:3:7", .line = 6, .reason = "error TS2322: Type 'string' is not assignable to type 'number'." },
        .{ .framework = .generic, .name = "src/main.zig:3:16", .line = 7, .reason = "error: use of undeclared identifier 'x'" },
        .{ .framework = .generic, .name = "/work/tool.py:8", .line = 14, .reason = "RuntimeError: boom" },
    }, .{});
    try testing.expectEqual(@as(u8, 1), status);
}

test "failure status: none failed, and nothing recognised" {
    const passing = try expectFailures(
        \\running 2 tests
        \\test a ... ok
        \\test b ... ok
        \\
        \\test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out
    , &.{}, .{ .passed = 2, .failed = 0, .skipped = 0 });
    try testing.expectEqual(@as(u8, 0), passing);

    const unknown = try expectFailures("hello\nworld\n", &.{}, .{});
    try testing.expectEqual(@as(u8, 2), unknown);
}

test "stats count lines, kinds and frameworks" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try stats(arena_state.allocator(),
        \\running 2 tests
        \\warning: unused import
        \\test a ... ok
        \\test b ... FAILED
        \\error: test failed
        \\
    );
    try testing.expectEqual(@as(u64, 5), s.lines);
    try testing.expectEqual(@as(u64, 1), s.warning_lines);
    try testing.expectEqual(@as(u64, 1), s.failure_lines);
    try testing.expectEqual(@as(u64, 1), s.error_lines);
    try testing.expectEqual(@as(?u64, 4), s.first_failure);
    try testing.expectEqual(@as(?u64, 5), s.first_error);
    try testing.expect(s.frameworks.contains(.cargo));
    try testing.expectEqual(@as(u64, 22), s.longest_line);
}

test "context returns the lines around a line" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text = "1\n2\n3\n4\n5\n";
    const around = try context(arena, text, lineAt(text, 3).?, 5, 1);
    try testing.expectEqual(@as(usize, 4), around.len);
    try testing.expectEqual(@as(u64, 1), around[0].number);
    try testing.expectEqualStrings("4", around[3].bytes(text));
}
