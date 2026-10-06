//! History expansion for interactive lines, following bash: event
//! designators (`!!`, `!n`, `!-n`, `!string`, `!?string?`, `!#`), word
//! designators (`!$`, `!^`, `!*`, `!:n`, `!:n-m`, ...), the modifiers
//! `:h :t :r :e :p :s/old/new/ :& :g`, and the `^old^new^` quick substitution.
//!
//! Nothing inside single quotes or after a backslash is expanded. A `!`
//! followed by blank, `=`, `(` or the end of the line stays literal, as does
//! `$!`, `${!name}`, `[!...]`, a `!"` closing a double-quoted string, and a
//! `!name(` call in a wsh expression.

const std = @import("std");
const shellmod = @import("../shell.zig");
const history = @import("../history.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;
const Allocator = std.mem.Allocator;

pub const Outcome = union(enum) {
    /// The line has no history reference.
    unchanged,
    /// The expanded line, which the shell echoes and runs.
    expanded: []const u8,
    /// `:p` was used: echo the line and record it, but do not run it.
    print_only: []const u8,
    /// Error text without the `wsh: ` prefix; the line must not run.
    failed: []const u8,
};

/// Expands `line` against `hist`, as typed at the prompt. Interactive REPL
/// glue: prints the expansion or the error the way bash does and returns the
/// line to run, or null when nothing should run.
pub fn apply(sh: *Shell, line: []const u8) ?[]const u8 {
    if (!sh.options.histexpand) return line;
    const arena = sh.scratch();
    const outcome = expand(arena, &sh.hist, line) catch {
        sys.writeStr(sh.default_err, "wsh: history expansion: out of memory\n");
        return null;
    };
    switch (outcome) {
        .unchanged => return line,
        .expanded => |text| {
            echo(sh, text);
            return text;
        },
        .print_only => |text| {
            echo(sh, text);
            sh.hist.add(sh.gpa, text) catch {};
            return null;
        },
        .failed => |message| {
            sys.writeStr(sh.default_err, "wsh: ");
            sys.writeStr(sh.default_err, message);
            sys.writeStr(sh.default_err, "\n");
            return null;
        },
    }
}

fn echo(sh: *Shell, text: []const u8) void {
    sys.writeStr(sh.default_err, text);
    sys.writeStr(sh.default_err, "\n");
}

const Failure = error{ExpansionFailed} || Allocator.Error;

const Expander = struct {
    arena: Allocator,
    hist: *const history.History,
    line: []const u8,
    out: std.ArrayList(u8) = .empty,
    print_only: bool = false,
    /// Set together with `error.ExpansionFailed`.
    message: []const u8 = "",

    fn fail(self: *Expander, comptime fmt: []const u8, args: anytype) Failure {
        self.message = try std.fmt.allocPrint(self.arena, fmt, args);
        return error.ExpansionFailed;
    }
};

pub fn expand(arena: Allocator, hist: *const history.History, line: []const u8) Allocator.Error!Outcome {
    if (std.mem.indexOfAny(u8, line, "!^") == null) return .unchanged;
    var ex = Expander{ .arena = arena, .hist = hist, .line = line };
    const changed = run(&ex) catch |err| switch (err) {
        error.ExpansionFailed => return .{ .failed = ex.message },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!changed) return .unchanged;
    const text = try ex.out.toOwnedSlice(arena);
    return if (ex.print_only) .{ .print_only = text } else .{ .expanded = text };
}

fn run(ex: *Expander) Failure!bool {
    var changed = false;
    var i: usize = 0;
    if (ex.line.len > 0 and ex.line[0] == '^') {
        i = try quickSubstitution(ex);
        changed = true;
    }

    const State = enum { plain, single, double };
    var state: State = .plain;
    const line = ex.line;
    while (i < line.len) {
        const c = line[i];
        if (state == .single) {
            if (c == '\'') state = .plain;
            try ex.out.append(ex.arena, c);
            i += 1;
            continue;
        }
        switch (c) {
            '\\' => {
                const end = @min(i + 2, line.len);
                try ex.out.appendSlice(ex.arena, line[i..end]);
                i = end;
                continue;
            },
            '\'' => if (state == .plain) {
                state = .single;
            },
            '"' => state = if (state == .double) .plain else .double,
            '!' => if (!inhibited(line, i, state == .double)) {
                if (try reference(ex, i, state == .double)) |end| {
                    i = end;
                    changed = true;
                    continue;
                }
            },
            else => {},
        }
        try ex.out.append(ex.arena, c);
        i += 1;
    }
    return changed;
}

fn inhibited(line: []const u8, i: usize, in_double: bool) bool {
    if (i + 1 >= line.len) return true;
    const next = line[i + 1];
    switch (next) {
        ' ', '\t', '\n', '\r', '=', '(' => return true,
        '"' => if (in_double) return true,
        else => {},
    }
    if (i > 0 and line[i - 1] == '$') return true;
    if (i > 1 and line[i - 1] == '{' and line[i - 2] == '$') return true;
    if (i > 0 and line[i - 1] == '[' and std.mem.indexOfScalarPos(u8, line, i + 1, ']') != null) return true;
    return false;
}

fn isWordDelimiter(c: u8, in_double: bool) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ':', ';', '&', '|', '(', ')', '<', '>', '\'', '`' => true,
        '"' => in_double,
        else => false,
    };
}

/// Expands the history reference starting at `line[i] == '!'` and returns
/// the index after it, or null when the `!` is literal.
fn reference(ex: *Expander, i: usize, in_double: bool) Failure!?usize {
    const line = ex.line;
    var pos = i + 1;
    const event: []const u8 = switch (line[pos]) {
        '!' => blk: {
            pos += 1;
            break :blk try eventByOffset(ex, 1, line[i..pos]);
        },
        '#' => blk: {
            pos += 1;
            break :blk try ex.arena.dupe(u8, ex.out.items);
        },
        '$', '^', '*', ':' => try eventByOffset(ex, 1, line[i .. i + 2]),
        '-' => blk: {
            const start = pos + 1;
            var end = start;
            while (end < line.len and std.ascii.isDigit(line[end])) end += 1;
            if (end == start) break :blk try stringEvent(ex, i, &pos, in_double) orelse return null;
            pos = end;
            const n = std.fmt.parseInt(usize, line[start..end], 10) catch return ex.fail("{s}: event not found", .{line[i..end]});
            break :blk try eventByOffset(ex, n, line[i..end]);
        },
        '0'...'9' => blk: {
            const start = pos;
            while (pos < line.len and std.ascii.isDigit(line[pos])) pos += 1;
            const n = std.fmt.parseInt(usize, line[start..pos], 10) catch 0;
            if (n == 0 or n > ex.hist.count()) return ex.fail("{s}: event not found", .{line[i..pos]});
            break :blk ex.hist.get(n - 1);
        },
        '?' => blk: {
            const start = pos + 1;
            const close = std.mem.indexOfAnyPos(u8, line, start, "?\n");
            const end = close orelse line.len;
            pos = if (close != null and line[end] == '?') end + 1 else end;
            const needle = line[start..end];
            const index = if (needle.len == 0) null else ex.hist.searchBackwardContains(ex.hist.count(), needle);
            break :blk ex.hist.get(index orelse return ex.fail("{s}: event not found", .{line[i..pos]}));
        },
        else => try stringEvent(ex, i, &pos, in_double) orelse return null,
    };

    var words: ?[]const []const u8 = null;
    var selected: []const u8 = event;
    // A word designator follows a `:`; the `:` may be dropped before `^ $ * %`.
    if (pos < line.len and (line[pos] == '^' or line[pos] == '$' or line[pos] == '*' or
        (line[pos] == ':' and pos + 1 < line.len and isDesignatorStart(line[pos + 1]))))
    {
        if (line[pos] == ':') pos += 1;
        words = try splitWords(ex.arena, event);
        selected = try designate(ex, words.?, &pos);
    }

    var text: []const u8 = try ex.arena.dupe(u8, selected);
    while (pos + 1 < line.len and line[pos] == ':' and (std.ascii.isAlphabetic(line[pos + 1]) or line[pos + 1] == '&')) {
        pos += 1;
        text = try modify(ex, text, &pos);
    }

    try ex.out.appendSlice(ex.arena, text);
    return pos;
}

fn isDesignatorStart(c: u8) bool {
    return std.ascii.isDigit(c) or c == '^' or c == '$' or c == '*' or c == '-' or c == '%';
}

fn eventByOffset(ex: *Expander, back: usize, text: []const u8) Failure![]const u8 {
    const count = ex.hist.count();
    if (back == 0 or back > count) return ex.fail("{s}: event not found", .{text});
    return ex.hist.get(count - back);
}

/// `!string`: the newest entry starting with `string`. Null leaves the `!`
/// literal, which is the case for a wsh call such as `!exists(path)`.
fn stringEvent(ex: *Expander, bang: usize, pos: *usize, in_double: bool) Failure!?[]const u8 {
    const line = ex.line;
    const start = bang + 1;
    var end = start;
    while (end < line.len and !isWordDelimiter(line[end], in_double)) end += 1;
    if (end == start) return null;
    if (end < line.len and line[end] == '(') return null;
    pos.* = end;
    const prefix = line[start..end];
    const index = ex.hist.searchBackward(ex.hist.count(), prefix) orelse
        return ex.fail("{s}: event not found", .{line[bang..end]});
    return ex.hist.get(index);
}

/// Parses a word designator at `pos.*` and returns the selected words.
fn designate(ex: *Expander, words: []const []const u8, pos: *usize) Failure![]const u8 {
    const line = ex.line;
    const start = pos.*;
    const last = if (words.len == 0) 0 else words.len - 1;
    var first: usize = undefined;
    var final: usize = undefined;

    switch (line[pos.*]) {
        '*' => {
            pos.* += 1;
            if (words.len <= 1) return "";
            return std.mem.join(ex.arena, " ", words[1..]);
        },
        '%' => return ex.fail("{s}: bad word specifier", .{line[start - 1 .. pos.* + 1]}),
        '-' => {
            first = 0;
        },
        else => {
            first = parseIndex(line, pos, last) orelse return ex.fail(":{s}: bad word specifier", .{line[start .. start + 1]});
        },
    }

    if (pos.* < line.len and line[pos.*] == '*') {
        pos.* += 1;
        final = last;
        if (first > last) return "";
    } else if (pos.* < line.len and line[pos.*] == '-') {
        pos.* += 1;
        if (parseIndex(line, pos, last)) |index| {
            final = index;
        } else {
            // `n-` drops the last word.
            if (last == 0 or first > last - 1) return ex.fail(":{s}: bad word specifier", .{line[start..pos.*]});
            final = last - 1;
        }
    } else {
        final = first;
    }

    if (words.len == 0 or first > last or final > last or first > final) {
        return ex.fail(":{s}: bad word specifier", .{line[start..pos.*]});
    }
    return std.mem.join(ex.arena, " ", words[first .. final + 1]);
}

fn parseIndex(line: []const u8, pos: *usize, last: usize) ?usize {
    if (pos.* >= line.len) return null;
    switch (line[pos.*]) {
        '^' => {
            pos.* += 1;
            return 1;
        },
        '$' => {
            pos.* += 1;
            return last;
        },
        '0'...'9' => {
            const start = pos.*;
            while (pos.* < line.len and std.ascii.isDigit(line[pos.*])) pos.* += 1;
            return std.fmt.parseInt(usize, line[start..pos.*], 10) catch std.math.maxInt(usize);
        },
        else => return null,
    }
}

/// Applies one `:x` modifier at `pos.*` to `text`.
fn modify(ex: *Expander, text: []const u8, pos: *usize) Failure![]const u8 {
    const line = ex.line;
    const c = line[pos.*];
    pos.* += 1;
    switch (c) {
        'h' => {
            const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
            return if (slash == 0) "/" else text[0..slash];
        },
        't' => {
            const slash = std.mem.lastIndexOfScalar(u8, text, '/') orelse return text;
            return text[slash + 1 ..];
        },
        'r' => {
            const dot = suffixDot(text) orelse return text;
            return text[0..dot];
        },
        'e' => {
            const dot = suffixDot(text) orelse return text;
            return text[dot..];
        },
        'p' => {
            ex.print_only = true;
            return text;
        },
        's', '&' => return substitute(ex, text, pos, c == '&', false),
        'g', 'a' => {
            if (pos.* < line.len and (line[pos.*] == 's' or line[pos.*] == '&')) {
                const again = line[pos.*] == '&';
                pos.* += 1;
                return substitute(ex, text, pos, again, true);
            }
            return ex.fail("{c}: unrecognized history modifier", .{c});
        },
        else => return ex.fail("{c}: unrecognized history modifier", .{c}),
    }
}

/// Index of the `.` that starts the file suffix in the last path component.
fn suffixDot(text: []const u8) ?usize {
    const dot = std.mem.lastIndexOfScalar(u8, text, '.') orelse return null;
    if (std.mem.indexOfScalarPos(u8, text, dot, '/') != null) return null;
    return dot;
}

/// The previous `s/old/new/`, reused by `:&` and by `^old^new^`.
var last_old: []const u8 = "";
var last_new: []const u8 = "";
var last_old_buf: [256]u8 = undefined;
var last_new_buf: [256]u8 = undefined;

/// An empty `old` keeps the previous pattern, as in `s//new/`.
fn rememberSubstitution(old: []const u8, new: []const u8) void {
    if (old.len != 0) {
        const old_len = @min(old.len, last_old_buf.len);
        @memcpy(last_old_buf[0..old_len], old[0..old_len]);
        last_old = last_old_buf[0..old_len];
    }
    const new_len = @min(new.len, last_new_buf.len);
    @memcpy(last_new_buf[0..new_len], new[0..new_len]);
    last_new = last_new_buf[0..new_len];
}

fn substitute(ex: *Expander, text: []const u8, pos: *usize, again: bool, global: bool) Failure![]const u8 {
    const line = ex.line;
    const start = pos.* - 1;
    if (!again) {
        if (pos.* >= line.len) return ex.fail(":{s}: substitution failed", .{line[start..]});
        const delimiter = line[pos.*];
        pos.* += 1;
        const parsed_old = try readDelimited(ex, delimiter, pos);
        const parsed_new = try readDelimited(ex, delimiter, pos);
        rememberSubstitution(parsed_old, parsed_new);
    }
    const old = last_old;
    const new = last_new;
    if (old.len == 0 or std.mem.indexOf(u8, text, old) == null) {
        return ex.fail("{s}: substitution failed", .{line[start - 1 .. pos.*]});
    }
    // `&` in the replacement stands for the matched text.
    var replacement: std.ArrayList(u8) = .empty;
    var k: usize = 0;
    while (k < new.len) : (k += 1) {
        if (new[k] == '\\' and k + 1 < new.len and new[k + 1] == '&') {
            try replacement.append(ex.arena, '&');
            k += 1;
        } else if (new[k] == '&') {
            try replacement.appendSlice(ex.arena, old);
        } else {
            try replacement.append(ex.arena, new[k]);
        }
    }
    if (global) return std.mem.replaceOwned(u8, ex.arena, text, old, replacement.items);

    const at = std.mem.indexOf(u8, text, old).?;
    return std.mem.concat(ex.arena, u8, &.{ text[0..at], replacement.items, text[at + old.len ..] });
}

/// Reads up to the next unescaped `delimiter` (or the end of the line).
fn readDelimited(ex: *Expander, delimiter: u8, pos: *usize) Failure![]const u8 {
    const line = ex.line;
    var out: std.ArrayList(u8) = .empty;
    while (pos.* < line.len and line[pos.*] != delimiter) : (pos.* += 1) {
        if (line[pos.*] == '\\' and pos.* + 1 < line.len and line[pos.* + 1] == delimiter) pos.* += 1;
        try out.append(ex.arena, line[pos.*]);
    }
    if (pos.* < line.len) pos.* += 1;
    return out.items;
}

/// `^old^new^rest`: the previous command with `old` replaced by `new`.
fn quickSubstitution(ex: *Expander) Failure!usize {
    var pos: usize = 1;
    const old = try readDelimited(ex, '^', &pos);
    const new = try readDelimited(ex, '^', &pos);
    const count = ex.hist.count();
    if (count == 0) return ex.fail("!!: event not found", .{});
    const previous = ex.hist.get(count - 1);
    if (old.len == 0 or std.mem.indexOf(u8, previous, old) == null) {
        return ex.fail(":s^{s}^{s}^: substitution failed", .{ old, new });
    }
    rememberSubstitution(old, new);
    const at = std.mem.indexOf(u8, previous, old).?;
    try ex.out.appendSlice(ex.arena, previous[0..at]);
    try ex.out.appendSlice(ex.arena, new);
    try ex.out.appendSlice(ex.arena, previous[at + old.len ..]);
    return pos;
}

/// Splits a command line into history words: blank-separated, quotes kept
/// together, and each run of shell operators (`2>`, `&&`, `;`, ...) a word of
/// its own.
pub fn splitWords(arena: Allocator, line: []const u8) Allocator.Error![]const []const u8 {
    var words: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (true) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\n' or line[i] == '\r')) i += 1;
        if (i >= line.len) break;
        const start = i;
        if (isOperator(line[i])) {
            i = operatorEnd(line, i);
        } else {
            i = wordEnd(line, i);
            // `2>` and `2>&1` keep their descriptor number.
            if (i < line.len and (line[i] == '<' or line[i] == '>') and allDigits(line[start..i])) {
                i = operatorEnd(line, i);
            }
        }
        try words.append(arena, line[start..i]);
    }
    return words.toOwnedSlice(arena);
}

fn isOperator(c: u8) bool {
    return switch (c) {
        ';', '&', '|', '<', '>', '(', ')' => true,
        else => false,
    };
}

fn operatorEnd(line: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= line.len) return i;
    const first = line[start];
    const second = line[i];
    const pair = (second == first and first != '(' and first != ')') or
        (first == '>' and (second == '&' or second == '|')) or
        (first == '<' and second == '&') or
        (first == '&' and second == '>') or
        (first == '|' and second == '&');
    if (pair) i += 1;
    return i;
}

fn wordEnd(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\n', '\r' => return i,
            '\\' => i = @min(i + 2, line.len),
            '\'', '"', '`' => {
                const close = std.mem.indexOfScalarPos(u8, line, i + 1, c);
                i = if (close) |end| end + 1 else line.len;
            },
            '$' => {
                if (i + 1 < line.len and (line[i + 1] == '(' or line[i + 1] == '{')) {
                    i = matchingClose(line, i + 1);
                } else {
                    i += 1;
                }
            },
            else => {
                if (isOperator(c)) return i;
                i += 1;
            },
        }
    }
    return i;
}

fn matchingClose(line: []const u8, open_index: usize) usize {
    const open = line[open_index];
    const close: u8 = if (open == '(') ')' else '}';
    var depth: usize = 0;
    var i = open_index;
    while (i < line.len) : (i += 1) {
        if (line[i] == open) depth += 1;
        if (line[i] == close) {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return line.len;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

// --- tests --------------------------------------------------------------------

const testing = std.testing;

fn expectExpansion(hist: *const history.History, line: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try expand(arena_state.allocator(), hist, line);
    switch (outcome) {
        .expanded => |text| try testing.expectEqualStrings(expected, text),
        .unchanged => try testing.expectEqualStrings(expected, line),
        .print_only => |text| try testing.expectEqualStrings(expected, text),
        .failed => |message| {
            std.debug.print("unexpected failure: {s}\n", .{message});
            return error.TestUnexpectedResult;
        },
    }
}

fn expectFailure(hist: *const history.History, line: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const outcome = try expand(arena_state.allocator(), hist, line);
    try testing.expectEqualStrings(expected, outcome.failed);
}

test "history word splitting keeps quotes and splits operators" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const words = try splitWords(arena_state.allocator(), "echo 'a b' \"c d\" x2>/dev/null && ls $(pwd)|wc");
    const expected = [_][]const u8{ "echo", "'a b'", "\"c d\"", "x2", ">", "/dev/null", "&&", "ls", "$(pwd)", "|", "wc" };
    try testing.expectEqual(expected.len, words.len);
    for (expected, words) |want, got| try testing.expectEqualStrings(want, got);

    const fd = try splitWords(arena_state.allocator(), "cmd 2>/dev/null");
    try testing.expectEqualStrings("2>", fd[1]);
}

test "event designators" {
    var hist = history.History{};
    defer hist.deinit(testing.allocator);
    try hist.add(testing.allocator, "echo one two three");
    try hist.add(testing.allocator, "ls -la /tmp");
    try hist.add(testing.allocator, "git status");

    try expectExpansion(&hist, "!!", "git status");
    try expectExpansion(&hist, "sudo !!", "sudo git status");
    try expectExpansion(&hist, "!1", "echo one two three");
    try expectExpansion(&hist, "!-2", "ls -la /tmp");
    try expectExpansion(&hist, "!ec", "echo one two three");
    try expectExpansion(&hist, "!?-la?", "ls -la /tmp");
    try expectExpansion(&hist, "!?status", "git status");
    try expectExpansion(&hist, "echo a !#", "echo a echo a ");
    try expectFailure(&hist, "!nope", "!nope: event not found");
    try expectFailure(&hist, "echo !9", "!9: event not found");
    try expectFailure(&hist, "!-7", "!-7: event not found");
}

test "word designators and modifiers" {
    var hist = history.History{};
    defer hist.deinit(testing.allocator);
    try hist.add(testing.allocator, "tar xf /srv/pkg.tar.gz -C out");

    try expectExpansion(&hist, "echo !$", "echo out");
    try expectExpansion(&hist, "echo !^", "echo xf");
    try expectExpansion(&hist, "echo !*", "echo xf /srv/pkg.tar.gz -C out");
    try expectExpansion(&hist, "echo !:2", "echo /srv/pkg.tar.gz");
    try expectExpansion(&hist, "echo !:1-2", "echo xf /srv/pkg.tar.gz");
    try expectExpansion(&hist, "echo !:3*", "echo -C out");
    try expectExpansion(&hist, "echo !:2-", "echo /srv/pkg.tar.gz -C");
    try expectExpansion(&hist, "echo !!:0", "echo tar");
    try expectExpansion(&hist, "echo !tar:2:h !tar:2:t", "echo /srv pkg.tar.gz");
    try expectExpansion(&hist, "echo !:2:r !:2:e", "echo /srv/pkg.tar .gz");
    try expectExpansion(&hist, "!!:s/out/build/", "tar xf /srv/pkg.tar.gz -C build");
    try expectExpansion(&hist, "!!:gs/r/R/", "taR xf /sRv/pkg.taR.gz -C out");
    try expectFailure(&hist, "echo !:9", ":9: bad word specifier");
    try expectFailure(&hist, "echo !!:z", "z: unrecognized history modifier");
    try expectFailure(&hist, "!!:s/nothere/x/", ":s/nothere/x/: substitution failed");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const printed = try expand(arena_state.allocator(), &hist, "echo !:1:p");
    try testing.expectEqualStrings("echo xf", printed.print_only);
}

test "quoting and literal bangs" {
    var hist = history.History{};
    defer hist.deinit(testing.allocator);
    try hist.add(testing.allocator, "make test");

    try expectExpansion(&hist, "echo '!!'", "echo '!!'");
    try expectExpansion(&hist, "echo \\!!", "echo \\!!");
    try expectExpansion(&hist, "echo \"!!\"", "echo \"make test\"");
    try expectExpansion(&hist, "echo \"hi!\"", "echo \"hi!\"");
    try expectExpansion(&hist, "echo hi! there", "echo hi! there");
    try expectExpansion(&hist, "[ a != b ]", "[ a != b ]");
    try expectExpansion(&hist, "echo $! ${!name} [!a]*", "echo $! ${!name} [!a]*");
    try expectExpansion(&hist, "if !exists(\"x\") { echo }", "if !exists(\"x\") { echo }");
    try expectExpansion(&hist, "! grep -q x f", "! grep -q x f");
}

test "quick substitution" {
    var hist = history.History{};
    defer hist.deinit(testing.allocator);
    try hist.add(testing.allocator, "git cmomit -m x");

    try expectExpansion(&hist, "^cmomit^commit^", "git commit -m x");
    try expectExpansion(&hist, "^cmomit^commit", "git commit -m x");
    try expectExpansion(&hist, "^-m x^--amend^ --no-edit", "git cmomit --amend --no-edit");
    try expectFailure(&hist, "^zzz^y^", ":s^zzz^y^: substitution failed");
}
