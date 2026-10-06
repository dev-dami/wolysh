//! `[[ expression ]]`: string, pattern, regular-expression, integer and file
//! tests. Each operand expands to one value, without splitting or globbing.

const std = @import("std");
const ast = @import("../ast.zig");
const shellmod = @import("../shell.zig");
const expand = @import("../expand.zig");
const arith = @import("../arith.zig");
const glob = @import("../glob.zig");
const regex = @import("../regex.zig");
const value = @import("../value.zig");
const strict = @import("../strict.zig");
const test_ops = @import("../builtins/test.zig");

const Shell = shellmod.Shell;

pub const Error = error{
    /// The right side of `=~` is not a valid regular expression; the message
    /// has been printed.
    BadRegex,
    /// BASH_REMATCH could not be set.
    ReadonlyVariable,
} || arith.Error;

/// Whether `cond` holds. `&&` and `||` short-circuit, so an operand that is
/// not needed is never expanded.
pub fn evaluate(sh: *Shell, arena: std.mem.Allocator, cond: *const ast.Cond) Error!bool {
    return check(sh, arena, cond, false);
}

/// `negated` marks a test directly under `!`, which `set -x` shows with it.
fn check(sh: *Shell, arena: std.mem.Allocator, cond: *const ast.Cond, negated: bool) Error!bool {
    return switch (cond.*) {
        .not => |inner| !(try check(sh, arena, inner, true)),
        .and_ => |pair| (try check(sh, arena, pair.lhs, false)) and (try check(sh, arena, pair.rhs, false)),
        .or_ => |pair| (try check(sh, arena, pair.lhs, false)) or (try check(sh, arena, pair.rhs, false)),
        .unary => |test_| unary(sh, arena, test_.op, test_.operand, negated),
        .binary => |test_| binary(sh, arena, test_.op, test_.lhs, test_.rhs, negated),
    };
}

fn unary(sh: *Shell, arena: std.mem.Allocator, op: []const u8, word: ast.Word, negated: bool) Error!bool {
    const operand = try expand.expandLiteral(sh, arena, word);
    try trace(sh, arena, negated, &.{ op, operand });
    if (op[1] == 'v') return isSet(sh, arena, operand);
    // Only `-t` fails, on a descriptor that is not a number: not a terminal.
    return test_ops.unary(sh, op, operand) catch false;
}

/// `-v name` and `-v name[subscript]`: whether `${name[subscript]+x}` would
/// expand. A bare array name means its element 0, as in bash, so an empty
/// array counts as unset.
fn isSet(sh: *Shell, arena: std.mem.Allocator, operand: []const u8) Error!bool {
    const name_end = std.mem.indexOfScalar(u8, operand, '[') orelse operand.len;
    const name = operand[0..name_end];
    if (!validName(name)) return false;
    if (name_end < operand.len and operand[operand.len - 1] != ']') return false;
    const element = name_end == operand.len and !std.ascii.isDigit(name[0]);
    const probe = try std.fmt.allocPrint(arena, "${{{s}{s}+x}}", .{ operand, if (element) "[0]" else "" });
    return (try expand.expandLiteral(sh, arena, probe)).len != 0;
}

/// A variable name or a positional parameter number.
fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.ascii.isDigit(name[0])) {
        for (name) |c| if (!std.ascii.isDigit(c)) return false;
        return true;
    }
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |c| if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    return true;
}

fn binary(sh: *Shell, arena: std.mem.Allocator, op: []const u8, lhs_word: ast.Word, rhs_word: ast.Word, negated: bool) Error!bool {
    const lhs = try expand.expandLiteral(sh, arena, lhs_word);
    if (std.mem.eql(u8, op, "==") or std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "!=")) {
        const pattern = try expand.expandPattern(sh, arena, rhs_word);
        if (sh.options.xtrace) try trace(sh, arena, negated, &.{ lhs, op, try shownPattern(arena, pattern) });
        const matched = glob.matchSegmentWith(pattern, lhs, .{ .nocase = sh.options.nocasematch });
        return matched != std.mem.eql(u8, op, "!=");
    }
    if (std.mem.eql(u8, op, "=~")) {
        const pattern = try expand.expandRegex(sh, arena, rhs_word);
        try trace(sh, arena, negated, &.{ lhs, op, pattern });
        return matchRegex(sh, arena, lhs, pattern);
    }
    const rhs = try expand.expandLiteral(sh, arena, rhs_word);
    try trace(sh, arena, negated, &.{ lhs, op, rhs });
    if (test_ops.isIntegerOp(op)) {
        // Each side is an arithmetic expression: `[[ n+1 -eq 2 ]]`.
        const a = try arith.evaluateExpanded(sh, arena, lhs);
        const b = try arith.evaluateExpanded(sh, arena, rhs);
        return test_ops.compareIntegers(op, a, b);
    }
    // Only the integer operators, handled above, can fail.
    return test_ops.binary(lhs, op, rhs) catch unreachable;
}

/// `=~`: BASH_REMATCH becomes the match and its groups (an empty string for a
/// group that took no part), or an empty array when nothing matched.
fn matchRegex(sh: *Shell, arena: std.mem.Allocator, text: []const u8, pattern: []const u8) Error!bool {
    const re = regex.compileOptions(arena, pattern, .{ .icase = sh.options.nocasematch }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            expand.printError(sh, "wsh: [[: invalid regular expression `{s}': {s}\n", .{ pattern, regex.errorMessage(err) });
            return error.BadRegex;
        },
    };
    const found = try re.match(text);
    const groups: []const ?regex.Span = if (found) |m| m.groups else &.{};
    const items = try arena.alloc(value.Value, groups.len);
    for (groups, items) |group, *item| {
        item.* = .{ .string = if (group) |span| text[span.start..span.end] else "" };
    }
    try sh.setVar("BASH_REMATCH", .{ .list = items });
    return found != null;
}

/// `set -x` shows each test on its own line, as bash does.
fn trace(sh: *Shell, arena: std.mem.Allocator, negated: bool, words: []const []const u8) Error!void {
    if (!sh.options.xtrace) return;
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, if (negated) "[[ ! " else "[[ ");
    for (words) |word| {
        try text.appendSlice(arena, word);
        try text.append(arena, ' ');
    }
    try text.appendSlice(arena, "]]");
    strict.traceText(sh, text.items);
}

/// A pattern as bash's `set -x` shows it: only glob characters keep the
/// backslash that makes them literal.
fn shownPattern(arena: std.mem.Allocator, pattern: []const u8) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < pattern.len) {
        if (pattern[i] == '\\' and i + 1 < pattern.len) {
            if (std.mem.indexOfScalar(u8, "*?[]\\", pattern[i + 1]) != null) try out.append(arena, '\\');
            try out.append(arena, pattern[i + 1]);
            i += 2;
            continue;
        }
        try out.append(arena, pattern[i]);
        i += 1;
    }
    return out.items;
}
