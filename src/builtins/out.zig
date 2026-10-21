//! `out`: answers small questions about command output (a summary within a
//! byte budget, the failed tests, the lines matching a query) so an agent
//! does not have to read a whole log. Input is stdin, a file (`--file`), or a
//! background run's log (`--run`). Files are mapped rather than read, and the
//! queries themselves live in `output_query.zig`.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");
const regex = @import("../regex.zig");
const oq = @import("../output_query.zig");

const Ctx = builtins.Ctx;
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const usage =
    \\usage: out SUBCOMMAND [options] [--file FILE | --run NAME]
    \\
    \\Answers questions about command output without reading all of it. Input
    \\is stdin unless --file or --run names a log.
    \\
    \\  out budget [N]           first and last lines, errors, failures and
    \\                           summaries, within N bytes (default 4096;
    \\                           accepts 2k, 64K, 1M); elided runs are marked
    \\                           with their exact line numbers
    \\  out find QUERY...        fuzzy-find the best lines (fzf-style; smart
    \\                           case; every word must match)
    \\  out grep PATTERN         lines containing PATTERN (--regex: an
    \\                           extended regex; -i: ignore case)
    \\  out failures             failed tests and checks, with summary counts;
    \\                           status 1 if any failed, 0 if none, 2 if no
    \\                           test output was recognised
    \\  out lines A-B            lines A to B (also A, A-, A..B)
    \\  out stats                lines, bytes, error/warning/failure lines,
    \\                           test frameworks seen
    \\
    \\Options:
    \\  --file FILE              read FILE
    \\  --run NAME               read the log of background run NAME
    \\  --json                   JSON lines for programs
    \\  --raw                    keep ANSI escapes in the lines shown
    \\  --budget N               cap the output at N bytes
    \\  --limit K                find: lines shown (default 20); grep: 100
    \\  --context C, -C C        find, grep: C lines of context
    \\
;

const Command = enum { budget, find, grep, failures, lines, stats };

const Options = struct {
    command: Command,
    operands: std.ArrayList([]const u8) = .empty,
    file: ?[]const u8 = null,
    run: ?[]const u8 = null,
    json: bool = false,
    raw: bool = false,
    budget: ?usize = null,
    limit: ?usize = null,
    context: usize = 0,
    regex: bool = false,
    ignore_case: bool = false,
};

/// Lines longer than this are shown as an excerpt around the match.
const max_shown = 1024;

pub fn run(ctx: Ctx) u8 {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const opts = parseArgs(ctx, arena) catch |err| switch (err) {
        error.Help => {
            ctx.out(usage);
            return 0;
        },
        error.Usage => return 2,
        error.OutOfMemory => return 1,
    };

    var input = loadInput(ctx, arena, opts) orelse return 2;
    defer input.deinit(ctx.sh.gpa);

    var buf: [64 * 1024]u8 = undefined;
    var out = FdWriter.init(ctx.stdout, &buf);
    const status = execute(ctx, arena, opts, input.bytes, &out.interface) catch |err| switch (err) {
        error.WriteFailed => if (out.broken_pipe) 1 else {
            ctx.err("wsh: out: write error\n");
            return 1;
        },
        error.OutOfMemory => {
            ctx.err("wsh: out: out of memory\n");
            return 1;
        },
        else => {
            ctx.errFmt("wsh: out: {s}\n", .{regex.errorMessage(@errorCast(err))});
            return 2;
        },
    };
    out.interface.flush() catch {
        if (!out.broken_pipe) ctx.err("wsh: out: write error\n");
        return 1;
    };
    return status;
}

fn usageError(ctx: Ctx, comptime fmt: []const u8, args: anytype) error{Usage} {
    ctx.errFmt("wsh: out: " ++ fmt ++ "\n", args);
    ctx.err("wsh: out: usage: out budget|find|grep|failures|lines|stats [options] [--file FILE | --run NAME]; see `out --help`\n");
    return error.Usage;
}

fn parseArgs(ctx: Ctx, arena: Allocator) error{ Help, Usage, OutOfMemory }!Options {
    const argv = ctx.argv;
    if (argv.len < 2) return usageError(ctx, "expected a subcommand", .{});
    if (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "help")) return error.Help;
    var opts = Options{ .command = std.meta.stringToEnum(Command, argv[1]) orelse
        return usageError(ctx, "{s}: unknown subcommand", .{argv[1]}) };

    var i: usize = 2;
    var operands_only = false;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (operands_only or arg.len < 2 or arg[0] != '-') {
            try opts.operands.append(arena, arg);
            continue;
        }
        if (std.mem.eql(u8, arg, "--")) {
            operands_only = true;
            continue;
        }
        // `--name=value` or `--name value`.
        const eq = std.mem.indexOfScalar(u8, arg, '=');
        const name = if (eq) |at| arg[0..at] else arg;
        const Flag = enum { file, run, json, raw, budget, limit, context, regex, ignore_case, help };
        const flags = [_]struct { []const u8, Flag }{
            .{ "--file", .file },       .{ "--run", .run },                 .{ "--json", .json },
            .{ "--raw", .raw },         .{ "--budget", .budget },           .{ "--limit", .limit },
            .{ "--context", .context }, .{ "-C", .context },                .{ "--regex", .regex },
            .{ "-E", .regex },          .{ "--ignore-case", .ignore_case }, .{ "-i", .ignore_case },
            .{ "--help", .help },       .{ "-h", .help },
        };
        const flag = for (flags) |entry| {
            if (std.mem.eql(u8, entry[0], name)) break entry[1];
        } else return usageError(ctx, "{s}: unknown option", .{arg});
        const takes_value = switch (flag) {
            .file, .run, .budget, .limit, .context => true,
            else => false,
        };
        var value: []const u8 = "";
        if (takes_value) {
            if (eq) |at| {
                value = arg[at + 1 ..];
            } else {
                i += 1;
                if (i >= argv.len) return usageError(ctx, "{s}: option requires an argument", .{arg});
                value = argv[i];
            }
        } else if (eq != null) return usageError(ctx, "{s}: option takes no argument", .{name});
        switch (flag) {
            .file => opts.file = value,
            .run => opts.run = value,
            .json => opts.json = true,
            .raw => opts.raw = true,
            .budget => opts.budget = parseSize(value) orelse return usageError(ctx, "{s}: invalid size", .{value}),
            .limit => opts.limit = std.fmt.parseInt(usize, value, 10) catch return usageError(ctx, "{s}: invalid count", .{value}),
            .context => opts.context = std.fmt.parseInt(usize, value, 10) catch return usageError(ctx, "{s}: invalid count", .{value}),
            .regex => opts.regex = true,
            .ignore_case => opts.ignore_case = true,
            .help => return error.Help,
        }
    }
    if (opts.file != null and opts.run != null) return usageError(ctx, "--file and --run are exclusive", .{});

    const n = opts.operands.items.len;
    switch (opts.command) {
        .budget => {
            if (n > 1) return usageError(ctx, "budget: expected at most one size", .{});
            if (n == 1) opts.budget = parseSize(opts.operands.items[0]) orelse
                return usageError(ctx, "{s}: invalid size", .{opts.operands.items[0]});
        },
        .find => if (n == 0) return usageError(ctx, "find: expected a query", .{}),
        .grep => if (n != 1) return usageError(ctx, "grep: expected one pattern", .{}),
        .lines => {
            if (n != 1) return usageError(ctx, "lines: expected a range such as 41-60", .{});
            if (parseRange(opts.operands.items[0]) == null) return usageError(ctx, "{s}: invalid range", .{opts.operands.items[0]});
        },
        .failures, .stats => if (n != 0) return usageError(ctx, "{s}: unexpected argument {s}", .{ @tagName(opts.command), opts.operands.items[0] }),
    }
    return opts;
}

/// `4096`, `2k`, `64K`, `1M`, `1g`: bytes, in powers of 1024.
pub fn parseSize(text: []const u8) ?usize {
    if (text.len == 0) return null;
    const unit: usize = switch (text[text.len - 1]) {
        'k', 'K' => 1 << 10,
        'm', 'M' => 1 << 20,
        'g', 'G' => 1 << 30,
        else => 1,
    };
    const digits = if (unit == 1) text else text[0 .. text.len - 1];
    const n = std.fmt.parseInt(usize, digits, 10) catch return null;
    return std.math.mul(usize, n, unit) catch null;
}

const Range = struct { from: u64, to: ?u64 };

/// `41-60`, `41–60` (as printed in elision markers), `41..60`, `41,60`,
/// `41` and `41-` (to the end).
fn parseRange(text: []const u8) ?Range {
    const separators = [_][]const u8{ "–", "..", "-", "," };
    for (separators) |sep| {
        if (std.mem.indexOf(u8, text, sep)) |at| {
            const from = std.fmt.parseInt(u64, text[0..at], 10) catch return null;
            const rest = text[at + sep.len ..];
            if (from == 0) return null;
            if (rest.len == 0) return .{ .from = from, .to = null };
            const to = std.fmt.parseInt(u64, rest, 10) catch return null;
            if (to < from) return null;
            return .{ .from = from, .to = to };
        }
    }
    const line = std.fmt.parseInt(u64, text, 10) catch return null;
    if (line == 0) return null;
    return .{ .from = line, .to = line };
}

// --- input -----------------------------------------------------------------------

/// Where background run `name` keeps its output. This must stay in step
/// with the runs feature (`run -d --name NAME -- command`), which owns the
/// layout: the state directory is `$XDG_RUNTIME_DIR/wsh` when
/// `XDG_RUNTIME_DIR` is set and is a directory, else `/tmp/wsh-<uid>`, and a
/// run's output is `<state>/runs/<name>/output.log`.
pub fn runLogPath(arena: Allocator, runtime_dir: ?[]const u8, name: []const u8) Allocator.Error![:0]u8 {
    if (runtime_dir) |dir| {
        if (dir.len != 0) {
            const z = try arena.dupeZ(u8, dir);
            if (fs.isDir(z)) return std.fmt.allocPrintSentinel(arena, "{s}/wsh/runs/{s}/output.log", .{ dir, name }, 0);
        }
    }
    return std.fmt.allocPrintSentinel(arena, "/tmp/wsh-{d}/runs/{s}/output.log", .{ linux.getuid(), name }, 0);
}

const Input = struct {
    bytes: []const u8 = "",
    mapped: ?[]const u8 = null,
    owned: ?[]u8 = null,

    fn deinit(self: *Input, gpa: Allocator) void {
        if (self.mapped) |m| _ = linux.munmap(m.ptr, m.len);
        if (self.owned) |o| gpa.free(o);
    }
};

fn loadInput(ctx: Ctx, arena: Allocator, opts: Options) ?Input {
    if (opts.run) |name| {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            ctx.errFmt("wsh: out: {s}: invalid run name\n", .{name});
            return null;
        }
        const path = runLogPath(arena, ctx.sh.getEnv("XDG_RUNTIME_DIR"), name) catch return null;
        if (!fs.exists(path)) {
            ctx.errFmt("wsh: out: {s}: no such run (no log at {s})\n", .{ name, path });
            return null;
        }
        return loadPath(ctx, path, name);
    }
    if (opts.file) |file| {
        const path = arena.dupeZ(u8, file) catch return null;
        return loadPath(ctx, path, file);
    }
    if (sys.isTty(ctx.stdin)) {
        ctx.err("wsh: out: standard input is a terminal; pipe output in or use --file or --run\n");
        return null;
    }
    return loadFd(ctx, ctx.stdin, "standard input");
}

fn loadPath(ctx: Ctx, path: [:0]const u8, label: []const u8) ?Input {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        ctx.errFmt("wsh: out: {s}: {s}\n", .{ label, proc.errorText(err) });
        return null;
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    return loadFd(ctx, fd, label);
}

/// Maps a regular file (from the descriptor's current offset) and reads
/// anything else, such as a pipe.
fn loadFd(ctx: Ctx, fd: i32, label: []const u8) ?Input {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true }, &st)) == .SUCCESS) {
        const kind = st.mode & linux.S.IFMT;
        if (kind == linux.S.IFDIR) {
            ctx.errFmt("wsh: out: {s}: Is a directory\n", .{label});
            return null;
        }
        if (kind == linux.S.IFREG and st.size > 0) {
            const offset_rc = linux.lseek(fd, 0, linux.SEEK.CUR);
            const offset: u64 = if (linux.errno(offset_rc) == .SUCCESS) @intCast(offset_rc) else 0;
            const size: usize = @intCast(st.size);
            const addr = linux.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE, .POPULATE = true }, fd, 0);
            if (linux.errno(addr) == .SUCCESS) {
                const ptr: [*]const u8 = @ptrFromInt(addr);
                const mapped = ptr[0..size];
                // Consume the input, as reading it would.
                _ = linux.lseek(fd, 0, linux.SEEK.END);
                return .{ .bytes = mapped[@min(offset, size)..], .mapped = mapped };
            }
        }
    }
    // A bigger pipe buffer means fewer wakeups while a writer streams a
    // large log in; it is only a hint, so failure does not matter.
    _ = linux.fcntl(fd, linux.F.SETPIPE_SZ, 1 << 20);
    var data: std.ArrayList(u8) = .empty;
    while (true) {
        data.ensureUnusedCapacity(ctx.sh.gpa, 1 << 20) catch {
            data.deinit(ctx.sh.gpa);
            ctx.err("wsh: out: out of memory\n");
            return null;
        };
        const spare = data.unusedCapacitySlice();
        const rc = linux.read(fd, spare.ptr, spare.len);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) {
            data.deinit(ctx.sh.gpa);
            ctx.errFmt("wsh: out: {s}: {s}\n", .{ label, proc.errorText(err) });
            return null;
        }
        if (rc == 0) break;
        data.items.len += rc;
    }
    const owned = data.toOwnedSlice(ctx.sh.gpa) catch {
        data.deinit(ctx.sh.gpa);
        return null;
    };
    return .{ .bytes = owned, .owned = owned };
}

// --- output ----------------------------------------------------------------------

/// A buffered writer onto a descriptor through `sys.writeAll`.
const FdWriter = struct {
    fd: i32,
    broken_pipe: bool = false,
    interface: Writer,

    fn init(fd: i32, buffer: []u8) FdWriter {
        return .{ .fd = fd, .interface = .{ .vtable = &.{ .drain = drain }, .buffer = buffer } };
    }

    fn send(self: *FdWriter, bytes: []const u8) Writer.Error!void {
        switch (sys.writeAll(self.fd, bytes)) {
            .ok => {},
            .broken_pipe => {
                self.broken_pipe = true;
                return error.WriteFailed;
            },
            .failed => return error.WriteFailed,
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *FdWriter = @alignCast(@fieldParentPtr("interface", w));
        try self.send(w.buffer[0..w.end]);
        w.end = 0;
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try self.send(bytes);
            written += bytes.len;
        }
        const pattern = data[data.len - 1];
        for (0..splat) |_| try self.send(pattern);
        return written + pattern.len * splat;
    }
};

/// Output collected as separate records, so `--budget` can drop whole
/// records and say how many.
const Records = struct {
    arena: Allocator,
    items: std.ArrayList([]const u8) = .empty,
    current: Writer.Allocating,

    fn init(arena: Allocator) Records {
        return .{ .arena = arena, .current = .init(arena) };
    }

    fn writer(self: *Records) *Writer {
        return &self.current.writer;
    }

    /// Ends the record written so far.
    fn finish(self: *Records) Allocator.Error!void {
        const bytes = try self.current.toOwnedSlice();
        if (bytes.len != 0) try self.items.append(self.arena, bytes);
    }
};

/// Writes `records` then `footer`, dropping trailing records that would
/// take the total past `max` and noting how many were dropped.
fn emitCapped(w: *Writer, records: []const []const u8, footer: []const u8, max: ?usize, json: bool) Writer.Error!void {
    const limit = max orelse {
        for (records) |record| try w.writeAll(record);
        try w.writeAll(footer);
        return;
    };
    var note_buf: [128]u8 = undefined;
    const reserve = footer.len + if (noteText(&note_buf, records.len, json)) |note| note.len else |_| 0;
    var used: usize = 0;
    var kept: usize = 0;
    for (records) |record| {
        if (used + record.len + reserve > limit) break;
        try w.writeAll(record);
        used += record.len;
        kept += 1;
    }
    if (kept < records.len) {
        const note: []const u8 = noteText(&note_buf, records.len - kept, json) catch "";
        if (used + note.len <= limit) {
            try w.writeAll(note);
            used += note.len;
        }
    }
    if (used + footer.len <= limit) try w.writeAll(footer);
}

fn noteText(buf: []u8, omitted: usize, json: bool) ![]const u8 {
    if (json) return std.fmt.bufPrint(buf, "{{\"type\":\"truncated\",\"omitted\":{d}}}\n", .{omitted});
    return std.fmt.bufPrint(buf, "[… {d} more not shown; raise --budget …]\n", .{omitted});
}

/// The part of `line` to show: all of it, or `max_shown` bytes starting a
/// little before `focus` when it is longer.
fn excerpt(line: []const u8, focus: usize) struct { start: usize, end: usize } {
    if (line.len <= max_shown) return .{ .start = 0, .end = line.len };
    var start = if (focus > 64) focus - 64 else 0;
    if (start + max_shown > line.len) start = line.len - max_shown;
    while (start > 0 and (line[start] & 0xc0) == 0x80) start -= 1;
    var end = @min(line.len, start + max_shown);
    while (end < line.len and (line[end] & 0xc0) == 0x80) end -= 1;
    return .{ .start = start, .end = end };
}

/// Writes `line[span]`, marking cut ends with how many bytes were left out.
fn writeExcerptText(w: *Writer, line: []const u8, start: usize, end: usize) Writer.Error!void {
    if (start > 0) try w.print("[+{d} bytes] … ", .{start});
    try w.writeAll(line[start..end]);
    if (end < line.len) try w.print(" … [+{d} bytes]", .{line.len - end});
}

fn shown(opts: Options, text: []const u8, line: oq.Line, cleaned: []const u8) []const u8 {
    return if (opts.raw) line.bytes(text) else cleaned;
}

// --- subcommands -----------------------------------------------------------------

fn execute(ctx: Ctx, arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    return switch (opts.command) {
        .budget => {
            const summary = try oq.budget(arena, text, opts.budget orelse 4096, .{
                .format = if (opts.json) .json else .text,
                .raw = opts.raw,
            });
            try w.writeAll(summary);
            return 0;
        },
        .find => find(arena, opts, text, w),
        .grep => grep(arena, opts, text, w),
        .failures => failures(arena, opts, text, w),
        .lines => lines(ctx, arena, opts, text, w),
        .stats => stats(arena, opts, text, w),
    };
}

fn find(arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    const query = try std.mem.join(arena, " ", opts.operands.items);
    const result = try oq.fuzzyFind(arena, text, query, opts.limit orelse 20);
    var records = Records.init(arena);
    for (result.matches) |match| {
        const rw = records.writer();
        if (opts.context > 0) try writeContext(rw, arena, opts, text, match.line, .before);
        const focus = if (match.positions.len != 0) match.positions[0] else 0;
        const display = shown(opts, text, match.line, match.text);
        const cut = excerpt(display, if (opts.raw) 0 else focus);
        if (opts.json) {
            try rw.print("{{\"type\":\"match\",\"line\":{d},\"offset\":{d},\"score\":{d},\"text\":", .{ match.line.number, match.line.start, match.score });
            try oq.writeJsonString(rw, display[cut.start..cut.end]);
            if (cut.start != 0 or cut.end != display.len) try rw.print(",\"excerpt_start\":{d}", .{cut.start});
            try rw.writeAll(",\"positions\":[");
            var first = true;
            for (match.positions) |pos| {
                if (pos < cut.start or pos >= cut.end) continue;
                if (!first) try rw.writeByte(',');
                first = false;
                try rw.print("{d}", .{pos - cut.start});
            }
            try rw.writeAll("]}\n");
        } else {
            try rw.print("{d}:", .{match.line.number});
            try writeExcerptText(rw, display, cut.start, cut.end);
            try rw.writeByte('\n');
        }
        if (opts.context > 0) {
            try writeContext(rw, arena, opts, text, match.line, .after);
            if (!opts.json) try rw.writeAll("--\n");
        }
        try records.finish();
    }
    const footer = try matchFooter(arena, opts, result.total, result.matches.len);
    try emitCapped(w, records.items.items, footer, opts.budget, opts.json);
    return if (result.total == 0) 1 else 0;
}

/// How many lines matched in all; in text form only when some are not shown.
fn matchFooter(arena: Allocator, opts: Options, total: u64, kept: usize) ![]const u8 {
    if (opts.json) return std.fmt.allocPrint(arena, "{{\"type\":\"summary\",\"matches\":{d},\"shown\":{d}}}\n", .{ total, kept });
    const more = total - kept;
    if (more == 0) return "";
    return std.fmt.allocPrint(arena, "[… {d} more matching line{s}; raise --limit …]\n", .{ more, if (more == 1) "" else "s" });
}

const Side = enum { before, after };

fn writeContext(w: *Writer, arena: Allocator, opts: Options, text: []const u8, line: oq.Line, side: Side) !void {
    const around = try oq.context(arena, text, line, if (side == .before) opts.context else 0, if (side == .after) opts.context else 0);
    for (around) |l| {
        if (l.number == line.number) continue;
        try writeContextLine(w, arena, opts, text, l);
    }
}

fn writeContextLine(w: *Writer, arena: Allocator, opts: Options, text: []const u8, l: oq.Line) !void {
    const display = if (opts.raw) l.bytes(text) else try oq.cleanAlloc(arena, l.bytes(text));
    const cut = excerpt(display, 0);
    if (opts.json) {
        try w.print("{{\"type\":\"context\",\"line\":{d},\"text\":", .{l.number});
        try oq.writeJsonString(w, display[cut.start..cut.end]);
        try w.writeAll("}\n");
    } else {
        try w.print("{d}-", .{l.number});
        try writeExcerptText(w, display, cut.start, cut.end);
        try w.writeByte('\n');
    }
}

fn grep(arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    const result = try oq.grep(arena, text, opts.operands.items[0], .{
        .regex = opts.regex,
        .ignore_case = opts.ignore_case,
        .limit = opts.limit orelse 100,
    });
    var records = Records.init(arena);
    // As in grep, context windows that touch merge and others are separated.
    var printed: u64 = 0;
    for (result.matches) |match| {
        const rw = records.writer();
        if (opts.context > 0) {
            const before = try oq.context(arena, text, match.line, opts.context, 0);
            if (printed != 0 and before[0].number > printed + 1 and !opts.json) try rw.writeAll("--\n");
            for (before) |l| {
                if (l.number == match.line.number or l.number <= printed) continue;
                try writeContextLine(rw, arena, opts, text, l);
            }
        }
        const display = shown(opts, text, match.line, match.text);
        const focus = if (match.spans.len != 0) match.spans[0].start else 0;
        const cut = excerpt(display, if (opts.raw) 0 else focus);
        if (opts.json) {
            try rw.print("{{\"type\":\"match\",\"line\":{d},\"offset\":{d},\"text\":", .{ match.line.number, match.line.start });
            try oq.writeJsonString(rw, display[cut.start..cut.end]);
            if (cut.start != 0 or cut.end != display.len) try rw.print(",\"excerpt_start\":{d}", .{cut.start});
            try rw.writeAll(",\"spans\":[");
            var first = true;
            for (match.spans) |span| {
                if (span.start < cut.start or span.end > cut.end) continue;
                if (!first) try rw.writeByte(',');
                first = false;
                try rw.print("[{d},{d}]", .{ span.start - cut.start, span.end - cut.start });
            }
            try rw.writeAll("]}\n");
        } else {
            try rw.print("{d}:", .{match.line.number});
            try writeExcerptText(rw, display, cut.start, cut.end);
            try rw.writeByte('\n');
        }
        printed = @max(printed, match.line.number);
        if (opts.context > 0) {
            const after = try oq.context(arena, text, match.line, 0, opts.context);
            for (after) |l| {
                if (l.number <= printed) continue;
                // A later match inside this window prints itself.
                if (isMatchLine(result.matches, l.number)) break;
                try writeContextLine(rw, arena, opts, text, l);
                printed = l.number;
            }
        }
        try records.finish();
    }
    const footer = try matchFooter(arena, opts, result.total, result.matches.len);
    try emitCapped(w, records.items.items, footer, opts.budget, opts.json);
    return if (result.total == 0) 1 else 0;
}

fn isMatchLine(matches: []const oq.GrepMatch, number: u64) bool {
    for (matches) |m| {
        if (m.line.number == number) return true;
        if (m.line.number > number) return false;
    }
    return false;
}

fn failures(arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    const report = try oq.failures(arena, text);
    var records = Records.init(arena);
    for (report.failures) |f| {
        const rw = records.writer();
        if (opts.json) {
            try rw.print("{{\"type\":\"failure\",\"framework\":\"{s}\",\"name\":", .{@tagName(f.framework)});
            try oq.writeJsonString(rw, f.name);
            try rw.print(",\"line\":{d},\"location\":", .{f.line});
            try writeJsonOptional(rw, f.location);
            try rw.writeAll(",\"reason\":");
            try writeJsonOptional(rw, f.reason);
            try rw.writeAll("}\n");
        } else {
            try rw.print("FAILED {s} [{s}] line {d}", .{ f.name, @tagName(f.framework), f.line });
            if (f.location) |location| {
                if (!std.mem.eql(u8, location, f.name)) try rw.print(" at {s}", .{location});
            }
            if (f.reason) |reason| try rw.print(": {s}", .{reason});
            try rw.writeByte('\n');
        }
        try records.finish();
    }

    var footer: Writer.Allocating = .init(arena);
    const fw = &footer.writer;
    const status = report.status();
    if (opts.json) {
        const word = switch (status) {
            0 => "passed",
            1 => "failed",
            else => "unrecognized",
        };
        try fw.print("{{\"type\":\"summary\",\"status\":\"{s}\",\"frameworks\":[", .{word});
        try writeFrameworksJson(fw, report.frameworks);
        try fw.writeAll("],\"passed\":");
        try writeOptionalNumber(fw, report.counts.passed);
        try fw.writeAll(",\"failed\":");
        try writeOptionalNumber(fw, report.counts.failed);
        try fw.writeAll(",\"skipped\":");
        try writeOptionalNumber(fw, report.counts.skipped);
        try fw.print(",\"failures\":{d},\"omitted\":{d}}}\n", .{ report.failures.len + report.omitted, report.omitted });
    } else if (status == 2) {
        try fw.writeAll("no recognizable test output\n");
    } else {
        const listed = report.failures.len + report.omitted;
        if (listed == 0) {
            try fw.writeAll("no failures");
        } else {
            try fw.print("{d} failure{s}", .{ listed, if (listed == 1) "" else "s" });
        }
        if (report.omitted != 0) try fw.print(" ({d} not listed)", .{report.omitted});
        var sep: []const u8 = "; ";
        const fields = [_]struct { ?u64, []const u8 }{
            .{ report.counts.passed, "passed" },
            .{ report.counts.failed, "failed" },
            .{ report.counts.skipped, "skipped" },
        };
        for (fields) |field| {
            if (field[0]) |n| {
                try fw.print("{s}{d} {s}", .{ sep, n, field[1] });
                sep = ", ";
            }
        }
        try fw.writeAll(" [");
        try writeFrameworksText(fw, report.frameworks);
        try fw.writeAll("]\n");
    }
    try emitCapped(w, records.items.items, footer.written(), opts.budget, opts.json);
    return status;
}

fn writeJsonOptional(w: *Writer, value: ?[]const u8) Writer.Error!void {
    if (value) |v| try oq.writeJsonString(w, v) else try w.writeAll("null");
}

fn writeOptionalNumber(w: *Writer, value: ?u64) Writer.Error!void {
    if (value) |v| try w.print("{d}", .{v}) else try w.writeAll("null");
}

fn writeFrameworksJson(w: *Writer, set: oq.FrameworkSet) Writer.Error!void {
    var it = set.iterator();
    var first = true;
    while (it.next()) |framework| {
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("\"{s}\"", .{@tagName(framework)});
    }
}

fn writeFrameworksText(w: *Writer, set: oq.FrameworkSet) Writer.Error!void {
    var it = set.iterator();
    var first = true;
    while (it.next()) |framework| {
        if (!first) try w.writeAll(", ");
        first = false;
        try w.writeAll(@tagName(framework));
    }
    if (first) try w.writeAll("none");
}

fn lines(ctx: Ctx, arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    const range = parseRange(opts.operands.items[0]).?;
    const first = oq.lineAt(text, range.from) orelse {
        ctx.errFmt("wsh: out: lines: line {d} is past the end ({d} lines)\n", .{ range.from, oq.countLines(text) });
        return 1;
    };
    var it = oq.LineIterator.initAt(text, first.start, first.number - 1);
    var cleaner = oq.Cleaner.init(arena);
    // Without a budget, lines stream straight out.
    var records = Records.init(arena);
    const target = if (opts.budget != null) records.writer() else w;
    while (it.next()) |line| {
        if (range.to) |to| {
            if (line.number > to) break;
        }
        const display = if (opts.raw) line.bytes(text) else try cleaner.cleanLine(text, line);
        if (opts.json) {
            try target.print("{{\"type\":\"line\",\"line\":{d},\"text\":", .{line.number});
            try oq.writeJsonString(target, display);
            try target.writeAll("}\n");
        } else {
            try target.writeAll(display);
            try target.writeByte('\n');
        }
        if (opts.budget != null) try records.finish();
    }
    if (opts.budget != null) try emitCapped(w, records.items.items, "", opts.budget, opts.json);
    return 0;
}

fn stats(arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    const s = try oq.stats(arena, text);
    var body: Writer.Allocating = .init(arena);
    const bw = &body.writer;
    if (opts.json) {
        try bw.print("{{\"type\":\"stats\",\"lines\":{d},\"bytes\":{d},\"errors\":{d},\"failures\":{d},\"warnings\":{d},\"first_error\":", .{ s.lines, s.bytes, s.error_lines, s.failure_lines, s.warning_lines });
        try writeOptionalNumber(bw, s.first_error);
        try bw.writeAll(",\"first_failure\":");
        try writeOptionalNumber(bw, s.first_failure);
        try bw.writeAll(",\"first_warning\":");
        try writeOptionalNumber(bw, s.first_warning);
        try bw.print(",\"longest_line\":{d},\"frameworks\":[", .{s.longest_line});
        try writeFrameworksJson(bw, s.frameworks);
        try bw.writeAll("]}\n");
    } else {
        try bw.print("lines: {d}\nbytes: {d}\n", .{ s.lines, s.bytes });
        const rows = [_]struct { []const u8, u64, ?u64 }{
            .{ "errors", s.error_lines, s.first_error },
            .{ "failures", s.failure_lines, s.first_failure },
            .{ "warnings", s.warning_lines, s.first_warning },
        };
        for (rows) |row| {
            try bw.print("{s}: {d}", .{ row[0], row[1] });
            if (row[2]) |first| try bw.print(" (first at line {d})", .{first});
            try bw.writeByte('\n');
        }
        try bw.print("longest line: {d} bytes\nframeworks: ", .{s.longest_line});
        try writeFrameworksText(bw, s.frameworks);
        try bw.writeByte('\n');
    }
    try emitCapped(w, &.{}, body.written(), opts.budget, opts.json);
    return 0;
}

test "sizes and ranges parse" {
    try std.testing.expectEqual(@as(?usize, 4096), parseSize("4096"));
    try std.testing.expectEqual(@as(?usize, 2048), parseSize("2k"));
    try std.testing.expectEqual(@as(?usize, 64 * 1024), parseSize("64K"));
    try std.testing.expectEqual(@as(?usize, 1 << 20), parseSize("1M"));
    try std.testing.expectEqual(@as(?usize, null), parseSize("lots"));
    try std.testing.expectEqual(@as(?usize, null), parseSize(""));

    try std.testing.expectEqual(Range{ .from = 41, .to = 9852 }, parseRange("41–9852").?);
    try std.testing.expectEqual(Range{ .from = 41, .to = 60 }, parseRange("41-60").?);
    try std.testing.expectEqual(Range{ .from = 41, .to = 60 }, parseRange("41..60").?);
    try std.testing.expectEqual(Range{ .from = 7, .to = 7 }, parseRange("7").?);
    try std.testing.expectEqual(Range{ .from = 7, .to = null }, parseRange("7-").?);
    try std.testing.expect(parseRange("9-3") == null);
    try std.testing.expect(parseRange("0-3") == null);
    try std.testing.expect(parseRange("x") == null);
}

test "run logs live under the runtime directory or /tmp" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("/tmp/wsh/runs/test/output.log", try runLogPath(arena, "/tmp", "test"));
    const fallback = try std.fmt.allocPrint(arena, "/tmp/wsh-{d}/runs/test/output.log", .{linux.getuid()});
    try std.testing.expectEqualStrings(fallback, try runLogPath(arena, "/definitely/not/a/dir", "test"));
    try std.testing.expectEqualStrings(fallback, try runLogPath(arena, null, "test"));
    try std.testing.expectEqualStrings(fallback, try runLogPath(arena, "", "test"));
}
