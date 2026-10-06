//! `read` and `mapfile`/`readarray`: delimited input from a file descriptor.
//!
//! Pipes and terminals are read one byte at a time so nothing past the
//! delimiter is consumed; seekable inputs (files, here-documents) are read in
//! chunks and the unused tail is given back with `lseek`, like bash does.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const printf = @import("printf.zig");
const shellmod = @import("../shell.zig");
const value = @import("../value.zig");
const sys = @import("../sys.zig");
const arith = @import("../arith.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;
const Allocator = std.mem.Allocator;

/// Status of a read that hit its `-t` deadline: 128 + SIGALRM, as in bash.
const timeout_status: u8 = 142;
const interrupt_status: u8 = 130;

const Event = union(enum) {
    byte: u8,
    eof,
    timeout,
    interrupted,
    failed: linux.E,
};

const Input = struct {
    sh: *Shell,
    fd: i32,
    /// Monotonic deadline in nanoseconds for `-t`.
    deadline: ?i128 = null,
    /// Seekable descriptors may be over-read because the excess is given
    /// back; `greedy` allows it for a pipe when the caller drains it anyway.
    seekable: bool,
    greedy: bool = false,
    buf: [4096]u8 = undefined,
    start: usize = 0,
    end: usize = 0,

    fn init(sh: *Shell, fd: i32) Input {
        const rc = linux.lseek(fd, 0, linux.SEEK.CUR);
        return .{ .sh = sh, .fd = fd, .seekable = linux.errno(rc) == .SUCCESS };
    }

    fn next(self: *Input) Event {
        if (self.start < self.end) {
            defer self.start += 1;
            return .{ .byte = self.buf[self.start] };
        }
        if (self.deadline) |deadline| {
            switch (self.waitReadable(deadline)) {
                .ready => {},
                .timeout => return .timeout,
                .interrupted => return .interrupted,
            }
        }
        const want: usize = if (self.seekable or self.greedy) self.buf.len else 1;
        while (true) {
            const rc = linux.read(self.fd, &self.buf, want);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) return .eof;
                    self.start = 1;
                    self.end = rc;
                    return .{ .byte = self.buf[0] };
                },
                .INTR => if (self.sh.interrupted) return .interrupted,
                .AGAIN => switch (self.waitReadable(self.deadline)) {
                    .ready => {},
                    .timeout => return .timeout,
                    .interrupted => return .interrupted,
                },
                else => |e| return .{ .failed = e },
            }
        }
    }

    const Wait = enum { ready, timeout, interrupted };

    fn waitReadable(self: *Input, deadline: ?i128) Wait {
        while (true) {
            var timeout_ms: i32 = -1;
            if (deadline) |d| {
                const left = d - now();
                if (left <= 0) return .timeout;
                timeout_ms = @intCast(@min(@divTrunc(left + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32)));
            }
            var fds = [_]linux.pollfd{.{ .fd = self.fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&fds, 1, timeout_ms);
            switch (linux.errno(rc)) {
                .SUCCESS => if (rc != 0) return .ready,
                .INTR => if (self.sh.interrupted) return .interrupted,
                else => return .ready,
            }
        }
    }

    /// Hands back whatever was read past the point the caller stopped at.
    fn finish(self: *Input) void {
        if (self.seekable and self.end > self.start) {
            const back: i64 = @intCast(self.end - self.start);
            _ = linux.lseek(self.fd, -back, linux.SEEK.CUR);
        }
        self.start = self.end;
    }
};

fn now() i128 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
}

fn validFd(fd: i32) bool {
    return linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) == .SUCCESS;
}

/// Parses the `-u` operand; reports and returns null when it is unusable.
fn parseFd(ctx: Ctx, name: []const u8, text: []const u8) ?i32 {
    const fd = std.fmt.parseInt(i32, text, 10) catch {
        ctx.errFmt("wsh: {s}: {s}: invalid file descriptor specification\n", .{ name, text });
        return null;
    };
    if (fd < 0 or !validFd(fd)) {
        ctx.errFmt("wsh: {s}: {s}: invalid file descriptor: Bad file descriptor\n", .{ name, text });
        return null;
    }
    return fd;
}

/// `-t` accepts a non-negative decimal number of seconds, fractions allowed.
fn parseTimeout(text: []const u8) ?i128 {
    if (text.len == 0) return null;
    var seconds: i128 = 0;
    var i: usize = 0;
    while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
        seconds = @min(seconds * 10 + (text[i] - '0'), std.math.maxInt(u32));
    }
    var nanos: i128 = 0;
    if (i < text.len and text[i] == '.') {
        i += 1;
        var scale: i128 = std.time.ns_per_s / 10;
        while (i < text.len and std.ascii.isDigit(text[i])) : (i += 1) {
            nanos += (text[i] - '0') * scale;
            scale = @divTrunc(scale, 10);
        }
    }
    if (i != text.len or std.mem.eql(u8, text, ".")) return null;
    return seconds * std.time.ns_per_s + nanos;
}

/// Current `IFS`: a shell variable first, then the environment (where
/// command-prefix assignments live), then the POSIX default.
pub fn currentIfs(sh: *Shell, arena: Allocator) Allocator.Error![]const u8 {
    if (sh.getVar("IFS")) |v| {
        return switch (v) {
            .string => |s| s,
            else => v.renderAlloc(arena) catch return error.OutOfMemory,
        };
    }
    return sh.getEnv("IFS") orelse " \t\n";
}

/// Puts a terminal into the mode `read -s`/`-n` need and restores it.
const TerminalMode = struct {
    fd: i32,
    saved: ?posix.termios = null,

    fn enter(fd: i32, silent: bool, char_mode: bool) TerminalMode {
        var mode = TerminalMode{ .fd = fd };
        if (!silent and !char_mode) return mode;
        const original = posix.tcgetattr(fd) catch return mode;
        var changed = original;
        if (silent) {
            changed.lflag.ECHO = false;
            changed.lflag.ECHOK = false;
            changed.lflag.ECHONL = false;
        }
        if (char_mode) {
            changed.lflag.ICANON = false;
            changed.cc[@intFromEnum(posix.V.MIN)] = 1;
            changed.cc[@intFromEnum(posix.V.TIME)] = 0;
        }
        posix.tcsetattr(fd, .NOW, changed) catch return mode;
        mode.saved = original;
        return mode;
    }

    fn leave(self: TerminalMode) void {
        if (self.saved) |original| posix.tcsetattr(self.fd, .NOW, original) catch {};
    }
};

// --- read --------------------------------------------------------------------

const read_usage = "wsh: read: usage: read [-rs] [-a array] [-d delim] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]\n";

/// The bytes of one record, with a flag per byte saying whether a backslash
/// escaped it (escaped bytes never split fields).
const Line = struct {
    bytes: std.ArrayList(u8) = .empty,
    escaped: std.ArrayList(bool) = .empty,

    fn append(self: *Line, arena: Allocator, c: u8, escaped: bool) Allocator.Error!void {
        try self.bytes.append(arena, c);
        try self.escaped.append(arena, escaped);
    }
};

pub fn read(ctx: Ctx) u8 {
    var raw = false;
    var silent = false;
    var array: ?[]const u8 = null;
    var delim: u8 = '\n';
    var nchars: ?usize = null;
    var exact = false;
    var prompt: ?[]const u8 = null;
    var timeout: ?i128 = null;
    var fd = ctx.stdin;

    var parser = options.Parser.init(ctx.argv, "ra:d:n:N:p:st:u:eiE");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid => |c| {
                ctx.errFmt("wsh: read: -{c}: invalid option\n", .{c});
                ctx.err(read_usage);
                return 2;
            },
            .missing => |c| {
                ctx.errFmt("wsh: read: -{c}: option requires an argument\n", .{c});
                ctx.err(read_usage);
                return 2;
            },
            .option => |c| switch (c) {
                'r' => raw = true,
                's' => silent = true,
                'a' => array = parser.optarg,
                'd' => delim = if (parser.optarg.len == 0) 0 else parser.optarg[0],
                'n', 'N' => {
                    nchars = std.fmt.parseInt(usize, parser.optarg, 10) catch {
                        ctx.errFmt("wsh: read: {s}: invalid number\n", .{parser.optarg});
                        return 1;
                    };
                    exact = c == 'N';
                },
                'p' => prompt = parser.optarg,
                't' => timeout = parseTimeout(parser.optarg) orelse {
                    ctx.errFmt("wsh: read: {s}: invalid timeout specification\n", .{parser.optarg});
                    return 1;
                },
                'u' => fd = parseFd(ctx, "read", parser.optarg) orelse return 1,
                else => {
                    ctx.errFmt("wsh: read: -{c}: line editing is not supported\n", .{c});
                    return 2;
                },
            },
        }
    }

    const names = parser.rest();
    for (names) |name| {
        if (!builtins.validName(name)) {
            ctx.errFmt("wsh: read: `{s}': not a valid identifier\n", .{name});
            return 1;
        }
    }
    if (array) |name| {
        if (!builtins.validName(name)) {
            ctx.errFmt("wsh: read: `{s}': not a valid identifier\n", .{name});
            return 1;
        }
    }

    // `-t 0` only asks whether input is waiting.
    if (timeout) |t| {
        if (t == 0) {
            var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.IN, .revents = 0 }};
            const rc = linux.poll(&fds, 1, 0);
            return if (linux.errno(rc) == .SUCCESS and rc != 0) 0 else 1;
        }
    }

    const is_tty = sys.isTty(fd);
    if (prompt) |text| {
        if (is_tty) ctx.err(text);
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const terminal = if (is_tty) TerminalMode.enter(fd, silent, nchars != null or delim != '\n') else TerminalMode{ .fd = fd };
    defer terminal.leave();

    var input = Input.init(ctx.sh, fd);
    if (timeout) |t| input.deadline = now() + t;
    var line = Line{};
    const status = readRecord(ctx, &input, arena, &line, .{
        .raw = raw,
        .delim = delim,
        .nchars = nchars,
        .exact = exact,
    }) catch {
        input.finish();
        ctx.err("wsh: read: out of memory\n");
        return 1;
    };
    input.finish();
    if (status == interrupt_status) return status;
    if (status == 2) return 1;

    const assigned = assignRecord(ctx, arena, &line, names, array, exact) catch {
        ctx.err("wsh: read: out of memory\n");
        return 1;
    };
    return if (assigned) status else 1;
}

const RecordOptions = struct {
    raw: bool,
    delim: u8,
    nchars: ?usize,
    exact: bool,
};

/// Reads one record into `line`. Returns 0 when the delimiter (or the
/// character count) ended it, 1 at end of input, `timeout_status` or
/// `interrupt_status`, and 2 after reporting a read error.
fn readRecord(ctx: Ctx, input: *Input, arena: Allocator, line: *Line, opts: RecordOptions) Allocator.Error!u8 {
    var count: usize = 0;
    var escape_pending = false;
    // Continuation bytes still owed to the last multibyte character.
    var continuation: usize = 0;
    while (true) {
        if (continuation == 0) {
            if (opts.nchars) |limit| {
                if (count >= limit) return 0;
            }
        }
        const c = switch (input.next()) {
            .byte => |b| b,
            .eof => return 1,
            .timeout => return timeout_status,
            .interrupted => return interrupt_status,
            .failed => |e| {
                ctx.errFmt("wsh: read: read error: {d}: {s}\n", .{ input.fd, @tagName(e) });
                return 2;
            },
        };
        if (continuation != 0) {
            continuation -= 1;
            try line.append(arena, c, escape_pending);
            continue;
        }
        if (escape_pending) {
            escape_pending = false;
            // A backslash-newline pair is a line continuation.
            if (c == '\n') continue;
            try line.append(arena, c, true);
            count += 1;
            continuation = utf8Continuations(c);
            continue;
        }
        if (!opts.raw and c == '\\') {
            escape_pending = true;
            continue;
        }
        if (c == opts.delim and !opts.exact) return 0;
        if (c == 0) continue;
        try line.append(arena, c, false);
        count += 1;
        continuation = utf8Continuations(c);
    }
}

fn utf8Continuations(lead: u8) usize {
    if (lead < 0xc0) return 0;
    const len = std.unicode.utf8ByteSequenceLength(lead) catch return 0;
    return len - 1;
}

fn isIfsWhitespace(c: u8, ifs: []const u8) bool {
    return (c == ' ' or c == '\t' or c == '\n') and std.mem.indexOfScalar(u8, ifs, c) != null;
}

/// Splits records the way bash's `read` does.
const Splitter = struct {
    line: *const Line,
    ifs: []const u8,
    pos: usize = 0,

    fn isDelim(self: *const Splitter, i: usize) bool {
        return !self.line.escaped.items[i] and std.mem.indexOfScalar(u8, self.ifs, self.line.bytes.items[i]) != null;
    }

    fn isSpace(self: *const Splitter, i: usize) bool {
        return !self.line.escaped.items[i] and isIfsWhitespace(self.line.bytes.items[i], self.ifs);
    }

    fn skipSpace(self: *Splitter) void {
        while (self.pos < self.line.bytes.items.len and self.isSpace(self.pos)) self.pos += 1;
    }

    fn atEnd(self: *const Splitter) bool {
        return self.pos >= self.line.bytes.items.len;
    }

    /// One field, then its delimiter: IFS whitespace, at most one other IFS
    /// character, and the whitespace after it.
    fn field(self: *Splitter) []const u8 {
        const bytes = self.line.bytes.items;
        const start = self.pos;
        while (self.pos < bytes.len and !self.isDelim(self.pos)) self.pos += 1;
        const word = bytes[start..self.pos];
        self.skipSpace();
        if (self.pos < bytes.len and self.isDelim(self.pos) and !self.isSpace(self.pos)) {
            self.pos += 1;
            self.skipSpace();
        }
        return word;
    }

    /// The rest of the record for the last name: a lone trailing field loses
    /// its delimiter, otherwise only trailing IFS whitespace is removed.
    fn remainder(self: *Splitter) []const u8 {
        const bytes = self.line.bytes.items;
        const start = self.pos;
        const word = self.field();
        if (self.atEnd()) return word;
        var end = bytes.len;
        while (end > start and self.isSpace(end - 1)) end -= 1;
        self.pos = bytes.len;
        return bytes[start..end];
    }
};

/// Assigns a record to the requested variables. Returns false after
/// reporting a readonly variable.
fn assignRecord(ctx: Ctx, arena: Allocator, line: *const Line, names: []const []const u8, array: ?[]const u8, exact: bool) Allocator.Error!bool {
    const sh = ctx.sh;
    if (array) |name| {
        const ifs = try currentIfs(sh, arena);
        var items: std.ArrayList(value.Value) = .empty;
        var splitter = Splitter{ .line = line, .ifs = ifs };
        splitter.skipSpace();
        while (!splitter.atEnd()) try items.append(arena, .{ .string = splitter.field() });
        return assign(ctx, name, .{ .list = items.items });
    }
    if (names.len == 0) return assign(ctx, "REPLY", .{ .string = line.bytes.items });
    if (exact) {
        // `-N` assigns exactly what was read, unsplit.
        if (!try assign(ctx, names[0], .{ .string = line.bytes.items })) return false;
        for (names[1..]) |name| {
            if (!try assign(ctx, name, .{ .string = "" })) return false;
        }
        return true;
    }

    const ifs = try currentIfs(sh, arena);
    var splitter = Splitter{ .line = line, .ifs = ifs };
    splitter.skipSpace();
    for (names, 0..) |name, i| {
        const text = if (i + 1 == names.len) splitter.remainder() else splitter.field();
        if (!try assign(ctx, name, .{ .string = text })) return false;
    }
    return true;
}

fn assign(ctx: Ctx, name: []const u8, val: value.Value) Allocator.Error!bool {
    ctx.sh.assignVar(name, val) catch |err| switch (err) {
        error.ReadonlyVariable => {
            ctx.errFmt("wsh: {s}: {s}: readonly variable\n", .{ ctx.argv[0], name });
            return false;
        },
        error.OutOfMemory => return error.OutOfMemory,
        // A `declare -i` variable's arithmetic failed.
        error.InvalidArithmetic, error.DivisionByZero => {
            ctx.errFmt("wsh: {s}\n", .{arith.errorMessage()});
            return false;
        },
        // Already reported by the expansion that failed.
        else => return false,
    };
    return true;
}

// --- mapfile -----------------------------------------------------------------

const mapfile_usage = "wsh: mapfile: usage: mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]\n";

fn parseCount(ctx: Ctx, text: []const u8, what: []const u8) ?usize {
    return std.fmt.parseInt(usize, text, 10) catch {
        ctx.errFmt("wsh: {s}: {s}: {s}\n", .{ ctx.argv[0], text, what });
        return null;
    };
}

pub fn mapfile(ctx: Ctx) u8 {
    var delim: u8 = '\n';
    var limit: usize = 0;
    var origin: ?usize = null;
    var skip: usize = 0;
    var trim = false;
    var fd = ctx.stdin;
    var callback: ?[]const u8 = null;
    var quantum: usize = 5000;

    var parser = options.Parser.init(ctx.argv, "d:n:O:s:tu:C:c:");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid => |c| {
                ctx.errFmt("wsh: {s}: -{c}: invalid option\n", .{ ctx.argv[0], c });
                ctx.err(mapfile_usage);
                return 2;
            },
            .missing => |c| {
                ctx.errFmt("wsh: {s}: -{c}: option requires an argument\n", .{ ctx.argv[0], c });
                ctx.err(mapfile_usage);
                return 2;
            },
            .option => |c| switch (c) {
                'd' => delim = if (parser.optarg.len == 0) 0 else parser.optarg[0],
                'n' => limit = parseCount(ctx, parser.optarg, "invalid line count") orelse return 1,
                'O' => origin = parseCount(ctx, parser.optarg, "invalid array origin") orelse return 1,
                's' => skip = parseCount(ctx, parser.optarg, "invalid line count") orelse return 1,
                't' => trim = true,
                'u' => fd = parseFd(ctx, ctx.argv[0], parser.optarg) orelse return 1,
                'C' => callback = parser.optarg,
                'c' => {
                    quantum = parseCount(ctx, parser.optarg, "invalid callback quantum") orelse return 1;
                    if (quantum == 0) {
                        ctx.errFmt("wsh: {s}: {s}: invalid callback quantum\n", .{ ctx.argv[0], parser.optarg });
                        return 1;
                    }
                },
                else => unreachable,
            },
        }
    }
    const operands = parser.rest();
    if (operands.len > 1) {
        ctx.errFmt("wsh: {s}: too many arguments\n", .{ctx.argv[0]});
        return 2;
    }
    const name = if (operands.len == 1) operands[0] else "MAPFILE";
    if (!builtins.validName(name)) {
        ctx.errFmt("wsh: {s}: `{s}': not a valid identifier\n", .{ ctx.argv[0], name });
        return 1;
    }
    if (ctx.sh.isReadonly(name)) {
        ctx.errFmt("wsh: {s}: {s}: readonly variable\n", .{ ctx.argv[0], name });
        return 1;
    }

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var existing: []const value.Value = &.{};
    if (origin) |start| {
        if (ctx.sh.getVar(name)) |current| {
            existing = switch (current) {
                .list => |items| items,
                .none => &.{},
                else => &.{current},
            };
        }
        if (start > existing.len) {
            ctx.errFmt("wsh: {s}: {d}: origin is past the end of {s} (wsh arrays are not sparse)\n", .{ ctx.argv[0], start, name });
            return 1;
        }
    }
    const first = origin orelse 0;

    var input = Input.init(ctx.sh, fd);
    // Without a line limit everything is consumed, so a pipe can be drained
    // in chunks.
    input.greedy = limit == 0;
    var lines: std.ArrayList(value.Value) = .empty;
    var status: u8 = 0;
    var seen: usize = 0;
    read_loop: while (limit == 0 or lines.items.len < limit) {
        var record: std.ArrayList(u8) = .empty;
        var ended = false;
        while (true) {
            switch (input.next()) {
                .byte => |c| {
                    if (c == delim) {
                        ended = true;
                        if (!trim) record.append(arena, c) catch return outOfMemory(ctx, &input);
                        break;
                    }
                    record.append(arena, c) catch return outOfMemory(ctx, &input);
                },
                .eof => break,
                .timeout => unreachable,
                .interrupted => {
                    status = interrupt_status;
                    break :read_loop;
                },
                .failed => |e| {
                    ctx.errFmt("wsh: {s}: read error: {d}: {s}\n", .{ ctx.argv[0], fd, @tagName(e) });
                    status = 1;
                    break :read_loop;
                },
            }
        }
        if (!ended and record.items.len == 0) break;
        seen += 1;
        if (seen > skip) {
            const index = first + lines.items.len;
            if (callback) |command| {
                if (lines.items.len % quantum == quantum - 1) {
                    runCallback(ctx, arena, command, index, record.items) catch return outOfMemory(ctx, &input);
                }
            }
            lines.append(arena, .{ .string = record.items }) catch return outOfMemory(ctx, &input);
        }
        if (!ended) break;
    }
    input.finish();
    if (status == interrupt_status) return status;

    var result: std.ArrayList(value.Value) = .empty;
    result.appendSlice(arena, existing[0..@min(first, existing.len)]) catch return outOfMemory(ctx, &input);
    result.appendSlice(arena, lines.items) catch return outOfMemory(ctx, &input);
    const end = first + lines.items.len;
    if (end < existing.len) result.appendSlice(arena, existing[end..]) catch return outOfMemory(ctx, &input);
    ctx.sh.assignVar(name, .{ .list = result.items }) catch {
        ctx.errFmt("wsh: {s}: {s}: cannot assign\n", .{ ctx.argv[0], name });
        return 1;
    };
    return status;
}

fn outOfMemory(ctx: Ctx, input: *Input) u8 {
    input.finish();
    ctx.errFmt("wsh: {s}: out of memory\n", .{ctx.argv[0]});
    return 1;
}

/// Evaluates `callback index line`, quoting the line so it arrives as one
/// argument.
fn runCallback(ctx: Ctx, arena: Allocator, command: []const u8, index: usize, line: []const u8) Allocator.Error!void {
    const run_source = ctx.run_source orelse return;
    var source: std.ArrayList(u8) = .empty;
    try source.print(arena, "{s} {d} ", .{ command, index });
    try printf.quote(arena, &source, line);
    _ = run_source(ctx.sh, source.items);
}

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn inputPipe(input: []const u8) !i32 {
    var fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })));
    if (input.len != 0) _ = linux.write(fds[1], input.ptr, input.len);
    _ = linux.close(fds[1]);
    return fds[0];
}

fn runRead(sh: *Shell, input: []const u8, argv: []const []const u8) !u8 {
    const fd = try inputPipe(input);
    defer _ = linux.close(fd);
    return read(.{ .sh = sh, .argv = argv, .stdin = fd, .stderr = -1 });
}

test "read splits on IFS, honours -r and returns 1 at end of input" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "one two three\n", &.{ "read", "a", "b" }));
    try testing.expectEqualStrings("one", sh.getVar("a").?.string);
    try testing.expectEqualStrings("two three", sh.getVar("b").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "  hello  \n", &.{ "read", "line" }));
    try testing.expectEqualStrings("hello", sh.getVar("line").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "  hello  \n", &.{"read"}));
    try testing.expectEqualStrings("  hello  ", sh.getVar("REPLY").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "x\\ y z\n", &.{ "read", "p", "q" }));
    try testing.expectEqualStrings("x y", sh.getVar("p").?.string);
    try testing.expectEqualStrings("z", sh.getVar("q").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "a\\b\n", &.{ "read", "-r", "raw" }));
    try testing.expectEqualStrings("a\\b", sh.getVar("raw").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "one \\\ntwo\n", &.{ "read", "joined" }));
    try testing.expectEqualStrings("one two", sh.getVar("joined").?.string);

    // A partial last line is assigned, but the status reports end of input.
    try testing.expectEqual(@as(u8, 1), try runRead(&sh, "tail", &.{ "read", "last" }));
    try testing.expectEqualStrings("tail", sh.getVar("last").?.string);
    try testing.expectEqual(@as(u8, 1), try runRead(&sh, "", &.{ "read", "last" }));
    try testing.expectEqualStrings("", sh.getVar("last").?.string);

    try sh.setVar("IFS", .{ .string = ":" });
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "a::b\n", &.{ "read", "x", "y", "z" }));
    try testing.expectEqualStrings("", sh.getVar("y").?.string);
    try testing.expectEqualStrings("b", sh.getVar("z").?.string);
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "x:y:\n", &.{ "read", "x", "y" }));
    try testing.expectEqualStrings("y", sh.getVar("y").?.string);
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "x:y::\n", &.{ "read", "x", "y" }));
    try testing.expectEqualStrings("y::", sh.getVar("y").?.string);
    _ = sh.unsetVar("IFS");
}

test "read options: -n, -N, -d, -a and invalid input" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "abcdef", &.{ "read", "-n", "3", "x" }));
    try testing.expectEqualStrings("abc", sh.getVar("x").?.string);
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "ab\ncd", &.{ "read", "-N4", "x" }));
    try testing.expectEqualStrings("ab\nc", sh.getVar("x").?.string);
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "a:b", &.{ "read", "-d", ":", "x" }));
    try testing.expectEqualStrings("a", sh.getVar("x").?.string);
    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "a\x00b", &.{ "read", "-rd", "", "x" }));
    try testing.expectEqualStrings("a", sh.getVar("x").?.string);

    try testing.expectEqual(@as(u8, 0), try runRead(&sh, "a b  c\n", &.{ "read", "-a", "arr" }));
    const items = sh.getVar("arr").?.list;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("c", items[2].string);

    try testing.expectEqual(@as(u8, 1), try runRead(&sh, "x\n", &.{ "read", "1x" }));
    try testing.expectEqual(@as(u8, 2), try runRead(&sh, "x\n", &.{ "read", "-z" }));
    try testing.expectEqual(@as(u8, 1), try runRead(&sh, "x\n", &.{ "read", "-t", "abc" }));
    try testing.expectEqual(@as(u8, 1), try runRead(&sh, "x\n", &.{ "read", "-u", "999", "x" }));
}

test "mapfile reads lines into a list" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    const fd = try inputPipe("l1\nl2\nl3\nl4\n");
    defer _ = linux.close(fd);
    const argv = [_][]const u8{ "mapfile", "-t", "-s", "1", "-n", "2", "lines" };
    try testing.expectEqual(@as(u8, 0), mapfile(.{ .sh = &sh, .argv = &argv, .stdin = fd, .stderr = -1 }));
    const items = sh.getVar("lines").?.list;
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("l2", items[0].string);
    try testing.expectEqualStrings("l3", items[1].string);

    const fd2 = try inputPipe("a\nb");
    defer _ = linux.close(fd2);
    const keep = [_][]const u8{"readarray"};
    try testing.expectEqual(@as(u8, 0), mapfile(.{ .sh = &sh, .argv = &keep, .stdin = fd2, .stderr = -1 }));
    const kept = sh.getVar("MAPFILE").?.list;
    try testing.expectEqualStrings("a\n", kept[0].string);
    try testing.expectEqualStrings("b", kept[1].string);
}
