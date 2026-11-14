//! Interactive line editor: cursor movement, history, tab completion,
//! autosuggestions, syntax highlighting, a kill ring with undo, bracketed
//! paste and an optional vi mode.
//!
//! Rendering is a full-line redraw. The editor tracks how many terminal rows the
//! previous frame occupied, moves back to the start of the input, clears, and
//! repaints — then walks the cursor to its logical position. That keeps wrapped
//! lines and long histories correct without incremental-diff bookkeeping.
//! Positions come from `layout`, which wraps exactly as the terminal does, and
//! a frame taller than the screen is drawn as a screen-high window around the
//! cursor. Up and Down use the same layout to move by screen row.
//!
//! The buffer is UTF-8. Every cursor movement and deletion steps over whole
//! characters (a code point plus its combining marks), and widths come from
//! `wcwidth.zig`, so wide and combining characters wrap and place the cursor
//! correctly. Control characters are drawn in caret notation (`^I`).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const shellmod = @import("../shell.zig");
const term = @import("term.zig");
const proc = @import("../proc.zig");
const highlight = @import("highlight.zig");
const complete = @import("complete.zig");
const wcwidth = @import("wcwidth.zig");
const histexpand = @import("histexpand.zig");
const vi = @import("vi.zig");
const bindings = @import("bindings.zig");
const pager = @import("pager.zig");

const Shell = shellmod.Shell;
pub const IsComplete = *const fn ([]const u8) bool;
pub const WriteContinuationPrompt = *const fn (*std.Io.Writer, *Shell, usize) anyerror!void;

pub const Key = union(enum) {
    eof,
    byte: u8,
    /// A complete multi-byte UTF-8 sequence.
    utf8: struct { bytes: [4]u8, len: u3 },
    /// A byte to insert as-is, read after Ctrl-V.
    literal: u8,
    escape,
    alt: u8,
    up,
    down,
    left,
    right,
    home,
    end,
    delete,
    word_left,
    word_right,
    page_up,
    page_down,
    paste_start,
    /// Shift-Tab (`CSI Z`).
    back_tab,
    resize,
    unknown,
};

pub const Outcome = enum { handled, accept, cancel, eof };

/// What the previous key did; consecutive kills append to one kill-ring
/// entry, Alt-Y only follows a yank, and typed characters undo as a group.
pub const Command = enum { other, insert, kill, yank, yank_arg, undo, vertical };

const kill_ring_max = 16;
/// The fewest screen rows the completion menu opens on: one for the
/// cursor's row and the rest for the menu.
const menu_screen_min = 4;
const undo_max = 256;

/// Display width of `text` in terminal columns, ignoring ANSI escape
/// sequences and other control bytes. Used for prompts and hints, which are
/// written to the terminal as they are.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i = escapeEnd(text, i);
            continue;
        }
        const decoded = wcwidth.decodeAt(text, i);
        i += decoded.len;
        if (decoded.cp < 0x20 or decoded.cp == 0x7f) continue;
        width += wcwidth.codepointWidth(decoded.cp);
    }
    return width;
}

/// Index after the escape sequence starting at `text[i] == ESC`: CSI
/// (`ESC [ ... final`), OSC (`ESC ] ... BEL` or `ESC ] ... ESC \`), or a
/// two-byte escape.
fn escapeEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= text.len) return i;
    switch (text[i]) {
        '[' => {
            i += 1;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            return @min(i + 1, text.len);
        },
        ']' => {
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) return i + 1;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
            }
            return text.len;
        },
        else => return i + 1,
    }
}

fn isControl(c: u8) bool {
    return c < 0x20 or c == 0x7f;
}

/// A spot in a frame, in rows below the first prompt row and columns. `col
/// == width` is a row filled to the right margin: the terminal keeps the
/// cursor on the last column until the next character wraps it.
pub const Pos = struct {
    row: usize = 0,
    col: usize = 0,

    /// Where a character `w` columns wide starts from here. One that does
    /// not fit wraps whole to the next row, so a wide character at the
    /// margin leaves the last column empty, as terminals draw it.
    fn place(self: Pos, w: usize, width: usize) Pos {
        if (self.col > 0 and self.col + w > width) return .{ .row = self.row + 1 };
        return self;
    }

    /// The pending wrap made real: a full row ends on the next row's first
    /// column, where the frame puts the cursor and the next line.
    fn settled(self: Pos, width: usize) Pos {
        if (self.col >= width) return .{ .row = self.row + 1 };
        return self;
    }
};

/// How text is measured. A prompt is written as it is, so escape sequences
/// and control bytes take no room; buffer text is drawn with each control
/// character in caret notation, two one-column characters.
const Measure = enum { prompt, buffer };

/// One step of `layout`: the character at `text[i]` drawn from `pos`.
const Step = struct { pos: Pos, next: usize };

fn layoutStep(pos: Pos, text: []const u8, i: usize, width: usize, measure: Measure) Step {
    const c = text[i];
    if (isControl(c)) {
        if (measure == .prompt) {
            return .{ .pos = pos, .next = if (c == 0x1b) escapeEnd(text, i) else i + 1 };
        }
        // `^` and the letter wrap independently, like any two characters.
        var at = pos.place(1, width);
        at.col += 1;
        at = at.place(1, width);
        at.col += 1;
        return .{ .pos = at, .next = i + 1 };
    }
    const next = wcwidth.nextCluster(text, i);
    const w = wcwidth.width(text[i..next]);
    if (w == 0) return .{ .pos = pos, .next = next };
    var at = pos.place(w, width);
    at.col += w;
    return .{ .pos = at, .next = next };
}

/// Where drawing `text` from `start` leaves the cursor on a terminal
/// `width` columns wide.
fn layout(start: Pos, text: []const u8, width: usize, measure: Measure) Pos {
    var pos = start;
    var i: usize = 0;
    while (i < text.len) {
        const step = layoutStep(pos, text, i, width, measure);
        pos = step.pos;
        i = step.next;
    }
    return pos;
}

/// Where the cursor shows in front of `text[i]` (buffer text) when the
/// text before it ends at `before`: on the character's cell, which for a
/// character that wraps is the next row, or after the end of the line.
fn cursorCell(before: Pos, text: []const u8, i: usize, width: usize) Pos {
    if (i < text.len and text[i] != '\n') {
        const w = if (isControl(text[i])) 1 else wcwidth.width(text[i..wcwidth.nextCluster(text, i)]);
        if (w > 0) return before.place(w, width);
    }
    return before.settled(width);
}

/// Copies a frame to `out`, keeping only rows `first..last` (inclusive) of
/// the layout. Escape sequences are always copied so colours stay right;
/// the line breaks and characters outside the window are dropped, so the
/// window is drawn from the current cursor row without scrolling past the
/// bottom of the screen.
fn writeRows(out: *std.Io.Writer, frame: []const u8, width: usize, first: usize, last: usize) void {
    var pos: Pos = .{};
    var i: usize = 0;
    while (i < frame.len) {
        const c = frame[i];
        if (c == 0x1b) {
            const end = escapeEnd(frame, i);
            out.writeAll(frame[i..end]) catch {};
            i = end;
            continue;
        }
        if (c == '\r') {
            pos.col = 0;
            if (pos.row >= first and pos.row <= last) out.writeByte('\r') catch {};
            i += 1;
            continue;
        }
        if (c == '\n') {
            if (pos.row >= first and pos.row < last) out.writeByte('\n') catch {};
            pos = .{ .row = pos.row + 1 };
            i += 1;
            continue;
        }
        // A character ends on the row it was drawn on.
        const step = layoutStep(pos, frame, i, width, .prompt);
        if (step.pos.row >= first and step.pos.row <= last) out.writeAll(frame[i..step.next]) catch {};
        pos = step.pos;
        i = step.next;
    }
}

/// The row the cursor is on, counted from the top of `drawn` (the bytes of
/// a frame drawn `old_width` columns wide, with the cursor left at
/// `cursor`), after a terminal that reflows on resize re-wraps it at
/// `new_width`: each logical line (text between line feeds, joined across
/// its wrapped rows) takes as many rows as its width needs, and the cursor
/// keeps its place in its line. VTE, kitty, iTerm2 and Windows Terminal
/// reflow like this; xterm leaves the rows as they were.
fn reflowedCursorRow(drawn: []const u8, old_width: usize, new_width: usize, cursor: Pos) usize {
    const new_w = @max(new_width, 1);
    var pos: Pos = .{};
    var line_top: usize = 0;
    var line_cols: usize = 0;
    var rows_before: usize = 0;
    var i: usize = 0;
    while (true) {
        const at_end = i >= drawn.len;
        if (at_end or drawn[i] == '\n') {
            // The cursor is on this line when the next one starts below it.
            if (at_end or pos.row >= cursor.row) {
                const offset = (cursor.row -| line_top) * old_width + cursor.col;
                return rows_before + offset / new_w;
            }
            rows_before += @max((line_cols + new_w - 1) / new_w, 1);
            pos = .{ .row = pos.row + 1 };
            line_top = pos.row;
            line_cols = 0;
            i += 1;
            continue;
        }
        if (drawn[i] == '\r') {
            pos.col = 0;
            i += 1;
            continue;
        }
        const step = layoutStep(pos, drawn, i, old_width, .prompt);
        pos = step.pos;
        i = step.next;
        line_cols = @max(line_cols, (pos.row - line_top) * old_width + pos.col);
    }
}

/// Word characters for the readline word commands (Alt-F/B/D, Alt-U/L/C):
/// letters and digits, and every byte of a multi-byte character.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

/// How deeply the next line of a multi-line command nests, for the indent of
/// its continuation prompt: brackets and `then`/`do` blocks the lines so far
/// left open. Quotes and comments are skipped. It is an estimate for display,
/// not a parse, and never goes below zero.
const Nesting = struct {
    depth: usize = 0,
    /// The quote of a string still open at the end of the last line.
    quote: u8 = 0,

    fn feed(self: *Nesting, line: []const u8) void {
        var i: usize = 0;
        while (i < line.len) {
            const c = line[i];
            if (self.quote != 0) {
                if (c == '\\' and self.quote == '"') {
                    i += 2;
                    continue;
                }
                if (c == self.quote) self.quote = 0;
                i += 1;
                continue;
            }
            const word_start = i == 0 or isSeparator(line[i - 1]);
            switch (c) {
                '\\' => {
                    i += 2;
                    continue;
                },
                '\'', '"' => self.quote = c,
                '#' => if (word_start) return,
                '{', '(' => self.depth += 1,
                '}', ')' => self.depth -|= 1,
                'a'...'z' => if (word_start) {
                    var end = i;
                    while (end < line.len and std.ascii.isAlphanumeric(line[end])) end += 1;
                    if (end == line.len or isSeparator(line[end])) {
                        const word = line[i..end];
                        if (std.mem.eql(u8, word, "then") or std.mem.eql(u8, word, "do")) self.depth += 1;
                        if (std.mem.eql(u8, word, "fi") or std.mem.eql(u8, word, "done")) self.depth -|= 1;
                    }
                    i = end;
                    continue;
                },
                else => {},
            }
            i += 1;
        }
    }

    fn isSeparator(c: u8) bool {
        return isBlank(c) or c == ';' or c == '&' or c == '|' or c == '(' or c == ')';
    }
};

pub const Editor = struct {
    sh: *Shell,
    in_fd: i32,
    out_fd: i32,
    buf: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    /// Index into history while browsing; null means "editing a new line".
    hist_index: ?usize = null,
    /// The in-progress line, stashed when history browsing begins.
    stashed: std.ArrayList(u8) = .empty,
    width: usize = 80,
    height: usize = 24,
    /// The first frame row on screen when the frame is taller than the
    /// screen; kept between frames so the window only scrolls as needed.
    view_top: usize = 0,
    /// Scratch buffers reused between frames.
    body: std.Io.Writer.Allocating,
    frame: std.Io.Writer.Allocating,
    visible_scratch: std.ArrayList(u8) = .empty,
    command_frame_active: bool = false,
    command_cursor_row: usize = 0,
    command_end_row: usize = 0,
    /// How the frame on screen was drawn, for a redraw after a resize: the
    /// width, whether `body` (a window of rows) or `frame` holds the bytes,
    /// and the cursor's cell counted from the top of what was drawn.
    drawn_width: usize = 0,
    drawn_window: bool = false,
    drawn_cursor: Pos = .{},
    /// The frame ends on a row of its own below its last line (that line
    /// filled its last row), so output after the frame starts right there.
    end_fresh: bool = false,
    /// The screen column Up / Down and vi j / k aim for, kept across a run
    /// of vertical moves so a short row on the way does not lose it, as vim
    /// does; `goal_at` is where the last vertical move left the cursor.
    goal_col: ?usize = null,
    goal_at: usize = 0,
    /// Set when the last line was cancelled with Ctrl-C.
    interrupted: bool = false,
    /// Set when `term.wake_fd` ended the last edit. The line is kept, and
    /// the next edit resumes it with the same cursor.
    woken: bool = false,

    prompt_text: []const u8 = "",
    /// The lines of a multi-line prompt before its last line. They are
    /// printed once, before editing starts, and again after Ctrl-L clears
    /// the screen.
    prompt_head: []const u8 = "",
    write_continuation: ?WriteContinuationPrompt = null,
    /// False for the final frame of a submitted line, which drops hints.
    hints: bool = true,
    /// Raw mode of the line being edited, so Ctrl-X Ctrl-E can leave it.
    raw: ?*term.RawMode = null,
    /// A byte read ahead while decoding a key.
    pending_byte: ?u8 = null,

    last: Command = .other,
    this_command: Command = .other,
    kill_ring: std.ArrayList([]u8) = .empty,
    yank_index: usize = 0,
    yank_start: usize = 0,
    yank_end: usize = 0,
    last_arg_index: usize = 0,
    last_arg_start: usize = 0,
    last_arg_end: usize = 0,
    undo_stack: std.ArrayList(Snapshot) = .empty,
    /// The buffer as it was before the current key, for undo.
    before: std.ArrayList(u8) = .empty,
    ctrl_x: bool = false,
    quoted_insert: bool = false,
    vi: vi.State = .{},
    /// The completion menu an ambiguous Tab opened, drawn below the line.
    menu: ?pager.Menu = null,

    const Snapshot = struct { text: []u8, cursor: usize };

    pub fn init(sh: *Shell, in_fd: i32, out_fd: i32) Editor {
        return .{
            .sh = sh,
            .in_fd = in_fd,
            .out_fd = out_fd,
            .body = .init(sh.gpa),
            .frame = .init(sh.gpa),
        };
    }

    pub fn deinit(self: *Editor) void {
        const gpa = self.sh.gpa;
        self.buf.deinit(gpa);
        self.stashed.deinit(gpa);
        self.body.deinit();
        self.frame.deinit();
        self.visible_scratch.deinit(gpa);
        for (self.kill_ring.items) |entry| gpa.free(entry);
        self.kill_ring.deinit(gpa);
        self.clearUndo();
        self.undo_stack.deinit(gpa);
        self.before.deinit(gpa);
        self.vi.deinit(gpa);
        self.closeMenu();
    }

    fn resetLine(self: *Editor) void {
        self.closeMenu();
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.stashed.clearRetainingCapacity();
        self.interrupted = false;
        self.command_frame_active = false;
        self.command_cursor_row = 0;
        self.command_end_row = 0;
        self.view_top = 0;
        self.hints = true;
        self.goal_col = null;
        self.pending_byte = null;
        self.last = .other;
        self.ctrl_x = false;
        self.quoted_insert = false;
        self.clearUndo();
        self.vi.reset();
    }

    /// Reads one line, with editing when stdin is a terminal. Returns null at
    /// end of input. The slice stays valid until the next call.
    pub fn readLine(self: *Editor, prompt_text: []const u8) ?[]const u8 {
        return self.edit(prompt_text, null, null);
    }

    /// Reads a whole command, continuing on further lines while `is_complete`
    /// says the input is unfinished.
    pub fn readCommand(
        self: *Editor,
        prompt_text: []const u8,
        is_complete: IsComplete,
        write_continuation: WriteContinuationPrompt,
    ) ?[]const u8 {
        return self.edit(prompt_text, is_complete, write_continuation);
    }

    fn edit(
        self: *Editor,
        prompt_text: []const u8,
        is_complete: ?IsComplete,
        write_continuation: ?WriteContinuationPrompt,
    ) ?[]const u8 {
        const gpa = self.sh.gpa;
        var kept: std.ArrayList(u8) = .empty;
        defer kept.deinit(gpa);
        const kept_cursor = self.cursor;
        const kept_vi = self.vi;
        const resuming = self.woken;
        self.woken = false;
        if (resuming) kept.appendSlice(gpa, self.buf.items) catch {};
        self.resetLine();
        if (resuming) {
            // The same line, cursor and vi mode the request interrupted.
            self.buf.appendSlice(gpa, kept.items) catch {};
            self.cursor = @min(kept_cursor, self.buf.items.len);
            self.vi = kept_vi;
        }
        self.prompt_text = prompt_text;
        self.write_continuation = write_continuation;
        // The head belongs to this prompt only; `read -e` has none.
        defer self.prompt_head = "";

        if (self.isDumbTerminal() and sys.isTty(self.in_fd)) return self.readDumb(is_complete);
        var raw = term.RawMode.enable(self.in_fd) orelse return self.readPlain(is_complete);
        self.raw = &raw;
        defer {
            self.raw = null;
            raw.disable();
        }
        self.write(term.paste_on);
        defer self.write(term.paste_off);
        term.watchResize(true);
        defer term.watchResize(false);

        self.updateWidth();
        self.render();

        while (true) {
            if (term.takeResize()) {
                self.updateWidth();
                self.render();
            }
            const key = self.nextKey();
            switch (self.handleKey(key)) {
                .handled => {},
                .accept => {
                    self.cursor = self.buf.items.len;
                    self.hints = false;
                    self.render();
                    self.hints = true;
                    // A line that filled the last row already moved the
                    // cursor to a fresh row; another newline would leave a
                    // blank line before the output.
                    const below: usize = if (self.end_fresh) 0 else 1;
                    if (below == 1) self.write("\r\n");
                    if (is_complete) |check| {
                        if (!check(self.buf.items)) {
                            // Each continuation line starts in vi insert mode.
                            self.vi.reset();
                            self.buf.append(self.sh.gpa, '\n') catch return null;
                            self.cursor = self.buf.items.len;
                            self.hist_index = null;
                            self.command_cursor_row = self.command_end_row + below;
                            self.command_frame_active = true;
                            self.render();
                            continue;
                        }
                    }
                    return self.buf.items;
                },
                .cancel => return self.buf.items,
                .eof => return null,
            }
            self.render();
        }
    }

    fn nextKey(self: *Editor) Key {
        if (self.quoted_insert) {
            self.quoted_insert = false;
            const b = self.readRawByte() orelse return .eof;
            return .{ .literal = b };
        }
        return self.readKey();
    }

    fn isDumbTerminal(self: *Editor) bool {
        const value = self.sh.getEnv("TERM") orelse return false;
        return std.mem.eql(u8, value, "dumb");
    }

    /// TERM=dumb: the terminal (or Emacs, or `script`) does the line editing,
    /// so read cooked lines and print the prompts without escape sequences.
    fn readDumb(self: *Editor, is_complete: ?IsComplete) ?[]const u8 {
        self.writeStripped(self.prompt_text);
        var line_index: usize = 0;
        while (true) {
            const line_start = self.buf.items.len;
            while (true) {
                const byte = self.readRawByte() orelse {
                    if (self.buf.items.len == 0) return null;
                    self.cursor = self.buf.items.len;
                    return self.buf.items;
                };
                if (byte == '\n') break;
                self.buf.append(self.sh.gpa, byte) catch return null;
            }
            if (self.buf.items.len > line_start and self.buf.items[self.buf.items.len - 1] == '\r') {
                self.buf.items.len -= 1;
            }
            self.cursor = self.buf.items.len;
            const check = is_complete orelse return self.buf.items;
            if (check(self.buf.items)) return self.buf.items;
            self.buf.append(self.sh.gpa, '\n') catch return null;
            line_index += 1;
            if (self.write_continuation) |write_prompt| {
                var continuation: std.Io.Writer.Allocating = .init(self.sh.gpa);
                defer continuation.deinit();
                write_prompt(&continuation.writer, self.sh, line_index) catch {};
                self.writeStripped(continuation.writer.buffered());
            }
        }
    }

    fn writeStripped(self: *Editor, text: []const u8) void {
        var start: usize = 0;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] != 0x1b) {
                i += 1;
                continue;
            }
            self.write(text[start..i]);
            i = escapeEnd(text, i);
            start = i;
        }
        self.write(text[start..]);
    }

    /// Fallback for a non-terminal stdin: plain line reading, no editing.
    fn readPlain(self: *Editor, is_complete: ?IsComplete) ?[]const u8 {
        while (true) {
            const line_start = self.buf.items.len;
            while (true) {
                const byte = self.readRawByte() orelse {
                    if (self.buf.items.len == 0) return null;
                    self.cursor = self.buf.items.len;
                    return self.buf.items;
                };
                if (byte == '\n') break;
                self.buf.append(self.sh.gpa, byte) catch return null;
            }
            if (self.buf.items.len > line_start and self.buf.items[self.buf.items.len - 1] == '\r') {
                self.buf.items.len -= 1;
            }
            self.cursor = self.buf.items.len;
            const check = is_complete orelse return self.buf.items;
            if (check(self.buf.items)) return self.buf.items;
            self.buf.append(self.sh.gpa, '\n') catch return null;
        }
    }

    // --- key dispatch -------------------------------------------------------

    /// Applies one key to the line. Separate from the read loop so the editing
    /// logic can be driven directly.
    pub fn handleKey(self: *Editor, key: Key) Outcome {
        if (key == .resize) {
            self.updateWidth();
            return .handled;
        }
        // A session request ended the key wait: leave the line exactly as it
        // is (vi's normal mode would otherwise treat the end as a key).
        if (key == .eof and self.woken) {
            if (self.menu != null) _ = self.dismissMenu();
            return .eof;
        }
        self.before.clearRetainingCapacity();
        self.before.appendSlice(self.sh.gpa, self.buf.items) catch {};
        const before_cursor = self.cursor;
        self.this_command = .other;

        const outcome = if (self.menu != null and self.handleMenuKey(key))
            .handled
        else if (self.sh.options.vi and self.vi.mode == .normal)
            vi.handleNormal(self, key)
        else
            self.handleInsertKey(key);

        self.recordUndo(before_cursor);
        // Any other move or an edit ends the run of vertical moves.
        if (self.this_command == .vertical) {
            self.goal_at = self.cursor;
        } else if (self.cursor != self.goal_at or !std.mem.eql(u8, self.before.items, self.buf.items)) {
            self.goal_col = null;
        }
        self.last = self.this_command;
        return outcome;
    }

    fn handleInsertKey(self: *Editor, key: Key) Outcome {
        if (self.ctrl_x) {
            self.ctrl_x = false;
            switch (key) {
                .byte => |b| switch (b) {
                    0x15 => self.undo(), // Ctrl-X Ctrl-U
                    0x05 => return self.editInEditor(), // Ctrl-X Ctrl-E
                    else => {},
                },
                else => {},
            }
            return .handled;
        }

        const chord: ?bindings.Chord = switch (key) {
            .byte => |b| .{ .byte = b },
            .alt => |c| .{ .meta = true, .byte = c },
            else => null,
        };
        if (chord) |c| {
            if (bindings.lookup(c)) |target| return self.runBinding(target, key);
        }

        switch (key) {
            // The terminal is gone or the shell got SIGHUP: no more keys will
            // come, even with text on the line (Ctrl-D arrives as a byte).
            .eof => {
                // A wake keeps the line on screen; the next edit redraws it.
                if (!self.woken) self.write("\r\n");
                return .eof;
            },
            .byte => |b| return self.handleControlOrByte(b),
            .utf8 => |sequence| {
                self.insertSlice(sequence.bytes[0..sequence.len]);
                self.this_command = .insert;
            },
            .literal => |b| {
                self.insertSlice(&.{b});
                self.this_command = .insert;
            },
            .escape => if (self.sh.options.vi) vi.enterNormal(self),
            // In vi mode a quick Esc-key pair is Esc followed by a command.
            .alt => |c| if (self.sh.options.vi) {
                vi.enterNormal(self);
                return vi.handleNormal(self, .{ .byte = c });
            } else switch (c) {
                'b', 'B' => self.moveWordLeft(),
                'f', 'F' => self.moveWordRight(),
                'd', 'D' => self.killWordForward(),
                0x7f, 0x08 => self.killWordBackward(),
                'y', 'Y' => self.yankPop(),
                '.', '_' => self.yankLastArg(),
                'u', 'U' => self.changeWordCase(.upper),
                'l', 'L' => self.changeWordCase(.lower),
                'c', 'C' => self.changeWordCase(.capital),
                // Alt-Enter: a new line at the cursor, without running the
                // command, as fish does.
                '\r', '\n' => {
                    self.insertSlice("\n");
                    self.this_command = .insert;
                },
                else => {},
            },
            .left => self.moveLeft(),
            .right => self.acceptSuggestionOrMoveRight(),
            .home => self.moveLineStart(),
            .end => self.moveLineEnd(),
            .delete => self.deleteAtCursor(),
            .word_left => self.moveWordLeft(),
            .word_right => self.moveWordRight(),
            .up => self.moveVertical(-1),
            .down => self.moveVertical(1),
            .paste_start => self.readPaste(),
            .page_up, .page_down, .back_tab, .resize, .unknown => {},
        }
        return .handled;
    }

    /// A key rebound with `bind`.
    fn runBinding(self: *Editor, target: bindings.Target, key: Key) Outcome {
        switch (target) {
            .unbound => return .handled,
            .function => |function| return self.runFunction(function, key),
            .command => |text| {
                self.runBoundCommand(text);
                return .handled;
            },
        }
    }

    fn runFunction(self: *Editor, function: bindings.Function, key: Key) Outcome {
        switch (function) {
            .accept_line => return .accept,
            .abort => {},
            .backward_char => self.moveLeft(),
            .backward_delete_char => self.deleteBefore(),
            .backward_kill_word => self.killWordBackward(),
            .backward_word => self.moveWordLeft(),
            .beginning_of_line => self.moveLineStart(),
            .capitalize_word => self.changeWordCase(.capital),
            .clear_screen => self.clearScreen(),
            .complete => self.handleTab(),
            .delete_char => self.deleteAtCursor(),
            .downcase_word => self.changeWordCase(.lower),
            .end_of_line => self.moveLineEnd(),
            .forward_char => self.moveRight(),
            .forward_word => self.moveWordRight(),
            .kill_line => self.killLine(),
            .kill_word => self.killWordForward(),
            .next_history => self.historyNext(),
            .previous_history => self.historyPrev(),
            .reverse_search_history => self.reverseSearch(),
            .self_insert => switch (key) {
                .byte => |b| if (b >= 0x20 and b != 0x7f) {
                    self.insertSlice(&.{b});
                    self.this_command = .insert;
                },
                .alt => |c| if (c >= 0x20 and c != 0x7f) {
                    self.insertSlice(&.{c});
                    self.this_command = .insert;
                },
                else => {},
            },
            .transpose_chars => self.transpose(),
            .undo => self.undo(),
            .unix_line_discard => self.killLineBackward(),
            .unix_word_rubout => self.killWordBackwardUnix(),
            .upcase_word => self.changeWordCase(.upper),
            .yank => self.yank(),
            .yank_last_arg => self.yankLastArg(),
            .yank_pop => self.yankPop(),
        }
        return .handled;
    }

    /// `bind -x`: runs a shell command with the line in `READLINE_LINE` and
    /// the cursor in `READLINE_POINT`, then takes both back.
    fn runBoundCommand(self: *Editor, command: []const u8) void {
        const runner = self.sh.trap_runner orelse return;
        const sh = self.sh;
        var cursor_text: [24]u8 = undefined;
        const point = std.fmt.bufPrint(&cursor_text, "{d}", .{self.cursor}) catch return;
        sh.setVar("READLINE_LINE", .{ .string = self.buf.items }) catch return;
        sh.setVar("READLINE_POINT", .{ .string = point }) catch return;

        self.leaveFrame();
        self.write(term.paste_off);
        if (self.raw) |raw| raw.disable();
        const saved_status = sh.last_status;
        _ = runner(sh, command, 1);
        sh.last_status = saved_status;
        if (self.raw) |raw| {
            if (term.RawMode.enable(self.in_fd)) |again| raw.* = again;
        }
        self.write(term.paste_on);

        if (sh.getVar("READLINE_LINE")) |line| {
            if (std.meta.activeTag(line) == .string) self.setLine(line.string);
        }
        if (sh.getVar("READLINE_POINT")) |position| {
            if (position.asInt()) |n| {
                if (n >= 0) self.cursor = @min(@as(usize, @intCast(n)), self.buf.items.len);
            }
        }
        _ = sh.unsetVar("READLINE_LINE");
        _ = sh.unsetVar("READLINE_POINT");
    }

    fn handleControlOrByte(self: *Editor, b: u8) Outcome {
        switch (b) {
            '\r', '\n' => return .accept,
            3 => return self.cancelLine(),
            4 => return self.endOfInput(), // Ctrl-D
            1 => self.moveLineStart(), // Ctrl-A
            5 => self.moveLineEnd(), // Ctrl-E
            2 => self.moveLeft(), // Ctrl-B
            6 => self.moveRight(), // Ctrl-F
            11 => self.killLine(), // Ctrl-K
            21 => self.killLineBackward(), // Ctrl-U
            23 => self.killWordBackwardUnix(), // Ctrl-W
            25 => self.yank(), // Ctrl-Y
            31 => self.undo(), // Ctrl-_
            24 => self.ctrl_x = true, // Ctrl-X prefix
            22 => self.quoted_insert = true, // Ctrl-V
            12 => self.clearScreen(), // Ctrl-L
            20 => self.transpose(), // Ctrl-T
            16 => self.historyPrev(), // Ctrl-P
            14 => self.historyNext(), // Ctrl-N
            18 => self.reverseSearch(), // Ctrl-R
            0x7f, 8 => self.deleteBefore(),
            '\t' => self.handleTab(),
            else => if (b >= 0x20) {
                self.insertSlice(&.{b});
                self.this_command = .insert;
            },
        }
        return .handled;
    }

    /// Ctrl-D: end of input on an empty line, otherwise delete forward.
    pub fn endOfInput(self: *Editor) Outcome {
        if (self.buf.items.len == 0) {
            self.write("\r\n");
            return .eof;
        }
        self.deleteAtCursor();
        return .handled;
    }

    /// Ctrl-C: abandon the line and give a fresh prompt.
    pub fn cancelLine(self: *Editor) Outcome {
        // Redraw with the cursor at the end, without hints, so `^C` follows
        // the whole command instead of overwriting the lines after the
        // cursor (Bash also moves to the last row first).
        if (self.command_frame_active) {
            self.cursor = self.buf.items.len;
            self.hints = false;
            self.render();
            self.hints = true;
        }
        self.write("^C\r\n");
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.command_frame_active = false;
        self.interrupted = true;
        self.sh.last_status = 130;
        return .cancel;
    }

    pub fn clearScreen(self: *Editor) void {
        self.write("\x1b[2J\x1b[H");
        // Raw mode leaves newlines alone, so each needs its carriage return.
        var lines = std.mem.splitScalar(u8, self.prompt_head, '\n');
        var first = true;
        while (lines.next()) |line| {
            if (!first) self.write("\r\n");
            first = false;
            self.write(line);
        }
        self.command_frame_active = false;
        self.command_cursor_row = 0;
    }

    // --- rendering ----------------------------------------------------------

    fn updateWidth(self: *Editor) void {
        if (sys.windowSize(self.out_fd)) |ws| {
            self.width = ws.cols;
            self.height = ws.rows;
        }
        if (self.width == 0) self.width = 80;
        if (self.height == 0) self.height = 24;
    }

    fn render(self: *Editor) void {
        if (self.vi.searching) |direction| {
            const label: []const u8 = if (direction == '/') "/" else "?";
            self.renderFrame(label, self.vi.query.items, self.vi.query.items.len, .plain);
            return;
        }
        self.renderFrame(self.prompt_text, self.buf.items, self.cursor, if (self.hints) .full else .highlighted);
    }

    /// `text` with control characters spelled out in caret notation, which is
    /// how the frame draws them and what `wcwidth.width` measures.
    fn visible(self: *Editor, text: []const u8) []const u8 {
        for (text) |c| {
            if (isControl(c)) break;
        } else return text;
        self.visible_scratch.clearRetainingCapacity();
        for (text) |c| {
            if (isControl(c)) {
                self.visible_scratch.append(self.sh.gpa, '^') catch return text;
                self.visible_scratch.append(self.sh.gpa, if (c == 0x7f) '?' else c + 0x40) catch return text;
            } else {
                self.visible_scratch.append(self.sh.gpa, c) catch return text;
            }
        }
        return self.visible_scratch.items;
    }

    /// The prompt drawn before logical line `index` of a frame: `first` for
    /// the first line, after that the continuation prompt, indented by how
    /// deeply the lines before it nest.
    fn linePrompt(self: *Editor, first: []const u8, index: usize, nesting: Nesting, scratch: *std.Io.Writer.Allocating) []const u8 {
        if (index == 0) return first;
        scratch.writer.end = 0;
        if (self.write_continuation) |write_prompt| write_prompt(&scratch.writer, self.sh, @max(nesting.depth, 1)) catch {};
        return scratch.writer.buffered();
    }

    /// Walks the cursor offsets of a frame (`prompt_text` and then `text`,
    /// continuation prompts before later lines) in order, with the cell the
    /// cursor shows on at each. Rendering and vertical motion share it, so
    /// Up and Down land where the eye expects.
    const Walk = struct {
        ed: *Editor,
        prompt_text: []const u8,
        text: []const u8,
        /// The cursor offset the frame makes room for (see `renderFrame`).
        cursor: usize,
        width: usize,
        scratch: std.Io.Writer.Allocating,
        offset: usize = 0,
        line_index: usize = 0,
        line_start: usize = 0,
        nesting: Nesting = .{},
        /// Where the text before `offset` ends.
        before: Pos = .{},

        fn init(ed: *Editor, prompt_text: []const u8, text: []const u8, cursor: usize) Walk {
            return .{
                .ed = ed,
                .prompt_text = prompt_text,
                .text = text,
                .cursor = cursor,
                .width = ed.width,
                .scratch = .init(ed.sh.gpa),
                .before = layout(.{}, prompt_text, ed.width, .prompt),
            };
        }

        fn deinit(self: *Walk) void {
            self.scratch.deinit();
        }

        fn cell(self: *const Walk) Pos {
            // The end of a full row that has no room after it: the last
            // cell of that row, after every other.
            if (!self.roomAfter()) return self.before;
            return cursorCell(self.before, self.text, self.offset, self.width);
        }

        /// False at the end of an earlier line that fills its last row
        /// without the cursor after it, so the next line follows directly.
        fn roomAfter(self: *const Walk) bool {
            if (self.offset >= self.text.len or self.text[self.offset] != '\n') return true;
            return self.before.col < self.width or self.offset == self.cursor;
        }

        /// Steps to the next cursor offset; false at the end of the text.
        fn next(self: *Walk) bool {
            if (self.offset >= self.text.len) return false;
            if (self.text[self.offset] == '\n') {
                const end = if (self.roomAfter()) self.before.settled(self.width) else self.before;
                self.nesting.feed(self.text[self.line_start..self.offset]);
                self.line_index += 1;
                self.offset += 1;
                self.line_start = self.offset;
                const prompt_text = self.ed.linePrompt(self.prompt_text, self.line_index, self.nesting, &self.scratch);
                self.before = layout(.{ .row = end.row + 1 }, prompt_text, self.width, .prompt);
                return true;
            }
            const step = layoutStep(self.before, self.text, self.offset, self.width, .buffer);
            self.before = step.pos;
            self.offset = step.next;
            return true;
        }
    };

    /// The cell the cursor shows on at `offset` of the edited line.
    fn cellOf(self: *Editor, offset: usize) Pos {
        var walk: Walk = .init(self, self.prompt_text, self.buf.items, self.cursor);
        defer walk.deinit();
        while (walk.offset < offset and walk.next()) {}
        return walk.cell();
    }

    const Decoration = enum { plain, highlighted, full };

    /// Draws the prompt and `text` with the cursor at `cursor`, replacing
    /// the previous frame. Positions come from `layout`, which wraps the
    /// way the terminal does (wide characters included). A line that fills
    /// its last row exactly gets an empty row after it when the cursor is at
    /// its end, so the cursor never shows on the following line (or past the
    /// margin); the last line always has it. A frame taller than the
    /// screen is drawn as a screen-high window around the cursor, because
    /// the terminal cannot move the cursor above its top row to redraw it.
    fn renderFrame(self: *Editor, prompt_text: []const u8, text: []const u8, cursor: usize, decoration: Decoration) void {
        self.updateWidth();
        if (self.command_frame_active and self.width != self.drawn_width) self.climbAfterResize();
        self.frame.writer.end = 0;
        const width = self.width;

        var continuation: std.Io.Writer.Allocating = .init(self.sh.gpa);
        defer continuation.deinit();

        var line_start: usize = 0;
        var line_index: usize = 0;
        var line_pos: Pos = .{};
        var end: Pos = .{};
        var nesting: Nesting = .{};
        const multiline = std.mem.indexOfScalar(u8, text, '\n') != null;
        const colour = decoration != .plain and self.sh.config.highlight;

        while (true) : (line_index += 1) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = text[line_start..line_end];
            const line_prompt = self.linePrompt(prompt_text, line_index, nesting, &continuation);
            tryWrite(&self.frame.writer, line_prompt);
            var pos = layout(line_pos, line_prompt, width, .prompt);
            pos = layout(pos, line, width, .buffer);

            const shown = self.visible(line);
            if (colour) {
                highlight.render(&self.frame.writer, self.sh, shown) catch {};
            } else {
                self.frame.writer.writeAll(shown) catch {};
            }

            if (line_end == text.len) {
                var correction_text: [320]u8 = undefined;
                const suggestion = if (decoration == .full and !multiline) blk: {
                    if (self.currentCachedCorrection()) |name| {
                        break :blk std.fmt.bufPrint(&correction_text, "  => {s}", .{name}) catch null;
                    }
                    break :blk self.currentSuggestion();
                } else null;
                if (suggestion) |hint_text| {
                    pos = layout(pos, hint_text, width, .buffer);
                    self.frame.writer.writeAll(if (highlight.colorEnabled(self.sh)) highlight.gray else highlight.dim) catch {};
                    self.frame.writer.writeAll(self.visible(hint_text)) catch {};
                    self.frame.writer.writeAll(highlight.reset) catch {};
                }
            }
            // At the exact right margin the terminal has not wrapped yet;
            // move to the next row so the row arithmetic holds.
            const room = pos.col >= width and (line_end == text.len or cursor == line_end);
            if (room) self.frame.writer.writeAll("\r\n") catch {};
            self.end_fresh = room;
            end = if (room) pos.settled(width) else pos;
            if (line_end == text.len) break;
            self.frame.writer.writeAll("\r\n") catch {};
            nesting.feed(line);
            line_pos = .{ .row = end.row + 1 };
            line_start = line_end + 1;
        }

        var walk: Walk = .init(self, prompt_text, text, cursor);
        defer walk.deinit();
        while (walk.offset < cursor and walk.next()) {}
        const cursor_cell = walk.cell();

        // A final frame (hints off: the line was submitted or cancelled) is
        // drawn whole, so all of it reaches the scrollback.
        const screen_rows = @max(self.height, 1);
        // A screen too small for a menu (it shrank while one was open)
        // keeps the selected word and drops the menu.
        if (self.menu != null and screen_rows < menu_screen_min) self.closeMenu();
        // While the menu is open it always keeps a few rows: the command is
        // windowed around the cursor in what is left, so a command that
        // fills the screen never hides the menu that Tab is cycling.
        const menu_open = decoration == .full and self.menu != null;
        const menu_room = if (menu_open) @min(pager.min_rows, screen_rows - 1, self.menuRowsWanted()) else 0;
        const command_screen = screen_rows - menu_room;
        var first: usize = 0;
        var last = end.row;
        if (self.hints and end.row >= command_screen) {
            first = @min(self.view_top, end.row + 1 - command_screen);
            if (cursor_cell.row < first) first = cursor_cell.row;
            if (cursor_cell.row >= first + command_screen) first = cursor_cell.row + 1 - command_screen;
            last = first + command_screen - 1;
        }
        self.view_top = first;
        // The completion menu is the frame's last rows, below the rows on
        // screen, so the next redraw repaints or clears it like the rest of
        // the frame.
        const command_len = self.frame.writer.end;
        var menu_rows: usize = 0;
        if (menu_open) menu_rows = self.writeMenuRows(last - first + 1);
        self.end_fresh = self.end_fresh and last == end.row and menu_rows == 0;

        self.write("\r");
        if (self.command_frame_active and self.command_cursor_row > 0) {
            var up: [64]u8 = undefined;
            const sequence = std.fmt.bufPrint(&up, "\x1b[{d}A", .{self.command_cursor_row}) catch "";
            self.write(sequence);
        }
        self.write("\x1b[J");
        self.drawn_width = width;
        self.drawn_window = !(first == 0 and last == end.row);
        if (!self.drawn_window) {
            self.write(self.frame.writer.buffered());
        } else {
            const frame = self.frame.writer.buffered();
            self.body.writer.end = 0;
            writeRows(&self.body.writer, frame[0..command_len], width, first, last);
            tryWrite(&self.body.writer, frame[command_len..]);
            self.write(self.body.writer.buffered());
        }

        // Rows are counted from the top of what was drawn from here on.
        const cursor_row = cursor_cell.row - first;
        self.drawn_cursor = .{ .row = cursor_row, .col = cursor_cell.col };
        var end_row = last - first + menu_rows;
        self.write("\r");
        var scratch: [64]u8 = undefined;
        if (end_row > cursor_row) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}A", .{end_row - cursor_row}) catch "";
            self.write(sequence);
        } else if (cursor_row > end_row) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}B", .{cursor_row - end_row}) catch "";
            self.write(sequence);
        }
        if (cursor_cell.col > 0) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}C", .{cursor_cell.col}) catch "";
            self.write(sequence);
        }

        // A whole frame taller than the screen scrolled its top away: the
        // next redraw can only climb to the top row of the screen.
        var top_row = cursor_row;
        if (end_row >= screen_rows) {
            top_row = (screen_rows - 1) -| (end_row - cursor_row);
            end_row = top_row + (end_row - cursor_row);
        }
        self.command_frame_active = true;
        self.command_cursor_row = top_row;
        self.command_end_row = end_row;
    }

    /// The width changed since the frame was drawn. A terminal that reflows
    /// re-wrapped the frame's lines at the new width, one that does not (xterm)
    /// kept its rows, and nothing tells the two apart. Climb to whichever top
    /// row is higher, so no stale copy of the prompt is left above the
    /// redraw: the reflowed count when narrower (lines take more rows), the
    /// drawn count when wider (wrapped lines took more rows). The cost is
    /// that the other kind of terminal loses as many rows of earlier output
    /// above the prompt as the two counts differ.
    fn climbAfterResize(self: *Editor) void {
        const drawn = if (self.drawn_window) self.body.writer.buffered() else self.frame.writer.buffered();
        const reflowed = reflowedCursorRow(drawn, self.drawn_width, self.width, self.drawn_cursor);
        self.command_cursor_row = @max(self.command_cursor_row, reflowed);
    }

    /// Moves below the current frame so output can follow it; the next render
    /// starts a fresh frame there.
    fn leaveFrame(self: *Editor) void {
        if (self.command_frame_active and self.command_end_row > self.command_cursor_row) {
            var scratch: [64]u8 = undefined;
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}B", .{self.command_end_row - self.command_cursor_row}) catch "";
            self.write(sequence);
        }
        // A last line that filled its row already moved to a fresh row, as
        // when a command is submitted; another newline would leave a blank.
        self.write(if (self.command_frame_active and self.end_fresh) "\r" else "\r\n");
        self.command_frame_active = false;
        self.command_cursor_row = 0;
    }

    fn tryWrite(writer: *std.Io.Writer, text: []const u8) void {
        writer.writeAll(text) catch {};
    }

    fn write(self: *Editor, text: []const u8) void {
        sys.writeStr(self.out_fd, text);
    }

    // --- reading keys -------------------------------------------------------

    fn readRawByte(self: *Editor) ?u8 {
        if (self.pending_byte) |b| {
            self.pending_byte = null;
            return b;
        }
        return term.readByte(self.in_fd);
    }

    fn readByteTimeout(self: *Editor, ms: i32) ?u8 {
        if (self.pending_byte) |b| {
            self.pending_byte = null;
            return b;
        }
        return term.readByteTimeout(self.in_fd, ms);
    }

    fn readKey(self: *Editor) Key {
        const b = blk: {
            if (self.pending_byte) |byte| {
                self.pending_byte = null;
                break :blk byte;
            }
            while (true) {
                switch (term.readByteInterruptible(self.in_fd)) {
                    .byte => |byte| break :blk byte,
                    .eof => return .eof,
                    .interrupted => {
                        if (term.takeResize()) return .resize;
                        if (proc.hangupPending()) return .eof;
                        if (term.wakePending()) {
                            self.woken = true;
                            return .eof;
                        }
                    },
                }
            }
        };

        if (b >= 0xC0) return self.readUtf8(b);
        if (b != 0x1b) return .{ .byte = b };

        const second = self.readByteTimeout(30) orelse return .escape;
        if (second != '[' and second != 'O') return .{ .alt = second };

        var params: [16]u8 = undefined;
        var count: usize = 0;
        while (count < params.len) {
            const c = self.readByteTimeout(30) orelse return .unknown;
            if (c >= 0x20 and c <= 0x3f) {
                params[count] = c;
                count += 1;
                continue;
            }
            return decodeCsi(params[0..count], c);
        }
        return .unknown;
    }

    /// Collects the continuation bytes of a UTF-8 sequence so a character is
    /// inserted whole, never one byte at a time.
    fn readUtf8(self: *Editor, lead: u8) Key {
        const len = std.unicode.utf8ByteSequenceLength(lead) catch return .{ .byte = lead };
        var key: Key = .{ .utf8 = .{ .bytes = undefined, .len = @intCast(len) } };
        key.utf8.bytes[0] = lead;
        var i: usize = 1;
        while (i < len) : (i += 1) {
            const next = self.readByteTimeout(30) orelse return .{ .byte = lead };
            if (next & 0xC0 != 0x80) {
                self.pending_byte = next;
                return .{ .byte = lead };
            }
            key.utf8.bytes[i] = next;
        }
        return key;
    }

    fn decodeCsi(params: []const u8, final: u8) Key {
        const ctrl = std.mem.endsWith(u8, params, ";5");
        const alt = std.mem.endsWith(u8, params, ";3");

        return switch (final) {
            'A' => .up,
            'B' => .down,
            'C' => if (ctrl or alt) .word_right else .right,
            'D' => if (ctrl or alt) .word_left else .left,
            'H' => .home,
            'F' => .end,
            'Z' => .back_tab,
            '~' => blk: {
                const number = std.fmt.parseInt(u32, params, 10) catch 0;
                break :blk switch (number) {
                    1, 7 => .home,
                    4, 8 => .end,
                    3 => .delete,
                    5 => .page_up,
                    6 => .page_down,
                    200 => .paste_start,
                    else => .unknown,
                };
            },
            else => .unknown,
        };
    }

    /// Reads a bracketed paste up to `ESC[201~` and inserts it literally.
    pub fn readPaste(self: *Editor) void {
        var data: std.ArrayList(u8) = .empty;
        defer data.deinit(self.sh.gpa);
        const end_marker = term.paste_end;
        var matched: usize = 0;
        // A generous timeout: the end marker is only missing if the terminal
        // is broken, and the paste must not be cut short under load.
        while (self.readByteTimeout(1000)) |b| {
            if (b == end_marker[matched]) {
                matched += 1;
                if (matched == end_marker.len) break;
                continue;
            }
            if (matched > 0) {
                data.appendSlice(self.sh.gpa, end_marker[0..matched]) catch return;
                matched = 0;
                if (b == end_marker[0]) {
                    matched = 1;
                    continue;
                }
            }
            data.append(self.sh.gpa, b) catch return;
        }
        self.insertPaste(data.items);
    }

    /// Inserts pasted text without running it. Terminals send line breaks as
    /// CR, which become newlines in the buffer.
    pub fn insertPaste(self: *Editor, text: []const u8) void {
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.sh.gpa);
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\r') {
                normalized.append(self.sh.gpa, '\n') catch return;
                if (i + 1 < text.len and text[i + 1] == '\n') i += 1;
                continue;
            }
            normalized.append(self.sh.gpa, text[i]) catch return;
        }
        self.insertSlice(normalized.items);
    }

    // --- editing ------------------------------------------------------------

    pub fn insertSlice(self: *Editor, text: []const u8) void {
        self.buf.insertSlice(self.sh.gpa, self.cursor, text) catch return;
        self.cursor += text.len;
    }

    pub fn setLine(self: *Editor, text: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.sh.gpa, text) catch return;
        self.cursor = self.buf.items.len;
    }

    /// Removes `[start, end)` from the buffer and leaves the cursor at `start`.
    pub fn removeRange(self: *Editor, start: usize, end: usize) void {
        if (start >= end) return;
        const items = self.buf.items;
        std.mem.copyForwards(u8, items[start..], items[end..]);
        self.buf.items.len -= end - start;
        self.cursor = start;
    }

    /// Replaces `[start, end)` with `text` and puts the cursor after it.
    pub fn replaceRange(self: *Editor, start: usize, end: usize, text: []const u8) void {
        self.removeRange(start, end);
        self.buf.insertSlice(self.sh.gpa, start, text) catch {
            self.cursor = start;
            return;
        };
        self.cursor = start + text.len;
    }

    fn deleteBefore(self: *Editor) void {
        if (self.cursor == 0) return;
        self.removeRange(wcwidth.prevCluster(self.buf.items, self.cursor), self.cursor);
    }

    fn deleteAtCursor(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        const keep = self.cursor;
        self.removeRange(keep, wcwidth.nextCluster(self.buf.items, keep));
    }

    pub fn moveLeft(self: *Editor) void {
        self.cursor = wcwidth.prevCluster(self.buf.items, self.cursor);
    }

    pub fn moveRight(self: *Editor) void {
        self.cursor = wcwidth.nextCluster(self.buf.items, self.cursor);
    }

    /// Start of the logical line (between newlines) holding `at`.
    pub fn lineStartOf(self: *const Editor, at: usize) usize {
        const newline = std.mem.lastIndexOfScalar(u8, self.buf.items[0..at], '\n') orelse return 0;
        return newline + 1;
    }

    /// End of the logical line holding `at`, before its newline.
    pub fn lineEndOf(self: *const Editor, at: usize) usize {
        return std.mem.indexOfScalarPos(u8, self.buf.items, at, '\n') orelse self.buf.items.len;
    }

    /// Home / Ctrl-A: the start of the current line of a multi-line command.
    fn moveLineStart(self: *Editor) void {
        self.cursor = self.lineStartOf(self.cursor);
    }

    /// End / Ctrl-E: the end of the current line. At the end of the command
    /// it accepts the suggestion, as Right does (and as fish does).
    fn moveLineEnd(self: *Editor) void {
        if (self.cursor == self.buf.items.len) {
            _ = self.acceptSuggestion();
            return;
        }
        self.cursor = self.lineEndOf(self.cursor);
    }

    /// Ctrl-K: kill to the end of the current line, or join the next line
    /// when the cursor is already at the end, as Emacs and fish do.
    fn killLine(self: *Editor) void {
        const end = self.lineEndOf(self.cursor);
        const stop = if (end == self.cursor and end < self.buf.items.len) end + 1 else end;
        self.killRange(self.cursor, stop, .forward, true);
    }

    /// Ctrl-U: kill back to the start of the current line, or join the
    /// previous line when the cursor is already at the start.
    fn killLineBackward(self: *Editor) void {
        const start = self.lineStartOf(self.cursor);
        const from = if (start == self.cursor and start > 0) start - 1 else start;
        self.killRange(from, self.cursor, .backward, true);
    }

    /// Up / Down: move to the screen row above or below, keeping the column,
    /// so a wrapped line is walked row by row. From the first or last row,
    /// or while a recalled history entry is still unedited, browse history
    /// instead, as fish does; a long recalled command does not have to be
    /// climbed through to reach the one before it.
    pub fn moveVertical(self: *Editor, direction: i8) void {
        if (self.browsingHistory()) {
            if (direction < 0) self.historyPrev() else self.historyNext();
            return;
        }
        if (self.verticalTarget(direction)) |target| {
            self.cursor = target;
            self.this_command = .vertical;
        } else if (direction < 0) {
            self.historyPrev();
        } else {
            self.historyNext();
        }
    }

    /// True while the line is a history entry shown as it was recalled.
    fn browsingHistory(self: *Editor) bool {
        const index = self.hist_index orelse return false;
        if (index >= self.sh.hist.count()) return false;
        return std.mem.eql(u8, self.buf.items, self.sh.hist.get(index));
    }

    /// The offset one screen row up or down from the cursor at the goal
    /// column (or the nearest one the row has), or null on the first or last
    /// row of the line. The goal is the cursor's column unless a run of
    /// vertical moves set it earlier (see `handleKey`).
    pub fn verticalTarget(self: *Editor, direction: i8) ?usize {
        var here = self.cellOf(self.cursor);
        if (self.goal_col) |col| here.col = col;
        self.goal_col = here.col;
        var walk: Walk = .init(self, self.prompt_text, self.buf.items, self.cursor);
        defer walk.deinit();
        var best: ?usize = null;
        var best_cell: Pos = .{};
        while (true) {
            const cell = walk.cell();
            const wanted = if (direction < 0) cell.row < here.row else cell.row > here.row;
            if (wanted) {
                if (best == null or
                    (direction < 0 and cell.row > best_cell.row) or
                    (cell.row == best_cell.row and cell.col <= here.col))
                {
                    best = walk.offset;
                    best_cell = cell;
                }
                // Rows only grow: past the row below, nothing nearer follows.
                if (direction > 0 and cell.row > best_cell.row) break;
            }
            if (!walk.next()) break;
        }
        return best;
    }

    fn wordStartBefore(self: *const Editor, from: usize) usize {
        const items = self.buf.items;
        var i = from;
        while (i > 0 and !isWordByte(items[i - 1])) i -= 1;
        while (i > 0 and isWordByte(items[i - 1])) i -= 1;
        return i;
    }

    fn wordEndAfter(self: *const Editor, from: usize) usize {
        const items = self.buf.items;
        var i = from;
        while (i < items.len and !isWordByte(items[i])) i += 1;
        while (i < items.len and isWordByte(items[i])) i += 1;
        return i;
    }

    fn moveWordLeft(self: *Editor) void {
        self.cursor = self.wordStartBefore(self.cursor);
    }

    fn moveWordRight(self: *Editor) void {
        self.cursor = self.wordEndAfter(self.cursor);
    }

    pub const KillDirection = enum { forward, backward };

    /// Deletes `[start, end)` into the kill ring. Consecutive kills with
    /// `merge` set grow one entry, so Ctrl-Y yanks them back together.
    pub fn killRange(self: *Editor, start: usize, end: usize, direction: KillDirection, merge: bool) void {
        if (start >= end) return;
        self.pushKill(self.buf.items[start..end], direction, merge and self.last == .kill);
        self.removeRange(start, end);
        self.this_command = .kill;
    }

    pub fn pushKill(self: *Editor, text: []const u8, direction: KillDirection, append: bool) void {
        const gpa = self.sh.gpa;
        if (append and self.kill_ring.items.len > 0) {
            const top = &self.kill_ring.items[self.kill_ring.items.len - 1];
            const parts: []const []const u8 = if (direction == .forward) &.{ top.*, text } else &.{ text, top.* };
            const joined = std.mem.concat(gpa, u8, parts) catch return;
            gpa.free(top.*);
            top.* = joined;
            return;
        }
        const copy = gpa.dupe(u8, text) catch return;
        if (self.kill_ring.items.len == kill_ring_max) gpa.free(self.kill_ring.orderedRemove(0));
        self.kill_ring.append(gpa, copy) catch gpa.free(copy);
    }

    /// The newest kill-ring entry, for vi `p`/`P`.
    pub fn lastKill(self: *const Editor) ?[]const u8 {
        if (self.kill_ring.items.len == 0) return null;
        return self.kill_ring.items[self.kill_ring.items.len - 1];
    }

    /// Ctrl-W: kill the whitespace-delimited word before the cursor.
    fn killWordBackwardUnix(self: *Editor) void {
        const items = self.buf.items;
        var start = self.cursor;
        while (start > 0 and isBlank(items[start - 1])) start -= 1;
        while (start > 0 and !isBlank(items[start - 1])) start -= 1;
        self.killRange(start, self.cursor, .backward, true);
    }

    /// Alt-D: kill from the cursor to the end of the next word.
    fn killWordForward(self: *Editor) void {
        self.killRange(self.cursor, self.wordEndAfter(self.cursor), .forward, true);
    }

    /// Alt-Backspace: kill from the start of the previous word to the cursor.
    fn killWordBackward(self: *Editor) void {
        self.killRange(self.wordStartBefore(self.cursor), self.cursor, .backward, true);
    }

    fn yank(self: *Editor) void {
        const text = self.lastKill() orelse return;
        self.yank_start = self.cursor;
        self.insertSlice(text);
        self.yank_end = self.cursor;
        self.yank_index = self.kill_ring.items.len - 1;
        self.this_command = .yank;
    }

    /// Alt-Y: replace the text just yanked with the next older kill.
    fn yankPop(self: *Editor) void {
        if (self.last != .yank or self.kill_ring.items.len == 0) return;
        const count = self.kill_ring.items.len;
        self.yank_index = (self.yank_index + count - 1) % count;
        const text = self.kill_ring.items[self.yank_index];
        self.replaceRange(self.yank_start, self.yank_end, text);
        self.yank_end = self.cursor;
        self.this_command = .yank;
    }

    /// Alt-. / Alt-_: insert the last word of the previous command; repeating
    /// it replaces that word with the last word of an older command.
    fn yankLastArg(self: *Editor) void {
        const count = self.sh.hist.count();
        if (count == 0) return;
        const repeating = self.last == .yank_arg;
        if (repeating and self.last_arg_index == 0) {
            self.this_command = .yank_arg;
            return;
        }
        const index = if (repeating) self.last_arg_index - 1 else count - 1;

        var arena_state = std.heap.ArenaAllocator.init(self.sh.gpa);
        defer arena_state.deinit();
        const words = histexpand.splitWords(arena_state.allocator(), self.sh.hist.get(index)) catch return;
        const word = if (words.len == 0) "" else words[words.len - 1];

        if (repeating) {
            self.replaceRange(self.last_arg_start, self.last_arg_end, word);
        } else {
            self.last_arg_start = self.cursor;
            self.insertSlice(word);
        }
        self.last_arg_end = self.cursor;
        self.last_arg_index = index;
        self.this_command = .yank_arg;
    }

    const Case = enum { upper, lower, capital };

    /// Alt-U/L/C: change the case of the next word and move past it.
    fn changeWordCase(self: *Editor, case: Case) void {
        const items = self.buf.items;
        var i = self.cursor;
        while (i < items.len and !isWordByte(items[i])) i += 1;
        var first = true;
        while (i < items.len and isWordByte(items[i])) : (i += 1) {
            items[i] = switch (case) {
                .upper => std.ascii.toUpper(items[i]),
                .lower => std.ascii.toLower(items[i]),
                .capital => if (first) std.ascii.toUpper(items[i]) else std.ascii.toLower(items[i]),
            };
            first = false;
        }
        self.cursor = i;
    }

    fn transpose(self: *Editor) void {
        const items = self.buf.items;
        if (items.len < 2 or self.cursor == 0) return;
        var middle = self.cursor;
        if (middle >= items.len) middle = wcwidth.prevCluster(items, items.len);
        if (middle == 0) return;
        const start = wcwidth.prevCluster(items, middle);
        const end = wcwidth.nextCluster(items, middle);
        var swapped: [64]u8 = undefined;
        const first = items[start..middle];
        const second = items[middle..end];
        if (first.len + second.len > swapped.len) return;
        @memcpy(swapped[0..second.len], second);
        @memcpy(swapped[second.len .. second.len + first.len], first);
        @memcpy(items[start..end], swapped[0 .. first.len + second.len]);
        self.cursor = end;
    }

    // --- undo ---------------------------------------------------------------

    fn clearUndo(self: *Editor) void {
        for (self.undo_stack.items) |snapshot| self.sh.gpa.free(snapshot.text);
        self.undo_stack.clearRetainingCapacity();
    }

    /// Records the line as it was before this key when the key changed it.
    /// A run of typed characters is a single undo step.
    fn recordUndo(self: *Editor, before_cursor: usize) void {
        if (self.this_command == .undo) return;
        if (std.mem.eql(u8, self.before.items, self.buf.items)) return;
        if (self.this_command == .insert and self.last == .insert and self.undo_stack.items.len > 0) return;
        const gpa = self.sh.gpa;
        const text = gpa.dupe(u8, self.before.items) catch return;
        if (self.undo_stack.items.len == undo_max) gpa.free(self.undo_stack.orderedRemove(0).text);
        self.undo_stack.append(gpa, .{ .text = text, .cursor = before_cursor }) catch gpa.free(text);
    }

    pub fn undo(self: *Editor) void {
        self.this_command = .undo;
        const snapshot = self.undo_stack.pop() orelse return;
        defer self.sh.gpa.free(snapshot.text);
        self.setLine(snapshot.text);
        self.cursor = @min(snapshot.cursor, self.buf.items.len);
    }

    // --- external editor ----------------------------------------------------

    /// Ctrl-X Ctrl-E: edit the line in $VISUAL, $EDITOR or vi, then run the
    /// result, as bash's edit-and-execute-command does.
    fn editInEditor(self: *Editor) Outcome {
        const runner = self.sh.trap_runner orelse return .handled;
        const gpa = self.sh.gpa;
        var arena_state = std.heap.ArenaAllocator.init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const tmpdir = self.sh.getEnv("TMPDIR") orelse "/tmp";
        var path: [:0]const u8 = undefined;
        var fd: i32 = -1;
        var attempt: usize = 0;
        while (attempt < 16) : (attempt += 1) {
            path = std.fmt.allocPrintSentinel(arena, "{s}/wsh-edit-{d}-{d}.sh", .{ tmpdir, sys.getpid(), attempt }, 0) catch return .handled;
            const rc = linux.openat(linux.AT.FDCWD, path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
            if (linux.errno(rc) == .SUCCESS) {
                fd = @intCast(rc);
                break;
            }
        }
        if (fd < 0) {
            self.leaveFrame();
            self.write("wsh: cannot create a temporary file for the editor\r\n");
            return .handled;
        }
        const wrote = sys.writeAll(fd, self.buf.items) == .ok and sys.writeAll(fd, "\n") == .ok;
        _ = linux.close(fd);
        defer _ = fs.removeFile(path);
        if (!wrote) return .handled;

        const editor_command = self.sh.getEnv("VISUAL") orelse self.sh.getEnv("EDITOR") orelse "vi";
        const source = std.fmt.allocPrint(arena, "{s} '{s}'", .{ editor_command, path }) catch return .handled;

        self.leaveFrame();
        self.write(term.paste_off);
        if (self.raw) |raw| raw.disable();
        const saved_status = self.sh.last_status;
        const status = runner(self.sh, source, 1);
        self.sh.last_status = saved_status;
        if (self.raw) |raw| {
            if (term.RawMode.enable(self.in_fd)) |again| raw.* = again;
        }
        self.write(term.paste_on);
        if (status != 0) return .handled;

        const contents = (fs.readFileAlloc(arena, path, 1 << 20) catch null) orelse return .handled;
        self.setLine(std.mem.trimEnd(u8, contents, "\n"));
        if (self.buf.items.len == 0) return .handled;
        return .accept;
    }

    // --- history ------------------------------------------------------------

    pub fn historyPrev(self: *Editor) void {
        const count = self.sh.hist.count();
        if (count == 0) return;
        if (self.hist_index == null) {
            self.stashed.clearRetainingCapacity();
            self.stashed.appendSlice(self.sh.gpa, self.buf.items) catch return;
            self.hist_index = count;
        }
        const index = self.hist_index.?;
        if (index == 0) return;
        self.hist_index = index - 1;
        self.setLine(self.sh.hist.get(index - 1));
    }

    pub fn historyNext(self: *Editor) void {
        const index = self.hist_index orelse return;
        const count = self.sh.hist.count();
        if (index + 1 >= count) {
            self.hist_index = null;
            self.setLine(self.stashed.items);
            return;
        }
        self.hist_index = index + 1;
        self.setLine(self.sh.hist.get(index + 1));
    }

    /// Shows history entry `index`, stashing the edited line the first time.
    pub fn showHistoryEntry(self: *Editor, index: usize) void {
        if (self.hist_index == null) {
            self.stashed.clearRetainingCapacity();
            self.stashed.appendSlice(self.sh.gpa, self.buf.items) catch return;
        }
        self.hist_index = index;
        self.setLine(self.sh.hist.get(index));
    }

    // --- autosuggestion -----------------------------------------------------

    fn currentSuggestion(self: *Editor) ?[]const u8 {
        if (!self.sh.config.autosuggest) return null;
        if (self.cursor != self.buf.items.len) return null;
        if (self.buf.items.len == 0) return null;
        if (self.hist_index != null) return null;

        const index = self.sh.hist.suggest(self.buf.items, self.sh.cwd, self.sh.config.suggest) orelse return null;
        return self.sh.hist.get(index)[self.buf.items.len..];
    }

    fn acceptSuggestionOrMoveRight(self: *Editor) void {
        if (!self.acceptSuggestion()) self.moveRight();
    }

    /// Takes the shown correction or history suggestion into the line.
    fn acceptSuggestion(self: *Editor) bool {
        if (self.currentCachedCorrection()) |command| {
            self.setLine(command);
            return true;
        }
        if (self.currentSuggestion()) |remaining| {
            self.insertSlice(remaining);
            return true;
        }
        return false;
    }

    fn currentCachedCorrection(self: *Editor) ?[]const u8 {
        if (!self.sh.config.autosuggest or self.cursor != self.buf.items.len or self.buf.items.len == 0) return null;
        if (self.hist_index != null) return null;
        if (std.mem.indexOfAny(u8, self.buf.items, " \t|&;<>()/\\") != null) return null;
        return self.sh.command_cache.correction(self.buf.items);
    }

    // --- completion ---------------------------------------------------------

    fn handleTab(self: *Editor) void {
        if (!self.sh.config.completion) return;
        var arena_state = std.heap.ArenaAllocator.init(self.sh.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const result = complete.complete(self.sh, arena, self.buf.items, self.cursor) catch return;
        if (result.items.len == 0) return;

        if (result.items.len == 1) {
            self.replaceRange(result.start, self.cursor, result.items[0]);
            return;
        }

        const prefix_len = complete.commonPrefix(result.items);
        const typed_len = self.cursor - result.start;
        if (prefix_len > typed_len) {
            self.replaceRange(result.start, self.cursor, result.items[0][0..prefix_len]);
            return;
        }

        // Ambiguous: open the menu below the line. Further keys go to
        // `handleMenuKey` while it is open. A screen with no room for it
        // only rings the bell, as Bash does before listing.
        self.closeMenu();
        if (self.height < menu_screen_min) {
            self.write("\x07");
            return;
        }
        self.menu = pager.Menu.init(self.sh.gpa, result.items, self.buf.items, result.start, self.cursor) catch return;
        // Descriptions are only worked out (and stat'ed) for a menu.
        const descriptions = complete.describe(self.sh, arena, result) catch &.{};
        self.menu.?.describe(descriptions) catch {};
    }

    fn closeMenu(self: *Editor) void {
        if (self.menu) |*menu| menu.deinit();
        self.menu = null;
    }

    /// Rows the open menu needs to list every item on the current width,
    /// laid out as `pager.draw` lays it out.
    fn menuRowsWanted(self: *Editor) usize {
        const menu = &(self.menu orelse return 0);
        return pager.rowsWanted(menu, self.width);
    }

    /// Writes the menu rows below a frame that has `command_rows` rows and
    /// returns how many it wrote.
    fn writeMenuRows(self: *Editor, command_rows: usize) usize {
        const menu = &(self.menu orelse return 0);
        return pager.draw(&self.frame.writer, menu, self.width, pager.maxRows(self.height, command_rows));
    }

    /// A key while the menu is open. Tab, Shift-Tab and the arrows move the
    /// selection, which replaces the word in the line as it moves; Enter
    /// keeps it and Esc or Ctrl-G puts the typed word back. Any other key
    /// closes the menu, erases it, and returns false so the key then does
    /// what it normally does.
    fn handleMenuKey(self: *Editor, key: Key) bool {
        const menu = &(self.menu.?);
        const rows: isize = @intCast(@max(menu.rows, 1));
        const step: isize = switch (key) {
            .byte => |b| switch (b) {
                '\t' => 1,
                '\r', '\n' => {
                    if (menu.selected == null) return self.dismissMenu();
                    self.closeMenu();
                    return true;
                },
                7 => return self.cancelMenu(), // Ctrl-G
                else => return self.dismissMenu(),
            },
            .escape => return self.cancelMenu(),
            .back_tab, .up => -1,
            .down => 1,
            .left => -rows,
            .right => rows,
            .resize => return true,
            else => return self.dismissMenu(),
        };
        const index = menu.stepped(step);
        menu.selected = index;
        self.replaceRange(menu.start, menu.end, menu.items[index].text);
        menu.end = self.cursor;
        return true;
    }

    fn cancelMenu(self: *Editor) bool {
        const menu = &(self.menu.?);
        self.replaceRange(menu.start, menu.end, menu.original);
        self.closeMenu();
        return true;
    }

    /// Closes the menu and redraws without it, so whatever the key does next
    /// (print `^C`, run a bound command, submit the line) starts below the
    /// command line with no menu rows left on screen.
    fn dismissMenu(self: *Editor) bool {
        self.closeMenu();
        if (self.command_frame_active) self.render();
        return false;
    }

    // --- incremental reverse search ----------------------------------------

    fn reverseSearch(self: *Editor) void {
        var query: std.ArrayList(u8) = .empty;
        defer query.deinit(self.sh.gpa);
        var label: std.ArrayList(u8) = .empty;
        defer label.deinit(self.sh.gpa);

        var match_index: ?usize = null;

        while (true) {
            const match_text = if (match_index) |index| self.sh.hist.get(index) else "";
            label.clearRetainingCapacity();
            const coloured = highlight.colorEnabled(self.sh);
            label.print(self.sh.gpa, "{s}(reverse-i-search){s}`{s}': ", .{
                if (coloured) highlight.yellow else "",
                if (coloured) highlight.reset else "",
                query.items,
            }) catch return;
            const at = if (query.items.len == 0) 0 else std.mem.indexOf(u8, match_text, query.items) orelse 0;
            self.renderFrame(label.items, match_text, at, .plain);

            const key = self.readKey();
            switch (key) {
                .byte => |b| switch (b) {
                    7, 3 => return, // Ctrl-G / Ctrl-C: cancel
                    '\r', '\n' => {
                        if (match_index) |index| self.setLine(self.sh.hist.get(index));
                        return;
                    },
                    18 => { // Ctrl-R again: keep searching further back
                        if (match_index) |index| {
                            if (self.sh.hist.searchBackwardContains(index, query.items)) |next| {
                                match_index = next;
                            }
                        }
                    },
                    0x7f, 8 => {
                        if (query.items.len > 0) query.items.len = wcwidth.prevCluster(query.items, query.items.len);
                        match_index = self.sh.hist.searchBackwardContains(self.sh.hist.count(), query.items);
                    },
                    else => if (b >= 0x20) {
                        query.append(self.sh.gpa, b) catch {};
                        match_index = self.sh.hist.searchBackwardContains(self.sh.hist.count(), query.items);
                    } else {
                        // Another control key ends the search on the match
                        // and then does its usual job, as in Bash.
                        self.takeMatch(match_index, at);
                        _ = self.handleControlOrByte(b);
                        return;
                    },
                },
                .utf8 => |sequence| {
                    query.appendSlice(self.sh.gpa, sequence.bytes[0..sequence.len]) catch {};
                    match_index = self.sh.hist.searchBackwardContains(self.sh.hist.count(), query.items);
                },
                .resize => self.updateWidth(),
                .eof => return,
                // Esc keeps the match for editing, and a movement key keeps
                // it and moves from where the query matched, as in Bash.
                .escape => {
                    self.takeMatch(match_index, at);
                    return;
                },
                .left, .right, .up, .down, .home, .end, .word_left, .word_right, .delete => {
                    self.takeMatch(match_index, at);
                    _ = self.handleInsertKey(key);
                    return;
                },
                else => {},
            }
        }
    }

    fn takeMatch(self: *Editor, match_index: ?usize, at: usize) void {
        const index = match_index orelse return;
        self.setLine(self.sh.hist.get(index));
        self.cursor = at;
    }
};

// --- tests ----------------------------------------------------------------------

const testing = std.testing;

fn typeText(ed: *Editor, text: []const u8) void {
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        if (len == 1) {
            _ = ed.handleKey(.{ .byte = text[i] });
        } else {
            var key: Key = .{ .utf8 = .{ .bytes = undefined, .len = @intCast(len) } };
            @memcpy(key.utf8.bytes[0..len], text[i .. i + len]);
            _ = ed.handleKey(key);
        }
        i += len;
    }
}

test "editor buffer editing helpers" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("echo hello");
    try testing.expectEqual(@as(usize, 10), ed.cursor);

    // Deleting at column 5 removes the space, giving "echohello".
    ed.cursor = 5;
    ed.deleteBefore();
    try testing.expectEqualStrings("echohello", ed.buf.items);
    try testing.expectEqual(@as(usize, 4), ed.cursor);

    ed.setLine("  foo bar");
    ed.cursor = ed.buf.items.len;
    ed.killWordBackwardUnix();
    try testing.expectEqualStrings("  foo ", ed.buf.items);

    ed.setLine("a b c");
    ed.cursor = 1;
    ed.killRange(ed.cursor, ed.buf.items.len, .forward, true);
    try testing.expectEqualStrings("a", ed.buf.items);
}

test "grapheme-free word movement" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("one two three");
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, 8), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, 4), ed.cursor);
    ed.moveWordLeft();
    try testing.expectEqual(@as(usize, 0), ed.cursor);
    ed.moveWordRight();
    try testing.expectEqual(@as(usize, 3), ed.cursor);
}

test "editing steps over whole UTF-8 characters" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    typeText(&ed, "x\u{e9}");
    _ = ed.handleKey(.{ .byte = 0x7f });
    try testing.expectEqualStrings("x", ed.buf.items);

    // Left then typing inserts before the character, never inside it.
    ed.setLine("a\u{4e2d}");
    _ = ed.handleKey(.left);
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    typeText(&ed, "b");
    try testing.expectEqualStrings("ab\u{4e2d}", ed.buf.items);

    // A combining mark goes with its base.
    ed.setLine("e\u{301}z");
    ed.cursor = 0;
    _ = ed.handleKey(.delete);
    try testing.expectEqualStrings("z", ed.buf.items);
    ed.setLine("ze\u{301}");
    _ = ed.handleKey(.{ .byte = 0x7f });
    try testing.expectEqualStrings("z", ed.buf.items);

    // Ctrl-T swaps characters, not bytes.
    ed.setLine("a\u{e9}");
    _ = ed.handleKey(.{ .byte = 20 });
    try testing.expectEqualStrings("\u{e9}a", ed.buf.items);
}

test "kill ring, yank and yank-pop" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("one two three");
    _ = ed.handleKey(.{ .byte = 23 }); // Ctrl-W kills "three"
    _ = ed.handleKey(.{ .byte = 23 }); // and again "two ", appended to the same kill
    try testing.expectEqualStrings("one ", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 25 }); // Ctrl-Y
    try testing.expectEqualStrings("one two three", ed.buf.items);

    ed.setLine("alpha beta");
    ed.cursor = 0;
    _ = ed.handleKey(.{ .alt = 'd' }); // Alt-D kills forward
    try testing.expectEqualStrings(" beta", ed.buf.items);
    try testing.expectEqual(@as(usize, 0), ed.cursor);

    _ = ed.handleKey(.end);
    _ = ed.handleKey(.{ .alt = 0x7f }); // Alt-Backspace kills backward
    try testing.expectEqualStrings(" ", ed.buf.items);

    _ = ed.handleKey(.{ .byte = 25 }); // yanks "beta"
    try testing.expectEqualStrings(" beta", ed.buf.items);
    _ = ed.handleKey(.{ .alt = 'y' }); // rotates to "alpha"
    try testing.expectEqualStrings(" alpha", ed.buf.items);
    _ = ed.handleKey(.{ .alt = 'y' }); // and to "two three"
    try testing.expectEqualStrings(" two three", ed.buf.items);

    // Ctrl-K and Ctrl-U kill to the ends of the line, and back to back they
    // build one entry in buffer order.
    ed.setLine("abc def");
    ed.cursor = 3;
    _ = ed.handleKey(.{ .byte = 11 });
    try testing.expectEqualStrings("abc", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 21 });
    try testing.expectEqualStrings("", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 25 });
    try testing.expectEqualStrings("abc def", ed.buf.items);
}

test "undo restores earlier states" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    typeText(&ed, "echo hi");
    _ = ed.handleKey(.{ .byte = 23 });
    try testing.expectEqualStrings("echo ", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 31 }); // Ctrl-_
    try testing.expectEqualStrings("echo hi", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 24 }); // Ctrl-X Ctrl-U
    _ = ed.handleKey(.{ .byte = 21 });
    try testing.expectEqualStrings("", ed.buf.items);
}

test "yank-last-arg walks back through history" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "cp a.txt /srv/old");
    try sh.hist.add(sh.gpa, "ls -la /tmp/new");

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();
    typeText(&ed, "cd ");
    _ = ed.handleKey(.{ .alt = '.' });
    try testing.expectEqualStrings("cd /tmp/new", ed.buf.items);
    _ = ed.handleKey(.{ .alt = '.' });
    try testing.expectEqualStrings("cd /srv/old", ed.buf.items);
    _ = ed.handleKey(.{ .alt = '_' });
    try testing.expectEqualStrings("cd /srv/old", ed.buf.items);
}

test "word case commands and quoted insert" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("make some NOISE");
    ed.cursor = 0;
    _ = ed.handleKey(.{ .alt = 'u' });
    try testing.expectEqualStrings("MAKE some NOISE", ed.buf.items);
    _ = ed.handleKey(.{ .alt = 'c' });
    try testing.expectEqualStrings("MAKE Some NOISE", ed.buf.items);
    _ = ed.handleKey(.{ .alt = 'l' });
    try testing.expectEqualStrings("MAKE Some noise", ed.buf.items);

    _ = ed.handleKey(.{ .byte = 22 });
    try testing.expect(ed.quoted_insert);
    ed.quoted_insert = false;
    _ = ed.handleKey(.{ .literal = '\t' });
    try testing.expectEqualStrings("MAKE Some noise\t", ed.buf.items);
}

test "bracketed paste inserts newlines instead of submitting" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.insertPaste("echo one\recho two\r\n");
    try testing.expectEqualStrings("echo one\necho two\n", ed.buf.items);
    try testing.expectEqual(ed.buf.items.len, ed.cursor);
}

test "autosuggestion comes from history" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "git checkout main");

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("git ch");
    try testing.expectEqualStrings("eckout main", ed.currentSuggestion().?);
    ed.acceptSuggestionOrMoveRight();
    try testing.expectEqualStrings("git checkout main", ed.buf.items);
}

test "cached command correction appears inline and Right accepts it" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.command_cache.remember(sh.gpa, "gti", &.{.{ .name = "git", .distance = 1 }});

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();
    ed.setLine("gt");

    try testing.expectEqualStrings("git", ed.currentCachedCorrection().?);
    ed.acceptSuggestionOrMoveRight();
    try testing.expectEqualStrings("git", ed.buf.items);
}

test "history navigation stashes the in-progress line" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "first");
    try sh.hist.add(sh.gpa, "second");

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("draft");
    ed.historyPrev();
    try testing.expectEqualStrings("second", ed.buf.items);
    ed.historyPrev();
    try testing.expectEqualStrings("first", ed.buf.items);
    ed.historyNext();
    try testing.expectEqualStrings("second", ed.buf.items);
    ed.historyNext();
    try testing.expectEqualStrings("draft", ed.buf.items);
}

test "up and down move between lines in a multiline command" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("if true {\nprint first\nprint second");
    ed.moveVertical(-1);
    ed.insertSlice("!");
    try testing.expectEqualStrings("if true {\nprint first!\nprint second", ed.buf.items);

    ed.moveVertical(1);
    try testing.expectEqual(ed.buf.items.len, ed.cursor);
}

test "display width ignores colour codes and counts columns" {
    try testing.expectEqual(@as(usize, 0), displayWidth(""));
    try testing.expectEqual(@as(usize, 5), displayWidth("abcde"));
    // Colour escapes take no columns.
    try testing.expectEqual(@as(usize, 5), displayWidth("\x1b[1m\x1b[36mabcde\x1b[0m"));
    // The prompt marker is three bytes but one column.
    try testing.expectEqual(@as(usize, 3), displayWidth("~ \u{276f}"));
    try testing.expectEqual(@as(usize, 1), displayWidth("\u{276f}"));
    // Wide characters take two columns, combining marks none.
    try testing.expectEqual(@as(usize, 4), displayWidth("\u{4e2d}\u{6587}"));
    try testing.expectEqual(@as(usize, 1), displayWidth("e\u{301}"));
    // A window-title OSC sequence is invisible.
    try testing.expectEqual(@as(usize, 2), displayWidth("\x1b]0;title\x07$ "));
}

test "measured prompt width drives cursor placement" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    // A highlighted body must measure the same as the raw text.
    var body: std.Io.Writer.Allocating = .init(testing.allocator);
    defer body.deinit();
    try highlight.render(&body.writer, &sh, "echo \"a b\"");
    try testing.expectEqual(displayWidth("echo \"a b\""), displayWidth(body.writer.buffered()));
}

test "control characters render in caret notation" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    try testing.expectEqualStrings("a^Ib", ed.visible("a\tb"));
    try testing.expectEqual(@as(usize, 4), wcwidth.width("a\tb"));
}

test "the completion menu replaces the word as the selection moves" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    typeText(&ed, "cat a | wc");
    ed.cursor = 5;
    ed.menu = try pager.Menu.init(testing.allocator, &.{ "apple ", "apricot ", "avocado " }, ed.buf.items, 4, 5);
    _ = ed.handleKey(.{ .byte = '\t' });
    try testing.expectEqualStrings("cat apple  | wc", ed.buf.items);
    try testing.expectEqual(@as(usize, 10), ed.cursor);
    _ = ed.handleKey(.{ .byte = '\t' });
    try testing.expectEqualStrings("cat apricot  | wc", ed.buf.items);
    _ = ed.handleKey(.back_tab);
    _ = ed.handleKey(.up);
    try testing.expectEqualStrings("cat avocado  | wc", ed.buf.items);
    // Esc puts the typed word back and closes the menu.
    _ = ed.handleKey(.escape);
    try testing.expectEqualStrings("cat a | wc", ed.buf.items);
    try testing.expectEqual(@as(usize, 5), ed.cursor);
    try testing.expect(ed.menu == null);
}

test "Enter keeps the menu selection and other keys close the menu" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    typeText(&ed, "cat a");
    ed.menu = try pager.Menu.init(testing.allocator, &.{ "apple ", "apricot " }, ed.buf.items, 4, 5);
    _ = ed.handleKey(.{ .byte = '\t' });
    try testing.expectEqual(Outcome.handled, ed.handleKey(.{ .byte = '\r' }));
    try testing.expectEqualStrings("cat apple ", ed.buf.items);
    try testing.expect(ed.menu == null);

    // With nothing selected, Enter closes the menu and submits the line.
    ed.menu = try pager.Menu.init(testing.allocator, &.{ "x", "y" }, ed.buf.items, 10, 10);
    try testing.expectEqual(Outcome.accept, ed.handleKey(.{ .byte = '\r' }));
    try testing.expect(ed.menu == null);

    // A typed key closes the menu and is inserted.
    ed.menu = try pager.Menu.init(testing.allocator, &.{ "x", "y" }, ed.buf.items, 10, 10);
    _ = ed.handleKey(.{ .byte = '\t' });
    _ = ed.handleKey(.{ .byte = 'z' });
    try testing.expectEqualStrings("cat apple xz", ed.buf.items);
    try testing.expect(ed.menu == null);

    // Ctrl-G restores the word like Esc.
    ed.menu = try pager.Menu.init(testing.allocator, &.{ "q1", "q2" }, ed.buf.items, 10, 12);
    _ = ed.handleKey(.{ .byte = '\t' });
    try testing.expectEqualStrings("cat apple q1", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 7 });
    try testing.expectEqualStrings("cat apple xz", ed.buf.items);
}

test "layout wraps the way the terminal does" {
    // A row filled to the margin waits there; the next character wraps.
    try testing.expectEqual(Pos{ .row = 0, .col = 4 }, layout(.{}, "abcd", 4, .buffer));
    try testing.expectEqual(Pos{ .row = 1, .col = 1 }, layout(.{}, "abcde", 4, .buffer));
    try testing.expectEqual(Pos{ .row = 1, .col = 0 }, layout(.{}, "abcd", 4, .buffer).settled(4));
    // A wide character that does not fit leaves the last column empty.
    try testing.expectEqual(Pos{ .row = 1, .col = 2 }, layout(.{}, "abc\u{4e2d}", 4, .buffer));
    // A combining mark takes no room.
    try testing.expectEqual(Pos{ .row = 0, .col = 2 }, layout(.{}, "e\u{301}z", 4, .buffer));
    // Caret notation is two characters that wrap independently.
    try testing.expectEqual(Pos{ .row = 1, .col = 1 }, layout(.{}, "abc\t", 4, .buffer));
    // A prompt's escape sequences and control bytes take no room.
    try testing.expectEqual(Pos{ .row = 0, .col = 2 }, layout(.{}, "\x1b[1;32m$\x1b[0m \x1b]0;t\x07", 4, .prompt));
}

test "the cursor shows on the cell of the character after it" {
    // Before a wide character that wraps: the start of the next row.
    const text = "abc\u{4e2d}";
    try testing.expectEqual(Pos{ .row = 1, .col = 0 }, cursorCell(layout(.{}, text[0..3], 4, .buffer), text, 3, 4));
    // At the end of a full row: the start of the next one.
    try testing.expectEqual(Pos{ .row = 1, .col = 0 }, cursorCell(layout(.{}, "abcd", 4, .buffer), "abcd", 4, 4));
    try testing.expectEqual(Pos{ .row = 0, .col = 2 }, cursorCell(layout(.{}, "ab", 4, .buffer), "abcd", 2, 4));
}

test "writeRows keeps the window and every escape sequence" {
    var out: std.Io.Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    // Rows: "abcd" | "ef" | "gh" | "ij".
    writeRows(&out.writer, "abcdef\r\n\x1b[1mgh\r\nij", 4, 1, 2);
    try testing.expectEqualStrings("ef\r\n\x1b[1mgh\r", out.writer.buffered());
}

test "continuation prompts indent by open blocks" {
    var nesting: Nesting = .{};
    nesting.feed("if true {");
    try testing.expectEqual(@as(usize, 1), nesting.depth);
    nesting.feed("for x in a b; do # a { in a comment");
    try testing.expectEqual(@as(usize, 2), nesting.depth);
    nesting.feed("echo \"} (\" '{' done=1 ${#x}");
    try testing.expectEqual(@as(usize, 2), nesting.depth);
    nesting.feed("done; }");
    try testing.expectEqual(@as(usize, 0), nesting.depth);
    nesting.feed("fi )");
    try testing.expectEqual(@as(usize, 0), nesting.depth);
    nesting.feed("echo 'open");
    nesting.feed("{ still quoted' {");
    try testing.expectEqual(@as(usize, 1), nesting.depth);
}

test "up and down move by screen row in a wrapped line" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "echo old");
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();
    ed.width = 10;
    ed.prompt_text = "$ ";

    // Rows: "$ echo aaa" | "aaaaaaaaaa" | "aaa".
    ed.setLine("echo aaaaaaaaaaaaaaaa");
    ed.moveVertical(-1);
    try testing.expectEqual(@as(usize, 11), ed.cursor);
    ed.moveVertical(-1);
    try testing.expectEqual(@as(usize, 1), ed.cursor);
    ed.moveVertical(1);
    try testing.expectEqual(@as(usize, 11), ed.cursor);
    // The last row is shorter: the cursor goes to its end.
    ed.cursor = 15;
    ed.moveVertical(1);
    try testing.expectEqual(ed.buf.items.len, ed.cursor);
    // From the first row, Up browses history, and keeps browsing while the
    // recalled entry is unedited.
    ed.cursor = 3;
    ed.moveVertical(-1);
    try testing.expectEqualStrings("echo old", ed.buf.items);
    ed.moveVertical(1);
    try testing.expectEqualStrings("echo aaaaaaaaaaaaaaaa", ed.buf.items);
}

test "line keys act on the current line of a multi-line command" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("if true {\necho one\n}");
    ed.cursor = 12;
    _ = ed.handleKey(.{ .byte = 1 }); // Ctrl-A
    try testing.expectEqual(@as(usize, 10), ed.cursor);
    _ = ed.handleKey(.{ .byte = 5 }); // Ctrl-E
    try testing.expectEqual(@as(usize, 18), ed.cursor);
    _ = ed.handleKey(.{ .byte = 11 }); // Ctrl-K at the end joins the next line
    try testing.expectEqualStrings("if true {\necho one}", ed.buf.items);
    ed.cursor = 15;
    _ = ed.handleKey(.{ .byte = 21 }); // Ctrl-U kills to the line start
    try testing.expectEqualStrings("if true {\none}", ed.buf.items);
    _ = ed.handleKey(.{ .byte = 21 }); // and then joins the previous line
    try testing.expectEqualStrings("if true {one}", ed.buf.items);
    _ = ed.handleKey(.{ .alt = '\r' }); // Alt-Enter splits it again
    try testing.expectEqualStrings("if true {\none}", ed.buf.items);
}

test "reflowedCursorRow re-wraps each drawn line at the new width" {
    // "$ " and 48 columns on 30 columns take two rows, with the cursor at
    // the end on row 1. At 20 columns the cursor is on row 2, at 60 on row 0.
    const line = "$ " ++ "z" ** 48;
    try testing.expectEqual(@as(usize, 2), reflowedCursorRow(line, 30, 20, .{ .row = 1, .col = 20 }));
    try testing.expectEqual(@as(usize, 0), reflowedCursorRow(line, 30, 60, .{ .row = 1, .col = 20 }));
    // Line feeds keep lines apart; escapes and carriage returns take no
    // room. The first line fills its row exactly, so the row after it is a
    // line of its own. At 5 columns the lines take 2, 1 and 1 rows.
    const frame = "\x1b[1m$ " ++ "a" ** 8 ++ "\x1b[0m\r\n\r\n> bb\r\n> " ++ "c" ** 12;
    try testing.expectEqual(@as(usize, 4), reflowedCursorRow(frame, 10, 5, .{ .row = 3, .col = 4 }));
    try testing.expectEqual(@as(usize, 6), reflowedCursorRow(frame, 10, 5, .{ .row = 4, .col = 4 }));
    try testing.expectEqual(@as(usize, 2), reflowedCursorRow(frame, 10, 5, .{ .row = 1, .col = 0 }));
}
