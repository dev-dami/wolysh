//! Local time for the prompt's `\t`, `\d` and `\D{...}` escapes. wolysh does
//! not link libc, so the zone is read here: a TZif file named by `TZ` or
//! /etc/localtime, plus the POSIX rule in its footer that covers times after
//! its last transition. `TZ` may also be a POSIX rule itself.

const std = @import("std");
const linux = std.os.linux;
const fs = @import("../fs.zig");

pub const Time = struct {
    year: i32,
    /// 1-12.
    month: u8,
    /// 1-31.
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,
    /// 0 = Sunday.
    weekday: u8,
    /// 0-365.
    yday: u16,
    /// Seconds east of UTC.
    offset: i32,
    zone_buf: [8]u8 = [_]u8{0} ** 8,
    zone_len: u8 = 0,
    unix: i64,

    pub fn zone(self: *const Time) []const u8 {
        return self.zone_buf[0..self.zone_len];
    }
};

/// A POSIX TZ rule such as `CET-1CEST,M3.5.0,M10.5.0/3`.
const Rule = struct {
    std_name: []const u8,
    std_offset: i32,
    dst_name: []const u8 = "",
    dst_offset: i32 = 0,
    start: Date = .{ .kind = .month_week_day, .month = 3, .week = 2, .day = 0 },
    start_time: i32 = 7200,
    end: Date = .{ .kind = .month_week_day, .month = 11, .week = 1, .day = 0 },
    end_time: i32 = 7200,

    fn hasDst(self: Rule) bool {
        return self.dst_name.len != 0;
    }
};

const Date = struct {
    kind: enum { julian_no_leap, zero_based, month_week_day },
    month: u8 = 0,
    week: u8 = 0,
    day: u16 = 0,
};

const Zone = struct {
    arena: std.heap.ArenaAllocator,
    tz: ?std.Tz = null,
    rule: ?Rule = null,
};

var cached: ?Zone = null;
var cached_key: [256]u8 = undefined;
var cached_key_len: usize = std.math.maxInt(usize);

pub fn now(tz_env: ?[]const u8) Time {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.REALTIME, &ts);
    return at(tz_env, @intCast(ts.sec));
}

/// Converts `unix` with the zone `tz_env` names (null: /etc/localtime). The
/// parsed zone is cached for the life of the process until `TZ` changes, so it
/// lives in page memory rather than a caller's allocator; an unreadable zone
/// is UTC.
pub fn at(tz_env: ?[]const u8, unix: i64) Time {
    const key = tz_env orelse "\x00localtime";
    const same = key.len == cached_key_len and std.mem.eql(u8, key, cached_key[0..cached_key_len]);
    if (!same or cached == null) {
        if (cached) |*old| old.arena.deinit();
        cached = loadZone(tz_env);
        if (key.len <= cached_key.len) {
            @memcpy(cached_key[0..key.len], key);
            cached_key_len = key.len;
        } else {
            cached_key_len = std.math.maxInt(usize);
        }
    }
    return convert(&cached.?, unix);
}

fn loadZone(tz_env: ?[]const u8) Zone {
    var zone = Zone{ .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator) };
    const arena = zone.arena.allocator();
    const spec = tz_env orelse {
        zone.tz = readTzif(arena, "/etc/localtime");
        return zone;
    };
    if (spec.len == 0) return zone;
    const name = if (spec[0] == ':') spec[1..] else spec;
    // glibc tries a zone file first, so `TZ=Europe/Berlin` works without `:`.
    if (name.len != 0 and std.mem.indexOf(u8, name, "..") == null) {
        const path = if (name[0] == '/')
            name
        else
            std.fmt.allocPrint(arena, "/usr/share/zoneinfo/{s}", .{name}) catch return zone;
        zone.tz = readTzif(arena, path);
        if (zone.tz != null) return zone;
    }
    if (spec[0] != ':') zone.rule = parseRule(spec);
    return zone;
}

fn readTzif(arena: std.mem.Allocator, path: []const u8) ?std.Tz {
    const z = arena.dupeZ(u8, path) catch return null;
    const data = (fs.readFileAlloc(arena, z, 1 << 20) catch return null) orelse return null;
    var reader = std.Io.Reader.fixed(data);
    return std.Tz.parse(arena, &reader) catch null;
}

fn convert(zone: *const Zone, unix: i64) Time {
    var offset: i32 = 0;
    var name: []const u8 = "UTC";
    if (zone.tz) |tz| {
        const footer_rule = if (tz.footer) |footer| parseRule(footer) else null;
        if (tz.transitions.len != 0 and unix >= tz.transitions[tz.transitions.len - 1].ts and footer_rule != null) {
            offset, name = ruleOffset(footer_rule.?, unix);
        } else if (latestTransition(tz.transitions, unix)) |transition| {
            offset = transition.timetype.offset;
            name = transition.timetype.name();
        } else if (footer_rule != null and tz.transitions.len == 0) {
            offset, name = ruleOffset(footer_rule.?, unix);
        } else if (tz.timetypes.len != 0) {
            offset = tz.timetypes[0].offset;
            name = tz.timetypes[0].name();
        }
    } else if (zone.rule) |rule| {
        offset, name = ruleOffset(rule, unix);
    }
    return breakDown(unix, offset, name);
}

fn latestTransition(transitions: []const std.tz.Transition, unix: i64) ?std.tz.Transition {
    if (transitions.len == 0 or unix < transitions[0].ts) return null;
    var low: usize = 0;
    var high: usize = transitions.len;
    while (high - low > 1) {
        const mid = low + (high - low) / 2;
        if (transitions[mid].ts <= unix) low = mid else high = mid;
    }
    return transitions[low];
}

pub fn breakDown(unix: i64, offset: i32, name: []const u8) Time {
    const local = unix + offset;
    const days = @divFloor(local, 86400);
    const secs: u32 = @intCast(local - days * 86400);
    const civil = civilFromDays(days);
    var t = Time{
        .year = civil.year,
        .month = civil.month,
        .day = civil.day,
        .hour = @intCast(secs / 3600),
        .minute = @intCast(secs / 60 % 60),
        .second = @intCast(secs % 60),
        .weekday = @intCast(@mod(days + 4, 7)),
        .yday = @intCast(days - daysFromCivil(civil.year, 1, 1)),
        .offset = offset,
        .unix = unix,
    };
    const len = @min(name.len, t.zone_buf.len);
    @memcpy(t.zone_buf[0..len], name[0..len]);
    t.zone_len = @intCast(len);
    return t;
}

// --- calendar arithmetic (proleptic Gregorian, days since 1970-01-01) --------

fn daysFromCivil(year: i32, month: u8, day: u8) i64 {
    const y: i64 = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m: i64 = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return era * 146097 + doe - 719468;
}

const Civil = struct { year: i32, month: u8, day: u8 };

fn civilFromDays(days: i64) Civil {
    const z = days + 719468;
    const era = @divFloor(z, 146097);
    const doe = z - era * 146097;
    const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
    const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
    const mp = @divFloor(5 * doy + 2, 153);
    const day = doy - @divFloor(153 * mp + 2, 5) + 1;
    const month = if (mp < 10) mp + 3 else mp - 9;
    const year = yoe + era * 400 + @as(i64, if (month <= 2) 1 else 0);
    return .{ .year = @intCast(year), .month = @intCast(month), .day = @intCast(day) };
}

fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

fn daysInMonth(year: i32, month: u8) u8 {
    const table = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeap(year)) return 29;
    return table[month - 1];
}

// --- POSIX TZ rules -----------------------------------------------------------

/// UTC offset and zone name `rule` gives at `unix`.
fn ruleOffset(rule: Rule, unix: i64) struct { i32, []const u8 } {
    if (!rule.hasDst()) return .{ rule.std_offset, rule.std_name };
    const year = breakDown(unix, rule.std_offset, "").year;
    // Transitions are written in the local time in force just before them.
    const start = dateDays(year, rule.start) * 86400 + rule.start_time - rule.std_offset;
    const end = dateDays(year, rule.end) * 86400 + rule.end_time - rule.dst_offset;
    const in_dst = if (start < end) unix >= start and unix < end else unix < end or unix >= start;
    return if (in_dst) .{ rule.dst_offset, rule.dst_name } else .{ rule.std_offset, rule.std_name };
}

fn dateDays(year: i32, date: Date) i64 {
    const jan1 = daysFromCivil(year, 1, 1);
    switch (date.kind) {
        .julian_no_leap => {
            var day: i64 = jan1 + date.day - 1;
            if (isLeap(year) and date.day >= 60) day += 1;
            return day;
        },
        .zero_based => return jan1 + date.day,
        .month_week_day => {
            const first = daysFromCivil(year, date.month, 1);
            const first_weekday: i64 = @mod(first + 4, 7);
            var day = first + @mod(@as(i64, date.day) - first_weekday + 7, 7) + (@as(i64, date.week) - 1) * 7;
            const last = first + daysInMonth(year, date.month) - 1;
            while (day > last) day -= 7;
            return day;
        },
    }
}

const RuleParser = struct {
    text: []const u8,
    pos: usize = 0,

    fn peek(self: *const RuleParser) ?u8 {
        return if (self.pos < self.text.len) self.text[self.pos] else null;
    }

    fn name(self: *RuleParser) ?[]const u8 {
        if (self.peek() == '<') {
            const close = std.mem.indexOfScalarPos(u8, self.text, self.pos, '>') orelse return null;
            const quoted = self.text[self.pos + 1 .. close];
            self.pos = close + 1;
            return quoted;
        }
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isAlphabetic(c)) break;
            self.pos += 1;
        }
        if (self.pos - start < 3) return null;
        return self.text[start..self.pos];
    }

    fn number(self: *RuleParser) ?i32 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (!std.ascii.isDigit(c)) break;
            self.pos += 1;
        }
        if (self.pos == start) return null;
        return std.fmt.parseInt(i32, self.text[start..self.pos], 10) catch null;
    }

    /// `[+-]hh[:mm[:ss]]` in seconds.
    fn time(self: *RuleParser) ?i32 {
        var sign: i32 = 1;
        if (self.peek() == '+' or self.peek() == '-') {
            if (self.peek() == '-') sign = -1;
            self.pos += 1;
        }
        var total = (self.number() orelse return null) * 3600;
        if (self.peek() == ':') {
            self.pos += 1;
            total += (self.number() orelse return null) * 60;
            if (self.peek() == ':') {
                self.pos += 1;
                total += self.number() orelse return null;
            }
        }
        return sign * total;
    }

    fn date(self: *RuleParser) ?Date {
        if (self.peek() == 'M') {
            self.pos += 1;
            const month = self.number() orelse return null;
            if (self.peek() != '.') return null;
            self.pos += 1;
            const week = self.number() orelse return null;
            if (self.peek() != '.') return null;
            self.pos += 1;
            const day = self.number() orelse return null;
            if (month < 1 or month > 12 or week < 1 or week > 5 or day > 6) return null;
            return .{ .kind = .month_week_day, .month = @intCast(month), .week = @intCast(week), .day = @intCast(day) };
        }
        if (self.peek() == 'J') {
            self.pos += 1;
            const day = self.number() orelse return null;
            if (day < 1 or day > 365) return null;
            return .{ .kind = .julian_no_leap, .day = @intCast(day) };
        }
        const day = self.number() orelse return null;
        if (day > 365) return null;
        return .{ .kind = .zero_based, .day = @intCast(day) };
    }
};

fn parseRule(text: []const u8) ?Rule {
    var p = RuleParser{ .text = text };
    const std_name = p.name() orelse return null;
    // POSIX offsets count hours west of Greenwich.
    const std_offset = -(p.time() orelse return null);
    var rule = Rule{ .std_name = std_name, .std_offset = std_offset };
    if (p.peek() == null) return rule;
    rule.dst_name = p.name() orelse return null;
    rule.dst_offset = std_offset + 3600;
    if (p.peek() != null and p.peek() != ',') rule.dst_offset = -(p.time() orelse return null);
    if (p.peek() == null) return rule;
    if (p.peek() != ',') return null;
    p.pos += 1;
    rule.start = p.date() orelse return null;
    if (p.peek() == '/') {
        p.pos += 1;
        rule.start_time = p.time() orelse return null;
    }
    if (p.peek() != ',') return null;
    p.pos += 1;
    rule.end = p.date() orelse return null;
    if (p.peek() == '/') {
        p.pos += 1;
        rule.end_time = p.time() orelse return null;
    }
    if (p.peek() != null) return null;
    return rule;
}

// --- strftime ---------------------------------------------------------------

const weekdays = [_][]const u8{ "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" };
const months = [_][]const u8{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" };

/// `strftime` in the C locale. Unknown conversions are written as given.
pub fn format(out: *std.Io.Writer, spec: []const u8, t: Time) std.Io.Writer.Error!void {
    var i: usize = 0;
    while (i < spec.len) : (i += 1) {
        if (spec[i] != '%' or i + 1 == spec.len) {
            try out.writeByte(spec[i]);
            continue;
        }
        i += 1;
        const hour12 = if (t.hour % 12 == 0) 12 else t.hour % 12;
        switch (spec[i]) {
            'a' => try out.writeAll(weekdays[t.weekday][0..3]),
            'A' => try out.writeAll(weekdays[t.weekday]),
            'b', 'h' => try out.writeAll(months[t.month - 1][0..3]),
            'B' => try out.writeAll(months[t.month - 1]),
            'c' => try format(out, "%a %b %e %H:%M:%S %Y", t),
            'C' => try out.print("{d:0>2}", .{@as(u32, @intCast(@divFloor(t.year, 100)))}),
            'd' => try out.print("{d:0>2}", .{t.day}),
            'D', 'x' => try format(out, "%m/%d/%y", t),
            'e' => try out.print("{d: >2}", .{t.day}),
            'F' => try format(out, "%Y-%m-%d", t),
            'H' => try out.print("{d:0>2}", .{t.hour}),
            'I' => try out.print("{d:0>2}", .{hour12}),
            'j' => try out.print("{d:0>3}", .{t.yday + 1}),
            'k' => try out.print("{d: >2}", .{t.hour}),
            'l' => try out.print("{d: >2}", .{hour12}),
            'm' => try out.print("{d:0>2}", .{t.month}),
            'M' => try out.print("{d:0>2}", .{t.minute}),
            'n' => try out.writeByte('\n'),
            'p' => try out.writeAll(if (t.hour < 12) "AM" else "PM"),
            'P' => try out.writeAll(if (t.hour < 12) "am" else "pm"),
            'r' => try format(out, "%I:%M:%S %p", t),
            'R' => try format(out, "%H:%M", t),
            's' => try out.print("{d}", .{t.unix}),
            'S' => try out.print("{d:0>2}", .{t.second}),
            't' => try out.writeByte('\t'),
            'T', 'X' => try format(out, "%H:%M:%S", t),
            'u' => try out.print("{d}", .{if (t.weekday == 0) 7 else t.weekday}),
            'w' => try out.print("{d}", .{t.weekday}),
            'y' => try out.print("{d:0>2}", .{@as(u32, @intCast(@mod(t.year, 100)))}),
            'Y' => try out.print("{d}", .{t.year}),
            'z' => {
                const abs: u32 = @abs(t.offset);
                try out.print("{c}{d:0>2}{d:0>2}", .{ @as(u8, if (t.offset < 0) '-' else '+'), abs / 3600, abs / 60 % 60 });
            },
            'Z' => try out.writeAll(t.zone()),
            '%' => try out.writeByte('%'),
            else => {
                try out.writeByte('%');
                try out.writeByte(spec[i]);
            },
        }
    }
}

test "calendar conversion round-trips" {
    try std.testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    const t = breakDown(1_790_000_000, 0, "UTC");
    try std.testing.expectEqual(@as(i32, 2026), t.year);
    try std.testing.expectEqual(@as(u8, 9), t.month);
    try std.testing.expectEqual(@as(u8, 21), t.day);
    try std.testing.expectEqual(@as(u8, 14), t.hour);
    try std.testing.expectEqual(@as(u8, 13), t.minute);
    try std.testing.expectEqual(@as(u8, 20), t.second);
    try std.testing.expectEqual(@as(u8, 1), t.weekday);
}

test "POSIX rules pick standard and daylight time" {
    const rule = parseRule("EST5EDT,M3.2.0,M11.1.0").?;
    // 2026-07-01 12:00 UTC is summer: UTC-4.
    try std.testing.expectEqual(@as(i32, -4 * 3600), ruleOffset(rule, 1782907200)[0]);
    // 2026-01-15 12:00 UTC is winter: UTC-5.
    try std.testing.expectEqual(@as(i32, -5 * 3600), ruleOffset(rule, 1768478400)[0]);

    const south = parseRule("<+1030>-10:30<+11>-11,M10.1.0,M4.1.0").?;
    try std.testing.expectEqual(@as(i32, 37800), south.std_offset);
    try std.testing.expectEqual(@as(i32, 11 * 3600), ruleOffset(south, 1768478400)[0]);

    const fixed = parseRule("JST-9").?;
    try std.testing.expectEqual(@as(i32, 9 * 3600), ruleOffset(fixed, 0)[0]);
    try std.testing.expect(parseRule("x") == null);
}

test "strftime conversions" {
    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const t = breakDown(1_790_000_000, 3600, "WAT");
    try format(&w, "%a %b %d|%H:%M:%S|%I %p|%Y-%m-%d|%Z %z|%q", t);
    try std.testing.expectEqualStrings("Mon Sep 21|15:13:20|03 PM|2026-09-21|WAT +0100|%q", w.buffered());
}
