//! `printf`: bash-compatible formatted output.
//!
//! Numbers follow the C library rules bash relies on: integers parse like
//! `strtoimax` with base detection, and floating-point conversions use the
//! x86-64 `long double` (`f80`) with exact decimal rounding, so `%f`, `%e`,
//! `%g` and `%a` print the same digits bash does.

const std = @import("std");
const builtins = @import("../builtins.zig");
const strftime = @import("strftime.zig");

const Ctx = builtins.Ctx;
const Allocator = std.mem.Allocator;
const Managed = std.math.big.int.Managed;

const usage = "wsh: printf: usage: printf [-v var] format [arguments]\n";

pub fn run(ctx: Ctx) u8 {
    var index: usize = 1;
    var target: ?[]const u8 = null;
    while (index < ctx.argv.len) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;
        if (arg[1] != 'v') {
            ctx.errFmt("wsh: printf: {s}: invalid option\n", .{arg[0..2]});
            ctx.err(usage);
            return 2;
        }
        if (arg.len > 2) {
            target = arg[2..];
        } else {
            index += 1;
            if (index >= ctx.argv.len) {
                ctx.err("wsh: printf: -v: option requires an argument\n");
                ctx.err(usage);
                return 2;
            }
            target = ctx.argv[index];
        }
        index += 1;
    }
    if (index >= ctx.argv.len) {
        ctx.err(usage);
        return 2;
    }
    if (target) |name| {
        if (!builtins.validName(name)) {
            ctx.errFmt("wsh: printf: `{s}': not a valid identifier\n", .{name});
            return 2;
        }
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    var printer = Printer{
        .ctx = ctx,
        .arena = arena_state.allocator(),
        .args = ctx.argv[index + 1 ..],
    };
    var status = printer.format(ctx.argv[index]) catch {
        ctx.err("wsh: printf: out of memory\n");
        return 1;
    };

    if (target) |name| {
        ctx.sh.assignVar(name, .{ .string = printer.out.items }) catch |err| {
            if (err == error.ReadonlyVariable) {
                ctx.errFmt("wsh: printf: {s}: readonly variable\n", .{name});
            } else {
                ctx.err("wsh: printf: out of memory\n");
            }
            status = 1;
        };
    } else {
        ctx.out(printer.out.items);
    }
    return status;
}

const Spec = struct {
    left: bool = false,
    plus: bool = false,
    space: bool = false,
    alt: bool = false,
    zero: bool = false,
    width: usize = 0,
    precision: ?usize = null,
};

/// What one pass over the format string ended with.
const Outcome = enum { done, stop, fail };

const Printer = struct {
    ctx: Ctx,
    arena: Allocator,
    args: []const []const u8,
    next: usize = 0,
    out: std.ArrayList(u8) = .empty,
    status: u8 = 0,

    /// POSIX reuses the format until the arguments run out; a pass that
    /// consumes nothing ends the loop, so a format without conversions prints
    /// exactly once.
    fn format(self: *Printer, text: []const u8) Allocator.Error!u8 {
        while (true) {
            const before = self.next;
            switch (try self.pass(text)) {
                .done => {},
                .stop => break,
                .fail => {
                    self.status = 1;
                    break;
                },
            }
            if (self.next >= self.args.len or self.next == before) break;
        }
        return self.status;
    }

    fn takeArg(self: *Printer) ?[]const u8 {
        if (self.next >= self.args.len) return null;
        defer self.next += 1;
        return self.args[self.next];
    }

    fn pass(self: *Printer, text: []const u8) Allocator.Error!Outcome {
        var i: usize = 0;
        while (i < text.len) {
            const c = text[i];
            if (c == '\\') {
                i = try self.formatEscape(text, i + 1);
                continue;
            }
            if (c != '%') {
                try self.out.append(self.arena, c);
                i += 1;
                continue;
            }
            i += 1;
            if (i < text.len and text[i] == '%') {
                try self.out.append(self.arena, '%');
                i += 1;
                continue;
            }

            var spec = Spec{};
            while (i < text.len) : (i += 1) {
                switch (text[i]) {
                    '-' => spec.left = true,
                    '+' => spec.plus = true,
                    ' ' => spec.space = true,
                    '#' => spec.alt = true,
                    '0' => spec.zero = true,
                    else => break,
                }
            }
            if (i < text.len and text[i] == '*') {
                i += 1;
                const width = self.signedArg();
                if (width < 0) spec.left = true;
                spec.width = @intCast(@min(@abs(width), std.math.maxInt(u32)));
            } else {
                spec.width = readCount(text, &i);
            }
            if (i < text.len and text[i] == '.') {
                i += 1;
                if (i < text.len and text[i] == '*') {
                    i += 1;
                    const precision = self.signedArg();
                    spec.precision = if (precision < 0) null else @intCast(@min(precision, std.math.maxInt(u32)));
                } else {
                    spec.precision = readCount(text, &i);
                }
            }
            while (i < text.len and std.mem.indexOfScalar(u8, "hlLjzt", text[i]) != null) i += 1;
            if (i >= text.len) {
                self.ctx.err("wsh: printf: `%': missing format character\n");
                return .fail;
            }

            const conversion = text[i];
            i += 1;
            switch (conversion) {
                'd', 'i' => {
                    const n = self.signedArg();
                    const negative = n < 0;
                    try self.integer(spec, @abs(n), negative, 10, false, true);
                },
                'o' => try self.integer(spec, self.unsignedArg(), false, 8, false, false),
                'u' => try self.integer(spec, self.unsignedArg(), false, 10, false, false),
                'x' => try self.integer(spec, self.unsignedArg(), false, 16, false, false),
                'X' => try self.integer(spec, self.unsignedArg(), false, 16, true, false),
                'c' => {
                    const arg = self.takeArg() orelse "";
                    const byte: []const u8 = if (arg.len == 0) "\x00" else arg[0..1];
                    try self.pad(spec, "", byte, false);
                },
                's' => {
                    const arg = self.takeArg() orelse "";
                    try self.pad(spec, "", truncate(arg, spec.precision), false);
                },
                'b' => {
                    var expanded: std.ArrayList(u8) = .empty;
                    const stop = try expandEscapes(self.arena, &expanded, self.takeArg() orelse "", self.ctx);
                    try self.pad(spec, "", truncate(expanded.items, spec.precision), false);
                    if (stop) return .stop;
                },
                'q' => {
                    var quoted: std.ArrayList(u8) = .empty;
                    try quote(self.arena, &quoted, self.takeArg() orelse "");
                    try self.pad(spec, "", truncate(quoted.items, spec.precision), false);
                },
                'e', 'E', 'f', 'F', 'g', 'G', 'a', 'A' => try self.float(spec, conversion, self.floatArg()),
                '(' => {
                    const close = std.mem.indexOfScalarPos(u8, text, i, ')') orelse {
                        self.ctx.err("wsh: printf: `(': missing closing parenthesis\n");
                        return .fail;
                    };
                    if (close + 1 >= text.len or text[close + 1] != 'T') {
                        self.ctx.err("wsh: printf: `(': time conversions are written %(format)T\n");
                        return .fail;
                    }
                    const time_format = text[i..close];
                    i = close + 2;
                    var stamp: ?[]const u8 = null;
                    try self.time(spec, time_format, &stamp);
                    if (stamp == null) return .fail;
                },
                else => {
                    self.ctx.errFmt("wsh: printf: `{c}': invalid format character\n", .{conversion});
                    return .fail;
                },
            }
        }
        return .done;
    }

    /// Handles the escape after a backslash in the format string and returns
    /// the index just past it.
    fn formatEscape(self: *Printer, text: []const u8, start: usize) Allocator.Error!usize {
        if (start >= text.len) {
            try self.out.append(self.arena, '\\');
            return start;
        }
        var i = start;
        const c = text[i];
        i += 1;
        switch (c) {
            '"', '\'', '?' => try self.out.append(self.arena, c),
            '0'...'7' => {
                var value: u32 = c - '0';
                var digits: usize = 1;
                while (digits < 3 and i < text.len and isOctal(text[i])) : (digits += 1) {
                    value = value * 8 + (text[i] - '0');
                    i += 1;
                }
                try self.out.append(self.arena, @truncate(value));
            },
            else => {
                if (try simpleEscape(self.arena, &self.out, c)) return i;
                if (c == 'x' or c == 'u' or c == 'U') return try hexEscape(self.arena, &self.out, text, i, c, self.ctx);
                try self.out.appendSlice(self.arena, &.{ '\\', c });
            },
        }
        return i;
    }

    /// `%(format)T`: the argument is seconds since the epoch, -1 (or no
    /// argument) is now. `stamp` stays null after a reported error.
    fn time(self: *Printer, spec: Spec, time_format: []const u8, stamp: *?[]const u8) Allocator.Error!void {
        var seconds: i64 = -1;
        if (self.next < self.args.len) seconds = self.signedArg();
        if (seconds == -1) {
            var ts: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.REALTIME, &ts);
            seconds = ts.sec;
        } else if (seconds == -2) {
            self.ctx.err("wsh: printf: -2: the shell start time is not recorded\n");
            return;
        }
        const tz = try self.timeZoneSetting();
        const zone = strftime.load(self.arena, tz) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidTimeZone => {
                self.ctx.errFmt("wsh: printf: TZ: cannot load time zone `{s}'\n", .{tz.?});
                return;
            },
        };
        var formatted: std.ArrayList(u8) = .empty;
        try strftime.format(self.arena, &formatted, if (time_format.len == 0) "%X" else time_format, strftime.localTime(zone, seconds));
        try self.pad(spec, "", truncate(formatted.items, spec.precision), false);
        stamp.* = formatted.items;
    }

    fn timeZoneSetting(self: *Printer) Allocator.Error!?[]const u8 {
        if (self.ctx.sh.getVar("TZ")) |v| {
            return switch (v) {
                .string => |s| s,
                else => v.renderAlloc(self.arena) catch return error.OutOfMemory,
            };
        }
        return self.ctx.sh.getEnv("TZ");
    }

    fn signedArg(self: *Printer) i64 {
        const text = self.takeArg() orelse return 0;
        if (charCode(text)) |code| return code;
        const parsed = parseInteger(text);
        self.checkNumber(text, parsed.end, parsed.digits, parsed.overflow);
        if (parsed.negative) {
            if (parsed.overflow or parsed.magnitude > @as(u64, 1) << 63) {
                if (!parsed.overflow) self.reportRange(text);
                return std.math.minInt(i64);
            }
            return @intCast(-@as(i128, parsed.magnitude));
        }
        if (parsed.overflow or parsed.magnitude > std.math.maxInt(i64)) {
            if (!parsed.overflow) self.reportRange(text);
            return std.math.maxInt(i64);
        }
        return @intCast(parsed.magnitude);
    }

    fn unsignedArg(self: *Printer) u64 {
        const text = self.takeArg() orelse return 0;
        if (charCode(text)) |code| return @intCast(code);
        const parsed = parseInteger(text);
        self.checkNumber(text, parsed.end, parsed.digits, parsed.overflow);
        if (parsed.overflow) return std.math.maxInt(u64);
        return if (parsed.negative) 0 -% parsed.magnitude else parsed.magnitude;
    }

    fn floatArg(self: *Printer) f80 {
        const text = self.takeArg() orelse return 0;
        if (charCode(text)) |code| return @floatFromInt(code);
        const scanned = scanFloat(text);
        if (scanned.end == 0) {
            self.reportInvalid(text);
            return 0;
        }
        if (scanned.end != text.len) self.reportInvalid(text);
        const body = std.mem.trimStart(u8, text[0..scanned.end], " \t\n\r\x0b\x0c");
        const unsigned = if (body[0] == '-' or body[0] == '+') body[1..] else body;
        const magnitude = std.fmt.parseFloat(f80, unsigned) catch {
            self.reportInvalid(text);
            return 0;
        };
        return if (body[0] == '-') -magnitude else magnitude;
    }

    fn checkNumber(self: *Printer, text: []const u8, end: usize, digits: bool, overflow: bool) void {
        if (!digits or end != text.len) {
            self.reportInvalid(text);
        } else if (overflow) {
            self.reportRange(text);
        }
    }

    fn reportInvalid(self: *Printer, text: []const u8) void {
        const kind = if (text.len > 1 and text[0] == '0' and std.ascii.isDigit(text[1]))
            "invalid octal number"
        else if (text.len > 1 and text[0] == '0' and text[1] == 'x')
            "invalid hex number"
        else
            "invalid number";
        self.ctx.errFmt("wsh: printf: {s}: {s}\n", .{ text, kind });
        self.status = 1;
    }

    fn reportRange(self: *Printer, text: []const u8) void {
        self.ctx.errFmt("wsh: printf: {s}: Numerical result out of range\n", .{text});
        self.status = 1;
    }

    fn integer(self: *Printer, spec: Spec, magnitude: u64, negative: bool, base: u8, upper: bool, signed: bool) Allocator.Error!void {
        var digit_buf: [64]u8 = undefined;
        var digits: []const u8 = digit_buf[0..std.fmt.printInt(&digit_buf, magnitude, base, if (upper) .upper else .lower, .{})];
        if (spec.precision) |precision| {
            if (precision == 0 and magnitude == 0) digits = "";
            if (digits.len < precision) {
                const padded = try self.arena.alloc(u8, precision);
                @memset(padded[0 .. precision - digits.len], '0');
                @memcpy(padded[precision - digits.len ..], digits);
                digits = padded;
            }
        }
        var prefix: []const u8 = "";
        if (signed) {
            if (negative) {
                prefix = "-";
            } else if (spec.plus) {
                prefix = "+";
            } else if (spec.space) {
                prefix = " ";
            }
        }
        if (spec.alt) {
            if (base == 8 and (digits.len == 0 or digits[0] != '0')) prefix = "0";
            if (base == 16 and magnitude != 0) prefix = if (upper) "0X" else "0x";
        }
        try self.pad(spec, prefix, digits, spec.precision == null);
    }

    fn float(self: *Printer, spec: Spec, conversion: u8, value: f80) Allocator.Error!void {
        const upper = std.ascii.isUpper(conversion);
        const negative = std.math.signbit(value);
        const sign: []const u8 = if (negative) "-" else if (spec.plus) "+" else if (spec.space) " " else "";
        if (std.math.isNan(value) or std.math.isInf(value)) {
            const word: []const u8 = if (std.math.isNan(value))
                (if (upper) "NAN" else "nan")
            else if (upper) "INF" else "inf";
            return self.pad(spec, sign, word, false);
        }

        const magnitude = @abs(value);
        var body: std.ArrayList(u8) = .empty;
        var prefix = sign;
        switch (std.ascii.toLower(conversion)) {
            'f' => try fixedNotation(self.arena, &body, magnitude, spec.precision orelse 6, spec.alt),
            'e' => try scientificNotation(self.arena, &body, magnitude, spec.precision orelse 6, spec.alt, upper),
            'g' => try generalNotation(self.arena, &body, magnitude, spec.precision orelse 6, spec.alt, upper),
            'a' => {
                prefix = try std.mem.concat(self.arena, u8, &.{ sign, if (upper) "0X" else "0x" });
                try hexNotation(self.arena, &body, magnitude, spec.precision, spec.alt, upper);
            },
            else => unreachable,
        }
        try self.pad(spec, prefix, body.items, true);
    }

    /// Writes `prefix` and `body` padded to the field width. Zero padding
    /// goes between the two, after any sign or `0x`.
    fn pad(self: *Printer, spec: Spec, prefix: []const u8, body: []const u8, zero_ok: bool) Allocator.Error!void {
        const len = prefix.len + body.len;
        const fill = if (spec.width > len) spec.width - len else 0;
        if (spec.left) {
            try self.out.appendSlice(self.arena, prefix);
            try self.out.appendSlice(self.arena, body);
            try self.out.appendNTimes(self.arena, ' ', fill);
        } else if (spec.zero and zero_ok) {
            try self.out.appendSlice(self.arena, prefix);
            try self.out.appendNTimes(self.arena, '0', fill);
            try self.out.appendSlice(self.arena, body);
        } else {
            try self.out.appendNTimes(self.arena, ' ', fill);
            try self.out.appendSlice(self.arena, prefix);
            try self.out.appendSlice(self.arena, body);
        }
    }
};

fn readCount(text: []const u8, i: *usize) usize {
    var n: usize = 0;
    while (i.* < text.len and std.ascii.isDigit(text[i.*])) : (i.* += 1) {
        n = @min(n * 10 + (text[i.*] - '0'), std.math.maxInt(u32));
    }
    return n;
}

fn truncate(text: []const u8, precision: ?usize) []const u8 {
    const limit = precision orelse return text;
    return text[0..@min(limit, text.len)];
}

fn isOctal(c: u8) bool {
    return c >= '0' and c <= '7';
}

/// Single-character escapes shared by the format string and `%b`.
fn simpleEscape(arena: Allocator, out: *std.ArrayList(u8), c: u8) Allocator.Error!bool {
    const byte: u8 = switch (c) {
        'a' => 0x07,
        'b' => 0x08,
        'e', 'E' => 0x1b,
        'f' => 0x0c,
        'n' => '\n',
        'r' => '\r',
        't' => '\t',
        'v' => 0x0b,
        '\\' => '\\',
        else => return false,
    };
    try out.append(arena, byte);
    return true;
}

/// `\xHH`, `\uHHHH` and `\UHHHHHHHH`. Returns the index past the digits.
fn hexEscape(arena: Allocator, out: *std.ArrayList(u8), text: []const u8, start: usize, kind: u8, ctx: Ctx) Allocator.Error!usize {
    const max_digits: usize = switch (kind) {
        'x' => 2,
        'u' => 4,
        else => 8,
    };
    var i = start;
    var value: u32 = 0;
    while (i - start < max_digits and i < text.len and std.ascii.isHex(text[i])) : (i += 1) {
        value = value * 16 + (std.fmt.charToDigit(text[i], 16) catch unreachable);
    }
    if (i == start) {
        if (kind == 'x') {
            ctx.err("wsh: printf: missing hex digit for \\x\n");
        } else {
            ctx.errFmt("wsh: printf: missing unicode digit for \\{c}\n", .{kind});
        }
        try out.appendSlice(arena, &.{ '\\', kind });
        return i;
    }
    if (kind == 'x') {
        try out.append(arena, @truncate(value));
        return i;
    }
    var buf: [4]u8 = undefined;
    const cp = std.math.cast(u21, value) orelse {
        try out.appendSlice(arena, text[start - 2 .. i]);
        return i;
    };
    const len = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(arena, text[start - 2 .. i]);
        return i;
    };
    try out.appendSlice(arena, buf[0..len]);
    return i;
}

/// Expands the escapes `%b` and `echo -e` understand. Returns true when `\c`
/// asked for all further output to be suppressed.
pub fn expandEscapes(arena: Allocator, out: *std.ArrayList(u8), text: []const u8, ctx: Ctx) Allocator.Error!bool {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != '\\' or i + 1 >= text.len) {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        const c = text[i + 1];
        i += 2;
        switch (c) {
            'c' => return true,
            '0'...'7' => {
                // `\0nnn` takes up to three digits after the zero; `\nnn` up
                // to three in total.
                var value: u32 = 0;
                var digits: usize = 0;
                const limit: usize = if (c == '0') 3 else 2;
                if (c != '0') value = c - '0';
                while (digits < limit and i < text.len and isOctal(text[i])) : (digits += 1) {
                    value = value * 8 + (text[i] - '0');
                    i += 1;
                }
                try out.append(arena, @truncate(value));
            },
            else => {
                if (try simpleEscape(arena, out, c)) continue;
                if (c == 'x' or c == 'u' or c == 'U') {
                    i = try hexEscape(arena, out, text, i, c, ctx);
                    continue;
                }
                try out.appendSlice(arena, &.{ '\\', c });
            },
        }
    }
    return false;
}

// --- shell quoting -----------------------------------------------------------

/// Quotes `text` so the shell reads it back as one word, the way bash's
/// `printf %q` does: `$'...'` when it holds unprintable bytes, backslashes
/// before special characters otherwise.
pub fn quote(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    if (text.len == 0) return out.appendSlice(arena, "''");
    if (needsAnsiQuote(text)) return ansiQuote(arena, out, text);
    for (text, 0..) |c, i| {
        const special = switch (c) {
            ' ', '\t', '\n', '\'', '"', '\\', '|', '&', ';', '(', ')', '<', '>', '!', '{', '}', '*', '[', '?', ']', '^', '$', '`', ',' => true,
            '#', '~' => i == 0,
            else => false,
        };
        if (special) try out.append(arena, '\\');
        try out.append(arena, c);
    }
}

/// Length of the printable UTF-8 character at the start of `text`, or null
/// for a control character or an invalid sequence.
fn printableLen(text: []const u8) ?usize {
    const c = text[0];
    if (c < 0x80) return if (c >= 0x20 and c != 0x7f) 1 else null;
    const len = std.unicode.utf8ByteSequenceLength(c) catch return null;
    if (len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[0..len]) catch return null;
    // C1 controls are not printable.
    if (cp < 0xa0) return null;
    return len;
}

pub fn needsAnsiQuote(text: []const u8) bool {
    var i: usize = 0;
    while (i < text.len) {
        i += printableLen(text[i..]) orelse return true;
    }
    return false;
}

pub fn ansiQuote(arena: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.appendSlice(arena, "$'");
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        const escape: ?u8 = switch (c) {
            0x1b => 'E',
            0x07 => 'a',
            0x0b => 'v',
            0x08 => 'b',
            0x0c => 'f',
            '\n' => 'n',
            '\r' => 'r',
            '\t' => 't',
            '\\' => '\\',
            '\'' => '\'',
            else => null,
        };
        if (escape) |e| {
            try out.appendSlice(arena, &.{ '\\', e });
            i += 1;
        } else if (printableLen(text[i..])) |len| {
            try out.appendSlice(arena, text[i .. i + len]);
            i += len;
        } else {
            try out.print(arena, "\\{o:0>3}", .{c});
            i += 1;
        }
    }
    try out.append(arena, '\'');
}

// --- numbers -----------------------------------------------------------------

/// `'c` and `"c` give the code of the character after the quote.
fn charCode(text: []const u8) ?i64 {
    if (text.len == 0 or (text[0] != '\'' and text[0] != '"')) return null;
    if (text.len == 1) return 0;
    const rest = text[1..];
    if (std.unicode.utf8ByteSequenceLength(rest[0])) |len| {
        if (len <= rest.len) {
            if (std.unicode.utf8Decode(rest[0..len])) |cp| return cp else |_| {}
        }
    } else |_| {}
    return rest[0];
}

const ParsedInteger = struct {
    magnitude: u64 = 0,
    negative: bool = false,
    /// True when at least one digit was read.
    digits: bool = false,
    overflow: bool = false,
    /// Index just past the parsed prefix.
    end: usize = 0,
};

fn isCSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

/// Parses a leading integer like `strtoimax(text, &end, 0)`: optional
/// whitespace and sign, then hex (`0x`), octal (leading `0`) or decimal.
fn parseInteger(text: []const u8) ParsedInteger {
    var result = ParsedInteger{};
    var i: usize = 0;
    while (i < text.len and isCSpace(text[i])) i += 1;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) {
        result.negative = text[i] == '-';
        i += 1;
    }
    var base: u8 = 10;
    if (i + 2 < text.len and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X') and std.ascii.isHex(text[i + 2])) {
        base = 16;
        i += 2;
    } else if (i < text.len and text[i] == '0') {
        base = 8;
    }
    while (i < text.len) : (i += 1) {
        const digit = std.fmt.charToDigit(text[i], base) catch break;
        result.digits = true;
        const shifted = @mulWithOverflow(result.magnitude, base);
        const added = @addWithOverflow(shifted[0], digit);
        if (shifted[1] != 0 or added[1] != 0) result.overflow = true;
        result.magnitude = added[0];
    }
    result.end = if (result.digits) i else 0;
    return result;
}

const ScannedFloat = struct { end: usize };

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    return text.len >= prefix.len and std.ascii.eqlIgnoreCase(text[0..prefix.len], prefix);
}

/// Finds the longest prefix `strtold` would accept. `end` is 0 when there is
/// no number at all.
fn scanFloat(text: []const u8) ScannedFloat {
    var i: usize = 0;
    while (i < text.len and isCSpace(text[i])) i += 1;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const rest = text[i..];
    if (startsWithIgnoreCase(rest, "infinity")) return .{ .end = i + 8 };
    if (startsWithIgnoreCase(rest, "inf") or startsWithIgnoreCase(rest, "nan")) return .{ .end = i + 3 };

    const hex = rest.len > 2 and rest[0] == '0' and (rest[1] == 'x' or rest[1] == 'X') and
        (std.ascii.isHex(rest[2]) or (rest[2] == '.' and rest.len > 3 and std.ascii.isHex(rest[3])));
    const base: u8 = if (hex) 16 else 10;
    if (hex) i += 2;

    var digits = false;
    while (i < text.len and (std.fmt.charToDigit(text[i], base) catch null) != null) : (i += 1) digits = true;
    if (i < text.len and text[i] == '.') {
        var j = i + 1;
        var fraction = false;
        while (j < text.len and (std.fmt.charToDigit(text[j], base) catch null) != null) : (j += 1) fraction = true;
        if (digits or fraction) {
            digits = true;
            i = j;
        }
    }
    if (!digits) return .{ .end = 0 };

    const exp_char: u8 = if (hex) 'p' else 'e';
    if (i < text.len and std.ascii.toLower(text[i]) == exp_char) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        if (j < text.len and std.ascii.isDigit(text[j])) {
            while (j < text.len and std.ascii.isDigit(text[j])) j += 1;
            i = j;
        }
    }
    return .{ .end = i };
}

// --- floating-point formatting ----------------------------------------------

/// The exact decimal value of a finite, non-negative float: `digits` is an
/// integer without leading zeros and the value is `digits * 10^exponent`.
const Exact = struct {
    digits: []const u8,
    exponent: i64,
};

fn exactDecimal(arena: Allocator, value: f80) Allocator.Error!Exact {
    if (value == 0) return .{ .digits = "0", .exponent = 0 };
    const bits: u80 = @bitCast(value);
    var mantissa: u64 = @truncate(bits);
    const biased: i64 = @intCast((bits >> 64) & 0x7fff);
    var exp2: i64 = (if (biased == 0) 1 else biased) - 16383 - 63;
    const zeros = @ctz(mantissa);
    mantissa >>= @intCast(zeros);
    exp2 += zeros;

    var number = try Managed.initSet(arena, mantissa);
    var exponent: i64 = 0;
    if (exp2 >= 0) {
        var shifted = try Managed.init(arena);
        try shifted.shiftLeft(&number, @intCast(exp2));
        number = shifted;
    } else {
        // m / 2^k == m * 5^k / 10^k
        const k: u32 = @intCast(-exp2);
        const five = try Managed.initSet(arena, 5);
        var power = try Managed.init(arena);
        try power.pow(&five, k);
        var product = try Managed.init(arena);
        try product.mul(&number, &power);
        number = product;
        exponent = exp2;
    }
    const digits = number.toString(arena, 10, .lower) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidBase => unreachable,
    };
    return .{ .digits = digits, .exponent = exponent };
}

/// Keeps the leading `keep` digits of `digits`, rounding half to even on the
/// exact remainder. The result can be one digit longer after a carry; with
/// `keep <= 0` it is "0" or "1".
fn roundDigits(arena: Allocator, digits: []const u8, keep: i64) Allocator.Error![]u8 {
    if (keep >= digits.len) {
        const out = try arena.alloc(u8, @intCast(keep));
        @memcpy(out[0..digits.len], digits);
        @memset(out[digits.len..], '0');
        return out;
    }
    if (keep < 0) return arena.dupe(u8, "0");

    const k: usize = @intCast(keep);
    const dropped = digits[k..];
    const last_odd = k > 0 and (digits[k - 1] - '0') % 2 == 1;
    const round_up = switch (std.math.order(dropped[0], '5')) {
        .gt => true,
        .lt => false,
        .eq => std.mem.indexOfNone(u8, dropped[1..], "0") != null or last_odd,
    };
    if (k == 0) return arena.dupe(u8, if (round_up) "1" else "0");

    var out = try arena.alloc(u8, k + 1);
    @memcpy(out[1..], digits[0..k]);
    out[0] = '0';
    if (round_up) {
        var j = k;
        while (true) : (j -= 1) {
            if (out[j] == '9') {
                out[j] = '0';
                continue;
            }
            out[j] += 1;
            break;
        }
    }
    return if (out[0] == '0') out[1..] else out;
}

fn fixedNotation(arena: Allocator, out: *std.ArrayList(u8), value: f80, precision: usize, alt: bool) Allocator.Error!void {
    const exact = try exactDecimal(arena, value);
    const keep = @as(i64, @intCast(exact.digits.len)) + exact.exponent + @as(i64, @intCast(precision));
    var scaled: []const u8 = try roundDigits(arena, exact.digits, keep);
    if (scaled.len <= precision) {
        const padded = try arena.alloc(u8, precision + 1);
        @memset(padded[0 .. padded.len - scaled.len], '0');
        @memcpy(padded[padded.len - scaled.len ..], scaled);
        scaled = padded;
    }
    try out.appendSlice(arena, scaled[0 .. scaled.len - precision]);
    if (precision != 0 or alt) try out.append(arena, '.');
    try out.appendSlice(arena, scaled[scaled.len - precision ..]);
}

/// Rounds to `significant` digits and returns them with the decimal exponent
/// of the first one.
fn significantDigits(arena: Allocator, value: f80, significant: usize) Allocator.Error!struct { digits: []const u8, exponent: i64 } {
    const exact = try exactDecimal(arena, value);
    var exponent = @as(i64, @intCast(exact.digits.len)) - 1 + exact.exponent;
    if (value == 0) exponent = 0;
    var digits = try roundDigits(arena, exact.digits, @intCast(significant));
    if (digits.len > significant) {
        exponent += 1;
        digits = digits[0..significant];
    }
    return .{ .digits = digits, .exponent = exponent };
}

fn scientificNotation(arena: Allocator, out: *std.ArrayList(u8), value: f80, precision: usize, alt: bool, upper: bool) Allocator.Error!void {
    const rounded = try significantDigits(arena, value, precision + 1);
    try writeScientific(arena, out, rounded.digits, rounded.exponent, alt, upper);
}

fn writeScientific(arena: Allocator, out: *std.ArrayList(u8), digits: []const u8, exponent: i64, alt: bool, upper: bool) Allocator.Error!void {
    try out.append(arena, digits[0]);
    if (digits.len > 1 or alt) try out.append(arena, '.');
    try out.appendSlice(arena, digits[1..]);
    try out.append(arena, if (upper) 'E' else 'e');
    try out.append(arena, if (exponent < 0) '-' else '+');
    try out.print(arena, "{d:0>2}", .{@abs(exponent)});
}

fn generalNotation(arena: Allocator, out: *std.ArrayList(u8), value: f80, requested: usize, alt: bool, upper: bool) Allocator.Error!void {
    const precision = @max(requested, 1);
    const rounded = try significantDigits(arena, value, precision);
    const start = out.items.len;
    if (rounded.exponent < precision and rounded.exponent >= -4) {
        const fraction: usize = @intCast(@as(i64, @intCast(precision)) - 1 - rounded.exponent);
        try fixedNotation(arena, out, value, fraction, alt);
        if (!alt) stripFraction(out, start, out.items.len);
        return;
    }
    try writeScientific(arena, out, rounded.digits, rounded.exponent, alt, upper);
    if (!alt) {
        const e = std.mem.lastIndexOfScalar(u8, out.items[start..], if (upper) 'E' else 'e').? + start;
        const tail = try arena.dupe(u8, out.items[e..]);
        stripFraction(out, start, e);
        try out.appendSlice(arena, tail);
    }
}

/// Drops trailing zeros (and a bare decimal point) from the number in
/// `out.items[start..end]`, which must be the end of the buffer.
fn stripFraction(out: *std.ArrayList(u8), start: usize, end: usize) void {
    const number = out.items[start..end];
    if (std.mem.indexOfScalar(u8, number, '.') == null) {
        out.shrinkRetainingCapacity(end);
        return;
    }
    var len = number.len;
    while (len > 0 and number[len - 1] == '0') len -= 1;
    if (len > 0 and number[len - 1] == '.') len -= 1;
    out.shrinkRetainingCapacity(start + len);
}

/// `%a` the way glibc prints a `long double`: the leading hex digit is the
/// top nibble of the 64-bit significand.
fn hexNotation(arena: Allocator, out: *std.ArrayList(u8), value: f80, precision: ?usize, alt: bool, upper: bool) Allocator.Error!void {
    const bits: u80 = @bitCast(value);
    const mantissa: u64 = @truncate(bits);
    const biased: i64 = @intCast((bits >> 64) & 0x7fff);
    var exponent: i64 = if (value == 0) 0 else (if (biased == 0) 1 else biased) - 16383 - 3;

    var digits: [17]u8 = undefined;
    var count: usize = 16;
    var kept: u128 = mantissa;
    if (precision) |p| {
        if (p < 15) {
            count = p + 1;
            const shift: u7 = @intCast(4 * (16 - count));
            const rest = kept & ((@as(u128, 1) << shift) - 1);
            const half = @as(u128, 1) << (shift - 1);
            kept >>= shift;
            if (rest > half or (rest == half and kept & 1 == 1)) kept += 1;
            if (kept >> @intCast(4 * count) != 0) {
                // A carry out of the leading digit renormalises to 0x1.
                kept = @as(u128, 1) << @intCast(4 * (count - 1));
                exponent += 4;
            }
        }
    }
    const case: std.fmt.Case = if (upper) .upper else .lower;
    _ = std.fmt.printInt(&digits, kept, 16, case, .{ .width = count, .fill = '0' });
    if (value == 0) @memset(digits[0..count], '0');

    var fraction: []const u8 = digits[1..count];
    if (precision) |p| {
        if (p > fraction.len) {
            try out.append(arena, digits[0]);
            try out.append(arena, '.');
            try out.appendSlice(arena, fraction);
            try out.appendNTimes(arena, '0', p - fraction.len);
            return finishHex(arena, out, exponent, upper);
        }
    } else {
        fraction = std.mem.trimEnd(u8, fraction, "0");
    }
    try out.append(arena, digits[0]);
    if (fraction.len != 0 or alt) try out.append(arena, '.');
    try out.appendSlice(arena, fraction);
    try finishHex(arena, out, exponent, upper);
}

fn finishHex(arena: Allocator, out: *std.ArrayList(u8), exponent: i64, upper: bool) Allocator.Error!void {
    try out.append(arena, if (upper) 'P' else 'p');
    try out.append(arena, if (exponent < 0) '-' else '+');
    try out.print(arena, "{d}", .{@abs(exponent)});
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;
const shellmod = @import("../shell.zig");

fn expectPrintf(expected: []const u8, expected_status: u8, argv: []const []const u8) !void {
    var sh = try shellmod.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var fds: [2]i32 = undefined;
    const linux = std.os.linux;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    const status = run(.{ .sh = &sh, .argv = argv, .stdout = fds[1], .stderr = -1 });
    _ = linux.close(fds[1]);
    var buf: [4096]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const rc = linux.read(fds[0], buf[len..].ptr, buf.len - len);
        if (linux.errno(rc) != .SUCCESS or rc == 0) break;
        len += rc;
    }
    _ = linux.close(fds[0]);
    try testing.expectEqualStrings(expected, buf[0..len]);
    try testing.expectEqual(expected_status, status);
}

test "printf formats, escapes and reuses its format" {
    try expectPrintf("a=3\nx\ny\n", 0, &.{ "printf", "%s=%d\\n%s\\n%s\\n", "a", "3", "x", "y" });
    try expectPrintf("Z%hi\ne%hi\n", 0, &.{ "printf", "%c%%hi\\n", "Z", "extra" });
    try expectPrintf("hi\n", 0, &.{ "printf", "hi\\n", "a", "b" });
    try expectPrintf("ab    |   cd|\n", 0, &.{ "printf", "%-6s|%5s|\\n", "ab", "cd" });
    try expectPrintf("00042|-7   |+5| 6|\n", 0, &.{ "printf", "%05d|%-5d|%+d|% d|\\n", "42", "-7", "5", "6" });
    try expectPrintf("ff FF 10 0xff 010 18446744073709551615\n", 0, &.{ "printf", "%x %X %o %#x %#o %u\\n", "255", "255", "8", "255", "8", "-1" });
    try expectPrintf("   42|7   |3.14\n", 0, &.{ "printf", "%*d|%-*d|%.*f\\n", "5", "42", "4", "7", "2", "3.14159" });
    try expectPrintf("|007|     007|\n", 0, &.{ "printf", "%.0d|%.3d|%08.3d|\\n", "0", "7", "7" });
    try expectPrintf("65 66 233\n", 0, &.{ "printf", "%d %d %d\\n", "'A", "\"B", "'\xc3\xa9" });
    try expectPrintf("A\x081A\xc3\xa9\n", 0, &.{ "printf", "\\101\\0101\\x41\\u00e9\\n" });
    try expectPrintf("a\\qb\"c'd?e", 0, &.{ "printf", "a\\qb\\\"c\\'d\\?e" });
}

test "printf reports invalid numbers and formats" {
    try expectPrintf("0\n", 1, &.{ "printf", "%d\\n", "abc" });
    try expectPrintf("12\n", 1, &.{ "printf", "%d\\n", "12abc" });
    try expectPrintf("9223372036854775807\n", 1, &.{ "printf", "%d\\n", "99999999999999999999" });
    try expectPrintf("31 8 -16\n", 0, &.{ "printf", "%d %d %d\\n", "0x1f", "010", "-0x10" });
    try expectPrintf("", 1, &.{ "printf", "%z" });
    try expectPrintf("abc", 1, &.{ "printf", "abc%" });
    try expectPrintf("", 1, &.{ "printf", "%5%" });
    try expectPrintf("", 2, &.{"printf"});
    try expectPrintf("", 2, &.{ "printf", "-x", "y" });
}

test "printf %b and %q" {
    try expectPrintf("a\tb|cAd|\n", 0, &.{ "printf", "%b|%b|\\n", "a\\tb", "c\\0101d" });
    try expectPrintf("xstop", 0, &.{ "printf", "x%by\\n", "stop\\cnow", "more" });
    try expectPrintf("a\\ b it\\'s '' \\~a a~ \\#a a# a=b\n", 0, &.{ "printf", "%q %q %q %q %q %q %q %q\\n", "a b", "it's", "", "~a", "a~", "#a", "a#", "a=b" });
    try expectPrintf("$'a\\tb' $'\\001' \xc3\xa9\n", 0, &.{ "printf", "%q %q %q\\n", "a\tb", "\x01", "\xc3\xa9" });
}

test "printf floating point matches long double output" {
    try expectPrintf("abc|      3.14|1.234e+03 |\n", 0, &.{ "printf", "%.3s|%10.2f|%-10.3e|\\n", "abcdef", "3.14159", "1234.5" });
    try expectPrintf("0.0001 1e+10 100000 1.23457e+06 1E-05\n", 0, &.{ "printf", "%g %g %g %g %G\\n", "0.0001", "1e10", "100000", "1234567", "0.00001" });
    try expectPrintf("0 2 2 2.67\n", 0, &.{ "printf", "%.0f %.0f %.0f %.2f\\n", "0.5", "1.5", "2.5", "2.675" });
    try expectPrintf("0x8p-3 0XC.CCCCCCCCCCCCCCDP-7\n", 0, &.{ "printf", "%a %A\\n", "1", "0.1" });
    try expectPrintf("0x1.000p+1 0x0p+0 -0x8p-2 0x0000008p-3\n", 0, &.{ "printf", "%.3a %a %a %012a\\n", "1.999999", "0", "-2", "1" });
    try expectPrintf("1.00000 1.00 1e-05 1.23457e+08\n", 0, &.{ "printf", "%#g %#.3g %g %g\\n", "1", "1", "1e-5", "123456789" });
    try expectPrintf("-inf nan -nan   inf\n", 0, &.{ "printf", "%f %e %g %05f\\n", "-inf", "nan", "-nan", "inf" });
    try expectPrintf("0.1 0.1 1.000e+01 -001.500\n", 0, &.{ "printf", "%.17g %.20g %.3e %08.3f\\n", "0.1", "0.1", "9.9996", "-1.5" });
    try expectPrintf("3.500000\n", 1, &.{ "printf", "%f\\n", "3.5abc" });
}
