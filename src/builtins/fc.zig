//! `fc`: list, edit and re-run commands from the history.
//!
//!     fc [-e editor] [-lnr] [first [last]]
//!     fc -s [old=new] [command]

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");

const Ctx = builtins.Ctx;

const usage = "wsh: fc: usage: fc [-e ename] [-lnr] [first] [last] or fc -s [pat=rep] [command]\n";

/// The history as `fc` sees it: without the `fc` command being run, which was
/// recorded before it started.
fn visibleCount(ctx: Ctx) usize {
    const hist = &ctx.sh.hist;
    const total = hist.count();
    if (total == 0) return 0;
    const last = hist.get(total - 1);
    if (ctx.sh.isEnteredLine(last)) return total - 1;
    return total;
}

/// Resolves a `first`/`last` operand to a 1-based history number: a number,
/// a negative offset from the newest entry, or the newest command starting
/// with the text.
fn resolve(ctx: Ctx, text: []const u8, count: usize) ?usize {
    if (std.fmt.parseInt(i64, text, 10)) |n| {
        const total: i64 = @intCast(count);
        const absolute = if (n < 0) total + n + 1 else if (n == 0) total else n;
        if (absolute < 1 or absolute > total) {
            ctx.err("wsh: fc: history specification out of range\n");
            return null;
        }
        return @intCast(absolute);
    } else |_| {}

    var index = count;
    while (index > 0) : (index -= 1) {
        if (std.mem.startsWith(u8, ctx.sh.hist.get(index - 1), text)) return index;
    }
    ctx.err("wsh: fc: no command found\n");
    return null;
}

pub fn run(ctx: Ctx) u8 {
    var list = false;
    var numbers = true;
    var reverse = false;
    var reexecute = false;
    var editor: ?[]const u8 = null;

    var parser = options.Parser.init(ctx.argv, "e:lnrs");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid => |c| {
                ctx.errFmt("wsh: fc: -{c}: invalid option\n", .{c});
                ctx.err(usage);
                return 2;
            },
            .missing => |c| {
                ctx.errFmt("wsh: fc: -{c}: option requires an argument\n", .{c});
                ctx.err(usage);
                return 2;
            },
            .option => |c| switch (c) {
                'e' => editor = parser.optarg,
                'l' => list = true,
                'n' => numbers = false,
                'r' => reverse = true,
                's' => reexecute = true,
                else => unreachable,
            },
        }
    }
    const operands = parser.rest();
    const count = visibleCount(ctx);

    if (reexecute) return reexecuteCommand(ctx, operands, count);

    if (operands.len > 2) {
        ctx.err("wsh: fc: too many arguments\n");
        return 2;
    }
    if (count == 0) {
        if (list) return 0;
        ctx.err("wsh: fc: no command found\n");
        return 1;
    }

    var first: usize = undefined;
    var last: usize = undefined;
    if (list) {
        first = if (count > 15) count - 15 else 1;
        if (operands.len > 0) first = resolve(ctx, operands[0], count) orelse return 1;
        last = count;
        if (operands.len > 1) last = resolve(ctx, operands[1], count) orelse return 1;
    } else {
        first = count;
        if (operands.len > 0) first = resolve(ctx, operands[0], count) orelse return 1;
        last = first;
        if (operands.len > 1) last = resolve(ctx, operands[1], count) orelse return 1;
    }
    // A reversed range lists (or edits) newest first, as with -r.
    if (first > last) {
        std.mem.swap(usize, &first, &last);
        reverse = !reverse;
    }

    if (list) {
        printRange(ctx, first, last, numbers, reverse);
        return 0;
    }
    return editAndRun(ctx, editor, first, last, reverse);
}

fn printRange(ctx: Ctx, first: usize, last: usize, numbers: bool, reverse: bool) void {
    var step: usize = 0;
    const span = last - first + 1;
    while (step < span) : (step += 1) {
        const number = if (reverse) last - step else first + step;
        const entry = ctx.sh.hist.get(number - 1);
        if (numbers) {
            ctx.outFmt("{d}\t", .{number});
        } else {
            ctx.out("\t");
        }
        ctx.out(entry);
        ctx.out("\n");
    }
}

/// `fc -s [old=new] [command]`: runs a command again, optionally with the
/// first `old` replaced by `new`.
fn reexecuteCommand(ctx: Ctx, operands: []const []const u8, count: usize) u8 {
    var rest = operands;
    var old: ?[]const u8 = null;
    var new: []const u8 = "";
    if (rest.len > 0) {
        if (std.mem.indexOfScalar(u8, rest[0], '=')) |at| {
            if (at > 0) {
                old = rest[0][0..at];
                new = rest[0][at + 1 ..];
                rest = rest[1..];
            }
        }
    }
    if (rest.len > 1) {
        ctx.err("wsh: fc: too many arguments\n");
        return 2;
    }
    if (count == 0) {
        ctx.err("wsh: fc: no command found\n");
        return 1;
    }
    var number = count;
    if (rest.len == 1) number = resolve(ctx, rest[0], count) orelse return 1;
    var command: []const u8 = ctx.sh.hist.get(number - 1);

    const arena = ctx.sh.scratch();
    if (old) |pattern| {
        if (std.mem.indexOf(u8, command, pattern)) |at| {
            command = std.mem.concat(arena, u8, &.{ command[0..at], new, command[at + pattern.len ..] }) catch return 1;
        }
    }
    return runCommand(ctx, command);
}

/// Echoes `text` as bash does before running it, records it, and runs it.
fn runCommand(ctx: Ctx, text: []const u8) u8 {
    const run_source = ctx.run_source orelse {
        ctx.err("wsh: fc: cannot run commands from here\n");
        return 1;
    };
    sys.writeStr(ctx.stderr, text);
    sys.writeStr(ctx.stderr, "\n");
    // The `fc` line itself is replaced by what actually ran.
    const hist = &ctx.sh.hist;
    if (hist.count() > 0 and ctx.sh.isEnteredLine(hist.get(hist.count() - 1))) hist.remove(ctx.sh.gpa, hist.count() - 1);
    _ = hist.record(ctx.sh.gpa, text, .{ .ignoredups = false }) catch {};
    return run_source(ctx.sh, text);
}

/// Writes the range to a temporary file, runs the editor on it, then runs
/// whatever the file holds.
fn editAndRun(ctx: Ctx, editor_name: ?[]const u8, first: usize, last: usize, reverse: bool) u8 {
    const sh = ctx.sh;
    const run_source = ctx.run_source orelse {
        ctx.err("wsh: fc: cannot run commands from here\n");
        return 1;
    };
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    var step: usize = 0;
    const span = last - first + 1;
    while (step < span) : (step += 1) {
        const number = if (reverse) last - step else first + step;
        body.appendSlice(arena, sh.hist.get(number - 1)) catch return 1;
        body.append(arena, '\n') catch return 1;
    }

    const tmpdir = sh.getEnv("TMPDIR") orelse "/tmp";
    var path: [:0]const u8 = undefined;
    var fd: i32 = -1;
    var attempt: usize = 0;
    while (attempt < 16) : (attempt += 1) {
        path = std.fmt.allocPrintSentinel(arena, "{s}/wsh-fc-{d}-{d}", .{ tmpdir, sys.getpid(), attempt }, 0) catch return 1;
        const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
        if (linux.errno(rc) == .SUCCESS) {
            fd = @intCast(rc);
            break;
        }
    }
    if (fd < 0) {
        ctx.err("wsh: fc: cannot create a temporary file\n");
        return 1;
    }
    const wrote = sys.writeAll(fd, body.items) == .ok;
    _ = linux.close(fd);
    defer _ = fs.removeFile(path);
    if (!wrote) {
        ctx.err("wsh: fc: cannot write the temporary file\n");
        return 1;
    }

    const editor = editor_name orelse sh.getEnv("FCEDIT") orelse sh.getEnv("EDITOR") orelse "vi";
    const command = std.fmt.allocPrint(arena, "{s} '{s}'", .{ editor, path }) catch return 1;
    const status = run_source(sh, command);
    if (status != 0) return status;

    const edited = (fs.readFileAlloc(arena, path, 1 << 20) catch null) orelse {
        ctx.err("wsh: fc: cannot read the edited file\n");
        return 1;
    };
    const text = std.mem.trimEnd(u8, edited, "\n");
    if (text.len == 0) return 0;
    return runCommand(ctx, text);
}
