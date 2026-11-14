//! The completion menu ("pager") that an ambiguous Tab opens below the
//! command line, fish-style.
//!
//! The editor owns one `Menu` while it is open and draws it as the last rows
//! of its frame, so every redraw repaints or erases it in place and nothing
//! reaches the scrollback. This file owns the menu's state, its keyboard
//! navigation helpers and the layout: candidates in as many columns as fit
//! the terminal (column-major, like `ls`), a height cap with a final
//! "…and N more" row, and truncation with "…" for cells wider than the
//! screen. The layout functions are pure so they can be tested directly.

const std = @import("std");
const wcwidth = @import("wcwidth.zig");
const complete = @import("complete.zig");

const Allocator = std.mem.Allocator;

/// One candidate. `text` is the replacement word as it goes into the line;
/// `label` is how the menu shows it. `description` is drawn dimmed after the
/// label when a completion source provides one (none do yet).
pub const Item = struct {
    text: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

/// Space between columns, and between a label and its description.
pub const gap = 2;
/// Most columns a layout uses; a cell is at least one column plus the gap.
pub const max_columns = 128;
/// The menu never takes fewer rows than this (screen permitting) nor more
/// than a third of the screen.
pub const min_rows = 4;

pub const Menu = struct {
    gpa: Allocator,
    arena: std.heap.ArenaAllocator,
    items: []Item,
    /// The buffer range that holds the word being completed: the typed word
    /// at first, then whichever candidate is selected.
    start: usize,
    end: usize,
    /// The word as typed, restored on Esc / Ctrl-G.
    original: []const u8,
    selected: ?usize = null,
    /// First item row shown when the list is taller than the menu.
    scroll: usize = 0,
    /// Item rows in the last layout, for Left / Right.
    rows: usize = 1,

    /// Copies `words` (completion results replacing `line[start..end]`)
    /// into a menu that owns them.
    pub fn init(gpa: Allocator, words: []const []const u8, line: []const u8, start: usize, end: usize) Allocator.Error!Menu {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();
        const items = try a.alloc(Item, words.len);
        const strip = dirPrefixLen(words);
        for (words, items) |word, *item| {
            const text = try a.dupe(u8, word);
            item.* = .{ .text = text, .label = try makeLabel(a, text, strip) };
        }
        return .{
            .gpa = gpa,
            .arena = arena,
            .items = items,
            .start = start,
            .end = end,
            .original = try a.dupe(u8, line[start..end]),
        };
    }

    pub fn deinit(self: *Menu) void {
        self.arena.deinit();
    }

    /// The item `step` places after (or before, when negative) the
    /// selection, wrapping around. With nothing selected yet, forward steps
    /// start at the first item and backward steps at the last.
    pub fn stepped(self: *const Menu, step: isize) usize {
        const n: isize = @intCast(self.items.len);
        const current: isize = if (self.selected) |s| @intCast(s) else if (step > 0) -1 else n;
        var next = current + step;
        if (step == 1 or step == -1) return @intCast(@mod(next, n));
        // A column step past either end moves to the first or last item
        // rather than wrapping into an unrelated row.
        if (next < 0) next = 0;
        if (next >= n) next = n - 1;
        return @intCast(next);
    }
};

/// Length of the directory part shared by every word (up to and including
/// its last `/`), which the labels leave out: `src/interactive/` completes
/// to `editor.zig`, `vi.zig`, ... as Bash shows file names.
fn dirPrefixLen(words: []const []const u8) usize {
    if (words.len == 0) return 0;
    const common = complete.commonPrefix(words);
    // A word that is itself a directory keeps its own trailing slash.
    var limit = common;
    for (words) |word| {
        if (word.len == common) limit = @min(limit, if (common > 0) common - 1 else 0);
    }
    const slash = std.mem.lastIndexOfScalar(u8, words[0][0..limit], '/') orelse return 0;
    return slash + 1;
}

/// The menu label for a replacement word: without the shared directory and
/// the trailing space, unquoted, with control characters shown as `?`.
fn makeLabel(arena: Allocator, word: []const u8, strip: usize) Allocator.Error![]const u8 {
    const trimmed = std.mem.trimEnd(u8, word[strip..], " ");
    const plain = try complete.dequote(arena, trimmed);
    for (plain) |c| {
        if (c < 0x20 or c == 0x7f) break;
    } else return plain;
    const copy = try arena.dupe(u8, plain);
    for (copy) |*c| {
        if (c.* < 0x20 or c.* == 0x7f) c.* = '?';
    }
    return copy;
}

/// Columns a cell needs: the label, and the description in parentheses.
pub fn cellWidth(item: Item) usize {
    var total = wcwidth.width(item.label);
    if (item.description.len > 0) total += gap + 2 + wcwidth.width(item.description);
    return total;
}

pub const Layout = struct {
    columns: usize,
    /// Rows the whole list needs.
    rows: usize,
    /// Width of each column, gap excluded, each at most the screen width.
    widths: [max_columns]usize,
};

/// Lays `cells` (display widths) out column-major in as many columns as fit
/// in `avail` columns of screen, with `gap` between columns.
pub fn layout(cells: []const usize, avail: usize) Layout {
    var result: Layout = .{ .columns = 1, .rows = cells.len, .widths = undefined };
    const n = cells.len;
    var widest: usize = 0;
    for (cells) |w| widest = @max(widest, w);
    result.widths[0] = @min(widest, avail);
    if (n <= 1) return result;

    var try_columns = @min(n, max_columns);
    while (try_columns > 1) : (try_columns -= 1) {
        const rows = (n + try_columns - 1) / try_columns;
        // Fewer columns may be needed for this row count; skip duplicates.
        const columns = (n + rows - 1) / rows;
        if (columns != try_columns) continue;
        var total: usize = gap * (columns - 1);
        var widths: [max_columns]usize = undefined;
        var fits = true;
        for (0..columns) |c| {
            var w: usize = 0;
            const first = c * rows;
            for (cells[first..@min(first + rows, n)]) |cell| w = @max(w, cell);
            widths[c] = w;
            total += w;
            if (total > avail) {
                fits = false;
                break;
            }
        }
        if (fits) {
            result.columns = columns;
            result.rows = rows;
            result.widths = widths;
            return result;
        }
    }
    return result;
}

/// Most rows the menu may use on a screen of `screen_rows` when the command
/// line already takes `command_rows`. Zero when there is no room at all.
pub fn maxRows(screen_rows: usize, command_rows: usize) usize {
    const third = @max(screen_rows / 3, min_rows);
    const room = if (screen_rows > command_rows) screen_rows - command_rows else 0;
    return @min(third, room);
}

pub const Window = struct {
    /// First item row shown.
    first: usize,
    /// Item rows shown.
    shown: usize,
    /// Whether a final "…and N more" row follows.
    more: bool,
};

/// Which item rows to show when the list needs `total` rows and the menu
/// may use `limit`, keeping `selected_row` in view and moving `scroll` as
/// little as possible.
pub fn window(total: usize, limit: usize, selected_row: ?usize, scroll: usize) Window {
    if (total <= limit) return .{ .first = 0, .shown = total, .more = false };
    if (limit <= 1) return .{ .first = 0, .shown = 0, .more = limit == 1 };
    const shown = limit - 1;
    var first = @min(scroll, total - shown);
    if (selected_row) |row| {
        if (row < first) first = row;
        if (row >= first + shown) first = row + 1 - shown;
    }
    return .{ .first = first, .shown = shown, .more = true };
}

/// The longest start of `text` that fits in `max` columns, and its width.
/// When `text` is cut, room is left for a trailing "…".
pub fn fit(text: []const u8, max: usize) struct { len: usize, width: usize, cut: bool } {
    const full = wcwidth.width(text);
    if (full <= max) return .{ .len = text.len, .width = full, .cut = false };
    if (max == 0) return .{ .len = 0, .width = 0, .cut = true };
    var i: usize = 0;
    var used: usize = 0;
    while (i < text.len) {
        const next = wcwidth.nextCluster(text, i);
        const w = wcwidth.width(text[i..next]);
        if (used + w > max - 1) break;
        used += w;
        i = next;
    }
    return .{ .len = i, .width = used, .cut = true };
}

pub const ellipsis = "…";
const reverse = "\x1b[7m";
const dim = "\x1b[2m";
const reset = "\x1b[0m";

/// Writes the menu rows, each preceded by "\r\n", for a screen `width`
/// columns wide and at most `limit` rows. Updates `menu.scroll` and
/// `menu.rows`. Returns the number of rows written.
pub fn draw(writer: *std.Io.Writer, menu: *Menu, width: usize, limit: usize) usize {
    if (menu.items.len == 0 or limit == 0 or width < 2) return 0;
    // One column spare: a row that ends exactly at the margin leaves the
    // terminal in its pending-wrap state, which differs between terminals.
    const avail = width - 1;
    const cells = menu.gpa.alloc(usize, menu.items.len) catch return 0;
    defer menu.gpa.free(cells);
    for (menu.items, cells) |item, *cell| cell.* = cellWidth(item);

    const lay = layout(cells, avail);
    menu.rows = lay.rows;
    const selected_row = if (menu.selected) |s| s % lay.rows else null;
    const win = window(lay.rows, limit, selected_row, menu.scroll);
    menu.scroll = win.first;

    var written: usize = 0;
    for (win.first..win.first + win.shown) |row| {
        writer.writeAll("\r\n") catch return written;
        written += 1;
        for (0..lay.columns) |column| {
            const index = column * lay.rows + row;
            if (index >= menu.items.len) break;
            if (column > 0) writer.splatByteAll(' ', gap) catch {};
            const last = column + 1 == lay.columns or index + lay.rows >= menu.items.len;
            drawCell(writer, menu.items[index], lay.widths[column], menu.selected == index, last);
        }
    }
    if (win.more) {
        writer.writeAll("\r\n") catch return written;
        written += 1;
        const hidden = menu.items.len - visibleCount(lay, win, menu.items.len);
        var text_buf: [64]u8 = undefined;
        const text = std.fmt.bufPrint(&text_buf, ellipsis ++ "and {d} more", .{hidden}) catch "";
        const shown = fit(text, avail);
        writer.writeAll(text[0..shown.len]) catch {};
    }
    return written;
}

fn visibleCount(lay: Layout, win: Window, n: usize) usize {
    var count: usize = 0;
    for (0..lay.columns) |column| {
        for (win.first..win.first + win.shown) |row| {
            if (column * lay.rows + row < n) count += 1;
        }
    }
    return count;
}

/// One cell, padded to `column_width` unless it is the last in its row.
fn drawCell(writer: *std.Io.Writer, item: Item, column_width: usize, selected: bool, last: bool) void {
    var used: usize = 0;
    const label = fit(item.label, column_width);
    if (selected) writer.writeAll(reverse) catch {};
    writer.writeAll(item.label[0..label.len]) catch {};
    used += label.width;
    if (label.cut) {
        writer.writeAll(ellipsis) catch {};
        used += 1;
    }
    if (selected) writer.writeAll(reset) catch {};
    // The description gets what is left, if that is enough to be useful.
    if (!label.cut and item.description.len > 0 and column_width >= used + gap + 4) {
        const room = column_width - used - gap - 2;
        const description = fit(item.description, room);
        writer.splatByteAll(' ', gap) catch {};
        writer.writeAll(dim) catch {};
        writer.writeAll("(") catch {};
        writer.writeAll(item.description[0..description.len]) catch {};
        if (description.cut) writer.writeAll(ellipsis) catch {};
        writer.writeAll(")") catch {};
        writer.writeAll(reset) catch {};
        used += gap + 2 + description.width + @intFromBool(description.cut);
    }
    if (!last and column_width > used) writer.splatByteAll(' ', column_width - used) catch {};
}

// --- tests --------------------------------------------------------------------------

const testing = std.testing;

test "layout fills as many columns as fit, column-major" {
    const cells = [_]usize{ 5, 7, 7, 3, 4 };
    // 5+2+7+2+... : three columns of two rows need 7 + 2 + 7 + 2 + 4 = 22.
    const wide = layout(&cells, 40);
    try testing.expectEqual(@as(usize, 5), wide.columns);
    try testing.expectEqual(@as(usize, 1), wide.rows);
    const mid = layout(&cells, 22);
    try testing.expectEqual(@as(usize, 3), mid.columns);
    try testing.expectEqual(@as(usize, 2), mid.rows);
    try testing.expectEqual(@as(usize, 7), mid.widths[0]);
    try testing.expectEqual(@as(usize, 7), mid.widths[1]);
    try testing.expectEqual(@as(usize, 4), mid.widths[2]);
    const narrow = layout(&cells, 8);
    try testing.expectEqual(@as(usize, 1), narrow.columns);
    try testing.expectEqual(@as(usize, 5), narrow.rows);
}

test "layout caps a single over-wide column at the screen width" {
    const cells = [_]usize{ 3, 90 };
    const lay = layout(&cells, 29);
    try testing.expectEqual(@as(usize, 1), lay.columns);
    try testing.expectEqual(@as(usize, 29), lay.widths[0]);
}

test "layout of no or one cell" {
    try testing.expectEqual(@as(usize, 0), layout(&.{}, 10).rows);
    const one = layout(&.{4}, 10);
    try testing.expectEqual(@as(usize, 1), one.rows);
    try testing.expectEqual(@as(usize, 4), one.widths[0]);
}

test "window keeps the selection in view with a more row" {
    try testing.expectEqual(Window{ .first = 0, .shown = 3, .more = false }, window(3, 5, null, 0));
    try testing.expectEqual(Window{ .first = 0, .shown = 4, .more = true }, window(10, 5, 2, 0));
    try testing.expectEqual(Window{ .first = 3, .shown = 4, .more = true }, window(10, 5, 6, 0));
    try testing.expectEqual(Window{ .first = 3, .shown = 4, .more = true }, window(10, 5, 4, 3));
    try testing.expectEqual(Window{ .first = 1, .shown = 4, .more = true }, window(10, 5, 1, 3));
    try testing.expectEqual(Window{ .first = 6, .shown = 4, .more = true }, window(10, 5, null, 50));
    try testing.expectEqual(Window{ .first = 0, .shown = 0, .more = true }, window(10, 1, 3, 0));
}

test "maxRows takes a third of the screen, at least a few rows" {
    try testing.expectEqual(@as(usize, 8), maxRows(24, 1));
    try testing.expectEqual(@as(usize, 4), maxRows(9, 1));
    try testing.expectEqual(@as(usize, 2), maxRows(9, 7));
    try testing.expectEqual(@as(usize, 0), maxRows(5, 9));
}

test "fit cuts on character boundaries and leaves room for the ellipsis" {
    const whole = fit("abc", 3);
    try testing.expect(!whole.cut);
    try testing.expectEqual(@as(usize, 3), whole.len);
    const cut = fit("abcdef", 4);
    try testing.expect(cut.cut);
    try testing.expectEqual(@as(usize, 3), cut.len);
    // "é" is two bytes, one column; "界" is three bytes, two columns.
    const accented = fit("été!", 3);
    try testing.expectEqual(@as(usize, 3), accented.len);
    try testing.expectEqual(@as(usize, 2), accented.width);
    const wide = fit("界界界", 4);
    try testing.expectEqual(@as(usize, 3), wide.len);
    try testing.expectEqual(@as(usize, 2), wide.width);
}

test "labels drop the shared directory, trailing space and quoting" {
    var menu = try Menu.init(testing.allocator, &.{ "src/my\\ file ", "src/dir/", "src/a\x01b " }, "x src/", 2, 6);
    defer menu.deinit();
    try testing.expectEqualStrings("my file", menu.items[0].label);
    try testing.expectEqualStrings("dir/", menu.items[1].label);
    try testing.expectEqualStrings("a?b", menu.items[2].label);
    try testing.expectEqualStrings("src/my\\ file ", menu.items[0].text);
    try testing.expectEqualStrings("src/", menu.original);

    var dirs = try Menu.init(testing.allocator, &.{ "src/", "src/x/" }, "src", 0, 3);
    defer dirs.deinit();
    try testing.expectEqualStrings("src/", dirs.items[0].label);
}

test "stepping wraps and column steps clamp" {
    var menu = try Menu.init(testing.allocator, &.{ "a", "b", "c", "d", "e" }, "", 0, 0);
    defer menu.deinit();
    try testing.expectEqual(@as(usize, 0), menu.stepped(1));
    try testing.expectEqual(@as(usize, 4), menu.stepped(-1));
    menu.selected = 4;
    try testing.expectEqual(@as(usize, 0), menu.stepped(1));
    try testing.expectEqual(@as(usize, 4), menu.stepped(3));
    menu.selected = 1;
    try testing.expectEqual(@as(usize, 0), menu.stepped(-3));
}

test "draw highlights the selection and counts hidden items" {
    var words: [20][]const u8 = undefined;
    var names: [20][8]u8 = undefined;
    for (&words, &names, 0..) |*w, *buf, i| w.* = std.fmt.bufPrint(buf, "item{d:0>2}", .{i}) catch unreachable;
    var menu = try Menu.init(testing.allocator, &words, "", 0, 0);
    defer menu.deinit();
    menu.selected = 1;
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Width 14 fits one column, so 20 rows; four rows are allowed.
    const rows = draw(&out.writer, &menu, 14, 4);
    try testing.expectEqual(@as(usize, 4), rows);
    try testing.expectEqualStrings("\r\nitem00\r\n\x1b[7mitem01\x1b[0m\r\nitem02\r\n…and 17 more", out.written());
}

test "draw shows descriptions when there is room" {
    var menu = try Menu.init(testing.allocator, &.{ "ab", "cd" }, "", 0, 0);
    defer menu.deinit();
    menu.items[0].description = "first";
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    _ = draw(&out.writer, &menu, 10, 4);
    try testing.expectEqualStrings("\r\nab  \x1b[2m(fi…)\x1b[0m\r\ncd", out.written());
}
