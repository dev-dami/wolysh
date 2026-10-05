//! Runs a script read from standard input one statement at a time.
//!
//! A statement runs as soon as its last line has arrived, so a producer that
//! keeps the pipe open (an agent harness feeding commands) sees each command
//! execute immediately. Like bash, the reader never keeps input that belongs
//! after the statement it is about to run: a pipe is read a byte at a time,
//! and read-ahead from a regular file is handed back with `lseek` first, so
//! commands in the script can read the lines that follow them.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const ast = @import("ast.zig");
const lexer = @import("lexer.zig");
const parser_mod = @import("parser.zig");
const exec = @import("exec.zig");
const sys = @import("sys.zig");
const shellmod = @import("shell.zig");

const Shell = shellmod.Shell;

/// Reads the script from a private duplicate of standard input, above the
/// descriptors a script can name, so `exec <file` inside it changes what its
/// commands read and not where the script comes from.
pub fn run(sh: *Shell) u8 {
    const rc = linux.fcntl(0, linux.F.DUPFD_CLOEXEC, 64);
    switch (linux.errno(rc)) {
        .SUCCESS => {},
        // A closed standard input is an empty script, as in bash.
        .BADF => return 0,
        else => {
            sys.writeStr(2, "wsh: cannot read standard input\n");
            return 1;
        },
    }
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    return runFd(sh, fd);
}

fn runFd(sh: *Shell, fd: i32) u8 {
    var reader = Reader.init(sh.gpa, fd);
    defer reader.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(sh.gpa);

    var line: usize = 1;
    var status: u8 = 0;
    while (!sh.should_exit) {
        source.clearRetainingCapacity();
        sh.resetLineArena();
        const next = nextStatement(sh, &reader, &source, line) catch |err| {
            sys.writeStr(2, if (err == error.OutOfMemory) "wsh: out of memory\n" else "wsh: cannot read standard input\n");
            return 1;
        };
        switch (next) {
            .end => break,
            .syntax_error => {
                sh.last_status = 2;
                return 2;
            },
            .statement => {},
        }
        reader.handBack();
        status = exec.runSource(sh, source.items);
        reader.reclaim();
        line += std.mem.count(u8, source.items, "\n");
    }
    return if (sh.should_exit) sh.exit_code else status;
}

const Next = enum { statement, end, syntax_error };

fn nextStatement(sh: *Shell, reader: *Reader, source: *std.ArrayList(u8), line: usize) !Next {
    try readComplete(reader, source);
    if (source.items.len == 0) return .end;
    while (true) {
        var p = parser_mod.Parser.init(sh.scratch(), source.items);
        const program = p.parseProgram() catch |err| switch (err) {
            error.SyntaxError => {
                reportSyntaxError(sh, &p, line);
                return .syntax_error;
            },
            else => |e| return e,
        };
        if (!endsWithOpenIf(program.stmts) or lastTag(source.items) != .rbrace) return .statement;
        if (!try takeElse(reader, source)) return .statement;
        try readComplete(reader, source);
    }
}

/// Appends lines until `source` holds a complete statement or the input ends.
fn readComplete(reader: *Reader, source: *std.ArrayList(u8)) !void {
    if (source.items.len != 0 and !continuesLine(source.items) and exec.isComplete(source.items)) return;
    var heredoc: ?HereDoc = null;
    while (true) {
        const start = source.items.len;
        if (!try reader.readLine(source)) return;
        if (heredoc) |*doc| {
            if (!doc.endsAt(source.items[start..])) continue;
            heredoc = null;
        }
        if (continuesLine(source.items)) continue;
        if (exec.isComplete(source.items)) return;
        heredoc = try HereDoc.opened(reader.gpa, source, start);
    }
}

/// A here-document body being read at the top level. Only its delimiter line
/// can complete the statement, so the completeness check, which rescans the
/// whole statement, is skipped for the body lines in between; otherwise a
/// long body would cost time quadratic in its length.
const HereDoc = struct {
    storage: [256]u8 = undefined,
    len: usize = 0,
    strip_tabs: bool,

    fn delimiter(self: *const HereDoc) []const u8 {
        return self.storage[0..self.len];
    }

    fn endsAt(self: *const HereDoc, line: []const u8) bool {
        var text = std.mem.trimEnd(u8, line, "\n");
        text = std.mem.trimEnd(u8, text, "\r");
        if (self.strip_tabs) text = std.mem.trimStart(u8, text, "\t");
        return std.mem.eql(u8, text, self.delimiter());
    }

    /// The here-document the line at `line_start` opens, when it is the only
    /// one and its delimiter alone would complete the statement. Anything
    /// else (several bodies, an enclosing block, an unusual delimiter) keeps
    /// the exact line-by-line check.
    fn opened(gpa: std.mem.Allocator, source: *std.ArrayList(u8), line_start: usize) !?HereDoc {
        const line = source.items[line_start..];
        if (std.mem.indexOf(u8, line, "<<") == null) return null;
        var doc: ?HereDoc = null;
        var lx = lexer.Lexer.init(line);
        var pending_strip: ?bool = null;
        while (true) {
            const tok = lx.next();
            if (tok.tag == .eof) break;
            if (pending_strip) |strip| {
                if (tok.tag != .word or doc != null) return null;
                doc = unquote(tok.text, strip) orelse return null;
                pending_strip = null;
            } else if (tok.tag == .here_doc or tok.tag == .here_doc_strip) {
                pending_strip = tok.tag == .here_doc_strip;
            }
        }
        if (pending_strip != null) return null;
        const found = doc orelse return null;

        const len = source.items.len;
        defer source.shrinkRetainingCapacity(len);
        try source.appendSlice(gpa, found.delimiter());
        try source.append(gpa, '\n');
        return if (exec.isComplete(source.items)) found else null;
    }

    fn unquote(raw: []const u8, strip_tabs: bool) ?HereDoc {
        var doc = HereDoc{ .strip_tabs = strip_tabs };
        var quote: u8 = 0;
        var i: usize = 0;
        while (i < raw.len) : (i += 1) {
            var c = raw[i];
            if (quote == 0 and (c == '\'' or c == '"')) {
                quote = c;
                continue;
            }
            if (quote != 0 and c == quote) {
                quote = 0;
                continue;
            }
            if (c == '\\' and quote != '\'' and i + 1 < raw.len) {
                i += 1;
                c = raw[i];
            }
            if (doc.len == doc.storage.len) return null;
            doc.storage[doc.len] = c;
            doc.len += 1;
        }
        if (quote != 0 or doc.len == 0) return null;
        return doc;
    }
};

/// True when the last line ends in an unescaped backslash, which joins it to
/// the next one.
fn continuesLine(source: []const u8) bool {
    if (source.len == 0 or source[source.len - 1] != '\n') return false;
    var slashes: usize = 0;
    var i = source.len - 1;
    while (i > 0 and source[i - 1] == '\\') : (i -= 1) slashes += 1;
    return slashes % 2 == 1;
}

/// `if` statements accept an `else` on a later line, so one that ends the
/// statement without an `else` is not finished yet.
fn endsWithOpenIf(stmts: []const ast.Stmt) bool {
    if (stmts.len == 0) return false;
    var stmt = stmts[stmts.len - 1];
    while (true) {
        const branch = switch (stmt) {
            .if_ => |b| b,
            else => return false,
        };
        const else_block = branch.else_ orelse return true;
        // `else if` is a block holding the nested `if`, which may itself
        // still take an `else`.
        if (else_block.stmts.len != 1) return false;
        stmt = else_block.stmts[0];
    }
}

fn lastTag(source: []const u8) lexer.Tag {
    var lx = lexer.Lexer.init(source);
    var last: lexer.Tag = .eof;
    while (true) {
        const tok = lx.next();
        switch (tok.tag) {
            .eof => return last,
            .newline, .semi => {},
            else => last = tok.tag,
        }
    }
}

/// Looks for an `else` on the next non-blank line, but only among input that
/// has already arrived: a producer that has not written the next line yet
/// should see the `if` run now. Lines that are not an `else` go back to the
/// reader.
fn takeElse(reader: *Reader, source: *std.ArrayList(u8)) !bool {
    var look: std.ArrayList(u8) = .empty;
    defer look.deinit(reader.gpa);
    while (reader.ready()) {
        const start = look.items.len;
        if (!try reader.readLine(&look)) break;
        const text = std.mem.trim(u8, look.items[start..], " \t\r\n");
        if (text.len == 0 or text[0] == '#') continue;
        if (startsWithElse(text)) {
            try source.appendSlice(reader.gpa, look.items);
            return true;
        }
        break;
    }
    try reader.unread(look.items);
    return false;
}

fn startsWithElse(text: []const u8) bool {
    if (!std.mem.startsWith(u8, text, "else")) return false;
    if (text.len == 4) return true;
    return switch (text[4]) {
        ' ', '\t', '{' => true,
        else => false,
    };
}

fn reportSyntaxError(sh: *Shell, p: *parser_mod.Parser, first_line: usize) void {
    // The parser counts lines from the start of this statement.
    if (p.err_tok.tag != .eof) p.err_tok.line += first_line - 1;
    var buf: [512]u8 = undefined;
    const msg = p.message(&buf);
    var out: [640]u8 = undefined;
    const text = std.fmt.bufPrint(&out, "wsh: {s}\n", .{msg}) catch msg;
    sys.writeStr(sh.default_err, text);
}

/// Line reader that can give unconsumed input back to the descriptor.
const Reader = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    /// Regular files are read in blocks and rewound; anything else is read a
    /// byte at a time because a pipe cannot take bytes back.
    seekable: bool,
    buf: std.ArrayList(u8) = .empty,
    /// First byte of `buf` not yet handed out.
    pos: usize = 0,
    eof: bool = false,
    /// Offset `handBack` rewound the descriptor to, while a statement runs.
    rewound: ?usize = null,

    const block_size = 64 * 1024;

    fn init(gpa: std.mem.Allocator, fd: i32) Reader {
        const rc = linux.lseek(fd, 0, linux.SEEK.CUR);
        return .{ .gpa = gpa, .fd = fd, .seekable = linux.errno(rc) == .SUCCESS };
    }

    fn deinit(self: *Reader) void {
        self.buf.deinit(self.gpa);
    }

    /// Appends the next line, newline included, to `out`. False when the
    /// input is exhausted.
    fn readLine(self: *Reader, out: *std.ArrayList(u8)) !bool {
        var got = false;
        while (true) {
            const rest = self.buf.items[self.pos..];
            if (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
                try out.appendSlice(self.gpa, rest[0 .. nl + 1]);
                self.pos += nl + 1;
                return true;
            }
            if (rest.len != 0) {
                try out.appendSlice(self.gpa, rest);
                self.pos = self.buf.items.len;
                got = true;
            }
            if (self.eof) return got;
            try self.fill();
        }
    }

    /// Replaces the (fully consumed) buffer with the next read.
    fn fill(self: *Reader) !void {
        self.buf.clearRetainingCapacity();
        self.pos = 0;
        const want: usize = if (self.seekable) block_size else 1;
        try self.buf.ensureUnusedCapacity(self.gpa, want);
        const dest = self.buf.unusedCapacitySlice()[0..want];
        while (true) {
            const rc = linux.read(self.fd, dest.ptr, dest.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) self.eof = true;
                    self.buf.items.len = rc;
                    return;
                },
                .INTR => continue,
                .AGAIN => {
                    var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
                    _ = posix.poll(&fds, -1) catch return error.ReadFailed;
                },
                else => return error.ReadFailed,
            }
        }
    }

    /// True when reading would not block.
    fn ready(self: *Reader) bool {
        if (self.pos < self.buf.items.len or self.eof or self.seekable) return true;
        var fds = [_]posix.pollfd{.{ .fd = self.fd, .events = posix.POLL.IN, .revents = 0 }};
        const n = posix.poll(&fds, 0) catch return false;
        return n != 0;
    }

    /// Puts back `bytes`, the most recently read input.
    fn unread(self: *Reader, bytes: []const u8) !void {
        try self.buf.replaceRange(self.gpa, 0, self.pos, bytes);
        self.pos = 0;
    }

    /// Before a statement runs: rewinds a regular file over the read-ahead so
    /// the statement's commands read from where the statement ends.
    fn handBack(self: *Reader) void {
        if (!self.seekable) return;
        const ahead = self.buf.items.len - self.pos;
        if (ahead == 0) return;
        const rc = linux.lseek(self.fd, -@as(i64, @intCast(ahead)), linux.SEEK.CUR);
        if (linux.errno(rc) == .SUCCESS) self.rewound = rc;
    }

    /// After the statement: keeps the read-ahead when nothing moved the file
    /// offset, otherwise drops it and continues from wherever the commands
    /// left off.
    fn reclaim(self: *Reader) void {
        const offset = self.rewound orelse return;
        self.rewound = null;
        const ahead = self.buf.items.len - self.pos;
        const rc = linux.lseek(self.fd, 0, linux.SEEK.CUR);
        if (linux.errno(rc) == .SUCCESS and rc == offset) {
            _ = linux.lseek(self.fd, @intCast(ahead), linux.SEEK.CUR);
            return;
        }
        self.buf.clearRetainingCapacity();
        self.pos = 0;
        self.eof = false;
    }
};

const testing = std.testing;

fn pipeWith(bytes: []const u8) !i32 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    _ = sys.writeAll(fds[1], bytes);
    _ = linux.close(fds[1]);
    return fds[0];
}

test "the reader hands out lines without reading past them" {
    const fd = try pipeWith("one\ntwo\nlast");
    defer _ = linux.close(fd);
    var reader = Reader.init(testing.allocator, fd);
    defer reader.deinit();
    try testing.expect(!reader.seekable);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(try reader.readLine(&out));
    try testing.expectEqualStrings("one\n", out.items);
    // Nothing beyond the first line has been taken from the pipe.
    var rest: [16]u8 = undefined;
    try testing.expectEqual(@as(usize, 4), sys.readAll(fd, rest[0..4]));
    try testing.expectEqualStrings("two\n", rest[0..4]);

    out.clearRetainingCapacity();
    try testing.expect(try reader.readLine(&out));
    try testing.expectEqualStrings("last", out.items);
    try testing.expect(!try reader.readLine(&out));
}

test "unread lines come back before the rest of the input" {
    const fd = try pipeWith("a\nb\n");
    defer _ = linux.close(fd);
    var reader = Reader.init(testing.allocator, fd);
    defer reader.deinit();

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try testing.expect(try reader.readLine(&out));
    try reader.unread(out.items);
    out.clearRetainingCapacity();
    try testing.expect(try reader.readLine(&out));
    try testing.expect(try reader.readLine(&out));
    try testing.expectEqualStrings("a\nb\n", out.items);
}

test "statement boundaries follow line continuations and open ifs" {
    try testing.expect(continuesLine("echo a \\\n"));
    try testing.expect(!continuesLine("echo a \\\\\n"));
    try testing.expect(!continuesLine("echo a\n"));
    try testing.expect(startsWithElse("else {"));
    try testing.expect(startsWithElse("else if x {"));
    try testing.expect(!startsWithElse("elsewhere"));
    try testing.expectEqual(lexer.Tag.rbrace, lastTag("if true {\n echo\n}\n"));
}

test "a top-level here-document is recognised by its delimiter" {
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(testing.allocator);

    try source.appendSlice(testing.allocator, "cat <<-'END' > out\n");
    const doc = (try HereDoc.opened(testing.allocator, &source, 0)).?;
    try testing.expectEqualStrings("cat <<-'END' > out\n", source.items);
    try testing.expect(doc.endsAt("\t\tEND\n"));
    try testing.expect(!doc.endsAt("END later\n"));

    // Inside a block the delimiter alone does not finish the statement.
    source.clearRetainingCapacity();
    try source.appendSlice(testing.allocator, "if true {\ncat <<EOF\n");
    try testing.expect(try HereDoc.opened(testing.allocator, &source, "if true {\n".len) == null);

    // Two bodies on one line keep the exact check.
    source.clearRetainingCapacity();
    try source.appendSlice(testing.allocator, "cat <<A <<B\n");
    try testing.expect(try HereDoc.opened(testing.allocator, &source, 0) == null);
}

test "statements from a pipe run one at a time" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    exec.install(&sh);

    const fd = try pipeWith("let x = 1\nif x == 1 {\n  let y = \"then\"\n}\nelse {\n  let y = \"else\"\n}\nlet z = y\n");
    defer _ = linux.close(fd);
    try testing.expectEqual(@as(u8, 0), runFd(&sh, fd));
    try testing.expectEqualStrings("then", sh.getVar("z").?.string);
}

test "a syntax error stops the script with status 2" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    exec.install(&sh);
    sh.default_err = -1;

    const fd = try pipeWith("let x = 1\n)\nlet x = 2\n");
    defer _ = linux.close(fd);
    try testing.expectEqual(@as(u8, 2), runFd(&sh, fd));
    try testing.expectEqual(@as(i64, 1), sh.getVar("x").?.int);
}
