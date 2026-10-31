//! `out`: answers small questions about command output (a summary within a
//! byte budget, the failed tests, the lines matching a query) so an agent
//! does not have to read a whole log. Input is stdin, a file (`--file`), or a
//! background run's log (`--run`). Files are mapped rather than read, and the
//! queries themselves live in `output_query.zig`.

const std = @import("std");
const agent_state = @import("../agent/state.zig");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const proc = @import("../proc.zig");
const regex = @import("../regex.zig");
const oq = @import("../output_query.zig");
const put = oq.put;
const putByte = oq.putByte;

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
            fail(ctx, &.{regex.errorMessage(@errorCast(err))});
            return 2;
        },
    };
    out.interface.flush() catch {
        if (!out.broken_pipe) ctx.err("wsh: out: write error\n");
        return 1;
    };
    return status;
}

/// Writes `wsh: out: `, then `parts`, as one line on stderr. Messages are
/// pieced together rather than formatted so that each one does not
/// instantiate its own formatting code.
noinline fn fail(ctx: Ctx, parts: []const []const u8) void {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    put(&w, "wsh: out: ") catch {};
    for (parts) |part| put(&w, part) catch {};
    putByte(&w, '\n') catch {
        buf[buf.len - 1] = '\n';
    };
    ctx.err(w.buffered());
}

fn usageError(ctx: Ctx, parts: []const []const u8) error{Usage} {
    fail(ctx, parts);
    ctx.err("wsh: out: usage: out budget|find|grep|failures|lines|stats [options] [--file FILE | --run NAME]; see `out --help`\n");
    return error.Usage;
}

noinline fn parseArgs(ctx: Ctx, arena: Allocator) error{ Help, Usage, OutOfMemory }!Options {
    const argv = ctx.argv;
    if (argv.len < 2) return usageError(ctx, &.{"expected a subcommand"});
    if (std.mem.eql(u8, argv[1], "--help") or std.mem.eql(u8, argv[1], "-h") or std.mem.eql(u8, argv[1], "help")) return error.Help;
    var opts = Options{ .command = std.meta.stringToEnum(Command, argv[1]) orelse
        return usageError(ctx, &.{ argv[1], ": unknown subcommand" }) };

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
        } else return usageError(ctx, &.{ arg, ": unknown option" });
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
                if (i >= argv.len) return usageError(ctx, &.{ arg, ": option requires an argument" });
                value = argv[i];
            }
        } else if (eq != null) return usageError(ctx, &.{ name, ": option takes no argument" });
        switch (flag) {
            .file => opts.file = value,
            .run => opts.run = value,
            .json => opts.json = true,
            .raw => opts.raw = true,
            .budget => opts.budget = parseSize(value) orelse return usageError(ctx, &.{ value, ": invalid size" }),
            .limit => opts.limit = parseCount(value) orelse return usageError(ctx, &.{ value, ": invalid count" }),
            .context => opts.context = parseCount(value) orelse return usageError(ctx, &.{ value, ": invalid count" }),
            .regex => opts.regex = true,
            .ignore_case => opts.ignore_case = true,
            .help => return error.Help,
        }
    }
    if (opts.file != null and opts.run != null) return usageError(ctx, &.{"--file and --run are exclusive"});

    const n = opts.operands.items.len;
    switch (opts.command) {
        .budget => {
            if (n > 1) return usageError(ctx, &.{"budget: expected at most one size"});
            if (n == 1) opts.budget = parseSize(opts.operands.items[0]) orelse
                return usageError(ctx, &.{ opts.operands.items[0], ": invalid size" });
        },
        .find => if (n == 0) return usageError(ctx, &.{"find: expected a query"}),
        .grep => if (n != 1) return usageError(ctx, &.{"grep: expected one pattern"}),
        .lines => {
            if (n != 1) return usageError(ctx, &.{"lines: expected a range such as 41-60"});
            if (parseRange(opts.operands.items[0]) == null) return usageError(ctx, &.{ opts.operands.items[0], ": invalid range" });
        },
        .failures, .stats => if (n != 0) return usageError(ctx, &.{ @tagName(opts.command), ": unexpected argument ", opts.operands.items[0] }),
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
    const n = parseCount(digits) orelse return null;
    return std.math.mul(usize, n, unit) catch null;
}

fn parseCount(text: []const u8) ?usize {
    return std.math.cast(usize, oq.parseNumber(text) orelse return null);
}

const Range = struct { from: u64, to: ?u64 };

/// `41-60`, `41–60` (as printed in elision markers), `41..60`, `41,60`,
/// `41` and `41-` (to the end).
noinline fn parseRange(text: []const u8) ?Range {
    const separators = [_][]const u8{ "–", "..", "-", "," };
    for (separators) |sep| {
        if (std.mem.indexOf(u8, text, sep)) |at| {
            const from = oq.parseNumber(text[0..at]) orelse return null;
            const rest = text[at + sep.len ..];
            if (from == 0) return null;
            if (rest.len == 0) return .{ .from = from, .to = null };
            const to = oq.parseNumber(rest) orelse return null;
            if (to < from) return null;
            return .{ .from = from, .to = to };
        }
    }
    const line = oq.parseNumber(text) orelse return null;
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
    const dir = try agent_state.dirPathFrom(arena, runtime_dir);
    return std.mem.concatWithSentinel(arena, u8, &.{ dir, "/runs/", name, "/output.log" }, 0);
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

noinline fn loadInput(ctx: Ctx, arena: Allocator, opts: Options) ?Input {
    if (opts.run) |name| {
        if (name.len == 0 or std.mem.indexOfScalar(u8, name, '/') != null or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) {
            fail(ctx, &.{ name, ": invalid run name" });
            return null;
        }
        const path = runLogPath(arena, ctx.sh.getEnv("XDG_RUNTIME_DIR"), name) catch return null;
        if (!fs.exists(path)) {
            fail(ctx, &.{ name, ": no such run (no log at ", path, ")" });
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

noinline fn loadPath(ctx: Ctx, path: [:0]const u8, label: []const u8) ?Input {
    const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        fail(ctx, &.{ label, ": ", proc.errorText(err) });
        return null;
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    return loadFd(ctx, fd, label);
}

/// Maps a regular file (from the descriptor's current offset) and reads
/// anything else, such as a pipe.
noinline fn loadFd(ctx: Ctx, fd: i32, label: []const u8) ?Input {
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .TYPE = true, .MODE = true, .SIZE = true }, &st)) == .SUCCESS) {
        const kind = st.mode & linux.S.IFMT;
        if (kind == linux.S.IFDIR) {
            fail(ctx, &.{ label, ": Is a directory" });
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
            fail(ctx, &.{ label, ": ", proc.errorText(err) });
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

/// Output under construction. Writes return nothing: the first failure is
/// remembered and checked once with `check`, which spares each of the many
/// writes its own error test, and a label with its number is one call.
const Out = struct {
    w: *Writer,
    failed: bool = false,

    noinline fn str(o: *Out, bytes: []const u8) void {
        o.w.writeAll(bytes) catch {
            o.failed = true;
        };
    }

    noinline fn byte(o: *Out, c: u8) void {
        o.w.writeByte(c) catch {
            o.failed = true;
        };
    }

    noinline fn num(o: *Out, n: u64) void {
        oq.writeNumber(o.w, n) catch {
            o.failed = true;
        };
    }

    /// `label` then `n`: `,"line":42`, `] line 42`.
    noinline fn field(o: *Out, label: []const u8, n: u64) void {
        o.str(label);
        o.num(n);
    }

    /// `label` then `n`, or `null`.
    noinline fn optField(o: *Out, label: []const u8, n: ?u64) void {
        o.str(label);
        if (n) |v| o.num(v) else o.str("null");
    }

    /// `label` then `text` as a JSON string, or `null`.
    noinline fn json(o: *Out, label: []const u8, text: ?[]const u8) void {
        o.str(label);
        const v = text orelse return o.str("null");
        oq.writeJsonString(o.w, v) catch {
            o.failed = true;
        };
    }

    fn check(o: Out) Writer.Error!void {
        if (o.failed) return error.WriteFailed;
    }
};

/// Output collected as separate records, so `--budget` can drop whole
/// records and say how many.
const Records = struct {
    arena: Allocator,
    items: std.ArrayList([]const u8) = .empty,
    current: Writer.Allocating,
    o: Out = .{ .w = undefined },

    fn init(arena: Allocator) Records {
        return .{ .arena = arena, .current = .init(arena) };
    }

    /// Where the current record is written.
    fn out(self: *Records) *Out {
        self.o = .{ .w = &self.current.writer, .failed = self.o.failed };
        return &self.o;
    }

    /// Ends the record written so far.
    fn finish(self: *Records) Allocator.Error!void {
        // Writing into memory fails only for want of it.
        if (self.o.failed) return error.OutOfMemory;
        const bytes = try self.current.toOwnedSlice();
        if (bytes.len != 0) try self.items.append(self.arena, bytes);
    }
};

/// Writes `records` then `footer`, dropping trailing records that would
/// take the total past `max` and noting how many were dropped.
noinline fn emitCapped(o: *Out, records: []const []const u8, footer: []const u8, max: ?usize, json: bool) void {
    const limit = max orelse {
        for (records) |record| o.str(record);
        o.str(footer);
        return;
    };
    var note_buf: [128]u8 = undefined;
    const reserve = footer.len + noteText(&note_buf, records.len, json).len;
    var used: usize = 0;
    var kept: usize = 0;
    for (records) |record| {
        if (used + record.len + reserve > limit) break;
        o.str(record);
        used += record.len;
        kept += 1;
    }
    if (kept < records.len) {
        const note = noteText(&note_buf, records.len - kept, json);
        if (used + note.len <= limit) {
            o.str(note);
            used += note.len;
        }
    }
    if (used + footer.len <= limit) o.str(footer);
}

noinline fn noteText(buf: *[128]u8, omitted: usize, json: bool) []const u8 {
    var w: Writer = .fixed(buf);
    var o: Out = .{ .w = &w };
    o.field(if (json) "{\"type\":\"truncated\",\"omitted\":" else "[… ", omitted);
    o.str(if (json) "}\n" else " more not shown; raise --budget …]\n");
    return w.buffered();
}

/// The part of `line` to show: all of it, or `max_shown` bytes starting a
/// little before `focus` when it is longer.
noinline fn excerpt(line: []const u8, focus: usize) struct { start: usize, end: usize } {
    if (line.len <= max_shown) return .{ .start = 0, .end = line.len };
    var start = if (focus > 64) focus - 64 else 0;
    if (start + max_shown > line.len) start = line.len - max_shown;
    while (start > 0 and (line[start] & 0xc0) == 0x80) start -= 1;
    var end = @min(line.len, start + max_shown);
    while (end < line.len and (line[end] & 0xc0) == 0x80) end -= 1;
    return .{ .start = start, .end = end };
}

/// `N:text` for a match or `N-text` for context, as grep prints them, with
/// cut ends marked with how many bytes were left out.
noinline fn writeNumbered(o: *Out, number: u64, mark: u8, line: []const u8, start: usize, end: usize) void {
    o.num(number);
    o.byte(mark);
    if (start > 0) {
        o.field("[+", start);
        o.str(" bytes] … ");
    }
    o.str(line[start..end]);
    if (end < line.len) {
        o.field(" … [+", line.len - end);
        o.str(" bytes]");
    }
    o.byte('\n');
}

/// `{"type":"match","line":N,"offset":O,"text":"…"` and, for an excerpt,
/// where it starts.
noinline fn writeMatchHead(o: *Out, line: oq.Line, display: []const u8, start: usize, end: usize) void {
    o.field("{\"type\":\"match\",\"line\":", line.number);
    o.field(",\"offset\":", line.start);
    o.json(",\"text\":", display[start..end]);
    if (start != 0 or end != display.len) o.field(",\"excerpt_start\":", start);
}

fn shown(opts: Options, text: []const u8, line: oq.Line, cleaned: []const u8) []const u8 {
    return if (opts.raw) line.bytes(text) else cleaned;
}

// --- subcommands -----------------------------------------------------------------

fn execute(ctx: Ctx, arena: Allocator, opts: Options, text: []const u8, w: *Writer) !u8 {
    var o: Out = .{ .w = w };
    const status = switch (opts.command) {
        .budget => blk: {
            o.str(try oq.budget(arena, text, opts.budget orelse 4096, .{
                .format = if (opts.json) .json else .text,
                .raw = opts.raw,
            }));
            break :blk 0;
        },
        .find => try find(arena, opts, text, &o),
        .grep => try grep(arena, opts, text, &o),
        .failures => try failures(arena, opts, text, &o),
        .lines => try lines(ctx, arena, opts, text, &o),
        .stats => try stats(arena, opts, text, &o),
    };
    try o.check();
    return status;
}

fn find(arena: Allocator, opts: Options, text: []const u8, o: *Out) !u8 {
    const query = try std.mem.join(arena, " ", opts.operands.items);
    const result = try oq.fuzzyFind(arena, text, query, opts.limit orelse 20);
    var records = Records.init(arena);
    for (result.matches) |match| {
        const r = records.out();
        if (opts.context > 0) try writeContext(r, arena, opts, text, match.line, .before);
        const focus = if (match.positions.len != 0) match.positions[0] else 0;
        const display = shown(opts, text, match.line, match.text);
        const cut = excerpt(display, if (opts.raw) 0 else focus);
        if (opts.json) {
            writeMatchHead(r, match.line, display, cut.start, cut.end);
            r.str(",\"score\":");
            if (match.score < 0) r.byte('-');
            r.num(@abs(match.score));
            r.str(",\"positions\":[");
            var first = true;
            for (match.positions) |pos| {
                if (pos < cut.start or pos >= cut.end) continue;
                if (!first) r.byte(',');
                first = false;
                r.num(pos - cut.start);
            }
            r.str("]}\n");
        } else {
            writeNumbered(r, match.line.number, ':', display, cut.start, cut.end);
        }
        if (opts.context > 0) {
            try writeContext(r, arena, opts, text, match.line, .after);
            if (!opts.json) r.str("--\n");
        }
        try records.finish();
    }
    emitCapped(o, records.items.items, try matchFooter(arena, opts, result.total, result.matches.len), opts.budget, opts.json);
    return if (result.total == 0) 1 else 0;
}

/// How many lines matched in all; in text form only when some are not shown.
noinline fn matchFooter(arena: Allocator, opts: Options, total: u64, kept: usize) ![]const u8 {
    const more = total - kept;
    if (!opts.json and more == 0) return "";
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);
    var o: Out = .{ .w = &w };
    if (opts.json) {
        o.field("{\"type\":\"summary\",\"matches\":", total);
        o.field(",\"shown\":", kept);
        o.str("}\n");
    } else {
        o.field("[… ", more);
        o.str(if (more == 1) " more matching line; raise --limit …]\n" else " more matching lines; raise --limit …]\n");
    }
    return arena.dupe(u8, w.buffered());
}

const Side = enum { before, after };

noinline fn writeContext(o: *Out, arena: Allocator, opts: Options, text: []const u8, line: oq.Line, side: Side) !void {
    const around = try oq.context(arena, text, line, if (side == .before) opts.context else 0, if (side == .after) opts.context else 0);
    for (around) |l| {
        if (l.number == line.number) continue;
        try writeContextLine(o, arena, opts, text, l);
    }
}

noinline fn writeContextLine(o: *Out, arena: Allocator, opts: Options, text: []const u8, l: oq.Line) !void {
    const display = if (opts.raw) l.bytes(text) else try oq.cleanAlloc(arena, l.bytes(text));
    const cut = excerpt(display, 0);
    if (opts.json) {
        o.field("{\"type\":\"context\",\"line\":", l.number);
        o.json(",\"text\":", display[cut.start..cut.end]);
        o.str("}\n");
    } else {
        writeNumbered(o, l.number, '-', display, cut.start, cut.end);
    }
}

fn grep(arena: Allocator, opts: Options, text: []const u8, o: *Out) !u8 {
    const result = try oq.grep(arena, text, opts.operands.items[0], .{
        .regex = opts.regex,
        .ignore_case = opts.ignore_case,
        .limit = opts.limit orelse 100,
    });
    var records = Records.init(arena);
    // As in grep, context windows that touch merge and others are separated.
    var printed: u64 = 0;
    for (result.matches) |match| {
        const r = records.out();
        if (opts.context > 0) {
            const before = try oq.context(arena, text, match.line, opts.context, 0);
            if (printed != 0 and before[0].number > printed + 1 and !opts.json) r.str("--\n");
            for (before) |l| {
                if (l.number == match.line.number or l.number <= printed) continue;
                try writeContextLine(r, arena, opts, text, l);
            }
        }
        const display = shown(opts, text, match.line, match.text);
        const focus = if (match.spans.len != 0) match.spans[0].start else 0;
        const cut = excerpt(display, if (opts.raw) 0 else focus);
        if (opts.json) {
            writeMatchHead(r, match.line, display, cut.start, cut.end);
            r.str(",\"spans\":[");
            var first = true;
            for (match.spans) |span| {
                if (span.start < cut.start or span.end > cut.end) continue;
                r.str(if (first) "[" else ",[");
                first = false;
                r.field("", span.start - cut.start);
                r.field(",", span.end - cut.start);
                r.byte(']');
            }
            r.str("]}\n");
        } else {
            writeNumbered(r, match.line.number, ':', display, cut.start, cut.end);
        }
        printed = @max(printed, match.line.number);
        if (opts.context > 0) {
            const after = try oq.context(arena, text, match.line, 0, opts.context);
            for (after) |l| {
                if (l.number <= printed) continue;
                // A later match inside this window prints itself.
                if (isMatchLine(result.matches, l.number)) break;
                try writeContextLine(r, arena, opts, text, l);
                printed = l.number;
            }
        }
        try records.finish();
    }
    emitCapped(o, records.items.items, try matchFooter(arena, opts, result.total, result.matches.len), opts.budget, opts.json);
    return if (result.total == 0) 1 else 0;
}

noinline fn isMatchLine(matches: []const oq.GrepMatch, number: u64) bool {
    for (matches) |m| {
        if (m.line.number == number) return true;
        if (m.line.number > number) return false;
    }
    return false;
}

fn failures(arena: Allocator, opts: Options, text: []const u8, o: *Out) !u8 {
    const report = try oq.failures(arena, text);
    var records = Records.init(arena);
    for (report.failures) |f| {
        const r = records.out();
        if (opts.json) {
            r.str("{\"type\":\"failure\",\"framework\":\"");
            r.str(@tagName(f.framework));
            r.json("\",\"name\":", f.name);
            r.field(",\"line\":", f.line);
            r.json(",\"location\":", f.location);
            r.json(",\"reason\":", f.reason);
            r.str("}\n");
        } else {
            r.str("FAILED ");
            r.str(f.name);
            r.str(" [");
            r.str(@tagName(f.framework));
            r.field("] line ", f.line);
            if (f.location) |location| {
                if (!std.mem.eql(u8, location, f.name)) {
                    r.str(" at ");
                    r.str(location);
                }
            }
            if (f.reason) |reason| {
                r.str(": ");
                r.str(reason);
            }
            r.byte('\n');
        }
        try records.finish();
    }

    const r = records.out();
    const status = report.status();
    const listed = report.failures.len + report.omitted;
    if (opts.json) {
        r.str("{\"type\":\"summary\",\"status\":\"");
        r.str(switch (status) {
            0 => "passed",
            1 => "failed",
            else => "unrecognized",
        });
        r.str("\",\"frameworks\":[");
        writeFrameworks(r, report.frameworks, true);
        r.optField("],\"passed\":", report.counts.passed);
        r.optField(",\"failed\":", report.counts.failed);
        r.optField(",\"skipped\":", report.counts.skipped);
        r.field(",\"failures\":", listed);
        r.field(",\"omitted\":", report.omitted);
        r.str("}\n");
    } else if (status == 2) {
        r.str("no recognizable test output\n");
    } else {
        if (listed == 0) {
            r.str("no failures");
        } else {
            r.num(listed);
            r.str(if (listed == 1) " failure" else " failures");
        }
        if (report.omitted != 0) {
            r.field(" (", report.omitted);
            r.str(" not listed)");
        }
        var sep: []const u8 = "; ";
        const fields = [_]struct { ?u64, []const u8 }{
            .{ report.counts.passed, " passed" },
            .{ report.counts.failed, " failed" },
            .{ report.counts.skipped, " skipped" },
        };
        for (fields) |field| {
            if (field[0]) |n| {
                r.field(sep, n);
                r.str(field[1]);
                sep = ", ";
            }
        }
        r.str(" [");
        writeFrameworks(r, report.frameworks, false);
        r.str("]\n");
    }
    if (r.failed) return error.OutOfMemory;
    emitCapped(o, records.items.items, records.current.written(), opts.budget, opts.json);
    return status;
}

/// The frameworks seen: `"cargo","go"` for JSON, `cargo, go` (or `none`)
/// for text.
noinline fn writeFrameworks(o: *Out, set: oq.FrameworkSet, json: bool) void {
    var it = set.iterator();
    var first = true;
    while (it.next()) |framework| {
        if (!first) o.str(if (json) "," else ", ");
        first = false;
        if (json) o.byte('"');
        o.str(@tagName(framework));
        if (json) o.byte('"');
    }
    if (first and !json) o.str("none");
}

fn lines(ctx: Ctx, arena: Allocator, opts: Options, text: []const u8, o: *Out) !u8 {
    const range = parseRange(opts.operands.items[0]).?;
    const first = oq.lineAt(text, range.from) orelse {
        var from_buf: [20]u8 = undefined;
        var count_buf: [20]u8 = undefined;
        fail(ctx, &.{ "lines: line ", oq.formatNumber(&from_buf, range.from), " is past the end (", oq.formatNumber(&count_buf, oq.countLines(text)), " lines)" });
        return 1;
    };
    var it = oq.LineIterator.initAt(text, first.start, first.number - 1);
    var cleaner = oq.Cleaner.init(arena);
    // Without a budget, lines stream straight out.
    var records = Records.init(arena);
    while (it.next()) |line| {
        if (range.to) |to| {
            if (line.number > to) break;
        }
        const target = if (opts.budget != null) records.out() else o;
        const display = if (opts.raw) line.bytes(text) else try cleaner.cleanLine(text, line);
        if (opts.json) {
            target.field("{\"type\":\"line\",\"line\":", line.number);
            target.json(",\"text\":", display);
            target.str("}\n");
        } else {
            target.str(display);
            target.byte('\n');
        }
        if (opts.budget != null) try records.finish();
    }
    if (opts.budget != null) emitCapped(o, records.items.items, "", opts.budget, opts.json);
    return 0;
}

fn stats(arena: Allocator, opts: Options, text: []const u8, o: *Out) !u8 {
    const s = try oq.stats(arena, text);
    var records = Records.init(arena);
    const r = records.out();
    if (opts.json) {
        const fields = [_]struct { []const u8, ?u64 }{
            .{ "{\"type\":\"stats\",\"lines\":", s.lines },
            .{ ",\"bytes\":", s.bytes },
            .{ ",\"errors\":", s.error_lines },
            .{ ",\"failures\":", s.failure_lines },
            .{ ",\"warnings\":", s.warning_lines },
            .{ ",\"first_error\":", s.first_error },
            .{ ",\"first_failure\":", s.first_failure },
            .{ ",\"first_warning\":", s.first_warning },
            .{ ",\"longest_line\":", s.longest_line },
        };
        for (fields) |field| r.optField(field[0], field[1]);
        r.str(",\"frameworks\":[");
        writeFrameworks(r, s.frameworks, true);
        r.str("]}\n");
    } else {
        r.field("lines: ", s.lines);
        r.field("\nbytes: ", s.bytes);
        const rows = [_]struct { []const u8, u64, ?u64 }{
            .{ "\nerrors: ", s.error_lines, s.first_error },
            .{ "\nfailures: ", s.failure_lines, s.first_failure },
            .{ "\nwarnings: ", s.warning_lines, s.first_warning },
        };
        for (rows) |row| {
            r.field(row[0], row[1]);
            if (row[2]) |at| {
                r.field(" (first at line ", at);
                r.byte(')');
            }
        }
        r.field("\nlongest line: ", s.longest_line);
        r.str(" bytes\nframeworks: ");
        writeFrameworks(r, s.frameworks, false);
        r.byte('\n');
    }
    if (r.failed) return error.OutOfMemory;
    emitCapped(o, &.{}, records.current.written(), opts.budget, opts.json);
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
