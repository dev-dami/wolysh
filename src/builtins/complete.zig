//! `complete` and `compgen`: programmable completion, following bash.
//!
//! `complete` stores a completion specification per command name; Tab in the
//! line editor looks it up (see `interactive/complete.zig`), and `compgen`
//! prints what a specification generates for a word.

const std = @import("std");
const builtins = @import("../builtins.zig");
const completion = @import("../interactive/complete.zig");

const Ctx = builtins.Ctx;

pub const Actions = struct {
    alias: bool = false,
    builtin: bool = false,
    command: bool = false,
    directory: bool = false,
    @"export": bool = false,
    file: bool = false,
    function: bool = false,
    group: bool = false,
    hostname: bool = false,
    job: bool = false,
    keyword: bool = false,
    running: bool = false,
    signal: bool = false,
    stopped: bool = false,
    user: bool = false,
    variable: bool = false,
};

pub const Options = struct {
    bashdefault: bool = false,
    default: bool = false,
    dirnames: bool = false,
    filenames: bool = false,
    noquote: bool = false,
    nosort: bool = false,
    nospace: bool = false,
    plusdirs: bool = false,
};

pub const Spec = struct {
    actions: Actions = .{},
    options: Options = .{},
    glob: ?[]const u8 = null,
    words: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    suffix: ?[]const u8 = null,
    filter: ?[]const u8 = null,
    command: ?[]const u8 = null,
    function: ?[]const u8 = null,
};

/// Action letters in the order `complete -p` prints them.
const action_letters = [_]struct { u8, []const u8 }{
    .{ 'a', "alias" },   .{ 'b', "builtin" }, .{ 'c', "command" },  .{ 'd', "directory" },
    .{ 'e', "export" },  .{ 'f', "file" },    .{ 'g', "group" },    .{ 'j', "job" },
    .{ 'k', "keyword" }, .{ 'u', "user" },    .{ 'v', "variable" },
};

/// Actions that only have a long `-A` name.
const long_actions = [_][]const u8{ "function", "hostname", "running", "signal", "stopped" };

/// bash actions wsh does not implement.
const unsupported_actions = [_][]const u8{ "arrayvar", "binding", "disabled", "enabled", "helptopic", "service", "setopt", "shopt" };

const option_names = [_][]const u8{ "bashdefault", "default", "dirnames", "filenames", "noquote", "nosort", "nospace", "plusdirs" };

fn setAction(actions: *Actions, name: []const u8) bool {
    inline for (std.meta.fields(Actions)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            @field(actions, field.name) = true;
            return true;
        }
    }
    return false;
}

fn hasAction(actions: Actions, name: []const u8) bool {
    inline for (std.meta.fields(Actions)) |field| {
        if (std.mem.eql(u8, field.name, name)) return @field(actions, field.name);
    }
    return false;
}

fn setOption(options: *Options, name: []const u8) bool {
    inline for (std.meta.fields(Options)) |field| {
        if (std.mem.eql(u8, field.name, name)) {
            @field(options, field.name) = true;
            return true;
        }
    }
    return false;
}

fn hasOption(options: Options, name: []const u8) bool {
    inline for (std.meta.fields(Options)) |field| {
        if (std.mem.eql(u8, field.name, name)) return @field(options, field.name);
    }
    return false;
}

// --- registry -------------------------------------------------------------------

/// Specifications by command name, in definition order. Process-wide, like
/// the shell's other interactive state; strings are owned by `gpa`.
var registry: std.StringArrayHashMapUnmanaged(Spec) = .empty;
var registry_gpa: ?std.mem.Allocator = null;

pub fn lookup(name: []const u8) ?Spec {
    return registry.get(name);
}

fn ownSpec(gpa: std.mem.Allocator, spec: Spec) !Spec {
    var owned = spec;
    inline for (.{ "glob", "words", "prefix", "suffix", "filter", "command", "function" }) |name| {
        if (@field(spec, name)) |text| @field(owned, name) = try gpa.dupe(u8, text);
    }
    return owned;
}

fn freeSpec(gpa: std.mem.Allocator, spec: Spec) void {
    inline for (.{ "glob", "words", "prefix", "suffix", "filter", "command", "function" }) |name| {
        if (@field(spec, name)) |text| gpa.free(text);
    }
}

fn define(gpa: std.mem.Allocator, name: []const u8, spec: Spec) !void {
    if (registry_gpa == null) registry_gpa = gpa;
    const owner = registry_gpa.?;
    const owned = try ownSpec(owner, spec);
    errdefer freeSpec(owner, owned);
    const gop = try registry.getOrPut(owner, name);
    if (gop.found_existing) {
        freeSpec(owner, gop.value_ptr.*);
    } else {
        gop.key_ptr.* = owner.dupe(u8, name) catch |err| {
            _ = registry.orderedRemove(name);
            return err;
        };
    }
    gop.value_ptr.* = owned;
}

fn remove(name: []const u8) bool {
    const owner = registry_gpa orelse return false;
    const index = registry.getIndex(name) orelse return false;
    const key = registry.keys()[index];
    freeSpec(owner, registry.values()[index]);
    registry.orderedRemoveAt(index);
    owner.free(key);
    return true;
}

/// Drops every specification.
pub fn reset() void {
    const owner = registry_gpa orelse return;
    for (registry.keys(), registry.values()) |key, spec| {
        owner.free(key);
        freeSpec(owner, spec);
    }
    registry.deinit(owner);
    registry = .empty;
    registry_gpa = null;
}

// --- argument parsing -------------------------------------------------------------

const usage = "complete: usage: complete [-abcdefgjksuv] [-pr] [-DEI] [-o option] [-A action] [-G globpat] [-W wordlist] [-F function] [-C command] [-X filterpat] [-P prefix] [-S suffix] [name ...]\n";
const compgen_usage = "compgen: usage: compgen [-abcdefgjksuv] [-o option] [-A action] [-G globpat] [-W wordlist] [-F function] [-C command] [-X filterpat] [-P prefix] [-S suffix] [word]\n";

const Parsed = struct {
    spec: Spec = .{},
    print: bool = false,
    remove: bool = false,
    names: []const []const u8 = &.{},
};

/// Parses `complete`/`compgen` options. Prints the error and returns null
/// when the arguments are invalid.
fn parse(ctx: Ctx, builtin_name: []const u8, is_compgen: bool) ?Parsed {
    var parsed = Parsed{};
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const arg = ctx.argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or arg[0] != '-') break;

        var j: usize = 1;
        while (j < arg.len) : (j += 1) {
            const letter = arg[j];
            switch (letter) {
                'o', 'A', 'G', 'W', 'F', 'C', 'X', 'P', 'S' => {
                    var operand: []const u8 = undefined;
                    if (j + 1 < arg.len) {
                        operand = arg[j + 1 ..];
                    } else if (i + 1 < ctx.argv.len) {
                        i += 1;
                        operand = ctx.argv[i];
                    } else {
                        ctx.errFmt("wsh: {s}: -{c}: option requires an argument\n", .{ builtin_name, letter });
                        return null;
                    }
                    j = arg.len;
                    if (!applyOperand(ctx, builtin_name, &parsed.spec, letter, operand)) return null;
                },
                'p', 'r' => {
                    if (is_compgen) return invalidOption(ctx, builtin_name, letter, is_compgen);
                    if (letter == 'p') parsed.print = true else parsed.remove = true;
                },
                'D', 'E', 'I' => {
                    ctx.errFmt("wsh: {s}: -{c}: not supported\n", .{ builtin_name, letter });
                    return null;
                },
                's' => {
                    ctx.errFmt("wsh: {s}: -s: service completion is not supported\n", .{builtin_name});
                    return null;
                },
                else => {
                    for (action_letters) |entry| {
                        if (entry[0] == letter) {
                            _ = setAction(&parsed.spec.actions, entry[1]);
                            break;
                        }
                    } else return invalidOption(ctx, builtin_name, letter, is_compgen);
                },
            }
        }
    }
    parsed.names = ctx.argv[i..];
    return parsed;
}

fn invalidOption(ctx: Ctx, builtin_name: []const u8, letter: u8, is_compgen: bool) ?Parsed {
    ctx.errFmt("wsh: {s}: -{c}: invalid option\n", .{ builtin_name, letter });
    ctx.err(if (is_compgen) compgen_usage else usage);
    return null;
}

fn applyOperand(ctx: Ctx, builtin_name: []const u8, spec: *Spec, letter: u8, operand: []const u8) bool {
    switch (letter) {
        'o' => if (!setOption(&spec.options, operand)) {
            ctx.errFmt("wsh: {s}: {s}: invalid option name\n", .{ builtin_name, operand });
            return false;
        },
        'A' => {
            for (unsupported_actions) |name| {
                if (std.mem.eql(u8, name, operand)) {
                    ctx.errFmt("wsh: {s}: {s}: action not supported\n", .{ builtin_name, operand });
                    return false;
                }
            }
            if (!setAction(&spec.actions, operand)) {
                ctx.errFmt("wsh: {s}: {s}: invalid action name\n", .{ builtin_name, operand });
                return false;
            }
        },
        'G' => spec.glob = operand,
        'W' => spec.words = operand,
        'F' => spec.function = operand,
        'C' => spec.command = operand,
        'X' => spec.filter = operand,
        'P' => spec.prefix = operand,
        'S' => spec.suffix = operand,
        else => unreachable,
    }
    return true;
}

// --- builtins -----------------------------------------------------------------------

pub fn runComplete(ctx: Ctx) u8 {
    const parsed = parse(ctx, "complete", false) orelse return 2;

    if (parsed.print or ctx.argv.len == 1) return printSpecs(ctx, parsed.names);

    if (parsed.remove) {
        if (parsed.names.len == 0) {
            reset();
            return 0;
        }
        var status: u8 = 0;
        for (parsed.names) |name| {
            if (!remove(name)) {
                ctx.errFmt("wsh: complete: {s}: no completion specification\n", .{name});
                status = 1;
            }
        }
        return status;
    }

    if (parsed.names.len == 0) {
        ctx.err(usage);
        return 2;
    }
    for (parsed.names) |name| {
        define(ctx.sh.gpa, name, parsed.spec) catch {
            ctx.err("wsh: complete: out of memory\n");
            return 1;
        };
    }
    return 0;
}

pub fn runCompgen(ctx: Ctx) u8 {
    const parsed = parse(ctx, "compgen", true) orelse return 2;
    const word = if (parsed.names.len > 0) parsed.names[0] else "";

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var candidates: std.ArrayList([]const u8) = .empty;
    completion.generate(ctx.sh, arena, parsed.spec, .{ .word = word }, &candidates) catch {
        ctx.err("wsh: compgen: out of memory\n");
        return 1;
    };
    if (candidates.items.len == 0) return 1;
    for (candidates.items) |candidate| {
        ctx.out(candidate);
        ctx.out("\n");
    }
    return 0;
}

fn printSpecs(ctx: Ctx, names: []const []const u8) u8 {
    if (names.len == 0) {
        for (registry.keys(), registry.values()) |name, spec| printSpec(ctx, name, spec);
        return 0;
    }
    var status: u8 = 0;
    for (names) |name| {
        if (lookup(name)) |spec| {
            printSpec(ctx, name, spec);
        } else {
            ctx.errFmt("wsh: complete: {s}: no completion specification\n", .{name});
            status = 1;
        }
    }
    return status;
}

/// Prints `spec` as the `complete` command that recreates it.
fn printSpec(ctx: Ctx, name: []const u8, spec: Spec) void {
    var line: std.Io.Writer.Allocating = .init(ctx.sh.gpa);
    defer line.deinit();
    const w = &line.writer;
    formatSpec(w, name, spec) catch return;
    ctx.out(line.writer.buffered());
}

fn formatSpec(w: *std.Io.Writer, name: []const u8, spec: Spec) !void {
    try w.writeAll("complete ");
    for (option_names) |option| {
        if (hasOption(spec.options, option)) try w.print("-o {s} ", .{option});
    }
    for (action_letters) |entry| {
        if (hasAction(spec.actions, entry[1])) try w.print("-{c} ", .{entry[0]});
    }
    for (long_actions) |action| {
        if (hasAction(spec.actions, action)) try w.print("-A {s} ", .{action});
    }
    inline for (.{ .{ "glob", "-G" }, .{ "words", "-W" }, .{ "prefix", "-P" }, .{ "suffix", "-S" }, .{ "filter", "-X" }, .{ "command", "-C" } }) |entry| {
        if (@field(spec, entry[0])) |text| {
            try w.print("{s} ", .{entry[1]});
            try writeQuoted(w, text);
            try w.writeByte(' ');
        }
    }
    if (spec.function) |function| try w.print("-F {s} ", .{function});
    try w.print("{s}\n", .{name});
}

fn writeQuoted(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('\'');
    for (text) |c| {
        if (c == '\'') {
            try w.writeAll("'\\''");
        } else {
            try w.writeByte(c);
        }
    }
    try w.writeByte('\'');
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;
const linux = std.os.linux;
const sys = @import("../sys.zig");
const Shell = @import("../shell.zig").Shell;

const Captured = struct { status: u8, out: []u8, err: []u8 };

fn capture(sh: *Shell, run: *const fn (Ctx) u8, argv: []const []const u8) !Captured {
    var out_fds: [2]i32 = undefined;
    var err_fds: [2]i32 = undefined;
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&out_fds, .{ .CLOEXEC = true })));
    try testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.pipe2(&err_fds, .{ .CLOEXEC = true })));
    const status = run(.{ .sh = sh, .argv = argv, .stdout = out_fds[1], .stderr = err_fds[1] });
    _ = linux.close(out_fds[1]);
    _ = linux.close(err_fds[1]);
    return .{ .status = status, .out = try drain(out_fds[0]), .err = try drain(err_fds[0]) };
}

fn drain(fd: i32) ![]u8 {
    defer _ = linux.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var buf: [4096]u8 = undefined;
    while (sys.readSome(fd, &buf)) |n| {
        if (n == 0) break;
        try out.appendSlice(testing.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(testing.allocator);
}

fn freeCaptured(captured: Captured) void {
    testing.allocator.free(captured.out);
    testing.allocator.free(captured.err);
}

test "complete stores, prints and removes specifications" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    defer reset();

    var r = try capture(&sh, runComplete, &.{ "complete", "-o", "nospace", "-o", "filenames", "-df", "-A", "hostname", "-W", "x y", "-X", "!*.c", "-F", "fn", "foo" });
    try testing.expectEqual(@as(u8, 0), r.status);
    freeCaptured(r);

    r = try capture(&sh, runComplete, &.{ "complete", "-p", "foo" });
    try testing.expectEqualStrings("complete -o filenames -o nospace -d -f -A hostname -W 'x y' -X '!*.c' -F fn foo\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runComplete, &.{ "complete", "-W", "it's", "bar" });
    freeCaptured(r);
    r = try capture(&sh, runComplete, &.{"complete"});
    try testing.expectEqualStrings(
        "complete -o filenames -o nospace -d -f -A hostname -W 'x y' -X '!*.c' -F fn foo\ncomplete -W 'it'\\''s' bar\n",
        r.out,
    );
    freeCaptured(r);

    r = try capture(&sh, runComplete, &.{ "complete", "-r", "foo" });
    try testing.expectEqual(@as(u8, 0), r.status);
    freeCaptured(r);
    try testing.expect(lookup("foo") == null);
    try testing.expect(lookup("bar") != null);

    r = try capture(&sh, runComplete, &.{ "complete", "-p", "foo" });
    try testing.expectEqual(@as(u8, 1), r.status);
    try testing.expectEqualStrings("wsh: complete: foo: no completion specification\n", r.err);
    freeCaptured(r);
}

test "complete rejects what it does not support" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    defer reset();

    const cases = [_]struct { argv: []const []const u8, message: []const u8 }{
        .{ .argv = &.{ "complete", "-Z", "x" }, .message = "wsh: complete: -Z: invalid option\n" ++ usage },
        .{ .argv = &.{ "complete", "-o", "bogus", "x" }, .message = "wsh: complete: bogus: invalid option name\n" },
        .{ .argv = &.{ "complete", "-A", "bogus", "x" }, .message = "wsh: complete: bogus: invalid action name\n" },
        .{ .argv = &.{ "complete", "-A", "binding", "x" }, .message = "wsh: complete: binding: action not supported\n" },
        .{ .argv = &.{ "complete", "-D", "-F", "f" }, .message = "wsh: complete: -D: not supported\n" },
        .{ .argv = &.{ "complete", "-W" }, .message = "wsh: complete: -W: option requires an argument\n" },
        .{ .argv = &.{ "complete", "-W", "a b" }, .message = usage },
    };
    for (cases) |case| {
        const r = try capture(&sh, runComplete, case.argv);
        defer freeCaptured(r);
        try testing.expectEqual(@as(u8, 2), r.status);
        try testing.expectEqualStrings(case.message, r.err);
    }
    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "compgen generates words and actions" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    var r = try capture(&sh, runCompgen, &.{ "compgen", "-W", "alpha beta alps", "al" });
    try testing.expectEqual(@as(u8, 0), r.status);
    try testing.expectEqualStrings("alpha\nalps\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-W", "alpha", "zz" });
    try testing.expectEqual(@as(u8, 1), r.status);
    try testing.expectEqualStrings("", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-b", "ec" });
    try testing.expectEqualStrings("echo\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-X", "&b", "-W", "ab abc", "a" });
    try testing.expectEqualStrings("abc\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-P", "<", "-S", ">", "-W", "a b" });
    try testing.expectEqualStrings("<a>\n<b>\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-A", "signal", "SIGIN" });
    try testing.expectEqualStrings("SIGINT\n", r.out);
    freeCaptured(r);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-d", "--", "sr" });
    try testing.expectEqualStrings("src\n", r.out);
    freeCaptured(r);

    // Like bash, compgen keeps directory order.
    r = try capture(&sh, runCompgen, &.{ "compgen", "-f", "--", "build.z" });
    const listed = r.out.len == "build.zig\nbuild.zig.zon\n".len and
        std.mem.indexOf(u8, r.out, "build.zig\n") != null and
        std.mem.indexOf(u8, r.out, "build.zig.zon\n") != null;
    freeCaptured(r);
    try testing.expect(listed);

    r = try capture(&sh, runCompgen, &.{ "compgen", "-p" });
    try testing.expectEqual(@as(u8, 2), r.status);
    freeCaptured(r);
}
