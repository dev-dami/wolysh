//! Interactive line editor: cursor movement, history, tab completion,
//! autosuggestions, syntax highlighting, a kill ring with undo, bracketed
//! paste and an optional vi mode.
//!
//! Rendering is a full-line redraw. The editor tracks how many terminal rows the
//! previous frame occupied, moves back to the start of the input, clears, and
//! repaints — then walks the cursor to its logical position. That keeps wrapped
//! lines and long histories correct without incremental-diff bookkeeping.
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
    resize,
    unknown,
};

pub const Outcome = enum { handled, accept, cancel, eof };

/// What the previous key did; consecutive kills append to one kill-ring
/// entry, Alt-Y only follows a yank, and typed characters undo as a group.
pub const Command = enum { other, insert, kill, yank, yank_arg, undo };

const kill_ring_max = 16;
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

/// Word characters for the readline word commands (Alt-F/B/D, Alt-U/L/C):
/// letters and digits, and every byte of a multi-byte character.
fn isWordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n';
}

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
    /// Scratch buffers reused between frames.
    body: std.Io.Writer.Allocating,
    frame: std.Io.Writer.Allocating,
    visible_scratch: std.ArrayList(u8) = .empty,
    command_frame_active: bool = false,
    command_cursor_row: usize = 0,
    command_end_row: usize = 0,
    /// Set when the last line was cancelled with Ctrl-C.
    interrupted: bool = false,

    prompt_text: []const u8 = "",
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
    }

    fn resetLine(self: *Editor) void {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.stashed.clearRetainingCapacity();
        self.interrupted = false;
        self.command_frame_active = false;
        self.command_cursor_row = 0;
        self.command_end_row = 0;
        self.hints = true;
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
        self.resetLine();
        self.prompt_text = prompt_text;
        self.write_continuation = write_continuation;

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
                    self.write("\r\n");
                    if (is_complete) |check| {
                        if (!check(self.buf.items)) {
                            // Each continuation line starts in vi insert mode.
                            self.vi.reset();
                            self.buf.append(self.sh.gpa, '\n') catch return null;
                            self.cursor = self.buf.items.len;
                            self.hist_index = null;
                            self.command_cursor_row = self.command_end_row + 1;
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
        self.before.clearRetainingCapacity();
        self.before.appendSlice(self.sh.gpa, self.buf.items) catch {};
        const before_cursor = self.cursor;
        self.this_command = .other;

        const outcome = if (self.sh.options.vi and self.vi.mode == .normal)
            vi.handleNormal(self, key)
        else
            self.handleInsertKey(key);

        self.recordUndo(before_cursor);
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

        switch (key) {
            // The terminal is gone or the shell got SIGHUP: no more keys will
            // come, even with text on the line (Ctrl-D arrives as a byte).
            .eof => {
                self.write("\r\n");
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
                else => {},
            },
            .left => self.moveLeft(),
            .right => self.acceptSuggestionOrMoveRight(),
            .home => self.cursor = 0,
            .end => self.cursor = self.buf.items.len,
            .delete => self.deleteAtCursor(),
            .word_left => self.moveWordLeft(),
            .word_right => self.moveWordRight(),
            .up => self.moveVertical(-1),
            .down => self.moveVertical(1),
            .paste_start => self.readPaste(),
            .page_up, .page_down, .resize, .unknown => {},
        }
        return .handled;
    }

    fn handleControlOrByte(self: *Editor, b: u8) Outcome {
        switch (b) {
            '\r', '\n' => return .accept,
            3 => return self.cancelLine(),
            4 => return self.endOfInput(), // Ctrl-D
            1 => self.cursor = 0, // Ctrl-A
            5 => self.cursor = self.buf.items.len, // Ctrl-E
            2 => self.moveLeft(), // Ctrl-B
            6 => self.moveRight(), // Ctrl-F
            11 => self.killRange(self.cursor, self.buf.items.len, .forward, true), // Ctrl-K
            21 => self.killRange(0, self.cursor, .backward, true), // Ctrl-U
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
        self.command_frame_active = false;
        self.command_cursor_row = 0;
    }

    // --- rendering ----------------------------------------------------------

    fn updateWidth(self: *Editor) void {
        if (sys.windowSize(self.out_fd)) |ws| self.width = ws.cols;
        if (self.width == 0) self.width = 80;
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

    fn rowsFor(self: *const Editor, columns: usize) usize {
        if (columns == 0) return 1;
        return (columns + self.width - 1) / self.width;
    }

    const Decoration = enum { plain, highlighted, full };

    fn renderFrame(self: *Editor, prompt_text: []const u8, text: []const u8, cursor: usize, decoration: Decoration) void {
        self.updateWidth();
        self.frame.writer.end = 0;

        var continuation: std.Io.Writer.Allocating = .init(self.sh.gpa);
        defer continuation.deinit();

        var line_start: usize = 0;
        var line_index: usize = 0;
        var visual_start: usize = 0;
        var cursor_row: usize = 0;
        var cursor_col: usize = 0;
        var cursor_found = false;
        var end_row: usize = 0;
        var end_col: usize = 0;
        const multiline = std.mem.indexOfScalar(u8, text, '\n') != null;
        const colour = decoration != .plain and self.sh.config.highlight;

        while (line_start <= text.len) : (line_index += 1) {
            const line_end = std.mem.indexOfScalarPos(u8, text, line_start, '\n') orelse text.len;
            const line = text[line_start..line_end];
            continuation.writer.end = 0;
            if (line_index == 0) {
                tryWrite(&self.frame.writer, prompt_text);
            } else if (self.write_continuation) |write_prompt| {
                write_prompt(&continuation.writer, self.sh, line_index) catch {};
                tryWrite(&self.frame.writer, continuation.writer.buffered());
            }
            const prompt_width = if (line_index == 0)
                displayWidth(prompt_text)
            else
                displayWidth(continuation.writer.buffered());

            if (!cursor_found and cursor >= line_start and cursor <= line_end) {
                const position = prompt_width + wcwidth.width(text[line_start..cursor]);
                cursor_row = visual_start + position / self.width;
                cursor_col = position % self.width;
                cursor_found = true;
            }

            const shown = self.visible(line);
            if (colour) {
                highlight.render(&self.frame.writer, self.sh, shown) catch {};
            } else {
                self.frame.writer.writeAll(shown) catch {};
            }

            const line_width = prompt_width + wcwidth.width(line);
            if (line_end < text.len) {
                self.frame.writer.writeAll("\r\n") catch {};
                visual_start += self.rowsFor(line_width);
                line_start = line_end + 1;
                continue;
            }

            var correction_text: [320]u8 = undefined;
            const suggestion = if (decoration == .full and !multiline) blk: {
                if (self.currentCachedCorrection()) |name| {
                    break :blk std.fmt.bufPrint(&correction_text, "  => {s}", .{name}) catch null;
                }
                break :blk self.currentSuggestion();
            } else null;
            var hint_width: usize = 0;
            if (suggestion) |hint_text| {
                const hint = self.visible(hint_text);
                hint_width = wcwidth.width(hint_text);
                self.frame.writer.writeAll(if (highlight.colorEnabled(self.sh)) highlight.gray else highlight.dim) catch {};
                self.frame.writer.writeAll(hint) catch {};
                self.frame.writer.writeAll(highlight.reset) catch {};
            }

            const final_width = line_width + hint_width;
            end_row = visual_start + final_width / self.width;
            end_col = final_width % self.width;
            // At the exact right margin the terminal has not wrapped yet;
            // force the wrap so the row arithmetic holds.
            if (final_width > 0 and end_col == 0) self.frame.writer.writeAll("\r\n") catch {};
            break;
        }

        if (!cursor_found) {
            cursor_row = end_row;
            cursor_col = end_col;
        }

        self.write("\r");
        if (self.command_frame_active and self.command_cursor_row > 0) {
            var up: [64]u8 = undefined;
            const sequence = std.fmt.bufPrint(&up, "\x1b[{d}A", .{self.command_cursor_row}) catch "";
            self.write(sequence);
        }
        self.write("\x1b[J");
        self.write(self.frame.writer.buffered());

        self.write("\r");
        var scratch: [64]u8 = undefined;
        if (end_row > cursor_row) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}A", .{end_row - cursor_row}) catch "";
            self.write(sequence);
        } else if (cursor_row > end_row) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}B", .{cursor_row - end_row}) catch "";
            self.write(sequence);
        }
        if (cursor_col > 0) {
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}C", .{cursor_col}) catch "";
            self.write(sequence);
        }

        self.command_frame_active = true;
        self.command_cursor_row = cursor_row;
        self.command_end_row = end_row;
    }

    /// Moves below the current frame so output can follow it; the next render
    /// starts a fresh frame there.
    fn leaveFrame(self: *Editor) void {
        if (self.command_frame_active and self.command_end_row > self.command_cursor_row) {
            var scratch: [64]u8 = undefined;
            const sequence = std.fmt.bufPrint(&scratch, "\x1b[{d}B", .{self.command_end_row - self.command_cursor_row}) catch "";
            self.write(sequence);
        }
        self.write("\r\n");
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
            'Z' => .unknown,
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

    fn moveVertical(self: *Editor, direction: i8) void {
        const previous_newline = std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n');
        const line_start = if (previous_newline) |index| index + 1 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, self.buf.items, line_start, '\n') orelse self.buf.items.len;
        const column = wcwidth.width(self.buf.items[line_start..self.cursor]);

        if (direction < 0) {
            if (line_start == 0) {
                self.historyPrev();
                return;
            }
            const previous_end = line_start - 1;
            const previous_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..previous_end], '\n')) |index|
                index + 1
            else
                0;
            self.cursor = previous_start + byteOffsetAtColumn(self.buf.items[previous_start..previous_end], column);
            return;
        }

        if (line_end == self.buf.items.len) {
            self.historyNext();
            return;
        }
        const next_start = line_end + 1;
        const next_end = std.mem.indexOfScalarPos(u8, self.buf.items, next_start, '\n') orelse self.buf.items.len;
        self.cursor = next_start + byteOffsetAtColumn(self.buf.items[next_start..next_end], column);
    }

    fn byteOffsetAtColumn(text: []const u8, column: usize) usize {
        var offset: usize = 0;
        var current_column: usize = 0;
        while (offset < text.len) {
            const next = wcwidth.nextCluster(text, offset);
            const next_column = current_column + wcwidth.width(text[offset..next]);
            if (next_column > column) break;
            offset = next;
            current_column = next_column;
        }
        return offset;
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

        const index = self.sh.hist.searchBackward(self.sh.hist.count(), self.buf.items) orelse return null;
        const entry = self.sh.hist.get(index);
        if (entry.len <= self.buf.items.len) return null;
        return entry[self.buf.items.len..];
    }

    fn acceptSuggestionOrMoveRight(self: *Editor) void {
        if (self.currentCachedCorrection()) |command| {
            self.setLine(command);
            return;
        }
        if (self.currentSuggestion()) |remaining| {
            self.insertSlice(remaining);
            return;
        }
        self.moveRight();
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

        // Ambiguous: list the candidates below the line, then repaint.
        self.leaveFrame();
        var col: usize = 0;
        for (result.items) |item| {
            const label = std.mem.trimEnd(u8, item, " ");
            const label_width = wcwidth.width(label);
            if (col != 0 and col + label_width + 2 > self.width) {
                self.write("\r\n");
                col = 0;
            }
            self.write(self.visible(label));
            self.write("  ");
            col += label_width + 2;
        }
        self.write("\r\n");
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
                    },
                },
                .utf8 => |sequence| {
                    query.appendSlice(self.sh.gpa, sequence.bytes[0..sequence.len]) catch {};
                    match_index = self.sh.hist.searchBackwardContains(self.sh.hist.count(), query.items);
                },
                .resize => self.updateWidth(),
                .escape, .eof => return,
                else => {},
            }
        }
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
