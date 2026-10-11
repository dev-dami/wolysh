//! Key bindings changed with `bind`: the line editor's named functions, the
//! keys the user rebound, and the default bindings `bind -p` lists.
//!
//! A binding is one control key (`\C-x`) or Alt/Meta plus a key (`\ex`,
//! `\M-x`); longer key sequences are not supported. The editor consults
//! `lookup` before its built-in keys.

const std = @import("std");

pub const Function = enum {
    accept_line,
    abort,
    backward_char,
    backward_delete_char,
    backward_kill_word,
    backward_word,
    beginning_of_line,
    capitalize_word,
    clear_screen,
    complete,
    delete_char,
    downcase_word,
    end_of_line,
    forward_char,
    forward_word,
    kill_line,
    kill_word,
    next_history,
    previous_history,
    reverse_search_history,
    self_insert,
    transpose_chars,
    undo,
    unix_line_discard,
    unix_word_rubout,
    upcase_word,
    yank,
    yank_last_arg,
    yank_pop,
};

const Named = struct { []const u8, Function };

/// Readline's names, alphabetical.
const named = [_]Named{
    .{ "abort", .abort },
    .{ "accept-line", .accept_line },
    .{ "backward-char", .backward_char },
    .{ "backward-delete-char", .backward_delete_char },
    .{ "backward-kill-word", .backward_kill_word },
    .{ "backward-word", .backward_word },
    .{ "beginning-of-line", .beginning_of_line },
    .{ "capitalize-word", .capitalize_word },
    .{ "clear-screen", .clear_screen },
    .{ "complete", .complete },
    .{ "delete-char", .delete_char },
    .{ "downcase-word", .downcase_word },
    .{ "end-of-line", .end_of_line },
    .{ "forward-char", .forward_char },
    .{ "forward-word", .forward_word },
    .{ "kill-line", .kill_line },
    .{ "kill-word", .kill_word },
    .{ "next-history", .next_history },
    .{ "previous-history", .previous_history },
    .{ "reverse-search-history", .reverse_search_history },
    .{ "self-insert", .self_insert },
    .{ "transpose-chars", .transpose_chars },
    .{ "undo", .undo },
    .{ "unix-line-discard", .unix_line_discard },
    .{ "unix-word-rubout", .unix_word_rubout },
    .{ "upcase-word", .upcase_word },
    .{ "yank", .yank },
    .{ "yank-last-arg", .yank_last_arg },
    .{ "yank-pop", .yank_pop },
};

const function_names = blk: {
    var names: [named.len][]const u8 = undefined;
    for (named, 0..) |entry, index| names[index] = entry[0];
    break :blk names;
};

/// Every function name, for `bind -l` and `compgen -A binding`.
pub fn functionNames() []const []const u8 {
    return &function_names;
}

pub fn functionByName(name: []const u8) ?Function {
    for (named) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

pub fn nameOf(function: Function) []const u8 {
    for (named) |entry| {
        if (entry[1] == function) return entry[0];
    }
    unreachable;
}

/// One key: a byte, optionally typed with Alt.
pub const Chord = struct {
    meta: bool = false,
    byte: u8,

    pub fn eql(a: Chord, b: Chord) bool {
        return a.meta == b.meta and a.byte == b.byte;
    }
};

pub const Target = union(enum) {
    function: Function,
    /// `bind -x`: a shell command run with `READLINE_LINE` and `READLINE_POINT`.
    command: []const u8,
    /// `bind '"key": ""'` style removal: the key does nothing.
    unbound,
};

pub const Binding = struct {
    chord: Chord,
    target: Target,
};

/// The editor's own emacs-mode keys, as `bind -p` lists them.
pub const defaults = [_]struct { Chord, Function }{
    .{ .{ .byte = 1 }, .beginning_of_line },
    .{ .{ .byte = 2 }, .backward_char },
    .{ .{ .byte = 4 }, .delete_char },
    .{ .{ .byte = 5 }, .end_of_line },
    .{ .{ .byte = 6 }, .forward_char },
    .{ .{ .byte = 8 }, .backward_delete_char },
    .{ .{ .byte = 9 }, .complete },
    .{ .{ .byte = 10 }, .accept_line },
    .{ .{ .byte = 11 }, .kill_line },
    .{ .{ .byte = 12 }, .clear_screen },
    .{ .{ .byte = 13 }, .accept_line },
    .{ .{ .byte = 14 }, .next_history },
    .{ .{ .byte = 16 }, .previous_history },
    .{ .{ .byte = 18 }, .reverse_search_history },
    .{ .{ .byte = 20 }, .transpose_chars },
    .{ .{ .byte = 21 }, .unix_line_discard },
    .{ .{ .byte = 23 }, .unix_word_rubout },
    .{ .{ .byte = 25 }, .yank },
    .{ .{ .byte = 31 }, .undo },
    .{ .{ .byte = 127 }, .backward_delete_char },
    .{ .{ .meta = true, .byte = 'b' }, .backward_word },
    .{ .{ .meta = true, .byte = 'c' }, .capitalize_word },
    .{ .{ .meta = true, .byte = 'd' }, .kill_word },
    .{ .{ .meta = true, .byte = 'f' }, .forward_word },
    .{ .{ .meta = true, .byte = 'l' }, .downcase_word },
    .{ .{ .meta = true, .byte = 'u' }, .upcase_word },
    .{ .{ .meta = true, .byte = 'y' }, .yank_pop },
    .{ .{ .meta = true, .byte = '.' }, .yank_last_arg },
    .{ .{ .meta = true, .byte = 127 }, .backward_kill_word },
};

// --- user bindings --------------------------------------------------------------------

/// Process-wide, like the completion registry. Command strings are owned by
/// `owner`.
var table: std.ArrayList(Binding) = .empty;
var owner: ?std.mem.Allocator = null;

pub fn list() []const Binding {
    return table.items;
}

/// The target a key was rebound to, if any.
pub fn lookup(chord: Chord) ?Target {
    for (table.items) |binding| {
        if (binding.chord.eql(chord)) return binding.target;
    }
    return null;
}

pub fn set(gpa: std.mem.Allocator, chord: Chord, target: Target) !void {
    if (owner == null) owner = gpa;
    const own = owner.?;
    var stored = target;
    if (target == .command) stored = .{ .command = try own.dupe(u8, target.command) };
    errdefer if (stored == .command) own.free(stored.command);

    for (table.items) |*binding| {
        if (!binding.chord.eql(chord)) continue;
        if (binding.target == .command) own.free(binding.target.command);
        binding.target = stored;
        return;
    }
    try table.append(own, .{ .chord = chord, .target = stored });
}

/// Forgets a user binding, restoring the key's default. False if it had none.
pub fn remove(chord: Chord) bool {
    const own = owner orelse return false;
    for (table.items, 0..) |binding, index| {
        if (!binding.chord.eql(chord)) continue;
        if (binding.target == .command) own.free(binding.target.command);
        _ = table.orderedRemove(index);
        return true;
    }
    return false;
}

/// Drops every user binding.
pub fn reset() void {
    const own = owner orelse return;
    for (table.items) |binding| {
        if (binding.target == .command) own.free(binding.target.command);
    }
    table.deinit(own);
    table = .empty;
    owner = null;
}

// --- key sequences ----------------------------------------------------------------------

/// Parses the inside of a quoted readline key sequence: `\C-a`, `\ea`,
/// `\M-a`, `\e\C-h`, `\\`, `\"`, `\t`, `\r` or one plain character. Null for
/// anything longer or unknown.
pub fn parseKeySequence(text: []const u8) ?Chord {
    var meta = false;
    var rest = text;
    if (std.mem.startsWith(u8, rest, "\\e")) {
        meta = true;
        rest = rest[2..];
    } else if (std.mem.startsWith(u8, rest, "\\M-")) {
        meta = true;
        rest = rest[3..];
    }
    const byte = parseKey(rest) orelse return null;
    return .{ .meta = meta, .byte = byte };
}

fn parseKey(text: []const u8) ?u8 {
    if (text.len == 0) return null;
    if (text[0] != '\\') return if (text.len == 1) text[0] else null;
    if (std.mem.startsWith(u8, text, "\\C-") or std.mem.startsWith(u8, text, "\\c")) {
        const key = if (text[1] == 'C') text[3..] else text[2..];
        if (key.len != 1) return null;
        if (key[0] == '?') return 127;
        return std.ascii.toLower(key[0]) & 0x1f;
    }
    if (text.len != 2) return null;
    return switch (text[1]) {
        'e' => 27,
        't' => 9,
        'r' => 13,
        'n' => 10,
        '\\' => '\\',
        '"' => '"',
        '\'' => '\'',
        'a' => 7,
        'b' => 8,
        else => null,
    };
}

/// Writes `chord` the way `bind -p` shows a key: `\C-a`, `\ex`, `\C-?`.
pub fn writeChord(w: *std.Io.Writer, chord: Chord) !void {
    if (chord.meta) try w.writeAll("\\e");
    const b = chord.byte;
    if (b == 127) {
        try w.writeAll("\\C-?");
    } else if (b == 27) {
        try w.writeAll("\\e");
    } else if (b == 9) {
        try w.writeAll("\\t");
    } else if (b == 13) {
        try w.writeAll("\\C-m");
    } else if (b == 10) {
        try w.writeAll("\\C-j");
    } else if (b < 0x20) {
        try w.print("\\C-{c}", .{b + 0x60});
    } else if (b == '\\' or b == '"') {
        try w.print("\\{c}", .{b});
    } else {
        try w.writeByte(b);
    }
}

// --- tests --------------------------------------------------------------------------------

const testing = std.testing;

test "key sequences" {
    try testing.expectEqual(Chord{ .byte = 1 }, parseKeySequence("\\C-a").?);
    try testing.expectEqual(Chord{ .meta = true, .byte = 'b' }, parseKeySequence("\\eb").?);
    try testing.expectEqual(Chord{ .meta = true, .byte = 'b' }, parseKeySequence("\\M-b").?);
    try testing.expectEqual(Chord{ .byte = 127 }, parseKeySequence("\\C-?").?);
    try testing.expect(parseKeySequence("\\C-x\\C-e") == null);
    try testing.expect(parseKeySequence("ab") == null);
}

test "bindings can be set, replaced and removed" {
    defer reset();
    try set(testing.allocator, .{ .byte = 7 }, .{ .function = .kill_line });
    try set(testing.allocator, .{ .byte = 7 }, .{ .command = "echo hi" });
    try testing.expectEqualStrings("echo hi", lookup(.{ .byte = 7 }).?.command);
    try testing.expect(remove(.{ .byte = 7 }));
    try testing.expect(lookup(.{ .byte = 7 }) == null);
    try testing.expect(functionByName("kill-line").? == .kill_line);
    try testing.expectEqualStrings("kill-line", nameOf(.kill_line));
}
