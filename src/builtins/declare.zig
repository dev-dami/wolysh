//! `declare`/`typeset` and `local`: attributes, arrays, and `declare -p`
//! listings in bash's format.
//!
//!     declare [-aAilurxgpfF] [+ilux] [name[=value] | name=(...) ...]
//!
//! Inside a function `declare` creates locals unless `-g` is given, as in
//! bash; `local` is only valid there.

const std = @import("std");
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const value = @import("../value.zig");
const arrays = @import("../arrays.zig");
const compound = @import("../compound.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;
const Value = value.Value;

const Options = struct {
    indexed: bool = false,
    assoc: bool = false,
    print: bool = false,
    functions: bool = false,
    function_names: bool = false,
    global: bool = false,
    readonly: bool = false,
    /// `-x` sets and `+x` clears; null leaves the attribute alone.
    exported: ?bool = null,
    integer: ?bool = null,
    lower: ?bool = null,
    upper: ?bool = null,

    fn filters(self: Options) bool {
        return self.indexed or self.assoc or self.readonly or self.exported == true or
            self.integer == true or self.lower == true or self.upper == true;
    }
};

pub fn declare(ctx: Ctx) u8 {
    return run(ctx, false);
}

pub fn local(ctx: Ctx) u8 {
    return run(ctx, true);
}

fn run(ctx: Ctx, is_local: bool) u8 {
    const sh = ctx.sh;
    const cmd = ctx.argv[0];
    if (is_local and sh.scopes.items.len == 0) {
        ctx.errFmt("wsh: {s}: can only be used in a function\n", .{cmd});
        return 1;
    }
    var opts = Options{};
    var i: usize = 1;
    while (i < ctx.argv.len) : (i += 1) {
        const arg = ctx.argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (arg.len < 2 or (arg[0] != '-' and arg[0] != '+')) break;
        const on = arg[0] == '-';
        for (arg[1..]) |letter| {
            switch (letter) {
                'a' => opts.indexed = true,
                'A' => opts.assoc = true,
                'i' => opts.integer = on,
                'l' => {
                    opts.lower = on;
                    if (on) opts.upper = false;
                },
                'u' => {
                    opts.upper = on;
                    if (on) opts.lower = false;
                },
                'x' => opts.exported = on,
                'r' => opts.readonly = true,
                'g' => opts.global = true,
                'p' => opts.print = true,
                'f' => opts.functions = true,
                'F' => opts.function_names = true,
                else => {
                    ctx.errFmt("wsh: {s}: {c}{c}: unsupported option\n", .{ cmd, arg[0], letter });
                    return 2;
                },
            }
            const removable = letter == 'a' or letter == 'A' or letter == 'r';
            if (!on and removable) {
                ctx.errFmt("wsh: {s}: +{c}: an array type or readonly cannot be removed\n", .{ cmd, letter });
                return 1;
            }
        }
    }
    if (opts.indexed and opts.assoc) {
        ctx.errFmt("wsh: {s}: -a and -A cannot be combined\n", .{cmd});
        return 1;
    }
    const names = ctx.argv[i..];
    if (opts.functions or opts.function_names) return printFunctions(ctx, names, opts.function_names);
    if (is_local and names.len == 0) return printLocals(ctx);
    if (opts.print or names.len == 0) return printVariables(ctx, names, opts);

    var status: u8 = 0;
    for (names) |arg| {
        declareOne(ctx, arg, opts, is_local) catch |err| {
            status = failed(ctx, arg, err);
        };
    }
    return status;
}

const Spec = struct {
    name: []const u8,
    subscript: ?[]const u8 = null,
    append: bool = false,
    /// The assigned text, or for a list the text between the parentheses.
    assigned: ?[]const u8 = null,
    list: bool = false,
};

/// Splits `name`, `name=value`, `name+=value`, `name[sub]=value` and the
/// marked `name=(...)` that `expandCommand` passes through.
fn parseSpec(arg: []const u8) Spec {
    var text = arg;
    const list = text.len > 0 and text[0] == compound.marker;
    if (list) text = text[1..];
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse return .{ .name = text };
    var lhs = text[0..eq];
    var spec = Spec{ .name = lhs, .assigned = text[eq + 1 ..], .list = list };
    if (lhs.len > 0 and lhs[lhs.len - 1] == '+') {
        spec.append = true;
        lhs = lhs[0 .. lhs.len - 1];
        spec.name = lhs;
    }
    if (lhs.len > 0 and lhs[lhs.len - 1] == ']') {
        if (std.mem.indexOfScalar(u8, lhs, '[')) |open| {
            spec.name = lhs[0..open];
            spec.subscript = lhs[open + 1 .. lhs.len - 1];
        }
    }
    if (list) spec.assigned = spec.assigned.?[1 .. spec.assigned.?.len - 1];
    return spec;
}

fn declareOne(ctx: Ctx, arg: []const u8, opts: Options, is_local: bool) !void {
    const sh = ctx.sh;
    const arena = sh.scratch();
    const spec = parseSpec(arg);
    if (!builtins.validName(spec.name) or (spec.list and spec.subscript != null)) {
        ctx.errFmt("wsh: {s}: `{s}': not a valid identifier\n", .{ ctx.argv[0], arg[@intFromBool(spec.list)..] });
        return error.Reported;
    }
    const name = spec.name;
    const changes_type = opts.indexed or opts.assoc;
    if (sh.isReadonly(name) and (spec.assigned != null or changes_type)) return error.ReadonlyVariable;

    if ((is_local or sh.scopes.items.len > 0) and !opts.global and !isLocalHere(sh, name)) {
        const initial: Value = if (opts.assoc) .{ .map = &.{} } else if (opts.indexed) .{ .list = &.{} } else .none;
        try sh.setLocal(name, initial);
    }

    // Type conversions, which bash allows only towards an indexed array.
    const existing = sh.vars.get(name);
    if (opts.assoc) {
        if (existing) |v| {
            if (v == .list) {
                ctx.errFmt("wsh: {s}: {s}: cannot convert indexed to associative array\n", .{ ctx.argv[0], name });
                return error.Reported;
            }
        }
        if (existing == null or existing.? != .map) {
            var entries: []const value.Entry = &.{};
            if (current(sh, name)) |v| entries = try arena.dupe(value.Entry, &.{.{ .key = "0", .value = v }});
            try sh.setVar(name, .{ .map = entries });
        }
    } else if (opts.indexed) {
        if (existing) |v| {
            if (v == .map) {
                ctx.errFmt("wsh: {s}: {s}: cannot convert associative to indexed array\n", .{ ctx.argv[0], name });
                return error.Reported;
            }
        }
        if (existing == null or existing.? != .list) {
            var items: []const Value = &.{};
            if (current(sh, name)) |v| items = try arena.dupe(Value, &.{v});
            try sh.setVar(name, .{ .list = items });
        }
    }

    var attrs = sh.getAttrs(name);
    if (opts.integer) |on| attrs.integer = on;
    if (opts.lower) |on| attrs.lower = on;
    if (opts.upper) |on| attrs.upper = on;
    if (opts.lower == true) attrs.upper = false;
    if (opts.upper == true) attrs.lower = false;
    try sh.setAttrs(name, attrs);

    if (spec.assigned) |text| {
        const stored = sh.vars.get(name);
        const is_array = if (stored) |v| v == .list or v == .map else false;
        if (spec.list) {
            const kind: arrays.Kind = if (opts.assoc) .assoc else if (opts.indexed) .indexed else .auto;
            try arrays.assignCompound(sh, arena, name, text, spec.append, kind);
        } else if (spec.subscript) |subscript| {
            try arrays.assignElement(sh, arena, name, subscript, text, spec.append);
        } else if (is_array) {
            try arrays.assignElement(sh, arena, name, "0", text, spec.append);
        } else {
            const old: ?Value = if (spec.append) current(sh, name) else null;
            try sh.setVar(name, try arrays.combine(sh, arena, attrs, old, text, spec.append));
        }
    } else if (sh.vars.get(name) == null and sh.getEnv(name) == null) {
        // Declared but unset, which `declare -p` still reports.
        try sh.setVar(name, .none);
    }

    if (opts.exported) |on| {
        if (!on) {
            _ = sh.unsetEnv(name);
        } else if (current(sh, name)) |v| {
            if (v != .none) try sh.setEnv(name, try v.renderAlloc(arena));
        }
    }
    if (opts.readonly) try sh.markReadonly(name);
}

fn current(sh: *Shell, name: []const u8) ?Value {
    if (sh.vars.get(name)) |v| return if (v == .none) null else v;
    if (sh.getEnv(name)) |text| return Value{ .string = text };
    return null;
}

/// `local` alone lists the innermost function's locals.
fn printLocals(ctx: Ctx) u8 {
    const sh = ctx.sh;
    const scope = sh.scopes.items[sh.scopes.items.len - 1];
    for (scope.saved.items) |saved| {
        const line = (arrays.describe(sh, sh.scratch(), saved.name) catch return 1) orelse continue;
        ctx.out(line);
        ctx.out("\n");
    }
    return 0;
}

/// True when `name` is already local to the innermost function scope.
fn isLocalHere(sh: *Shell, name: []const u8) bool {
    if (sh.scopes.items.len == 0) return false;
    const scope = sh.scopes.items[sh.scopes.items.len - 1];
    for (scope.saved.items) |saved| {
        if (std.mem.eql(u8, saved.name, name)) return true;
    }
    return false;
}

fn failed(ctx: Ctx, arg: []const u8, err: anyerror) u8 {
    const cmd = ctx.argv[0];
    const shown = if (arg.len > 0 and arg[0] == compound.marker) arg[1..] else arg;
    switch (err) {
        error.Reported => {},
        error.BadSubstitution, error.UnboundVariable => {
            // Already reported; a failed expansion ends a script, as in bash.
            if (!ctx.sh.interactive) {
                ctx.sh.should_exit = true;
                ctx.sh.exit_code = 1;
            }
        },
        error.ReadonlyVariable => ctx.errFmt("wsh: {s}: {s}: readonly variable\n", .{ cmd, parseSpec(arg).name }),
        error.InvalidArithmetic => ctx.errFmt("wsh: {s}: {s}: arithmetic syntax error\n", .{ cmd, shown }),
        error.DivisionByZero => ctx.errFmt("wsh: {s}: {s}: division by zero\n", .{ cmd, shown }),
        else => ctx.errFmt("wsh: {s}: {s}: {s}\n", .{ cmd, shown, @errorName(err) }),
    }
    return 1;
}

fn printVariables(ctx: Ctx, names: []const []const u8, opts: Options) u8 {
    const sh = ctx.sh;
    const arena = sh.scratch();
    if (names.len != 0) {
        var status: u8 = 0;
        for (names) |name| {
            const line = (arrays.describe(sh, arena, name) catch return 1) orelse {
                ctx.errFmt("wsh: {s}: {s}: not found\n", .{ ctx.argv[0], name });
                status = 1;
                continue;
            };
            ctx.out(line);
            ctx.out("\n");
        }
        return status;
    }

    var all: std.ArrayList([]const u8) = .empty;
    var vars = sh.vars.iterator();
    while (vars.next()) |entry| all.append(arena, entry.key_ptr.*) catch return 1;
    var env = sh.env.iterator();
    while (env.next()) |entry| {
        if (!sh.vars.contains(entry.key_ptr.*)) all.append(arena, entry.key_ptr.*) catch return 1;
    }
    std.mem.sort([]const u8, all.items, {}, lessThan);
    for (all.items) |name| {
        if (opts.filters() and !matches(sh, name, opts)) continue;
        const line = (arrays.describe(sh, arena, name) catch return 1) orelse continue;
        ctx.out(line);
        ctx.out("\n");
    }
    return 0;
}

/// Whether `name` has every attribute the listing asked for.
fn matches(sh: *Shell, name: []const u8, opts: Options) bool {
    const v = sh.vars.get(name);
    const attrs = sh.getAttrs(name);
    if (opts.indexed and (v == null or v.? != .list)) return false;
    if (opts.assoc and (v == null or v.? != .map)) return false;
    if (opts.integer == true and !attrs.integer) return false;
    if (opts.lower == true and !attrs.lower) return false;
    if (opts.upper == true and !attrs.upper) return false;
    if (opts.readonly and !sh.isReadonly(name)) return false;
    if (opts.exported == true and sh.getEnv(name) == null) return false;
    return true;
}

fn printFunctions(ctx: Ctx, names: []const []const u8, names_only: bool) u8 {
    const sh = ctx.sh;
    if (names.len == 0) {
        var all: std.ArrayList([]const u8) = .empty;
        var it = sh.funcs.iterator();
        while (it.next()) |entry| all.append(sh.scratch(), entry.key_ptr.*) catch return 1;
        std.mem.sort([]const u8, all.items, {}, lessThan);
        for (all.items) |name| printFunction(ctx, name, names_only);
        return 0;
    }
    var status: u8 = 0;
    for (names) |name| {
        if (sh.getFunc(name) == null) {
            status = 1;
            continue;
        }
        if (names_only) ctx.outFmt("{s}\n", .{name}) else printFunction(ctx, name, false);
    }
    return status;
}

fn printFunction(ctx: Ctx, name: []const u8, names_only: bool) void {
    if (names_only) {
        ctx.outFmt("declare -f {s}\n", .{name});
        return;
    }
    const source = ctx.sh.getFunc(name) orelse return;
    ctx.out(source);
    if (source.len == 0 or source[source.len - 1] != '\n') ctx.out("\n");
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

const testing = std.testing;

fn capture(sh: *Shell, argv: []const []const u8, is_local: bool) ![]u8 {
    var fds: [2]i32 = undefined;
    const linux = std.os.linux;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    _ = run(.{ .sh = sh, .argv = argv, .stdout = fds[1], .stderr = -1 }, is_local);
    _ = linux.close(fds[1]);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    var buf: [1024]u8 = undefined;
    while (true) {
        const n = linux.read(fds[0], &buf, buf.len);
        if (linux.errno(n) != .SUCCESS or n == 0) break;
        try out.appendSlice(testing.allocator, buf[0..n]);
    }
    _ = linux.close(fds[0]);
    return out.toOwnedSlice(testing.allocator);
}

test "declare builds arrays and prints them in bash's format" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    const marked = "\x00a=(1 \"x y\" '$z')";
    _ = run(.{ .sh = &sh, .argv = &.{ "declare", "-a", marked }, .stderr = -1 }, false);
    const out = try capture(&sh, &.{ "declare", "-p", "a" }, false);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("declare -a a=([0]=\"1\" [1]=\"x y\" [2]=\"\\$z\")\n", out);

    _ = run(.{ .sh = &sh, .argv = &.{ "declare", "-A", "m" }, .stderr = -1 }, false);
    _ = run(.{ .sh = &sh, .argv = &.{ "declare", "m[k]=v" }, .stderr = -1 }, false);
    const map = try capture(&sh, &.{ "typeset", "-p", "m" }, false);
    defer testing.allocator.free(map);
    try testing.expectEqualStrings("declare -A m=([k]=\"v\" )\n", map);

    _ = run(.{ .sh = &sh, .argv = &.{ "declare", "-i", "n=2*3" }, .stderr = -1 }, false);
    try testing.expectEqual(@as(i64, 6), sh.getVar("n").?.int);

    try testing.expectEqual(@as(u8, 1), run(.{ .sh = &sh, .argv = &.{ "local", "x=1" }, .stderr = -1 }, true));
    try testing.expectEqual(@as(u8, 1), run(.{ .sh = &sh, .argv = &.{ "declare", "-p", "nope" }, .stderr = -1 }, false));
}

test "declare inside a function is local" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try sh.setVar("x", .{ .string = "outer" });
    try sh.setAttrs("n", .{ .integer = true });
    try sh.setVar("n", .{ .string = "1+1" });
    try sh.beginScope();
    _ = run(.{ .sh = &sh, .argv = &.{ "declare", "x=inner" }, .stderr = -1 }, false);
    _ = run(.{ .sh = &sh, .argv = &.{ "local", "-a", "fresh" }, .stderr = -1 }, true);
    _ = run(.{ .sh = &sh, .argv = &.{ "local", "n=2*3" }, .stderr = -1 }, true);
    try testing.expectEqualStrings("inner", sh.getVar("x").?.string);
    try testing.expect(sh.getVar("fresh").? == .list);
    try testing.expectEqualStrings("2*3", sh.getVar("n").?.string);
    sh.endScope();
    try testing.expectEqualStrings("outer", sh.getVar("x").?.string);
    try testing.expect(sh.getVar("fresh") == null);
    try testing.expectEqual(@as(i64, 2), sh.getVar("n").?.int);
    try testing.expect(sh.getAttrs("n").integer);
}
