//! Bash arrays and variable attributes.
//!
//! Indexed arrays are `Value.list`s whose unset elements are `none`;
//! associative arrays are `Value.map`s. This module performs `name=(...)`,
//! `name+=(...)`, `name[i]=v` and `name+=v` assignments, `unset 'name[i]'`,
//! and the `declare -i/-l/-u` transforms that every assignment goes through.

const std = @import("std");
const ast = @import("ast.zig");
const shellmod = @import("shell.zig");
const value = @import("value.zig");
const expand = @import("expand.zig");
const arith = @import("arith.zig");
const compound = @import("compound.zig");
const param_ops = @import("param_ops.zig");
const special_vars = @import("special_vars.zig");

const Shell = shellmod.Shell;
const Value = value.Value;

pub const Error = expand.Error || error{ReadonlyVariable};

/// Indexed arrays are dense, so an index this large is refused rather than
/// allocating millions of empty slots; `declare -A` suits sparse keys.
pub const max_index = 1 << 20;

pub const Kind = enum { auto, indexed, assoc };

/// The array and append forms of a standalone assignment. Returns false for a
/// plain `name=value` on a variable that is not an array; the caller stores
/// that one as before.
pub fn persist(sh: *Shell, arena: std.mem.Allocator, a: ast.PrefixAssign) Error!bool {
    if (a.compound) {
        try assignCompound(sh, arena, a.name, a.value, a.append, .auto);
        return true;
    }
    if (a.index) |subscript| {
        const text = try expand.expandLiteral(sh, arena, a.value);
        try assignElement(sh, arena, a.name, subscript, text, a.append);
        return true;
    }
    const existing = sh.vars.get(a.name);
    const is_array = if (existing) |v| v == .list or v == .map else false;
    if (!is_array and !a.append) return false;
    const text = try expand.expandLiteral(sh, arena, a.value);
    // As in bash, a plain assignment to an array sets element 0.
    if (is_array) {
        try assignElement(sh, arena, a.name, "0", text, a.append);
        return true;
    }
    if (sh.isReadonly(a.name)) return error.ReadonlyVariable;
    const exported = sh.getEnv(a.name) != null;
    const combined = try combine(sh, arena, sh.getAttrs(a.name), current(sh, a.name), text, true);
    try sh.setVar(a.name, combined);
    if (exported) try sh.setEnv(a.name, try render(arena, sh.getVar(a.name) orelse combined));
    return true;
}

/// The variable's value, falling back to the environment.
fn current(sh: *Shell, name: []const u8) ?Value {
    if (sh.vars.get(name)) |v| return v;
    if (sh.getEnv(name)) |text| return Value{ .string = text };
    return null;
}

fn render(arena: std.mem.Allocator, v: Value) std.mem.Allocator.Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        else => v.renderAlloc(arena) catch return error.OutOfMemory,
    };
}

/// `name=(...)` and `name+=(...)`. `body` is the text between the
/// parentheses. `kind` forces an indexed or associative result; `auto` keeps an
/// existing associative array associative.
pub fn assignCompound(
    sh: *Shell,
    arena: std.mem.Allocator,
    name: []const u8,
    body: []const u8,
    append: bool,
    kind: Kind,
) Error!void {
    if (sh.isReadonly(name)) return error.ReadonlyVariable;
    const words = try compound.splitElements(arena, body);
    const existing = sh.vars.get(name);
    const as_map = switch (kind) {
        .assoc => true,
        .indexed => false,
        .auto => if (existing) |v| v == .map else false,
    };
    const attrs = sh.getAttrs(name);

    if (as_map) {
        var entries: std.ArrayList(value.Entry) = .empty;
        if (append) {
            if (existing) |v| if (v == .map) try entries.appendSlice(arena, v.map);
        }
        var i: usize = 0;
        while (i < words.len) : (i += 1) {
            var key: []const u8 = undefined;
            var text: []const u8 = "";
            var add = false;
            if (compound.keyed(words[i])) |k| {
                key = try expand.expandLiteral(sh, arena, k.key);
                text = try expand.expandLiteral(sh, arena, k.value);
                add = k.append;
            } else {
                // bash 5.1: bare words alternate between keys and values.
                key = try expand.expandLiteral(sh, arena, words[i]);
                if (i + 1 < words.len) {
                    i += 1;
                    text = try expand.expandLiteral(sh, arena, words[i]);
                }
            }
            const slot = findEntry(entries.items, key);
            const old: ?Value = if (slot) |s| entries.items[s].value else null;
            const item = try combine(sh, arena, attrs, old, text, add);
            if (slot) |s| {
                entries.items[s].value = item;
            } else {
                try entries.append(arena, .{ .key = key, .value = item });
            }
        }
        try sh.setVar(name, .{ .map = entries.items });
        return;
    }

    var items: std.ArrayList(Value) = .empty;
    if (append) {
        if (existing) |v| switch (v) {
            .list => |list| try items.appendSlice(arena, list),
            .map => return badSubscript(sh, name, "+=(...)"),
            .none => {},
            else => try items.append(arena, v),
        } else if (sh.getEnv(name)) |text| try items.append(arena, .{ .string = text });
    }
    var next: usize = items.items.len;
    for (words) |word| {
        if (compound.keyed(word)) |k| {
            const index = try resolveIndex(sh, arena, name, k.key, items.items.len);
            const text = try expand.expandLiteral(sh, arena, k.value);
            const old: ?Value = if (index < items.items.len) items.items[index] else null;
            try putItem(arena, &items, index, try combine(sh, arena, attrs, old, text, k.append));
            next = index + 1;
            continue;
        }
        var fields: std.ArrayList([]const u8) = .empty;
        try expand.expandWord(sh, arena, word, &fields);
        for (fields.items) |field| {
            if (next >= max_index) return tooLarge(sh, name, next);
            try putItem(arena, &items, next, try combine(sh, arena, attrs, null, field, false));
            next += 1;
        }
    }
    try sh.setVar(name, .{ .list = items.items });
}

fn putItem(arena: std.mem.Allocator, items: *std.ArrayList(Value), index: usize, item: Value) !void {
    while (items.items.len <= index) try items.append(arena, .none);
    items.items[index] = item;
}

fn findEntry(entries: []const value.Entry, key: []const u8) ?usize {
    for (entries, 0..) |entry, i| {
        if (std.mem.eql(u8, entry.key, key)) return i;
    }
    return null;
}

/// `name[subscript]=text` and `name[subscript]+=text`, updating the stored
/// array in place. A scalar becomes element 0 of a new indexed array.
pub fn assignElement(
    sh: *Shell,
    arena: std.mem.Allocator,
    name: []const u8,
    subscript: []const u8,
    text: []const u8,
    append: bool,
) Error!void {
    if (sh.isReadonly(name)) return error.ReadonlyVariable;
    const existing = sh.vars.get(name);
    if (existing == null or (existing.? != .list and existing.? != .map)) {
        var initial: []const Value = &.{};
        if (current(sh, name)) |v| {
            if (v != .none) initial = try arena.dupe(Value, &.{v});
        }
        try sh.setVar(name, .{ .list = initial });
        // `RANDOM` and `SECONDS` take the assignment instead of storing it.
        if (sh.vars.get(name) == null) return sh.setVar(name, .{ .string = text });
    }
    const attrs = sh.getAttrs(name);
    // The subscript and an `-i` value are expanded and evaluated first: that
    // can assign other variables and move the stored array, so the slot is
    // looked up again just before the store.
    if (sh.vars.get(name).? == .map) {
        const key = try expand.expandLiteral(sh, arena, subscript);
        const entries = sh.vars.get(name).?.map;
        const old: ?Value = if (findEntry(entries, key)) |i| entries[i].value else null;
        const item = try combine(sh, arena, attrs, old, text, append);
        return storeEntry(sh.gpa, sh.vars.getPtr(name).?, key, item);
    }
    const index = try resolveIndex(sh, arena, name, subscript, sh.vars.get(name).?.list.len);
    const items = sh.vars.get(name).?.list;
    const old: ?Value = if (index < items.len) items[index] else null;
    const item = try combine(sh, arena, attrs, old, text, append);
    try storeItem(sh.gpa, sh.vars.getPtr(name).?, index, item);
}

/// Evaluates an indexed-array subscript. A negative index counts back from
/// the end; one that is still negative is an error.
fn resolveIndex(sh: *Shell, arena: std.mem.Allocator, name: []const u8, subscript: []const u8, len: usize) Error!usize {
    const text = try expand.expandLiteral(sh, arena, subscript);
    if (std.mem.trim(u8, text, " \t\n").len == 0) return badSubscript(sh, name, subscript);
    const n = try arith.evaluate(sh, arena, text);
    const index: i64 = if (n < 0) n + @as(i64, @intCast(len)) else n;
    if (index < 0) return badSubscript(sh, name, subscript);
    if (index >= max_index) return tooLarge(sh, name, @intCast(index));
    return @intCast(index);
}

fn badSubscript(sh: *Shell, name: []const u8, subscript: []const u8) Error {
    expand.report(sh, "wsh: {s}[{s}]: bad array subscript\n", .{ name, subscript });
    return error.BadSubstitution;
}

fn tooLarge(sh: *Shell, name: []const u8, index: usize) Error {
    expand.report(sh, "wsh: {s}[{d}]: index too large for an indexed array (use declare -A)\n", .{ name, index });
    return error.BadSubstitution;
}

/// The value an assignment stores, after `+=` and the variable's attributes.
pub fn combine(sh: *Shell, arena: std.mem.Allocator, attrs: Shell.Attrs, old: ?Value, text: []const u8, append: bool) Error!Value {
    if (attrs.integer) {
        var n = try arith.evaluate(sh, arena, text);
        if (append) {
            if (old) |v| n +%= try integerOf(sh, arena, v);
        }
        return .{ .int = n };
    }
    var result = text;
    if (append) {
        if (old) |v| result = try std.fmt.allocPrint(arena, "{s}{s}", .{ try render(arena, v), text });
    }
    if (attrs.upper) return .{ .string = try param_ops.caseAll(arena, result, true) };
    if (attrs.lower) return .{ .string = try param_ops.caseAll(arena, result, false) };
    return .{ .string = result };
}

fn integerOf(sh: *Shell, arena: std.mem.Allocator, v: Value) Error!i64 {
    return switch (v) {
        .int => |n| n,
        .none => 0,
        else => arith.evaluate(sh, arena, try render(arena, v)),
    };
}

/// Applies `declare -i/-l/-u` to a value about to be stored under `name`.
pub fn applyAttrs(sh: *Shell, name: []const u8, val: Value) Error!Value {
    const attrs = sh.getAttrs(name);
    if (!attrs.any()) return val;
    const arena = sh.scratch();
    switch (val) {
        .list => |items| {
            const out = try arena.alloc(Value, items.len);
            for (items, 0..) |item, i| out[i] = try convert(sh, arena, attrs, item);
            return .{ .list = out };
        },
        .map => |entries| {
            const out = try arena.alloc(value.Entry, entries.len);
            for (entries, 0..) |entry, i| out[i] = .{ .key = entry.key, .value = try convert(sh, arena, attrs, entry.value) };
            return .{ .map = out };
        },
        else => return convert(sh, arena, attrs, val),
    }
}

fn convert(sh: *Shell, arena: std.mem.Allocator, attrs: Shell.Attrs, v: Value) Error!Value {
    switch (v) {
        .none, .list, .map => return v,
        .int => if (attrs.integer) return v,
        else => {},
    }
    return combine(sh, arena, attrs, null, try render(arena, v), false);
}

/// Replaces or adds item `index` of the stored list `slot`, owned by `gpa`.
fn storeItem(gpa: std.mem.Allocator, slot: *Value, index: usize, item: Value) !void {
    const owned = try shellmod.cloneValue(gpa, item);
    errdefer shellmod.freeValue(gpa, owned);
    var items = slot.list;
    if (index >= items.len) {
        const grown = try gpa.alloc(Value, index + 1);
        @memcpy(grown[0..items.len], items);
        for (grown[items.len..]) |*fresh| fresh.* = .none;
        if (items.len != 0) gpa.free(items);
        slot.* = .{ .list = grown };
        items = grown;
    }
    const target = &@constCast(items)[index];
    shellmod.freeValue(gpa, target.*);
    target.* = owned;
}

/// Replaces or adds `key` in the stored map `slot`, owned by `gpa`.
fn storeEntry(gpa: std.mem.Allocator, slot: *Value, key: []const u8, item: Value) !void {
    const entries = slot.map;
    if (findEntry(entries, key)) |i| {
        const owned = try shellmod.cloneValue(gpa, item);
        const target = &@constCast(entries)[i];
        shellmod.freeValue(gpa, target.value);
        target.value = owned;
        return;
    }
    const entry = try shellmod.cloneEntry(gpa, .{ .key = key, .value = item });
    errdefer shellmod.freeEntry(gpa, entry);
    const grown = try gpa.alloc(value.Entry, entries.len + 1);
    @memcpy(grown[0..entries.len], entries);
    grown[entries.len] = entry;
    if (entries.len != 0) gpa.free(entries);
    slot.* = .{ .map = grown };
}

/// The attribute letters of `declare -p` and `${name@a}`, in bash's order.
pub fn flagLetters(sh: *Shell, name: []const u8, buf: *[8]u8) []const u8 {
    var n: usize = 0;
    if (sh.vars.get(name)) |v| {
        if (v == .list or v == .map) {
            buf[n] = if (v == .list) 'a' else 'A';
            n += 1;
        }
    }
    const attrs = sh.getAttrs(name);
    const letters = [_]struct { on: bool, letter: u8 }{
        .{ .on = attrs.integer, .letter = 'i' },
        .{ .on = sh.isReadonly(name), .letter = 'r' },
        .{ .on = sh.getEnv(name) != null, .letter = 'x' },
        .{ .on = attrs.lower, .letter = 'l' },
        .{ .on = attrs.upper, .letter = 'u' },
    };
    for (letters) |l| {
        if (!l.on) continue;
        buf[n] = l.letter;
        n += 1;
    }
    return buf[0..n];
}

/// `declare -p name` output, without the newline, or null when the name is
/// neither set nor declared.
pub fn describe(sh: *Shell, arena: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error!?[]const u8 {
    var buf: [8]u8 = undefined;
    const flags = flagLetters(sh, name, &buf);
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "declare -{s} {s}", .{ if (flags.len == 0) "-" else flags, name });
    const v = current(sh, name) orelse special_vars.get(sh, name) orelse {
        // Attributes alone, as after `declare -i n`.
        return if (flags.len == 0) null else out.items;
    };
    switch (v) {
        .none => {},
        .list => |items| {
            try out.appendSlice(arena, "=(");
            var first = true;
            for (items, 0..) |item, i| {
                if (item == .none) continue;
                if (!first) try out.append(arena, ' ');
                first = false;
                try out.print(arena, "[{d}]={s}", .{ i, try param_ops.quoteDouble(arena, try render(arena, item)) });
            }
            try out.append(arena, ')');
        },
        .map => |entries| {
            try out.appendSlice(arena, "=(");
            for (entries) |entry| {
                try out.print(arena, "[{s}]={s} ", .{
                    try param_ops.quoteKey(arena, entry.key),
                    try param_ops.quoteDouble(arena, try render(arena, entry.value)),
                });
            }
            try out.append(arena, ')');
        },
        else => try out.print(arena, "={s}", .{try param_ops.quoteDouble(arena, try render(arena, v))}),
    }
    return out.items;
}

/// `unset 'name[subscript]'`. Returns null when `spec` has no subscript, so
/// the caller unsets a whole variable instead; otherwise the status.
pub fn unsetElement(sh: *Shell, spec: []const u8) ?u8 {
    const open = std.mem.indexOfScalar(u8, spec, '[') orelse return null;
    if (open == 0 or spec[spec.len - 1] != ']') return null;
    const name = spec[0..open];
    const subscript = spec[open + 1 .. spec.len - 1];
    for (name, 0..) |c, i| {
        const ok = c == '_' or std.ascii.isAlphabetic(c) or (i > 0 and std.ascii.isDigit(c));
        if (!ok) return null;
    }
    if (sh.isReadonly(name)) {
        expand.report(sh, "wsh: unset: {s}: readonly variable\n", .{name});
        return 1;
    }
    const stored = sh.vars.get(name) orelse return 0;
    const whole = std.mem.eql(u8, subscript, "@") or std.mem.eql(u8, subscript, "*");
    if (stored == .map) {
        if (whole) {
            sh.setVar(name, .{ .map = &.{} }) catch return 1;
            return 0;
        }
        // As in bash, the key is expanded here, so `unset 'm[$k]'` works.
        const key = expand.expandLiteral(sh, sh.scratch(), subscript) catch return 1;
        const entries = (sh.vars.get(name) orelse return 0).map;
        const index = findEntry(entries, key) orelse return 0;
        const shrunk = sh.gpa.alloc(value.Entry, entries.len - 1) catch return 1;
        @memcpy(shrunk[0..index], entries[0..index]);
        @memcpy(shrunk[index..], entries[index + 1 ..]);
        shellmod.freeEntry(sh.gpa, entries[index]);
        sh.gpa.free(entries);
        sh.vars.getPtr(name).?.* = .{ .map = shrunk };
        return 0;
    }
    if (whole) {
        if (stored == .list) {
            sh.setVar(name, .{ .list = &.{} }) catch return 1;
        } else {
            _ = sh.unsetVar(name);
        }
        return 0;
    }
    const n = arith.evaluate(sh, sh.scratch(), subscript) catch {
        expand.report(sh, "wsh: unset: {s}: bad array subscript\n", .{spec});
        return 1;
    };
    // Looked up after the arithmetic, which may have moved the storage.
    const slot = sh.vars.getPtr(name) orelse return 0;
    if (slot.* != .list) {
        // A scalar is element 0 of itself.
        if (n == 0) _ = sh.unsetVar(name);
        return 0;
    }
    const items = slot.list;
    const index: i64 = if (n < 0) n + @as(i64, @intCast(items.len)) else n;
    if (index < 0) {
        expand.report(sh, "wsh: unset: {s}: bad array subscript\n", .{spec});
        return 1;
    }
    if (index >= items.len) return 0;
    const target = &@constCast(items)[@intCast(index)];
    shellmod.freeValue(sh.gpa, target.*);
    target.* = .none;
    var len = items.len;
    while (len > 0 and items[len - 1] == .none) len -= 1;
    if (len != items.len) {
        const shrunk = sh.gpa.alloc(Value, len) catch return 1;
        @memcpy(shrunk, items[0..len]);
        sh.gpa.free(items);
        slot.* = .{ .list = shrunk };
    }
    return 0;
}

const testing = std.testing;

test "element assignment grows a sparse list and unset trims it" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    sh.default_err = -1;

    try assignCompound(&sh, arena, "a", "x \"y z\"", false, .auto);
    try assignElement(&sh, arena, "a", "3", "w", false);
    try assignElement(&sh, arena, "a", "1", "!", true);
    const list = sh.getVar("a").?.list;
    try testing.expectEqual(@as(usize, 4), list.len);
    try testing.expectEqualStrings("y z!", list[1].string);
    try testing.expect(list[2] == .none);

    try testing.expectEqual(@as(?u8, 0), unsetElement(&sh, "a[3]"));
    try testing.expectEqual(@as(usize, 2), sh.getVar("a").?.list.len);
    try testing.expectEqual(@as(?u8, null), unsetElement(&sh, "a"));
    try testing.expectError(error.BadSubstitution, assignElement(&sh, arena, "a", "-9", "v", false));
}

test "associative arrays keep insertion order and integer attributes apply" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();
    sh.scratch_override = arena;
    defer sh.scratch_override = null;

    try assignCompound(&sh, arena, "m", "[b]=2 [a]=1", false, .assoc);
    try assignElement(&sh, arena, "m", "b", "3", true);
    try assignElement(&sh, arena, "m", "c d", "4", false);
    const map = sh.getVar("m").?.map;
    try testing.expectEqual(@as(usize, 3), map.len);
    try testing.expectEqualStrings("b", map[0].key);
    try testing.expectEqualStrings("23", map[0].value.string);
    try testing.expectEqualStrings("c d", map[2].key);
    try testing.expectEqual(@as(?u8, 0), unsetElement(&sh, "m[a]"));
    try testing.expectEqual(@as(usize, 2), sh.getVar("m").?.map.len);

    try sh.setAttrs("n", .{ .integer = true });
    try sh.setVar("n", .{ .string = "2*3" });
    try testing.expectEqual(@as(i64, 6), sh.getVar("n").?.int);
    try testing.expect(try persist(&sh, arena, .{ .name = "n", .value = "4", .append = true }));
    try testing.expectEqual(@as(i64, 10), sh.getVar("n").?.int);
}
