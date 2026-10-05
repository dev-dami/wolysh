//! Local time and `strftime` in the C locale, for `printf %(fmt)T`.
//!
//! Time zones come from `TZ` the way glibc reads it: unset means
//! `/etc/localtime`, a name is a TZif file under `/usr/share/zoneinfo`, and
//! anything else is a POSIX rule such as `EST5EDT,M3.2.0,M11.1.0`.

const std = @import("std");
const fs = @import("../fs.zig");

const Allocator = std.mem.Allocator;

pub const Error = Allocator.Error || error{InvalidTimeZone};

const zoneinfo_dir = "/usr/share/zoneinfo";

const TimeType = struct {
    /// Seconds east of UTC.
    utoff: i64,
    isdst: bool,
    abbr: []const u8,
};

const DateRule = union(enum) {
    /// `Jn`: 1..365, February 29 is never counted.
    julian: u16,
    /// `n`: 0..365, counting February 29.
    day: u16,
    /// `Mm.w.d`: weekday d of week w (5 = last) of month m.
    month: struct { m: u8, w: u8, d: u8 },
};

const Transition = struct {
    date: DateRule,
    /// Local wall-clock seconds after midnight; may be negative or past 24h.
    time: i64,
};

/// A POSIX `TZ` rule: standard time, optionally with daylight saving time.
const Rule = struct {
    std_type: TimeType,
    dst: ?struct {
        dst_type: TimeType,
        start: Transition,
        end: Transition,
    } = null,

    fn lookup(self: Rule, t: i64) TimeType {
        const dst = self.dst orelse return self.std_type;
        const year = civilFromDays(@divFloor(t + self.std_type.utoff, std.time.s_per_day)).year;
        const start = dayOf(year, dst.start.date) * std.time.s_per_day + dst.start.time - self.std_type.utoff;
        const end = dayOf(year, dst.end.date) * std.time.s_per_day + dst.end.time - dst.dst_type.utoff;
        const in_dst = if (start < end) t >= start and t < end else !(t >= end and t < start);
        return if (in_dst) dst.dst_type else self.std_type;
    }
};

pub const Zone = struct {
    transitions: []const i64 = &.{},
    indices: []const u8 = &.{},
    types: []const TimeType = &.{},
    rule: ?Rule = null,

    const utc = Zone{ .rule = .{ .std_type = .{ .utoff = 0, .isdst = false, .abbr = "UTC" } } };

    fn lookup(self: Zone, t: i64) TimeType {
        if (self.transitions.len == 0) {
            if (self.rule) |rule| return rule.lookup(t);
            if (self.types.len != 0) return self.types[0];
            return .{ .utoff = 0, .isdst = false, .abbr = "UTC" };
        }
        if (t < self.transitions[0]) return self.types[0];
        var low: usize = 0;
        var high: usize = self.transitions.len;
        while (high - low > 1) {
            const mid = (low + high) / 2;
            if (self.transitions[mid] <= t) low = mid else high = mid;
        }
        if (low + 1 == self.transitions.len) {
            if (self.rule) |rule| return rule.lookup(t);
        }
        return self.types[self.indices[low]];
    }
};

/// Loads the zone `TZ` names; `tz` is null when `TZ` is unset.
pub fn load(arena: Allocator, tz: ?[]const u8) Error!Zone {
    const spec = tz orelse return loadFile(arena, "/etc/localtime") orelse Zone.utc;
    if (spec.len == 0) return Zone.utc;
    if (spec[0] == ':') return try loadNamed(arena, spec[1..]) orelse error.InvalidTimeZone;
    if (try loadNamed(arena, spec)) |zone| return zone;
    return .{ .rule = parseRule(spec) orelse return error.InvalidTimeZone };
}

fn loadNamed(arena: Allocator, name: []const u8) Error!?Zone {
    if (name.len == 0 or std.mem.indexOf(u8, name, "..") != null) return null;
    const path = if (name[0] == '/') name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ zoneinfo_dir, name });
    return loadFile(arena, path);
}

fn loadFile(arena: Allocator, path: []const u8) ?Zone {
    const z = arena.dupeZ(u8, path) catch return null;
    const data = (fs.readFileAlloc(arena, z, 1 << 20) catch return null) orelse return null;
    return parseTzif(arena, data) catch null;
}

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, n: usize) error{InvalidTimeZone}![]const u8 {
        if (self.data.len - self.pos < n) return error.InvalidTimeZone;
        defer self.pos += n;
        return self.data[self.pos..][0..n];
    }

    fn int(self: *Reader, comptime T: type) error{InvalidTimeZone}!T {
        const bytes = try self.take(@sizeOf(T));
        return std.mem.readInt(T, bytes[0..@sizeOf(T)], .big);
    }
};

const Counts = struct { isut: usize, isstd: usize, leap: usize, time: usize, type: usize, char: usize };

fn header(r: *Reader) error{InvalidTimeZone}!struct { version: u8, counts: Counts } {
    if (!std.mem.eql(u8, try r.take(4), "TZif")) return error.InvalidTimeZone;
    const version = (try r.take(16))[0];
    var counts: [6]usize = undefined;
    for (&counts) |*count| count.* = try r.int(u32);
    return .{ .version = version, .counts = .{
        .isut = counts[0],
        .isstd = counts[1],
        .leap = counts[2],
        .time = counts[3],
        .type = counts[4],
        .char = counts[5],
    } };
}

fn parseTzif(arena: Allocator, data: []const u8) Error!Zone {
    var r = Reader{ .data = data };
    var head = try header(&r);
    var time_size: usize = 4;
    if (head.version >= '2') {
        // Skip the 32-bit block; the 64-bit one after it covers all times.
        const c = head.counts;
        _ = try r.take(c.time * 5 + c.type * 6 + c.char + c.leap * 8 + c.isstd + c.isut);
        head = try header(&r);
        time_size = 8;
    }
    const c = head.counts;
    if (c.type == 0) return error.InvalidTimeZone;

    const transitions = try arena.alloc(i64, c.time);
    for (transitions) |*t| t.* = if (time_size == 8) try r.int(i64) else try r.int(i32);
    const indices = try r.take(c.time);
    const raw_types = try r.take(c.type * 6);
    const abbrs = try r.take(c.char);
    _ = try r.take(c.leap * (time_size + 4) + c.isstd + c.isut);

    const types = try arena.alloc(TimeType, c.type);
    for (types, 0..) |*t, i| {
        const raw = raw_types[i * 6 ..][0..6];
        const index = raw[5];
        if (index >= abbrs.len) return error.InvalidTimeZone;
        const end = std.mem.indexOfScalarPos(u8, abbrs, index, 0) orelse abbrs.len;
        t.* = .{
            .utoff = std.mem.readInt(i32, raw[0..4], .big),
            .isdst = raw[4] != 0,
            .abbr = abbrs[index..end],
        };
    }
    for (indices) |index| {
        if (index >= types.len) return error.InvalidTimeZone;
    }

    var zone = Zone{ .transitions = transitions, .indices = indices, .types = types };
    if (head.version >= '2' and r.pos < data.len and data[r.pos] == '\n') {
        const rest = data[r.pos + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (end != 0) zone.rule = parseRule(rest[0..end]) orelse return error.InvalidTimeZone;
    }
    return zone;
}

// --- POSIX TZ rules ------------------------------------------------------------

const RuleParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(self: *const RuleParser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn name(self: *RuleParser) ?[]const u8 {
        if (self.peek() == '<') {
            const end = std.mem.indexOfScalarPos(u8, self.text, self.pos, '>') orelse return null;
            defer self.pos = end + 1;
            return self.text[self.pos + 1 .. end];
        }
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isAlphabetic(c)) break;
            self.pos += 1;
        }
        return if (self.pos - start >= 3) self.text[start..self.pos] else null;
    }

    fn number(self: *RuleParser, max: i64) ?i64 {
        const start = self.pos;
        var n: i64 = 0;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            n = n * 10 + (c - '0');
            if (n > max) return null;
            self.pos += 1;
        }
        return if (self.pos == start) null else n;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds.
    fn duration(self: *RuleParser) ?i64 {
        var sign: i64 = 1;
        if (self.peek() == '+' or self.peek() == '-') {
            if (self.peek() == '-') sign = -1;
            self.pos += 1;
        }
        var seconds = (self.number(167) orelse return null) * 3600;
        if (self.peek() == ':') {
            self.pos += 1;
            seconds += (self.number(59) orelse return null) * 60;
            if (self.peek() == ':') {
                self.pos += 1;
                seconds += self.number(59) orelse return null;
            }
        }
        return sign * seconds;
    }

    fn date(self: *RuleParser) ?DateRule {
        const c = self.peek() orelse return null;
        if (c == 'J') {
            self.pos += 1;
            const n = self.number(365) orelse return null;
            return if (n >= 1) .{ .julian = @intCast(n) } else null;
        }
        if (c == 'M') {
            self.pos += 1;
            const m = self.number(12) orelse return null;
            if (self.peek() != '.') return null;
            self.pos += 1;
            const w = self.number(5) orelse return null;
            if (self.peek() != '.') return null;
            self.pos += 1;
            const d = self.number(6) orelse return null;
            if (m < 1 or w < 1) return null;
            return .{ .month = .{ .m = @intCast(m), .w = @intCast(w), .d = @intCast(d) } };
        }
        return .{ .day = @intCast(self.number(365) orelse return null) };
    }

    fn transition(self: *RuleParser) ?Transition {
        const when = self.date() orelse return null;
        var time: i64 = 2 * 3600;
        if (self.peek() == '/') {
            self.pos += 1;
            time = self.duration() orelse return null;
        }
        return .{ .date = when, .time = time };
    }
};

fn parseRule(text: []const u8) ?Rule {
    var p = RuleParser{ .text = text };
    const std_name = p.name() orelse return null;
    // POSIX offsets count west of UTC.
    const std_off = -(p.duration() orelse return null);
    var rule = Rule{ .std_type = .{ .utoff = std_off, .isdst = false, .abbr = std_name } };
    if (p.peek() == null) return rule;

    const dst_name = p.name() orelse return null;
    var dst_off = std_off + 3600;
    if (p.peek() != null and p.peek() != ',') dst_off = -(p.duration() orelse return null);
    var start = Transition{ .date = .{ .month = .{ .m = 3, .w = 2, .d = 0 } }, .time = 2 * 3600 };
    var end = Transition{ .date = .{ .month = .{ .m = 11, .w = 1, .d = 0 } }, .time = 2 * 3600 };
    if (p.peek() == ',') {
        p.pos += 1;
        start = p.transition() orelse return null;
        if (p.peek() != ',') return null;
        p.pos += 1;
        end = p.transition() orelse return null;
    }
    if (p.peek() != null) return null;
    rule.dst = .{ .dst_type = .{ .utoff = dst_off, .isdst = true, .abbr = dst_name }, .start = start, .end = end };
    return rule;
}

// --- calendar ------------------------------------------------------------------

fn isLeap(year: i64) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i64, month: u8) u8 {
    const table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    return if (month == 2 and isLeap(year)) 29 else table[month - 1];
}

/// Days since 1970-01-01 of a proleptic Gregorian date (month 1..12).
fn daysFromCivil(year: i64, month: u8, day: u8) i64 {
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const mp: i64 = @mod(@as(i64, month) + 9, 12);
    const doy = @divFloor(153 * mp + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: i64, month: u8, day: u8 };

fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day: u8 = @intCast(doy - @divFloor(153 * mp + 2, 5) + 1);
    const month: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    return .{ .year = yoe + era * 400 + @intFromBool(month <= 2), .month = month, .day = day };
}

fn weekday(days: i64) u8 {
    return @intCast(@mod(days + 4, 7));
}

fn dayOf(year: i64, rule: DateRule) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    switch (rule) {
        .julian => |n| return jan1 + n - 1 + @intFromBool(isLeap(year) and n >= 60),
        .day => |n| return jan1 + n,
        .month => |m| {
            const first = daysFromCivil(year, m.m, 1);
            var day = first + @mod(@as(i64, m.d) - weekday(first) + 7, 7) + (@as(i64, m.w) - 1) * 7;
            while (day >= first + daysInMonth(year, m.m)) day -= 7;
            return day;
        },
    }
}

pub const Tm = struct {
    year: i64,
    month: u8,
    mday: u8,
    hour: u8,
    min: u8,
    sec: u8,
    /// 0 is Sunday.
    wday: u8,
    /// 0-based day of the year.
    yday: u16,
    utoff: i64,
    zone: []const u8,
    epoch: i64,
};

pub fn localTime(zone: Zone, t: i64) Tm {
    const kind = zone.lookup(t);
    const local = t + kind.utoff;
    const days = @divFloor(local, std.time.s_per_day);
    const secs: u32 = @intCast(@mod(local, std.time.s_per_day));
    const civil = civilFromDays(days);
    return .{
        .year = civil.year,
        .month = civil.month,
        .mday = civil.day,
        .hour = @intCast(secs / 3600),
        .min = @intCast(secs / 60 % 60),
        .sec = @intCast(secs % 60),
        .wday = weekday(days),
        .yday = @intCast(days - daysFromCivil(civil.year, 1, 1)),
        .utoff = kind.utoff,
        .zone = kind.abbr,
        .epoch = t,
    };
}

// --- strftime ----------------------------------------------------------------

const day_names = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const month_names = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

fn isoWeeks(year: i64) i64 {
    const p = struct {
        fn f(y: i64) i64 {
            return @mod(y + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400), 7);
        }
    }.f;
    return if (p(year) == 4 or p(year - 1) == 3) 53 else 52;
}

/// ISO 8601 week-based year and week number.
fn isoWeek(tm: Tm) struct { year: i64, week: i64 } {
    const monday_based: i64 = @mod(@as(i64, tm.wday) + 6, 7);
    const week = @divFloor(@as(i64, tm.yday) - monday_based + 10, 7);
    if (week < 1) return .{ .year = tm.year - 1, .week = isoWeeks(tm.year - 1) };
    if (week > isoWeeks(tm.year)) return .{ .year = tm.year + 1, .week = 1 };
    return .{ .year = tm.year, .week = week };
}

const Pad = enum { zero, space, none };

const Field = struct {
    pad: ?Pad = null,
    width: ?usize = null,
    upper: bool = false,
};

fn number(arena: Allocator, out: *std.ArrayList(u8), field: Field, value: i64, width: usize, pad: Pad) Allocator.Error!void {
    var buf: [24]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{@abs(value)}) catch unreachable;
    const want = field.width orelse width;
    const how = field.pad orelse pad;
    const sign_len: usize = @intFromBool(value < 0);
    const fill = if (how != .none and want > digits.len + sign_len) want - digits.len - sign_len else 0;
    if (how == .space) try out.appendNTimes(arena, ' ', fill);
    if (value < 0) try out.append(arena, '-');
    if (how == .zero) try out.appendNTimes(arena, '0', fill);
    try out.appendSlice(arena, digits);
}

fn word(arena: Allocator, out: *std.ArrayList(u8), field: Field, value: []const u8) Allocator.Error!void {
    if (field.width) |w| {
        if (w > value.len) try out.appendNTimes(arena, if (field.pad == .zero) '0' else ' ', w - value.len);
    }
    for (value) |c| try out.append(arena, if (field.upper) std.ascii.toUpper(c) else c);
}

/// Formats `tm` like `strftime(3)` in the C locale, including the GNU
/// `%k %l %P %s` conversions and the `_ - 0 ^` flags.
pub fn format(arena: Allocator, out: *std.ArrayList(u8), fmt: []const u8, tm: Tm) Allocator.Error!void {
    var i: usize = 0;
    while (i < fmt.len) {
        if (fmt[i] != '%' or i + 1 >= fmt.len) {
            try out.append(arena, fmt[i]);
            i += 1;
            continue;
        }
        const start = i;
        i += 1;
        var field = Field{};
        while (i < fmt.len) : (i += 1) {
            switch (fmt[i]) {
                '_' => field.pad = .space,
                '-' => field.pad = .none,
                '0' => field.pad = .zero,
                '^' => field.upper = true,
                '#' => {},
                else => break,
            }
        }
        var width: usize = 0;
        var has_width = false;
        while (i < fmt.len and std.ascii.isDigit(fmt[i])) : (i += 1) {
            width = @min(width * 10 + (fmt[i] - '0'), 1024);
            has_width = true;
        }
        if (has_width) field.width = width;
        if (i < fmt.len and (fmt[i] == 'E' or fmt[i] == 'O')) i += 1;
        if (i >= fmt.len) {
            try out.appendSlice(arena, fmt[start..]);
            break;
        }
        const conversion = fmt[i];
        i += 1;
        const hour12: i64 = if (tm.hour % 12 == 0) 12 else tm.hour % 12;
        switch (conversion) {
            'a' => try word(arena, out, field, day_names[tm.wday][0..3]),
            'A' => try word(arena, out, field, day_names[tm.wday]),
            'b', 'h' => try word(arena, out, field, month_names[tm.month - 1][0..3]),
            'B' => try word(arena, out, field, month_names[tm.month - 1]),
            'c' => try format(arena, out, "%a %b %e %H:%M:%S %Y", tm),
            'C' => try number(arena, out, field, @divFloor(tm.year, 100), 2, .zero),
            'd' => try number(arena, out, field, tm.mday, 2, .zero),
            'D', 'x' => try format(arena, out, "%m/%d/%y", tm),
            'e' => try number(arena, out, field, tm.mday, 2, .space),
            'F' => try format(arena, out, "%Y-%m-%d", tm),
            'g' => try number(arena, out, field, @mod(isoWeek(tm).year, 100), 2, .zero),
            'G' => try number(arena, out, field, isoWeek(tm).year, 0, .zero),
            'H' => try number(arena, out, field, tm.hour, 2, .zero),
            'I' => try number(arena, out, field, hour12, 2, .zero),
            'j' => try number(arena, out, field, @as(i64, tm.yday) + 1, 3, .zero),
            'k' => try number(arena, out, field, tm.hour, 2, .space),
            'l' => try number(arena, out, field, hour12, 2, .space),
            'm' => try number(arena, out, field, tm.month, 2, .zero),
            'M' => try number(arena, out, field, tm.min, 2, .zero),
            'n' => try out.append(arena, '\n'),
            'p' => try word(arena, out, field, if (tm.hour < 12) "AM" else "PM"),
            'P' => try word(arena, out, field, if (tm.hour < 12) "am" else "pm"),
            'r' => try format(arena, out, "%I:%M:%S %p", tm),
            'R' => try format(arena, out, "%H:%M", tm),
            's' => try number(arena, out, field, tm.epoch, 0, .zero),
            'S' => try number(arena, out, field, tm.sec, 2, .zero),
            't' => try out.append(arena, '\t'),
            'T', 'X' => try format(arena, out, "%H:%M:%S", tm),
            'u' => try number(arena, out, field, if (tm.wday == 0) 7 else tm.wday, 1, .zero),
            'U' => try number(arena, out, field, @divFloor(@as(i64, tm.yday) + 7 - tm.wday, 7), 2, .zero),
            'V' => try number(arena, out, field, isoWeek(tm).week, 2, .zero),
            'w' => try number(arena, out, field, tm.wday, 1, .zero),
            'W' => try number(arena, out, field, @divFloor(@as(i64, tm.yday) + 7 - @mod(@as(i64, tm.wday) + 6, 7), 7), 2, .zero),
            'y' => try number(arena, out, field, @mod(tm.year, 100), 2, .zero),
            'Y' => try number(arena, out, field, tm.year, 0, .zero),
            'z' => {
                const minutes = @divTrunc(@abs(tm.utoff), 60);
                try out.print(arena, "{c}{d:0>2}{d:0>2}", .{ @as(u8, if (tm.utoff < 0) '-' else '+'), minutes / 60, minutes % 60 });
            },
            'Z' => try word(arena, out, field, tm.zone),
            '%' => try out.append(arena, '%'),
            else => try out.appendSlice(arena, fmt[start..i]),
        }
    }
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn expectFormat(expected: []const u8, fmt: []const u8, zone: Zone, t: i64) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var out: std.ArrayList(u8) = .empty;
    try format(arena_state.allocator(), &out, fmt, localTime(zone, t));
    try testing.expectEqualStrings(expected, out.items);
}

test "calendar conversions round-trip" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 11016), daysFromCivil(2000, 2, 29));
    const civil = civilFromDays(11016);
    try testing.expectEqual(@as(i64, 2000), civil.year);
    try testing.expectEqual(@as(u8, 2), civil.month);
    try testing.expectEqual(@as(u8, 29), civil.day);
    try testing.expectEqual(@as(u8, 4), weekday(0));
}

test "strftime in UTC" {
    try expectFormat("1970-01-02 00:00:00|Fri|Friday|Jan|002", "%F %T|%a|%A|%b|%j", Zone.utc, 86400);
    try expectFormat("Thu Jan  1 00:00:00 1970", "%c", Zone.utc, 0);
    try expectFormat("01/01/70 12:00:00 AM +0000 UTC %", "%x %r %z %Z %%", Zone.utc, 0);
    try expectFormat("2021-W52-6", "%G-W%V-%u", Zone.utc, 1641038400);
    try expectFormat(" 5| 5|5| 5|NOV|1699160400", "%e|%k|%-H|%_2H|%^b|%s", Zone.utc, 1699160400);
}

test "POSIX rules switch to daylight saving time" {
    const london = Zone{ .rule = parseRule("GMT0BST,M3.5.0/1,M10.5.0").? };
    // 2024-07-01 12:00 UTC is summer time; 2024-01-15 is not.
    try expectFormat("13:00 BST +0100", "%H:%M %Z %z", london, 1719835200);
    try expectFormat("12:00 GMT +0000", "%H:%M %Z %z", london, 1705320000);
    const kolkata = Zone{ .rule = parseRule("<+0530>-5:30").? };
    try expectFormat("05:30 +0530 +0530", "%H:%M %Z %z", kolkata, 0);
    const sydney = Zone{ .rule = parseRule("AEST-10AEDT,M10.1.0,M4.1.0/3").? };
    try expectFormat("AEDT", "%Z", sydney, 1704067200);
    try expectFormat("AEST", "%Z", sydney, 1719835200);
    try testing.expect(parseRule("1abc") == null);
}
