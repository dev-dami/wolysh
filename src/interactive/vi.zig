//! vi editing mode, active while `set -o vi` is on. Insert mode keeps the
//! regular editing keys; Esc switches to normal mode, where commands take
//! counts (`3w`, `d2b`) and the operators `d`, `c` and `y` take a motion.
//! Deleted text goes to the editor's kill ring, which `p` and `P` put back.

const std = @import("std");
const editor_mod = @import("editor.zig");
const wcwidth = @import("wcwidth.zig");

const Editor = editor_mod.Editor;
const Key = editor_mod.Key;
const Outcome = editor_mod.Outcome;

pub const Mode = enum { insert, normal };

/// Counts are capped so a stray `99999x` cannot stall the editor.
const max_count = 1 << 16;

pub const State = struct {
    mode: Mode = .insert,
    count: usize = 0,
    /// Pending operator: `d`, `c` or `y`, or 0.
    operator: u8 = 0,
    operator_count: usize = 1,
    /// `r` is waiting for its replacement character.
    replace_pending: bool = false,
    /// `/` or `?` while a search pattern is being typed.
    searching: ?u8 = null,
    query: std.ArrayList(u8) = .empty,
    last_query: std.ArrayList(u8) = .empty,
    last_search: u8 = '/',

    pub fn reset(self: *State) void {
        self.mode = .insert;
        self.clearPending();
        self.searching = null;
        self.query.clearRetainingCapacity();
    }

    fn clearPending(self: *State) void {
        self.count = 0;
        self.operator = 0;
        self.operator_count = 1;
        self.replace_pending = false;
    }

    fn takeCount(self: *State) usize {
        const n = if (self.count == 0) 1 else @min(self.count, max_count);
        self.count = 0;
        return n;
    }

    pub fn deinit(self: *State, gpa: std.mem.Allocator) void {
        self.query.deinit(gpa);
        self.last_query.deinit(gpa);
    }
};

/// Esc from insert mode: like vi, the cursor steps back onto the last
/// character typed.
pub fn enterNormal(ed: *Editor) void {
    ed.vi.mode = .normal;
    ed.vi.clearPending();
    if (ed.cursor > 0) ed.moveLeft();
}

fn enterInsert(ed: *Editor) void {
    ed.vi.mode = .insert;
    ed.vi.clearPending();
}

pub fn handleNormal(ed: *Editor, key: Key) Outcome {
    const st = &ed.vi;
    if (st.searching != null) {
        searchKey(ed, key);
        return .handled;
    }
    if (st.replace_pending) {
        st.replace_pending = false;
        const n = st.takeCount();
        switch (key) {
            .byte => |b| if (b >= 0x20 and b != 0x7f) replaceChars(ed, &.{b}, n),
            .utf8 => |sequence| replaceChars(ed, sequence.bytes[0..sequence.len], n),
            .literal => |b| replaceChars(ed, &.{b}, n),
            else => {},
        }
        st.clearPending();
        clampCursor(ed);
        return .handled;
    }

    const c: u8 = switch (key) {
        .byte => |b| b,
        .left => 'h',
        .right => 'l',
        .up => 'k',
        .down => 'j',
        .home => '0',
        .end => '$',
        .delete => 'x',
        .word_left => 'b',
        .word_right => 'w',
        .escape => {
            st.clearPending();
            return .handled;
        },
        .eof => return ed.endOfInput(),
        .paste_start => {
            ed.readPaste();
            return .handled;
        },
        else => return .handled,
    };
    return command(ed, c);
}

fn command(ed: *Editor, c: u8) Outcome {
    const st = &ed.vi;
    if ((c >= '1' and c <= '9') or (c == '0' and st.count > 0)) {
        st.count = @min(st.count *| 10 +| (c - '0'), max_count);
        return .handled;
    }
    switch (c) {
        '\r', '\n' => {
            st.clearPending();
            return .accept;
        },
        3 => {
            st.clearPending();
            return ed.cancelLine();
        },
        4 => return ed.endOfInput(),
        12 => {
            ed.clearScreen();
            return .handled;
        },
        else => {},
    }
    if (st.operator != 0) {
        operatorMotion(ed, c);
        clampCursor(ed);
        return .handled;
    }

    const n = st.takeCount();
    const len = ed.buf.items.len;
    switch (c) {
        'd', 'c', 'y' => {
            st.operator = c;
            st.operator_count = n;
            return .handled;
        },
        'i' => enterInsert(ed),
        'a' => {
            if (len > 0) ed.moveRight();
            enterInsert(ed);
        },
        'I' => {
            ed.cursor = 0;
            enterInsert(ed);
        },
        'A' => {
            ed.cursor = len;
            enterInsert(ed);
        },
        'x' => ed.killRange(ed.cursor, advance(ed.buf.items, ed.cursor, n), .forward, false),
        'X' => ed.killRange(retreat(ed.buf.items, ed.cursor, n), ed.cursor, .backward, false),
        'D' => ed.killRange(ed.cursor, len, .forward, false),
        'C' => {
            ed.killRange(ed.cursor, len, .forward, false);
            enterInsert(ed);
        },
        'S' => {
            ed.killRange(0, len, .forward, false);
            enterInsert(ed);
        },
        's' => {
            ed.killRange(ed.cursor, advance(ed.buf.items, ed.cursor, n), .forward, false);
            enterInsert(ed);
        },
        'r' => {
            st.replace_pending = true;
            st.count = n;
            return .handled;
        },
        '~' => toggleCase(ed, n),
        'p' => put(ed, n, true),
        'P' => put(ed, n, false),
        'u' => ed.undo(),
        'k', '-' => {
            for (0..n) |_| ed.historyPrev();
            ed.cursor = 0;
        },
        'j', '+' => {
            for (0..n) |_| ed.historyNext();
            ed.cursor = 0;
        },
        '/', '?' => {
            st.searching = c;
            st.query.clearRetainingCapacity();
            return .handled;
        },
        'n' => search(ed, st.last_search, n),
        'N' => search(ed, if (st.last_search == '/') '?' else '/', n),
        else => if (motion(ed, c, n, false)) |m| {
            ed.cursor = m.target;
        },
    }
    clampCursor(ed);
    return .handled;
}

/// In normal mode the cursor sits on a character, never after the last one.
fn clampCursor(ed: *Editor) void {
    if (ed.vi.mode != .normal) return;
    const len = ed.buf.items.len;
    if (len > 0 and ed.cursor >= len) ed.cursor = wcwidth.prevCluster(ed.buf.items, len);
}

// --- motions ------------------------------------------------------------------

const Motion = struct {
    target: usize,
    /// The character at `target` belongs to the range (`e`, `E`).
    inclusive: bool = false,
};

/// 0: blank, 1: word characters, 2: punctuation. A `W`-style big word
/// treats everything that is not blank as one class.
fn class(c: u8, big: bool) u2 {
    if (c == ' ' or c == '\t' or c == '\n') return 0;
    if (big or std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80) return 1;
    return 2;
}

fn advance(text: []const u8, from: usize, n: usize) usize {
    var pos = from;
    for (0..n) |_| {
        if (pos >= text.len) break;
        pos = wcwidth.nextCluster(text, pos);
    }
    return pos;
}

fn retreat(text: []const u8, from: usize, n: usize) usize {
    var pos = from;
    for (0..n) |_| {
        if (pos == 0) break;
        pos = wcwidth.prevCluster(text, pos);
    }
    return pos;
}

fn nextWordStart(text: []const u8, from: usize, big: bool) usize {
    if (from >= text.len) return text.len;
    var i = from;
    const start_class = class(text[i], big);
    if (start_class != 0) {
        while (i < text.len and class(text[i], big) == start_class) i += 1;
    }
    while (i < text.len and class(text[i], big) == 0) i += 1;
    return i;
}

fn prevWordStart(text: []const u8, from: usize, big: bool) usize {
    if (from == 0) return 0;
    var i = from - 1;
    while (i > 0 and class(text[i], big) == 0) i -= 1;
    const word_class = class(text[i], big);
    while (i > 0 and class(text[i - 1], big) == word_class) i -= 1;
    return i;
}

/// Start of the last character of the word ending after `from`; from the
/// end of a word this moves on to the end of the next one, as in vi.
fn wordEnd(text: []const u8, from: usize, big: bool) usize {
    if (text.len == 0) return 0;
    var i = wcwidth.nextCluster(text, from);
    while (i < text.len and class(text[i], big) == 0) i += 1;
    if (i >= text.len) return wcwidth.prevCluster(text, text.len);
    const word_class = class(text[i], big);
    while (i + 1 < text.len and class(text[i + 1], big) == word_class) i += 1;
    return wcwidth.prevCluster(text, i + 1);
}

fn firstNonBlank(text: []const u8) usize {
    var i: usize = 0;
    while (i < text.len and (text[i] == ' ' or text[i] == '\t')) i += 1;
    return i;
}

fn motion(ed: *Editor, c: u8, n: usize, for_operator: bool) ?Motion {
    const text = ed.buf.items;
    var pos = ed.cursor;
    switch (c) {
        'h', 0x7f, 0x08 => pos = retreat(text, pos, n),
        'l', ' ' => pos = advance(text, pos, n),
        '0' => pos = 0,
        '^' => pos = firstNonBlank(text),
        '$' => pos = text.len,
        'w', 'W' => for (0..n) |_| {
            pos = nextWordStart(text, pos, c == 'W');
        },
        'b', 'B' => for (0..n) |_| {
            pos = prevWordStart(text, pos, c == 'B');
        },
        'e', 'E' => {
            for (0..n) |_| pos = wordEnd(text, pos, c == 'E');
            return .{ .target = pos, .inclusive = for_operator };
        },
        else => return null,
    }
    return .{ .target = pos };
}

/// `d`, `c` or `y` followed by a motion, or doubled (`dd`) for the line.
fn operatorMotion(ed: *Editor, c: u8) void {
    const st = &ed.vi;
    const op = st.operator;
    const n = @min(st.takeCount() * st.operator_count, max_count);
    st.operator = 0;
    st.operator_count = 1;

    const text = ed.buf.items;
    var start: usize = 0;
    var end: usize = text.len;
    if (c != op) {
        var motion_key = c;
        // `cw` on a word changes to the end of the word, keeping the blank.
        if (op == 'c' and (c == 'w' or c == 'W') and ed.cursor < text.len and class(text[ed.cursor], false) != 0) {
            motion_key = if (c == 'w') 'e' else 'E';
        }
        const m = motion(ed, motion_key, n, true) orelse return;
        start = @min(ed.cursor, m.target);
        end = @max(ed.cursor, m.target);
        if (m.inclusive) end = wcwidth.nextCluster(text, end);
    }

    switch (op) {
        'd' => ed.killRange(start, end, .forward, false),
        'c' => {
            ed.killRange(start, end, .forward, false);
            enterInsert(ed);
        },
        'y' => {
            if (end > start) ed.pushKill(text[start..end], .forward, false);
            ed.cursor = start;
        },
        else => {},
    }
}

// --- commands -------------------------------------------------------------------

fn put(ed: *Editor, n: usize, after: bool) void {
    const text = ed.lastKill() orelse return;
    if (after and ed.buf.items.len > 0) ed.moveRight();
    for (0..n) |_| ed.insertSlice(text);
    if (ed.cursor > 0) ed.moveLeft();
}

fn toggleCase(ed: *Editor, n: usize) void {
    const items = ed.buf.items;
    for (0..n) |_| {
        if (ed.cursor >= items.len) break;
        const next = wcwidth.nextCluster(items, ed.cursor);
        if (next == ed.cursor + 1) {
            const ch = items[ed.cursor];
            items[ed.cursor] = if (std.ascii.isUpper(ch)) std.ascii.toLower(ch) else std.ascii.toUpper(ch);
        }
        ed.cursor = next;
    }
}

/// `r`: replaces `n` characters with `replacement`; does nothing when fewer
/// than `n` characters follow the cursor, as in vi.
fn replaceChars(ed: *Editor, replacement: []const u8, n: usize) void {
    const items = ed.buf.items;
    var end = ed.cursor;
    for (0..n) |_| {
        if (end >= items.len) return;
        end = wcwidth.nextCluster(items, end);
    }
    const gpa = ed.sh.gpa;
    var repeated: std.ArrayList(u8) = .empty;
    defer repeated.deinit(gpa);
    for (0..n) |_| repeated.appendSlice(gpa, replacement) catch return;
    const start = ed.cursor;
    ed.replaceRange(start, end, repeated.items);
    ed.cursor = start + repeated.items.len - replacement.len;
}

fn searchKey(ed: *Editor, key: Key) void {
    const st = &ed.vi;
    const gpa = ed.sh.gpa;
    switch (key) {
        .byte => |b| switch (b) {
            '\r', '\n' => {
                const direction = st.searching.?;
                st.searching = null;
                if (st.query.items.len > 0) {
                    st.last_query.clearRetainingCapacity();
                    st.last_query.appendSlice(gpa, st.query.items) catch return;
                }
                st.last_search = direction;
                search(ed, direction, 1);
            },
            0x7f, 0x08 => {
                if (st.query.items.len == 0) {
                    st.searching = null;
                } else {
                    st.query.items.len = wcwidth.prevCluster(st.query.items, st.query.items.len);
                }
            },
            3, 7 => st.searching = null,
            else => if (b >= 0x20) st.query.append(gpa, b) catch {},
        },
        .utf8 => |sequence| st.query.appendSlice(gpa, sequence.bytes[0..sequence.len]) catch {},
        .escape => st.searching = null,
        else => {},
    }
}

/// `/` searches older history entries for the pattern, `?` newer ones.
fn search(ed: *Editor, direction: u8, n: usize) void {
    const pattern = ed.vi.last_query.items;
    if (pattern.len == 0) return;
    const hist = &ed.sh.hist;
    for (0..n) |_| {
        const count = hist.count();
        const from = ed.hist_index orelse count;
        var found: ?usize = null;
        if (direction == '/') {
            var i = from;
            while (i > 0) {
                i -= 1;
                if (std.mem.indexOf(u8, hist.get(i), pattern) != null) {
                    found = i;
                    break;
                }
            }
        } else {
            var i = from + 1;
            while (i < count) : (i += 1) {
                if (std.mem.indexOf(u8, hist.get(i), pattern) != null) {
                    found = i;
                    break;
                }
            }
        }
        ed.showHistoryEntry(found orelse return);
        ed.cursor = 0;
    }
}

// --- tests ------------------------------------------------------------------------

const testing = std.testing;
const Shell = @import("../shell.zig").Shell;

fn keys(ed: *Editor, sequence: []const u8) void {
    for (sequence) |b| {
        _ = ed.handleKey(if (b == 0x1b) .escape else .{ .byte = b });
    }
}

fn viEditor(sh: *Shell, text: []const u8) Editor {
    sh.options.vi = true;
    var ed = Editor.init(sh, -1, -1);
    ed.setLine(text);
    enterNormal(&ed);
    return ed;
}

test "vi motions with counts" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = viEditor(&sh, "git commit --amend -m msg");
    defer ed.deinit();

    keys(&ed, "0");
    try testing.expectEqual(@as(usize, 0), ed.cursor);
    keys(&ed, "w");
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    keys(&ed, "2w");
    try testing.expectEqual(@as(usize, 13), ed.cursor); // "amend": `--` is a word of its own
    keys(&ed, "W");
    try testing.expectEqual(@as(usize, 19), ed.cursor);
    keys(&ed, "b");
    try testing.expectEqual(@as(usize, 13), ed.cursor);
    keys(&ed, "B");
    try testing.expectEqual(@as(usize, 11), ed.cursor);
    keys(&ed, "e");
    try testing.expectEqual(@as(usize, 12), ed.cursor);
    keys(&ed, "e");
    try testing.expectEqual(@as(usize, 17), ed.cursor);
    keys(&ed, "E");
    try testing.expectEqual(@as(usize, 20), ed.cursor);
    keys(&ed, "$");
    try testing.expectEqual(ed.buf.items.len - 1, ed.cursor);
    keys(&ed, "^");
    try testing.expectEqual(@as(usize, 0), ed.cursor);
    keys(&ed, "3l");
    try testing.expectEqual(@as(usize, 3), ed.cursor);
    keys(&ed, "h");
    try testing.expectEqual(@as(usize, 2), ed.cursor);
}

test "vi operators delete, change and yank" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = viEditor(&sh, "one two three four");
    defer ed.deinit();

    keys(&ed, "0dw");
    try testing.expectEqualStrings("two three four", ed.buf.items);
    keys(&ed, "de");
    try testing.expectEqualStrings(" three four", ed.buf.items);
    keys(&ed, "x");
    try testing.expectEqualStrings("three four", ed.buf.items);
    keys(&ed, "$db");
    try testing.expectEqualStrings("three r", ed.buf.items);
    keys(&ed, "0d$");
    try testing.expectEqualStrings("", ed.buf.items);
    keys(&ed, "u");
    try testing.expectEqualStrings("three r", ed.buf.items);

    ed.setLine("alpha beta gamma");
    ed.cursor = 0;
    keys(&ed, "cwALPHA\x1b");
    try testing.expectEqualStrings("ALPHA beta gamma", ed.buf.items);
    try testing.expectEqual(Mode.normal, ed.vi.mode);
    keys(&ed, "wcbX\x1b");
    try testing.expectEqualStrings("Xbeta gamma", ed.buf.items);
    keys(&ed, "wce" ++ "G\x1b");
    try testing.expectEqualStrings("Xbeta G", ed.buf.items);
    keys(&ed, "0c$new\x1b");
    try testing.expectEqualStrings("new", ed.buf.items);
    keys(&ed, "ccfresh\x1b");
    try testing.expectEqualStrings("fresh", ed.buf.items);
    keys(&ed, "dd");
    try testing.expectEqualStrings("", ed.buf.items);
    keys(&ed, "p");
    try testing.expectEqualStrings("fresh", ed.buf.items);

    ed.setLine("ab cd");
    ed.cursor = 0;
    keys(&ed, "ywP");
    try testing.expectEqualStrings("ab ab cd", ed.buf.items);
    keys(&ed, "0d2w");
    try testing.expectEqualStrings("cd", ed.buf.items);
}

test "vi single-character commands" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = viEditor(&sh, "hello world");
    defer ed.deinit();

    keys(&ed, "0rJ");
    try testing.expectEqualStrings("Jello world", ed.buf.items);
    keys(&ed, "2~");
    try testing.expectEqualStrings("jEllo world", ed.buf.items);
    try testing.expectEqual(@as(usize, 2), ed.cursor);
    keys(&ed, "X");
    try testing.expectEqualStrings("jllo world", ed.buf.items);
    keys(&ed, "$x");
    try testing.expectEqualStrings("jllo worl", ed.buf.items);
    keys(&ed, "0D");
    try testing.expectEqualStrings("", ed.buf.items);

    ed.setLine("abc");
    ed.cursor = 1;
    keys(&ed, "sX\x1b");
    try testing.expectEqualStrings("aXc", ed.buf.items);
    keys(&ed, "C!\x1b");
    try testing.expectEqualStrings("a!", ed.buf.items);
    keys(&ed, "Sline\x1b");
    try testing.expectEqualStrings("line", ed.buf.items);
    keys(&ed, "I>\x1bA<\x1b");
    try testing.expectEqualStrings(">line<", ed.buf.items);
    keys(&ed, "0a+\x1b");
    try testing.expectEqualStrings(">+line<", ed.buf.items);
    keys(&ed, "0i-\x1b");
    try testing.expectEqualStrings("->+line<", ed.buf.items);
}

test "vi history movement and search" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "make build");
    try sh.hist.add(sh.gpa, "git status");
    try sh.hist.add(sh.gpa, "make test");

    var ed = viEditor(&sh, "");
    defer ed.deinit();

    keys(&ed, "k");
    try testing.expectEqualStrings("make test", ed.buf.items);
    keys(&ed, "2k");
    try testing.expectEqualStrings("make build", ed.buf.items);
    keys(&ed, "j");
    try testing.expectEqualStrings("git status", ed.buf.items);
    keys(&ed, "j");
    keys(&ed, "j");
    try testing.expectEqualStrings("", ed.buf.items);

    keys(&ed, "/make\r");
    try testing.expectEqualStrings("make test", ed.buf.items);
    try testing.expect(ed.vi.searching == null);
    keys(&ed, "n");
    try testing.expectEqualStrings("make build", ed.buf.items);
    keys(&ed, "N");
    try testing.expectEqualStrings("make test", ed.buf.items);
    keys(&ed, "?stat\r");
    try testing.expectEqualStrings("make test", ed.buf.items);
    keys(&ed, "/stat\r");
    try testing.expectEqualStrings("git status", ed.buf.items);

    // Enter in normal mode accepts the line.
    try testing.expectEqual(Outcome.accept, ed.handleKey(.{ .byte = '\r' }));
}
