//! `history`: list, edit and persist the command history.

const std = @import("std");
const builtins = @import("../builtins.zig");
const history = @import("../history.zig");

const Ctx = builtins.Ctx;

const usage = "history: usage: history [-c] [-d offset] [n] or history -anrw [filename]\n";

pub fn run(ctx: Ctx) u8 {
    var clear = false;
    var delete: ?[]const u8 = null;
    var file_op: ?u8 = null;
    var index: usize = 1;
    while (index < ctx.argv.len) : (index += 1) {
        const arg = ctx.argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        // `-3` is a count only for `-d`; on its own it is an option error, as in bash.
        if (arg.len < 2 or arg[0] != '-') break;
        for (arg[1..], 1..) |flag, at| switch (flag) {
            'c' => clear = true,
            'd' => {
                if (at + 1 < arg.len) {
                    delete = arg[at + 1 ..];
                } else {
                    index += 1;
                    delete = ctx.arg(index) orelse {
                        ctx.err("wsh: history: -d: option requires an argument\n");
                        ctx.err(usage);
                        return 2;
                    };
                }
                break;
            },
            'a', 'r', 'w' => {
                if (file_op != null and file_op.? != flag) {
                    ctx.err("wsh: history: cannot use more than one of -anrw\n");
                    return 1;
                }
                file_op = flag;
            },
            'n', 'p', 's' => {
                ctx.errFmt("wsh: history: -{c}: not supported\n", .{flag});
                return 2;
            },
            else => {
                ctx.errFmt("wsh: history: -{c}: invalid option\n", .{flag});
                ctx.err(usage);
                return 2;
            },
        };
    }
    const rest = ctx.argv[@min(index, ctx.argv.len)..];

    if (!clear and delete == null and file_op == null) {
        if (rest.len == 0) return list(ctx, 0);
        if (rest.len > 1) {
            ctx.err("wsh: history: too many arguments\n");
            return 1;
        }
        if (std.mem.eql(u8, rest[0], "clear")) return clearAll(ctx);
        const count = std.fmt.parseInt(usize, rest[0], 10) catch {
            ctx.errFmt("wsh: history: {s}: numeric argument required\n", .{rest[0]});
            return 2;
        };
        return list(ctx, count);
    }

    if (clear) ctx.sh.hist.clear(ctx.sh.gpa);
    if (delete) |spec| {
        const status = deleteEntries(ctx, spec);
        if (status != 0) return status;
    }
    if (file_op) |op| {
        if (rest.len > 1) {
            ctx.err("wsh: history: too many arguments\n");
            return 1;
        }
        return fileOperation(ctx, op, if (rest.len == 1) rest[0] else null);
    }
    if (rest.len != 0) {
        ctx.err("wsh: history: too many arguments\n");
        return 1;
    }
    return 0;
}

fn list(ctx: Ctx, limit: usize) u8 {
    const total = ctx.sh.hist.count();
    const start = if (limit != 0 and total > limit) total - limit else 0;
    var i = start;
    while (i < total) : (i += 1) {
        // Entries can be longer than `outFmt`'s buffer.
        ctx.outFmt("{d: >5}  ", .{i + 1});
        ctx.out(ctx.sh.hist.get(i));
        ctx.out("\n");
    }
    return 0;
}

/// `history clear`: forgets every entry, in memory and in the history file.
fn clearAll(ctx: Ctx) u8 {
    ctx.sh.hist.clear(ctx.sh.gpa);
    if (ctx.sh.history_path.len == 0) return 0;
    history.writeEntries(ctx.sh.gpa, ctx.sh.history_path, &.{}) catch {
        ctx.errFmt("wsh: history: {s}: cannot write\n", .{ctx.sh.history_path});
        return 1;
    };
    ctx.sh.hist.file_entries = 0;
    return 0;
}

/// Resolves a `history -d` position: 1-based, or negative from the end.
fn position(ctx: Ctx, text: []const u8) ?usize {
    const total = ctx.sh.hist.count();
    const n = std.fmt.parseInt(i64, text, 10) catch {
        ctx.errFmt("wsh: history: {s}: invalid number\n", .{text});
        return null;
    };
    const resolved: i64 = if (n < 0) @as(i64, @intCast(total)) + n + 1 else n;
    if (resolved < 1 or resolved > total) {
        ctx.errFmt("wsh: history: {s}: history position out of range\n", .{text});
        return null;
    }
    return @intCast(resolved - 1);
}

/// `history -d N` or `-d START-END`. The entries are also dropped from the
/// history file: they were written there when entered, and `-d` is how a
/// mistyped secret gets removed.
fn deleteEntries(ctx: Ctx, spec: []const u8) u8 {
    var first: usize = undefined;
    var last: usize = undefined;
    const dash = if (spec.len > 1) std.mem.indexOfScalarPos(u8, spec, 1, '-') else null;
    if (dash) |at| {
        first = position(ctx, spec[0..at]) orelse return 1;
        last = position(ctx, spec[at + 1 ..]) orelse return 1;
        if (last < first) return 1;
    } else {
        first = position(ctx, spec) orelse return 1;
        last = first;
    }

    const sh = ctx.sh;
    var removed: std.ArrayList([]const u8) = .empty;
    defer {
        for (removed.items) |entry| sh.gpa.free(entry);
        removed.deinit(sh.gpa);
    }
    var i = last + 1;
    while (i > first) {
        i -= 1;
        const copy = sh.gpa.dupe(u8, sh.hist.get(i)) catch return 1;
        removed.append(sh.gpa, copy) catch {
            sh.gpa.free(copy);
            return 1;
        };
        sh.hist.remove(sh.gpa, i);
    }

    if (sh.history_path.len == 0) return 0;
    const kept = history.forgetInFile(sh.gpa, sh.history_path, removed.items) catch {
        ctx.errFmt("wsh: history: {s}: cannot rewrite\n", .{sh.history_path});
        return 1;
    };
    sh.hist.file_entries = kept;
    return 0;
}

fn fileOperation(ctx: Ctx, op: u8, file: ?[]const u8) u8 {
    const sh = ctx.sh;
    const path = file orelse sh.history_path;
    if (path.len == 0) {
        ctx.err("wsh: history: no history file\n");
        return 1;
    }
    const is_history_file = std.mem.eql(u8, path, sh.history_path);
    const entries = sh.hist.entries.items;
    switch (op) {
        'w' => {
            history.writeEntries(sh.gpa, path, @ptrCast(entries)) catch {
                ctx.errFmt("wsh: history: {s}: cannot write\n", .{path});
                return 1;
            };
            if (is_history_file) sh.hist.file_entries = entries.len;
        },
        'a' => {
            // Entries reach the history file as they are entered; only another
            // file can still be missing some.
            if (!is_history_file) {
                history.appendEntries(sh.gpa, path, @ptrCast(entries[@min(sh.hist.unsaved, entries.len)..])) catch {
                    ctx.errFmt("wsh: history: {s}: cannot write\n", .{path});
                    return 1;
                };
            }
        },
        'r' => {
            const found = sh.hist.readFrom(sh.gpa, path) catch return 1;
            return if (found) 0 else 1;
        },
        else => unreachable,
    }
    sh.hist.unsaved = sh.hist.count();
    return 0;
}
