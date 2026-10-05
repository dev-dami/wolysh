//! Persistent, searchable command history.
//!
//! The history file starts with `header`; every later line is one entry with
//! `\` and newline escaped, so multi-line commands survive a restart. A file
//! without the header is the older plain format, one entry per line, and loads
//! unchanged. Entries are appended as they are entered (`appendToFile`), so a
//! crash or a closed terminal loses nothing and concurrent shells keep each
//! other's entries.

const std = @import("std");
const linux = std.os.linux;
const fs = @import("fs.zig");
const sys = @import("sys.zig");

pub const header = "#wsh-history v2";

pub const Error = std.mem.Allocator.Error || error{HistoryFileUnwritable};

/// `HISTCONTROL`: which entered lines are kept.
pub const Control = struct {
    ignorespace: bool = false,
    ignoredups: bool = true,
    erasedups: bool = false,

    /// Parses a colon-separated `HISTCONTROL`. Unset keeps wsh's default of
    /// skipping immediate repeats; once set, only the listed words apply.
    pub fn parse(text: ?[]const u8) Control {
        const value = text orelse return .{};
        var control = Control{ .ignoredups = false };
        var words = std.mem.splitScalar(u8, value, ':');
        while (words.next()) |word| {
            if (std.mem.eql(u8, word, "ignorespace")) {
                control.ignorespace = true;
            } else if (std.mem.eql(u8, word, "ignoredups")) {
                control.ignoredups = true;
            } else if (std.mem.eql(u8, word, "ignoreboth")) {
                control.ignorespace = true;
                control.ignoredups = true;
            } else if (std.mem.eql(u8, word, "erasedups")) {
                control.erasedups = true;
            }
        }
        return control;
    }
};

pub const History = struct {
    /// Oldest first, like the history file.
    entries: std.ArrayList([]u8) = .empty,
    limit: usize = 5000,
    /// Entries the history file is known to hold. Once it is well past
    /// `limit`, `appendToFile` rewrites the file with the newest `limit`.
    file_entries: usize = 0,
    /// First entry `history -a` has not written yet.
    unsaved: usize = 0,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        self.entries.deinit(allocator);
    }

    pub fn count(self: *const History) usize {
        return self.entries.items.len;
    }

    pub fn get(self: *const History, index: usize) []const u8 {
        return self.entries.items[index];
    }

    /// Appends a line, skipping blanks and immediate duplicates.
    pub fn add(self: *History, allocator: std.mem.Allocator, line: []const u8) !void {
        _ = try self.record(allocator, line, .{});
    }

    /// Adds an entered line under `control`. Returns the stored entry, or null
    /// when the line is not kept.
    pub fn record(self: *History, allocator: std.mem.Allocator, line: []const u8, control: Control) !?[]const u8 {
        if (control.ignorespace and line.len != 0 and (line[0] == ' ' or line[0] == '\t')) return null;
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return null;
        if (control.ignoredups and self.entries.items.len > 0) {
            if (std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], trimmed)) return null;
        }
        if (control.erasedups) {
            var index = self.entries.items.len;
            while (index > 0) {
                index -= 1;
                if (std.mem.eql(u8, self.entries.items[index], trimmed)) self.remove(allocator, index);
            }
        }
        const owned = try allocator.dupe(u8, trimmed);
        errdefer allocator.free(owned);
        try self.entries.append(allocator, owned);
        while (self.entries.items.len > self.limit) self.remove(allocator, 0);
        return owned;
    }

    pub fn remove(self: *History, allocator: std.mem.Allocator, index: usize) void {
        allocator.free(self.entries.orderedRemove(index));
        if (self.unsaved > index) self.unsaved -= 1;
    }

    pub fn clear(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        self.entries.clearRetainingCapacity();
        self.unsaved = 0;
    }

    /// Loads the whole history file, keeping its newest `limit` entries. A
    /// missing file is an empty history.
    pub fn load(self: *History, allocator: std.mem.Allocator, path: []const u8) !void {
        const data = (try readFile(allocator, path)) orelse return;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.list.deinit(allocator);

        self.file_entries = lines.list.items.len;
        const start = lines.list.items.len -| self.limit;
        for (lines.list.items[start..]) |line| {
            const entry = if (lines.escaped) try decode(allocator, line) else try allocator.dupe(u8, line);
            if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], entry)) {
                allocator.free(entry);
                continue;
            }
            self.entries.append(allocator, entry) catch |err| {
                allocator.free(entry);
                return err;
            };
        }
        while (self.entries.items.len > self.limit) self.remove(allocator, 0);
        self.unsaved = self.entries.items.len;
    }

    /// Adds every entry of another history file, for `history -r`.
    pub fn readFrom(self: *History, allocator: std.mem.Allocator, path: []const u8) !bool {
        const data = (try readFile(allocator, path)) orelse return false;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.list.deinit(allocator);
        for (lines.list.items) |line| {
            const entry = if (lines.escaped) try decode(allocator, line) else try allocator.dupe(u8, line);
            defer allocator.free(entry);
            _ = try self.record(allocator, entry, .{ .ignoredups = false });
        }
        return true;
    }

    /// Appends one entry to the history file with a single `O_APPEND` write,
    /// so concurrent shells interleave whole entries. The file is trimmed to
    /// `limit` once it has grown well past it.
    pub fn appendToFile(self: *History, allocator: std.mem.Allocator, path: []const u8, entry: []const u8) Error!void {
        // The history file's directory is the shell's own to create; a file
        // named to `history -a` or `-w` is not.
        makeParents(allocator, path) catch {};
        try appendEntries(allocator, path, &.{entry});
        self.file_entries += 1;
        if (self.file_entries > self.limit + trimSlack(self.limit)) try self.trimFile(allocator, path);
    }

    /// Rewrites the file with its newest `limit` entries, re-reading it first
    /// so entries other shells appended are kept.
    pub fn trimFile(self: *History, allocator: std.mem.Allocator, path: []const u8) Error!void {
        const data = (readFile(allocator, path) catch return error.HistoryFileUnwritable) orelse return;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.list.deinit(allocator);
        const start = lines.list.items.len -| self.limit;
        try rewriteLines(allocator, path, lines.list.items[start..], lines.escaped);
        self.file_entries = lines.list.items.len - start;
    }

    /// Index of the newest entry at or before `before` that starts with
    /// `prefix`, or null. Used for prefix history search.
    pub fn searchBackward(self: *const History, before: usize, prefix: []const u8) ?usize {
        if (self.entries.items.len == 0) return null;
        var i = @min(before, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            if (prefix.len == 0 or std.mem.startsWith(u8, self.entries.items[i], prefix)) return i;
        }
        return null;
    }

    /// Index of the newest entry that *contains* `needle`.
    pub fn searchBackwardContains(self: *const History, before: usize, needle: []const u8) ?usize {
        if (self.entries.items.len == 0) return null;
        var i = @min(before, self.entries.items.len);
        while (i > 0) {
            i -= 1;
            if (needle.len == 0 or std.mem.indexOf(u8, self.entries.items[i], needle) != null) return i;
        }
        return null;
    }
};

/// How far past `limit` the file may grow before it is rewritten; rewriting
/// on every command would make appends as costly as the old full saves.
fn trimSlack(limit: usize) usize {
    return @max(limit / 2, 100);
}

/// Escapes `\` and newline so an entry fits on one line.
pub fn encode(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: []const u8) !void {
    for (entry) |c| switch (c) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '\n' => try out.appendSlice(allocator, "\\n"),
        else => try out.append(allocator, c),
    };
}

/// Reverses `encode`. Any other backslash is kept as written.
pub fn decode(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, line.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            const next = line[i + 1];
            if (next == 'n' or next == '\\') {
                out.appendAssumeCapacity(if (next == 'n') '\n' else '\\');
                i += 1;
                continue;
            }
        }
        out.appendAssumeCapacity(line[i]);
    }
    return out.toOwnedSlice(allocator);
}

const Lines = struct {
    /// Slices into the file data, one per entry, still encoded when `escaped`.
    list: std.ArrayList([]const u8) = .empty,
    escaped: bool = false,
};

fn isEncoded(data: []const u8) bool {
    if (!std.mem.startsWith(u8, data, header)) return false;
    return data.len == header.len or data[header.len] == '\n';
}

fn fileLines(allocator: std.mem.Allocator, data: []const u8) !Lines {
    var lines = Lines{ .escaped = isEncoded(data) };
    errdefer lines.list.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // Shells racing to create the file can each write a header.
        if (lines.escaped and std.mem.eql(u8, line, header)) continue;
        try lines.list.append(allocator, line);
    }
    return lines;
}

/// The whole file, or null when it does not exist or cannot be read.
fn readFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    return fs.readFileAlloc(allocator, z, std.math.maxInt(usize));
}

/// Creates the directories leading to `path`, private to the user as the XDG
/// base directory specification asks.
fn makeParents(allocator: std.mem.Allocator, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    const z = try allocator.dupeZ(u8, parent);
    defer allocator.free(z);
    if (fs.isDir(z)) return;
    var end: usize = 1;
    while (end < z.len) : (end += 1) {
        if (z[end] != '/') continue;
        z[end] = 0;
        _ = linux.mkdirat(linux.AT.FDCWD, z.ptr, 0o700);
        z[end] = '/';
    }
    _ = linux.mkdirat(linux.AT.FDCWD, z.ptr, 0o700);
}

fn openHistory(z: [:0]const u8, flags: linux.O) ?i32 {
    const rc = linux.openat(linux.AT.FDCWD, z.ptr, flags, 0o600);
    if (linux.errno(rc) != .SUCCESS) return null;
    return @intCast(rc);
}

/// Appends entries in the encoded format, converting an older plain file
/// first so the two formats never mix.
pub fn appendEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const []const u8) Error!void {
    if (entries.len == 0) return;
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);

    var converted = false;
    while (true) {
        const fd = openHistory(z, .{ .ACCMODE = .RDWR, .CREAT = true, .APPEND = true, .CLOEXEC = true }) orelse
            return error.HistoryFileUnwritable;
        defer _ = linux.close(fd);

        const end = linux.lseek(fd, 0, linux.SEEK.END);
        if (linux.errno(end) != .SUCCESS) return error.HistoryFileUnwritable;
        var start: [header.len + 1]u8 = undefined;
        const empty = end == 0;
        if (!empty) {
            const got = linux.pread(fd, &start, start.len, 0);
            if (linux.errno(got) != .SUCCESS) return error.HistoryFileUnwritable;
            if (!isEncoded(start[0..got])) {
                if (converted) return error.HistoryFileUnwritable;
                try convertPlain(allocator, path);
                converted = true;
                continue;
            }
        }

        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        if (empty) try out.appendSlice(allocator, header ++ "\n");
        for (entries) |entry| {
            try encode(allocator, &out, entry);
            try out.append(allocator, '\n');
        }
        if (sys.writeAll(fd, out.items) != .ok) return error.HistoryFileUnwritable;
        return;
    }
}

fn convertPlain(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const data = (readFile(allocator, path) catch return error.HistoryFileUnwritable) orelse return;
    defer allocator.free(data);
    var lines = try fileLines(allocator, data);
    defer lines.list.deinit(allocator);
    try rewriteLines(allocator, path, lines.list.items, lines.escaped);
}

/// Drops the newest occurrence of each of `texts` from the history file and
/// returns how many entries the file keeps.
pub fn forgetInFile(allocator: std.mem.Allocator, path: []const u8, texts: []const []const u8) Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = (readFile(arena, path) catch return error.HistoryFileUnwritable) orelse return 0;
    const lines = try fileLines(arena, data);
    var entries: std.ArrayList([]const u8) = .empty;
    for (lines.list.items) |line| {
        try entries.append(arena, if (lines.escaped) try decode(arena, line) else line);
    }
    var changed = false;
    for (texts) |text| {
        var i = entries.items.len;
        while (i > 0) {
            i -= 1;
            if (!std.mem.eql(u8, entries.items[i], text)) continue;
            _ = entries.orderedRemove(i);
            changed = true;
            break;
        }
    }
    if (changed) try rewriteLines(allocator, path, entries.items, false);
    return entries.items.len;
}

/// Replaces the history file with `entries` (plain, unencoded text).
pub fn writeEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const []const u8) Error!void {
    try rewriteLines(allocator, path, entries, false);
}

/// Replaces the file through a temporary file and `rename`, so readers and a
/// crash only ever see the old or the new history.
fn rewriteLines(allocator: std.mem.Allocator, path: []const u8, lines: []const []const u8, encoded: bool) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, header ++ "\n");
    for (lines) |line| {
        if (encoded) try out.appendSlice(allocator, line) else try encode(allocator, &out, line);
        try out.append(allocator, '\n');
    }

    const target = try allocator.dupeZ(u8, path);
    defer allocator.free(target);
    const temp = try std.fmt.allocPrintSentinel(allocator, "{s}.{d}.tmp", .{ path, sys.getpid() }, 0);
    defer allocator.free(temp);

    const fd = openHistory(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }) orelse
        return error.HistoryFileUnwritable;
    const written = sys.writeAll(fd, out.items) == .ok and linux.errno(linux.fsync(fd)) == .SUCCESS;
    _ = linux.close(fd);
    if (!written or linux.errno(linux.rename(temp.ptr, target.ptr)) != .SUCCESS) {
        _ = fs.removeFile(temp);
        return error.HistoryFileUnwritable;
    }
}

test "history add, dedupe and search" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);

    try h.add(a, "ls -la");
    try h.add(a, "ls -la"); // duplicate is ignored
    try h.add(a, "");
    try h.add(a, "git status");
    try std.testing.expectEqual(@as(usize, 2), h.count());

    try std.testing.expectEqual(@as(?usize, 1), h.searchBackward(h.count(), "git"));
    try std.testing.expectEqual(@as(?usize, 0), h.searchBackward(h.count(), "ls"));
    try std.testing.expectEqual(@as(?usize, null), h.searchBackward(h.count(), "cargo"));
}

test "HISTCONTROL words" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);

    const both = Control.parse("ignoreboth");
    try std.testing.expect(try h.record(a, " secret", both) == null);
    try std.testing.expect(try h.record(a, "ls", both) != null);
    try std.testing.expect(try h.record(a, "ls", both) == null);

    const keep = Control.parse("ignorespace");
    try std.testing.expect(try h.record(a, "ls", keep) != null);
    try std.testing.expectEqual(@as(usize, 2), h.count());

    _ = try h.record(a, "pwd", keep);
    _ = try h.record(a, "ls", Control.parse("erasedups"));
    try std.testing.expectEqual(@as(usize, 2), h.count());
    try std.testing.expectEqualStrings("pwd", h.get(0));
    try std.testing.expectEqualStrings("ls", h.get(1));
}

test "encoding round-trips backslashes and newlines" {
    const a = std.testing.allocator;
    const entry = "if true {\n  printf 'a\\nb\\\\'\n}";
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try encode(a, &out, entry);
    try std.testing.expect(std.mem.indexOfScalar(u8, out.items, '\n') == null);
    const back = try decode(a, out.items);
    defer a.free(back);
    try std.testing.expectEqualStrings(entry, back);
}

test "history file appends, loads multi-line entries and trims" {
    const a = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "zig-cache-history-test-{d}", .{sys.getpid()});
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/sub/history", .{dir});
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer {
        _ = fs.removeFile(path_z);
        var sub_buf: [160]u8 = undefined;
        if (std.fmt.bufPrintZ(&sub_buf, "{s}/sub", .{dir})) |sub| _ = linux.unlinkat(linux.AT.FDCWD, sub.ptr, linux.AT.REMOVEDIR) else |_| {}
        if (std.fmt.bufPrintZ(&sub_buf, "{s}", .{dir})) |top| _ = linux.unlinkat(linux.AT.FDCWD, top.ptr, linux.AT.REMOVEDIR) else |_| {}
    }

    // An older plain file loads line by line, backslashes untouched.
    try makeParents(a, path);
    try std.testing.expect(fs.writeFile(path_z, "echo one\nprintf 'a\\nb'\n"));
    var plain = History{};
    defer plain.deinit(a);
    try plain.load(a, path);
    try std.testing.expectEqual(@as(usize, 2), plain.count());
    try std.testing.expectEqualStrings("printf 'a\\nb'", plain.get(1));

    // Appending converts it, and a multi-line entry survives a reload.
    var writer = History{ .limit = 3 };
    defer writer.deinit(a);
    try writer.load(a, path);
    try writer.appendToFile(a, path, "if true {\n  echo hi\n}");
    var reader = History{};
    defer reader.deinit(a);
    try reader.load(a, path);
    try std.testing.expectEqual(@as(usize, 3), reader.count());
    try std.testing.expectEqualStrings("printf 'a\\nb'", reader.get(1));
    try std.testing.expectEqualStrings("if true {\n  echo hi\n}", reader.get(2));

    // Well past the limit the file is cut back to the newest entries.
    var i: usize = 0;
    while (i < 110) : (i += 1) {
        var buf: [32]u8 = undefined;
        try writer.appendToFile(a, path, try std.fmt.bufPrint(&buf, "echo {d}", .{i}));
    }
    var trimmed = History{ .limit = 1000 };
    defer trimmed.deinit(a);
    try trimmed.load(a, path);
    try std.testing.expect(trimmed.count() < 110);
    try std.testing.expectEqualStrings("echo 109", trimmed.get(trimmed.count() - 1));
}
