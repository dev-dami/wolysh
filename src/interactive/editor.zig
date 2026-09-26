//! Interactive line editor: cursor movement, history, tab completion,
//! autosuggestions and syntax highlighting.
//!
//! Rendering is a full-line redraw. The editor tracks how many terminal rows the
//! previous frame occupied, moves back to the start of the input, clears, and
//! repaints — then walks the cursor to its logical position. That keeps wrapped
//! lines and long histories correct without incremental-diff bookkeeping.

const std = @import("std");
const sys = @import("../sys.zig");
const shellmod = @import("../shell.zig");
const term = @import("term.zig");
const highlight = @import("highlight.zig");
const complete = @import("complete.zig");

const Shell = shellmod.Shell;
pub const IsComplete = *const fn ([]const u8) bool;
pub const WriteContinuationPrompt = *const fn (*std.Io.Writer, *Shell, usize) anyerror!void;

const Key = union(enum) {
    eof,
    byte: u8,
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
    unknown,
};

/// Display width of `text` in terminal columns, ignoring ANSI escape sequences.
/// Each UTF-8 code point counts as one column, which is correct for the prompt,
/// for highlighted command lines, and for the box-drawing/arrow characters used
/// in prompts and completion output.
pub fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            i += 1;
            if (i < text.len and text[i] == '[') {
                i += 1;
                while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
                if (i < text.len) i += 1;
            }
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        i += @min(sequence_len, text.len - i);
        width += 1;
    }
    return width;
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
    /// Rows occupied by the previous frame.
    last_rows: usize = 0,
    /// Scratch buffer for the highlighted body, reused between frames.
    body: std.Io.Writer.Allocating,
    frame: std.Io.Writer.Allocating,
    command_frame_active: bool = false,
    command_cursor_row: usize = 0,
    command_end_row: usize = 0,
    /// Set when the last line was cancelled with Ctrl-C.
    interrupted: bool = false,

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
        self.buf.deinit(self.sh.gpa);
        self.stashed.deinit(self.sh.gpa);
        self.body.deinit();
        self.frame.deinit();
    }

    /// Reads one line, with editing when stdin is a terminal. Returns null at
    /// end of input. The slice stays valid until the next call.
    pub fn readLine(self: *Editor, prompt_text: []const u8) ?[]const u8 {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.stashed.clearRetainingCapacity();
        self.interrupted = false;
        self.last_rows = 0;

        var raw = term.RawMode.enable(self.in_fd) orelse return self.readLinePlain();
        defer raw.disable();

        self.updateWidth();
        self.render(prompt_text);

        while (true) {
            const key = self.readKey();
            switch (key) {
                .eof => {
                    if (self.buf.items.len == 0) {
                        sys.writeStr(self.out_fd, "\r\n");
                        return null;
                    }
                    self.deleteAtCursor();
                },
                .byte => |b| switch (self.handleByte(b)) {
                    .handled => {},
                    .submit, .cancel => return self.buf.items,
                    .eof => return null,
                },
                .escape => {},
                .alt => |c| switch (c) {
                    'b', 'B' => self.moveWordLeft(),
                    'f', 'F' => self.moveWordRight(),
                    'd', 'D' => self.killWord(),
                    else => {},
                },
                .left => self.moveLeft(),
                .right => self.acceptSuggestionOrMoveRight(),
                .home => self.cursor = 0,
                .end => self.cursor = self.buf.items.len,
                .delete => self.deleteAtCursor(),
                .word_left => self.moveWordLeft(),
                .word_right => self.moveWordRight(),
                .up => self.historyPrev(),
                .down => self.historyNext(),
                .page_up, .page_down, .unknown => {},
            }
            self.render(prompt_text);
        }
    }

    pub fn readCommand(
        self: *Editor,
        prompt_text: []const u8,
        is_complete: IsComplete,
        write_continuation: WriteContinuationPrompt,
    ) ?[]const u8 {
        self.buf.clearRetainingCapacity();
        self.cursor = 0;
        self.hist_index = null;
        self.stashed.clearRetainingCapacity();
        self.interrupted = false;
        self.last_rows = 0;
        self.command_frame_active = false;
        self.command_cursor_row = 0;
        self.command_end_row = 0;

        var raw = term.RawMode.enable(self.in_fd) orelse return self.readCommandPlain(is_complete);
        defer raw.disable();

        self.updateWidth();
        self.renderCommand(prompt_text, write_continuation);

        while (true) {
            const key = self.readKey();
            switch (key) {
                .eof => {
                    if (self.buf.items.len == 0) {
                        sys.writeStr(self.out_fd, "\r\n");
                        return null;
                    }
                    self.deleteAtCursor();
                },
                .byte => |byte| {
                    if (byte == '\r' or byte == '\n') {
                        if (is_complete(self.buf.items)) {
                            self.cursor = self.buf.items.len;
                            self.renderCommand(prompt_text, write_continuation);
                            self.write("\r\n");
                            return self.buf.items;
                        }
                        self.cursor = self.buf.items.len;
                        self.renderCommand(prompt_text, write_continuation);
                        self.write("\r\n");
                        self.buf.append(self.sh.gpa, '\n') catch return null;
                        self.cursor = self.buf.items.len;
                        self.hist_index = null;
                        self.command_cursor_row = self.command_end_row + 1;
                        self.command_frame_active = true;
                        self.renderCommand(prompt_text, write_continuation);
                        continue;
                    }
                    switch (self.handleByte(byte)) {
                        .handled => {},
                        .cancel => return self.buf.items,
                        .submit => return self.buf.items,
                        .eof => return null,
                    }
                },
                .escape => {},
                .alt => |character| switch (character) {
                    'b', 'B' => self.moveWordLeft(),
                    'f', 'F' => self.moveWordRight(),
                    'd', 'D' => self.killWord(),
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
                .page_up, .page_down, .unknown => {},
            }
            self.renderCommand(prompt_text, write_continuation);
        }
    }

    fn readCommandPlain(self: *Editor, is_complete: IsComplete) ?[]const u8 {
        while (true) {
            const line_start = self.buf.items.len;
            while (true) {
                const byte = term.readByte(self.in_fd) orelse {
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
            if (is_complete(self.buf.items)) {
                self.cursor = self.buf.items.len;
                return self.buf.items;
            }
            self.buf.append(self.sh.gpa, '\n') catch return null;
        }
    }

    const ByteResult = enum { handled, submit, cancel, eof };

    fn handleByte(self: *Editor, b: u8) ByteResult {
        switch (b) {
            '\r', '\n' => {
                sys.writeStr(self.out_fd, "\r\n");
                return .submit;
            },
            3 => { // Ctrl-C: abandon the line and give a fresh prompt.
                sys.writeStr(self.out_fd, "^C\r\n");
                self.buf.clearRetainingCapacity();
                self.cursor = 0;
                self.last_rows = 0;
                self.interrupted = true;
                self.sh.last_status = 130;
                return .cancel;
            },
            4 => { // Ctrl-D
                if (self.buf.items.len == 0) {
                    sys.writeStr(self.out_fd, "\r\n");
                    return .eof;
                }
                self.deleteAtCursor();
            },
            1 => self.cursor = 0, // Ctrl-A
            5 => self.cursor = self.buf.items.len, // Ctrl-E
            2 => self.moveLeft(), // Ctrl-B
            6 => self.moveRight(), // Ctrl-F
            11 => self.killToEnd(), // Ctrl-K
            21 => self.killToStart(), // Ctrl-U
            23 => self.killWord(), // Ctrl-W
            12 => { // Ctrl-L
                sys.writeStr(self.out_fd, "\x1b[2J\x1b[H");
                self.last_rows = 0;
            },
            20 => self.transpose(), // Ctrl-T
            16 => self.historyPrev(), // Ctrl-P
            14 => self.historyNext(), // Ctrl-N
            18 => self.reverseSearch(), // Ctrl-R
            0x7f, 8 => self.deleteBefore(),
            '\t' => self.handleTab(),
            else => if (b >= 0x20) self.insertByte(b),
        }
        return .handled;
    }

    /// Fallback for a non-terminal stdin: plain line reading, no editing.
    fn readLinePlain(self: *Editor) ?[]const u8 {
        self.buf.clearRetainingCapacity();
        while (true) {
            const b = term.readByte(self.in_fd) orelse {
                if (self.buf.items.len == 0) return null;
                break;
            };
            if (b == '\n') break;
            self.buf.append(self.sh.gpa, b) catch return null;
        }
        if (self.buf.items.len > 0 and self.buf.items[self.buf.items.len - 1] == '\r') {
            self.buf.items.len -= 1;
        }
        self.cursor = self.buf.items.len;
        return self.buf.items;
    }

    // --- rendering ----------------------------------------------------------

    fn updateWidth(self: *Editor) void {
        if (sys.windowSize(self.out_fd)) |ws| self.width = ws.cols;
        if (self.width == 0) self.width = 80;
    }

    fn render(self: *Editor, prompt_text: []const u8) void {
        self.updateWidth();

        self.body.writer.end = 0;
        if (self.sh.config.highlight) {
            highlight.render(&self.body.writer, self.sh, self.buf.items) catch {};
        } else {
            self.body.writer.writeAll(self.buf.items) catch {};
        }

        const correction = self.currentCachedCorrection();
        var correction_text: [320]u8 = undefined;
        const suggestion = if (correction) |name|
            std.fmt.bufPrint(&correction_text, "  => {s}", .{name}) catch null
        else
            self.currentSuggestion();
        // All of this is measured in *display columns*, not bytes: the
        // highlighted body carries ANSI escapes and the prompt marker is a
        // multi-byte code point. Counting bytes parked the cursor far from the
        // text and drifted the prompt away from the output above it.
        const body_cols = displayWidth(self.body.writer.buffered());
        const hint_cols = if (suggestion) |s| displayWidth(s) else 0;
        const prompt_cols = displayWidth(prompt_text);
        const end_cols = prompt_cols + body_cols + hint_cols;
        const end_row = end_cols / self.width;

        const cursor_cols = prompt_cols + displayWidth(self.buf.items[0..self.cursor]);
        const cur_row = cursor_cols / self.width;
        const cur_col = cursor_cols % self.width;

        var scratch: [64]u8 = undefined;

        // Back to the first row of the previous frame, then clear it away.
        self.write("\r");
        if (self.last_rows > 0) {
            const up = std.fmt.bufPrint(&scratch, "\x1b[{d}A", .{self.last_rows}) catch "";
            self.write(up);
        }
        self.write("\x1b[J");

        self.write(prompt_text);
        self.write(self.body.writer.buffered());
        if (suggestion) |remaining| {
            self.write(highlight.gray);
            self.write(remaining);
            self.write(highlight.reset);
        }

        // Walk the cursor from the end of the frame to its logical position.
        self.write("\r");
        if (end_row > cur_row) {
            const up = std.fmt.bufPrint(&scratch, "\x1b[{d}A", .{end_row - cur_row}) catch "";
            self.write(up);
        } else if (cur_row > end_row) {
            const down = std.fmt.bufPrint(&scratch, "\x1b[{d}B", .{cur_row - end_row}) catch "";
            self.write(down);
        }
        if (cur_col > 0) {
            const right = std.fmt.bufPrint(&scratch, "\x1b[{d}C", .{cur_col}) catch "";
            self.write(right);
        }

        self.last_rows = end_row;
    }

    fn renderCommand(self: *Editor, prompt_text: []const u8, write_continuation: WriteContinuationPrompt) void {
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
        const multiline = std.mem.indexOfScalar(u8, self.buf.items, '\n') != null;

        while (line_start <= self.buf.items.len) : (line_index += 1) {
            const line_end = std.mem.indexOfScalarPos(u8, self.buf.items, line_start, '\n') orelse self.buf.items.len;
            const text = self.buf.items[line_start..line_end];
            continuation.writer.end = 0;
            if (line_index == 0) {
                tryWrite(&self.frame.writer, prompt_text);
            } else {
                write_continuation(&continuation.writer, self.sh, line_index) catch {};
                tryWrite(&self.frame.writer, continuation.writer.buffered());
            }
            const prompt_width = if (line_index == 0)
                displayWidth(prompt_text)
            else
                displayWidth(continuation.writer.buffered());

            if (!cursor_found and self.cursor >= line_start and self.cursor <= line_end) {
                const position = prompt_width + displayWidth(self.buf.items[line_start..self.cursor]);
                cursor_row = visual_start + position / self.width;
                cursor_col = position % self.width;
                cursor_found = true;
            }

            if (self.sh.config.highlight) {
                highlight.render(&self.frame.writer, self.sh, text) catch {};
            } else {
                self.frame.writer.writeAll(text) catch {};
            }

            const line_width = prompt_width + displayWidth(text);
            if (line_end < self.buf.items.len) {
                self.frame.writer.writeAll("\r\n") catch {};
                visual_start += line_width / self.width + 1;
                line_start = line_end + 1;
                continue;
            }

            var correction_text: [320]u8 = undefined;
            const suggestion = if (!multiline) blk: {
                if (self.currentCachedCorrection()) |name| {
                    break :blk std.fmt.bufPrint(&correction_text, "  => {s}", .{name}) catch null;
                }
                break :blk self.currentSuggestion();
            } else null;
            const hint_width = if (suggestion) |text_hint| displayWidth(text_hint) else 0;
            if (suggestion) |hint| {
                self.frame.writer.writeAll(highlight.gray) catch {};
                self.frame.writer.writeAll(hint) catch {};
                self.frame.writer.writeAll(highlight.reset) catch {};
            }

            const final_width = line_width + hint_width;
            end_row = visual_start + final_width / self.width;
            end_col = final_width % self.width;
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

    fn tryWrite(writer: *std.Io.Writer, text: []const u8) void {
        writer.writeAll(text) catch {};
    }

    fn write(self: *Editor, text: []const u8) void {
        sys.writeStr(self.out_fd, text);
    }

    // --- editing ------------------------------------------------------------

    fn insertByte(self: *Editor, b: u8) void {
        self.buf.insert(self.sh.gpa, self.cursor, b) catch return;
        self.cursor += 1;
    }

    fn insertSlice(self: *Editor, text: []const u8) void {
        self.buf.insertSlice(self.sh.gpa, self.cursor, text) catch return;
        self.cursor += text.len;
    }

    fn setLine(self: *Editor, text: []const u8) void {
        self.buf.clearRetainingCapacity();
        self.buf.appendSlice(self.sh.gpa, text) catch return;
        self.cursor = self.buf.items.len;
    }

    fn deleteBefore(self: *Editor) void {
        if (self.cursor == 0) return;
        _ = self.buf.orderedRemove(self.cursor - 1);
        self.cursor -= 1;
    }

    fn deleteAtCursor(self: *Editor) void {
        if (self.cursor >= self.buf.items.len) return;
        _ = self.buf.orderedRemove(self.cursor);
    }

    fn moveLeft(self: *Editor) void {
        if (self.cursor > 0) self.cursor -= 1;
    }

    fn moveRight(self: *Editor) void {
        if (self.cursor < self.buf.items.len) self.cursor += 1;
    }

    fn moveVertical(self: *Editor, direction: i8) void {
        const previous_newline = std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor], '\n');
        const line_start = if (previous_newline) |index| index + 1 else 0;
        const line_end = std.mem.indexOfScalarPos(u8, self.buf.items, line_start, '\n') orelse self.buf.items.len;
        const column = displayWidth(self.buf.items[line_start..self.cursor]);

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
        while (offset < text.len and current_column < column) {
            const sequence_len = std.unicode.utf8ByteSequenceLength(text[offset]) catch 1;
            offset += @min(sequence_len, text.len - offset);
            current_column += 1;
        }
        return offset;
    }

    fn moveWordLeft(self: *Editor) void {
        var i = self.cursor;
        while (i > 0 and self.buf.items[i - 1] == ' ') i -= 1;
        while (i > 0 and self.buf.items[i - 1] != ' ') i -= 1;
        self.cursor = i;
    }

    fn moveWordRight(self: *Editor) void {
        var i = self.cursor;
        const len = self.buf.items.len;
        while (i < len and self.buf.items[i] == ' ') i += 1;
        while (i < len and self.buf.items[i] != ' ') i += 1;
        self.cursor = i;
    }

    fn killToEnd(self: *Editor) void {
        self.buf.items.len = self.cursor;
    }

    fn killToStart(self: *Editor) void {
        const tail = self.buf.items.len - self.cursor;
        std.mem.copyForwards(u8, self.buf.items[0..tail], self.buf.items[self.cursor..]);
        self.buf.items.len = tail;
        self.cursor = 0;
    }

    fn killWord(self: *Editor) void {
        var start = self.cursor;
        while (start > 0 and self.buf.items[start - 1] == ' ') start -= 1;
        while (start > 0 and self.buf.items[start - 1] != ' ') start -= 1;
        var i = self.cursor;
        while (i > start) : (i -= 1) {
            _ = self.buf.orderedRemove(i - 1);
        }
        self.cursor = start;
    }

    fn transpose(self: *Editor) void {
        if (self.buf.items.len < 2 or self.cursor == 0) return;
        var i = self.cursor;
        if (i >= self.buf.items.len) i = self.buf.items.len - 1;
        const tmp = self.buf.items[i - 1];
        self.buf.items[i - 1] = self.buf.items[i];
        self.buf.items[i] = tmp;
        if (self.cursor < self.buf.items.len) self.cursor += 1;
    }

    // --- history ------------------------------------------------------------

    fn historyPrev(self: *Editor) void {
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

    fn historyNext(self: *Editor) void {
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

        // Ambiguous: list the candidates, then let the caller repaint.
        self.write("\r\n");
        var col: usize = 0;
        for (result.items) |item| {
            if (col != 0 and col + displayWidth(item) + 2 > self.width) {
                self.write("\r\n");
                col = 0;
            }
            self.write(item);
            self.write("  ");
            col += displayWidth(item) + 2;
        }
        self.write("\r\n");
        self.last_rows = 0;
    }

    /// Replaces `[start, end)` with `text` and puts the cursor after it.
    fn replaceRange(self: *Editor, start: usize, end: usize, text: []const u8) void {
        var i = end;
        while (i > start) : (i -= 1) {
            _ = self.buf.orderedRemove(i - 1);
        }
        self.buf.insertSlice(self.sh.gpa, start, text) catch {
            self.cursor = start;
            return;
        };
        self.cursor = start + text.len;
    }

    // --- incremental reverse search ----------------------------------------

    fn reverseSearch(self: *Editor) void {
        var query: std.ArrayList(u8) = .empty;
        defer query.deinit(self.sh.gpa);

        var match_index: ?usize = null;
        var from = self.sh.hist.count();

        while (true) {
            const match_text = if (match_index) |index| self.sh.hist.get(index) else "";
            self.drawSearch(query.items, match_text);

            const key = self.readKey();
            switch (key) {
                .byte => |b| switch (b) {
                    7, 3 => { // Ctrl-G / Ctrl-C: cancel
                        self.write("\r\n");
                        return;
                    },
                    '\r', '\n' => {
                        if (match_index) |index| self.setLine(self.sh.hist.get(index));
                        self.write("\r\n");
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
                        if (query.items.len > 0) _ = query.pop();
                        from = self.sh.hist.count();
                        match_index = self.sh.hist.searchBackwardContains(from, query.items);
                    },
                    else => if (b >= 0x20) {
                        query.append(self.sh.gpa, b) catch {};
                        from = self.sh.hist.count();
                        match_index = self.sh.hist.searchBackwardContains(from, query.items);
                    },
                },
                .escape, .eof => {
                    self.write("\r\n");
                    return;
                },
                else => {},
            }
        }
    }

    fn drawSearch(self: *Editor, query: []const u8, match_text: []const u8) void {
        const label = "reverse-i-search";
        self.write("\r\x1b[K");
        self.write(highlight.yellow);
        self.write(label);
        self.write(highlight.reset);
        self.write("`");
        self.write(query);
        self.write("`: ");
        self.write(match_text);

        // Keep the cursor on the line when the match is wider than the screen.
        var scratch: [32]u8 = undefined;
        const used = displayWidth(label) + 4 + displayWidth(query) + displayWidth(match_text);
        if (used > self.width) {
            const back = std.fmt.bufPrint(&scratch, "\x1b[{d}D", .{used - self.width}) catch "";
            self.write(back);
        }
    }

    // --- key decoding -------------------------------------------------------

    fn readKey(self: *Editor) Key {
        const b = term.readByte(self.in_fd) orelse return .eof;
        if (b != 0x1b) return .{ .byte = b };

        const second = term.readByteTimeout(self.in_fd, 30) orelse return .escape;
        if (second != '[' and second != 'O') return .{ .alt = second };

        var params: [16]u8 = undefined;
        var count: usize = 0;
        while (count < params.len) {
            const c = term.readByteTimeout(self.in_fd, 30) orelse return .unknown;
            if (c >= 0x20 and c <= 0x3f) {
                params[count] = c;
                count += 1;
                continue;
            }
            return decodeCsi(params[0..count], c);
        }
        return .unknown;
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
                    else => .unknown,
                };
            },
            else => .unknown,
        };
    }
};

test "editor buffer editing helpers" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("echo hello");
    try std.testing.expectEqual(@as(usize, 10), ed.cursor);

    // Deleting at column 5 removes the space, giving "echohello".
    ed.cursor = 5;
    ed.deleteBefore();
    try std.testing.expectEqualStrings("echohello", ed.buf.items);
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);

    ed.setLine("  foo bar");
    ed.cursor = ed.buf.items.len;
    ed.killWord();
    try std.testing.expectEqualStrings("  foo ", ed.buf.items);

    ed.setLine("a b c");
    ed.cursor = 1;
    ed.killToEnd();
    try std.testing.expectEqualStrings("a", ed.buf.items);
}

test "grapheme-free word movement" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("one two three");
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 8), ed.cursor);
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 4), ed.cursor);
    ed.moveWordLeft();
    try std.testing.expectEqual(@as(usize, 0), ed.cursor);
    ed.moveWordRight();
    try std.testing.expectEqual(@as(usize, 3), ed.cursor);
}

test "autosuggestion comes from history" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "git checkout main");

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("git ch");
    try std.testing.expectEqualStrings("eckout main", ed.currentSuggestion().?);
    ed.acceptSuggestionOrMoveRight();
    try std.testing.expectEqualStrings("git checkout main", ed.buf.items);
}

test "cached command correction appears inline and Right accepts it" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.command_cache.remember(sh.gpa, "gti", &.{.{ .name = "git", .distance = 1 }});

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();
    ed.setLine("gt");

    try std.testing.expectEqualStrings("git", ed.currentCachedCorrection().?);
    ed.acceptSuggestionOrMoveRight();
    try std.testing.expectEqualStrings("git", ed.buf.items);
}

test "history navigation stashes the in-progress line" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    try sh.hist.add(sh.gpa, "first");
    try sh.hist.add(sh.gpa, "second");

    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("draft");
    ed.historyPrev();
    try std.testing.expectEqualStrings("second", ed.buf.items);
    ed.historyPrev();
    try std.testing.expectEqualStrings("first", ed.buf.items);
    ed.historyNext();
    try std.testing.expectEqualStrings("second", ed.buf.items);
    ed.historyNext();
    try std.testing.expectEqualStrings("draft", ed.buf.items);
}

test "up and down move between lines in a multiline command" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    ed.setLine("if true {\nprint first\nprint second");
    ed.moveVertical(-1);
    ed.insertByte('!');
    try std.testing.expectEqualStrings("if true {\nprint first!\nprint second", ed.buf.items);

    ed.moveVertical(1);
    try std.testing.expectEqual(ed.buf.items.len, ed.cursor);
}

test "display width ignores colour codes and counts code points" {
    try std.testing.expectEqual(@as(usize, 0), displayWidth(""));
    try std.testing.expectEqual(@as(usize, 5), displayWidth("abcde"));
    // Colour escapes take no columns.
    try std.testing.expectEqual(@as(usize, 5), displayWidth("\x1b[1m\x1b[36mabcde\x1b[0m"));
    // The prompt marker is three bytes but one column.
    try std.testing.expectEqual(@as(usize, 3), displayWidth("~ \u{276f}"));
    try std.testing.expectEqual(@as(usize, 1), displayWidth("\u{276f}"));
}

test "measured prompt width drives cursor placement" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var ed = Editor.init(&sh, -1, -1);
    defer ed.deinit();

    // A highlighted body must measure the same as the raw text.
    var body: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer body.deinit();
    try highlight.render(&body.writer, &sh, "echo \"a b\"");
    try std.testing.expectEqual(displayWidth("echo \"a b\""), displayWidth(body.writer.buffered()));
}
