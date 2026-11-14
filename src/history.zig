//! Persistent, searchable command history.
//!
//! The history file starts with `header`. In format v3 every entry is one
//! line, `+TIME<TAB>TAG<TAB>PREV<TAB>CWD<TAB>COMMAND`: when it was entered,
//! the entering shell's tag (`pid.seq`, hex), a fingerprint of the command
//! that shell ran before it, the working directory, and the command with `\`
//! and newline escaped so multi-line commands survive a restart. When the
//! command finishes, the shell appends a status line, `=TAG<TAB>STATUS<TAB>MS`.
//! Suggestions use the directory, the previous command and the status to rank
//! history (see `suggest`).
//!
//! Entries are appended as they are entered (`appendToFile`), so a crash or a
//! closed terminal loses nothing and concurrent shells keep each other's
//! entries; an entry whose status line never arrives counts as successful.
//! Older files (v2, which is v3's command field alone, and the plain format,
//! one raw entry per line) load unchanged and are rewritten as v3 on the
//! first append.

const std = @import("std");
const linux = std.os.linux;
const fs = @import("fs.zig");
const sys = @import("sys.zig");

pub const header = "#wsh-history v3";
const header_v2 = "#wsh-history v2";

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

/// What the history knows about an entry besides its text.
pub const Meta = struct {
    /// When it was entered, in Unix seconds; 0 when unknown.
    time: i64 = 0,
    /// The directory it was entered in, owned by the history; empty when
    /// unknown.
    cwd: []const u8 = "",
    /// `fingerprint` of the command the same shell ran before it; 0 for none.
    prev: u32 = 0,
    /// This shell's sequence number for it, which tags its status line in
    /// the file; 0 when it gets none.
    seq: u32 = 0,
    /// Its run exited non-zero.
    failed: bool = false,
};

/// How suggestions are picked: `let suggest = "recent"` is the newest prefix
/// match, the default `context` ranks matches as `suggest` describes.
pub const Rank = enum { context, recent };

/// A short, stable hash of a command, for `Meta.prev`. Never 0.
pub fn fingerprint(text: []const u8) u32 {
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, text));
    return if (hash == 0) 1 else hash;
}

pub const History = struct {
    /// Oldest first, like the history file.
    entries: std.ArrayList([]u8) = .empty,
    /// One per entry. Entries read from an older file carry the time they
    /// were read, as Bash shows entries saved without a timestamp.
    meta: std.ArrayList(Meta) = .empty,
    limit: usize = 5000,
    /// Entries the history file is known to hold. Once it is well past
    /// `limit`, `appendToFile` rewrites the file with the newest `limit`.
    file_entries: usize = 0,
    /// First entry `history -a` has not written yet.
    unsaved: usize = 0,
    /// `fingerprint` of the last line this shell entered; 0 before the first.
    last_fp: u32 = 0,
    /// Last `Meta.seq` handed out.
    last_seq: u32 = 0,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        for (self.meta.items) |m| freeCwd(allocator, m);
        self.entries.deinit(allocator);
        self.meta.deinit(allocator);
    }

    /// When entry `index` was added, in Unix seconds.
    pub fn time(self: *const History, index: usize) i64 {
        return if (index < self.meta.items.len) self.meta.items[index].time else 0;
    }

    fn appendEntry(self: *History, allocator: std.mem.Allocator, entry: []u8) !void {
        try self.meta.ensureUnusedCapacity(allocator, 1);
        try self.entries.append(allocator, entry);
        self.meta.appendAssumeCapacity(.{ .time = nowSeconds() });
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
        try self.appendEntry(allocator, owned);
        while (self.entries.items.len > self.limit) self.remove(allocator, 0);
        return owned;
    }

    /// `record` for a line the user entered in `cwd`: the entry also gets
    /// the directory, the previous command's fingerprint and a sequence
    /// number for its status line. A line that is not kept still becomes the
    /// previous command.
    pub fn recordEntered(self: *History, allocator: std.mem.Allocator, line: []const u8, control: Control, cwd: []const u8) !?[]const u8 {
        const prev = self.last_fp;
        self.last_fp = fingerprint(std.mem.trim(u8, line, " \t\r\n"));
        const entry = (try self.record(allocator, line, control)) orelse return null;
        const m = &self.meta.items[self.meta.items.len - 1];
        m.cwd = if (cwd.len == 0) "" else try allocator.dupe(u8, cwd);
        m.prev = prev;
        self.last_seq +%= 1;
        if (self.last_seq == 0) self.last_seq = 1;
        m.seq = self.last_seq;
        return entry;
    }

    /// Notes how the entered `entry` ended and, when it went to the history
    /// file, appends its status line there.
    pub fn finishEntered(self: *History, allocator: std.mem.Allocator, path: []const u8, entry: []const u8, status: u8, millis: u64) Error!void {
        const index = self.indexOf(entry) orelse return;
        const m = &self.meta.items[index];
        m.failed = status != 0;
        if (path.len == 0 or m.seq == 0) return;
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.print(allocator, "={x}.{x}\t{d}\t{d}\n", .{ sys.getpid(), m.seq, status, millis });
        try appendRaw(allocator, path, line.items);
    }

    /// The index of the stored entry `entry` (the slice `record` returned),
    /// looking from the newest, or null once it is gone.
    fn indexOf(self: *const History, entry: []const u8) ?usize {
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            if (self.entries.items[i].ptr == entry.ptr) return i;
        }
        return null;
    }

    pub fn remove(self: *History, allocator: std.mem.Allocator, index: usize) void {
        allocator.free(self.entries.orderedRemove(index));
        if (index < self.meta.items.len) freeCwd(allocator, self.meta.orderedRemove(index));
        if (self.unsaved > index) self.unsaved -= 1;
    }

    pub fn clear(self: *History, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| allocator.free(entry);
        for (self.meta.items) |m| freeCwd(allocator, m);
        self.entries.clearRetainingCapacity();
        self.meta.clearRetainingCapacity();
        self.unsaved = 0;
    }

    /// Gives the newest entry the metadata read from a file line. Its time is
    /// kept when the file has none.
    fn adoptMeta(self: *History, allocator: std.mem.Allocator, lines: *const Lines, index: usize) !void {
        if (lines.format != .v3) return;
        const m = &self.meta.items[self.meta.items.len - 1];
        const read = try parseMeta(allocator, lines.list.items[index], lines.status.items[index]);
        freeCwd(allocator, m.*);
        const keep_time = m.time;
        m.* = read;
        if (m.time == 0) m.time = keep_time;
    }

    /// Loads the whole history file, keeping its newest `limit` entries. A
    /// missing file is an empty history.
    pub fn load(self: *History, allocator: std.mem.Allocator, path: []const u8) !void {
        const data = (try readFile(allocator, path)) orelse return;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.deinit(allocator);

        self.file_entries = lines.list.items.len;
        const start = lines.list.items.len -| self.limit;
        for (start..lines.list.items.len) |index| {
            const entry = try entryText(allocator, &lines, index);
            if (self.entries.items.len > 0 and std.mem.eql(u8, self.entries.items[self.entries.items.len - 1], entry)) {
                // A repeat stands for its latest run.
                allocator.free(entry);
                try self.adoptMeta(allocator, &lines, index);
                continue;
            }
            self.appendEntry(allocator, entry) catch |err| {
                allocator.free(entry);
                return err;
            };
            try self.adoptMeta(allocator, &lines, index);
        }
        while (self.entries.items.len > self.limit) self.remove(allocator, 0);
        self.unsaved = self.entries.items.len;
    }

    /// Adds every entry of another history file, for `history -r`.
    pub fn readFrom(self: *History, allocator: std.mem.Allocator, path: []const u8) !bool {
        const data = (try readFile(allocator, path)) orelse return false;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.deinit(allocator);
        try self.recordLines(allocator, &lines, 0);
        return true;
    }

    /// Adds the entries of a history file after its first `skip`, for
    /// `history -n`. Returns how many entries the file holds, or null when it
    /// does not exist.
    pub fn readNewFrom(self: *History, allocator: std.mem.Allocator, path: []const u8, skip_entries: usize) !?usize {
        const data = (try readFile(allocator, path)) orelse return null;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.deinit(allocator);
        try self.recordLines(allocator, &lines, @min(skip_entries, lines.list.items.len));
        return lines.list.items.len;
    }

    fn recordLines(self: *History, allocator: std.mem.Allocator, lines: *const Lines, skip: usize) !void {
        for (skip..lines.list.items.len) |index| {
            const entry = try entryText(allocator, lines, index);
            defer allocator.free(entry);
            if (try self.record(allocator, entry, .{ .ignoredups = false }) != null) try self.adoptMeta(allocator, lines, index);
        }
    }

    /// Appends one entry to the history file with a single `O_APPEND` write,
    /// so concurrent shells interleave whole entries. An entry this history
    /// holds is written with its metadata. The file is trimmed to `limit`
    /// once it has grown well past it.
    pub fn appendToFile(self: *History, allocator: std.mem.Allocator, path: []const u8, entry: []const u8) Error!void {
        // The history file's directory is the shell's own to create; a file
        // named to `history -a` or `-w` is not.
        makeParents(allocator, path) catch {};
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        const m: Meta = if (self.indexOf(entry)) |index| self.meta.items[index] else .{ .time = nowSeconds() };
        try writeEntryLine(allocator, &out, entry, m);
        try appendRaw(allocator, path, out.items);
        self.file_entries += 1;
        if (self.file_entries > self.limit + trimSlack(self.limit)) try self.trimFile(allocator, path);
    }

    /// Appends the entries from `start` on to another file, for `history -a`.
    pub fn appendRangeToFile(self: *const History, allocator: std.mem.Allocator, path: []const u8, start: usize) Error!void {
        if (start >= self.entries.items.len) return;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        for (start..self.entries.items.len) |index| try writeEntryLine(allocator, &out, self.entries.items[index], self.metaForCopy(index));
        try appendRaw(allocator, path, out.items);
    }

    /// Replaces a file with this whole history, for `history -w`.
    pub fn writeFile(self: *const History, allocator: std.mem.Allocator, path: []const u8) Error!void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try out.appendSlice(allocator, header ++ "\n");
        for (self.entries.items, 0..) |entry, index| {
            const m = self.metaForCopy(index);
            try writeEntryLine(allocator, &out, entry, m);
            if (m.failed) try out.appendSlice(allocator, "=\t1\t0\n");
        }
        try replaceFile(allocator, path, out.items);
    }

    /// An entry's metadata for writing outside the live append path. The
    /// sequence number is dropped, since no status line will follow; a known
    /// failure is kept as an untagged status line instead (see `writeFile`).
    fn metaForCopy(self: *const History, index: usize) Meta {
        var m = self.meta.items[index];
        m.seq = 0;
        return m;
    }

    /// Rewrites the file with its newest `limit` entries, re-reading it first
    /// so entries other shells appended are kept.
    pub fn trimFile(self: *History, allocator: std.mem.Allocator, path: []const u8) Error!void {
        const data = (readFile(allocator, path) catch return error.HistoryFileUnwritable) orelse return;
        defer allocator.free(data);
        var lines = try fileLines(allocator, data);
        defer lines.deinit(allocator);
        const start = lines.list.items.len -| self.limit;
        try rewriteLines(allocator, path, &lines, start, null);
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

    /// The entry to suggest for a typed `prefix`: one that starts with it and
    /// is longer. `recent` takes the newest. `context` takes the newest from
    /// the best tier: entered in `cwd` right after the command this shell ran
    /// last, then entered in `cwd`, then anywhere. A command whose latest run
    /// failed is suggested only when no successful one matches.
    pub fn suggest(self: *const History, prefix: []const u8, cwd: []const u8, rank: Rank) ?usize {
        if (prefix.len == 0) return null;
        // best[failed * 3 + tier]
        var best = [_]?usize{null} ** 6;
        // The newest occurrence of each matching text decides whether it
        // failed; older copies follow it. Bounded, so a huge history stays
        // cheap; past the bound a copy is judged on its own run.
        var newest: [64]usize = undefined;
        var newest_len: usize = 0;
        var i = self.entries.items.len;
        while (i > 0) {
            i -= 1;
            const entry = self.entries.items[i];
            if (entry.len <= prefix.len or !std.mem.startsWith(u8, entry, prefix)) continue;
            if (rank == .recent) return i;
            const m = self.meta.items[i];
            var failed = m.failed;
            var seen = false;
            for (newest[0..newest_len]) |n| {
                if (std.mem.eql(u8, self.entries.items[n], entry)) {
                    failed = self.meta.items[n].failed;
                    seen = true;
                    break;
                }
            }
            if (!seen and newest_len < newest.len) {
                newest[newest_len] = i;
                newest_len += 1;
            }
            const same_dir = m.cwd.len != 0 and std.mem.eql(u8, m.cwd, cwd);
            const same_prev = self.last_fp != 0 and m.prev == self.last_fp;
            const tier: usize = if (same_dir and same_prev) 0 else if (same_dir) 1 else 2;
            const slot = @as(usize, @intFromBool(failed)) * 3 + tier;
            if (best[slot] == null) best[slot] = i;
            if (slot == 0) break;
        }
        for (best) |candidate| if (candidate) |index| return index;
        return null;
    }
};

fn freeCwd(allocator: std.mem.Allocator, m: Meta) void {
    if (m.cwd.len != 0) allocator.free(m.cwd);
}

fn nowSeconds() i64 {
    var ts: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.REALTIME, &ts)) != .SUCCESS) return 0;
    return ts.sec;
}

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

/// `encode` that also escapes tab, for a v3 field other than the last.
fn encodeField(allocator: std.mem.Allocator, out: *std.ArrayList(u8), field: []const u8) !void {
    for (field) |c| switch (c) {
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try encode(allocator, out, &.{c}),
    };
}

/// Reverses `encode`. Any other backslash is kept as written.
pub fn decode(allocator: std.mem.Allocator, line: []const u8) ![]u8 {
    return decodeWith(allocator, line, false);
}

fn decodeWith(allocator: std.mem.Allocator, line: []const u8, tabs: bool) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(allocator, line.len);
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] == '\\' and i + 1 < line.len) {
            const next = line[i + 1];
            if (next == 'n' or next == '\\' or (tabs and next == 't')) {
                out.appendAssumeCapacity(switch (next) {
                    'n' => '\n',
                    't' => '\t',
                    else => '\\',
                });
                i += 1;
                continue;
            }
        }
        out.appendAssumeCapacity(line[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// One v3 entry line, newline included.
fn writeEntryLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: []const u8, m: Meta) !void {
    try out.print(allocator, "+{d}\t", .{m.time});
    if (m.seq != 0) try out.print(allocator, "{x}.{x}", .{ sys.getpid(), m.seq });
    try out.print(allocator, "\t{x}\t", .{m.prev});
    try encodeField(allocator, out, m.cwd);
    try out.append(allocator, '\t');
    try encode(allocator, out, entry);
    try out.append(allocator, '\n');
}

/// The fields of a v3 entry line: time, tag, prev, cwd, command. A line
/// without the `+` marker is a bare command.
const EntryFields = struct { time: []const u8 = "", tag: []const u8 = "", prev: []const u8 = "", cwd: []const u8 = "", command: []const u8 };

fn splitEntry(line: []const u8) EntryFields {
    if (line.len == 0 or line[0] != '+') return .{ .command = line };
    var fields: [4][]const u8 = undefined;
    var rest = line[1..];
    for (&fields) |*field| {
        const tab = std.mem.indexOfScalar(u8, rest, '\t') orelse return .{ .command = line };
        field.* = rest[0..tab];
        rest = rest[tab + 1 ..];
    }
    return .{ .time = fields[0], .tag = fields[1], .prev = fields[2], .cwd = fields[3], .command = rest };
}

fn parseMeta(allocator: std.mem.Allocator, line: []const u8, status_line: ?[]const u8) !Meta {
    const fields = splitEntry(line);
    var m = Meta{
        .time = std.fmt.parseInt(i64, fields.time, 10) catch 0,
        .prev = std.fmt.parseInt(u32, fields.prev, 16) catch 0,
    };
    if (status_line) |status| {
        // `=TAG<TAB>STATUS<TAB>MS`
        var parts = std.mem.splitScalar(u8, status, '\t');
        _ = parts.next();
        const code = std.fmt.parseInt(u32, parts.next() orelse "0", 10) catch 0;
        m.failed = code != 0;
    }
    if (fields.cwd.len != 0) m.cwd = try decodeWith(allocator, fields.cwd, true);
    return m;
}

/// The text of entry `index` of a parsed file, owned by the caller.
fn entryText(allocator: std.mem.Allocator, lines: *const Lines, index: usize) ![]u8 {
    const line = lines.list.items[index];
    return switch (lines.format) {
        .plain => allocator.dupe(u8, line),
        .v2 => decode(allocator, line),
        .v3 => decode(allocator, splitEntry(line).command),
    };
}

const Format = enum { plain, v2, v3 };

const Lines = struct {
    /// Slices into the file data, one per entry, still encoded unless plain.
    list: std.ArrayList([]const u8) = .empty,
    /// v3: each entry's status line, when one was found.
    status: std.ArrayList(?[]const u8) = .empty,
    format: Format = .plain,

    fn deinit(self: *Lines, allocator: std.mem.Allocator) void {
        self.list.deinit(allocator);
        self.status.deinit(allocator);
    }
};

fn startsWithHeader(data: []const u8, text: []const u8) bool {
    if (!std.mem.startsWith(u8, data, text)) return false;
    return data.len == text.len or data[text.len] == '\n';
}

fn formatOf(data: []const u8) Format {
    if (startsWithHeader(data, header)) return .v3;
    if (startsWithHeader(data, header_v2)) return .v2;
    return .plain;
}

fn fileLines(allocator: std.mem.Allocator, data: []const u8) !Lines {
    var lines = Lines{ .format = formatOf(data) };
    errdefer lines.deinit(allocator);
    // v3: entry index by tag, to pair status lines with their entries.
    var tags: std.StringHashMapUnmanaged(usize) = .empty;
    defer tags.deinit(allocator);
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        switch (lines.format) {
            .plain => {},
            // Shells racing to create the file can each write a header.
            .v2 => if (std.mem.eql(u8, line, header_v2)) continue,
            .v3 => {
                if (std.mem.eql(u8, line, header)) continue;
                if (line[0] == '=') {
                    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                    const tag = line[1..tab];
                    // An untagged status line belongs to the entry just before it.
                    const target: ?usize = if (tag.len == 0)
                        (if (lines.list.items.len == 0) null else lines.list.items.len - 1)
                    else
                        tags.get(tag);
                    // A status whose entry was trimmed away is dropped.
                    if (target) |index| lines.status.items[index] = line;
                    continue;
                }
                const tag = splitEntry(line).tag;
                if (tag.len != 0) try tags.put(allocator, tag, lines.list.items.len);
                try lines.status.append(allocator, null);
            },
        }
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

/// Appends already formatted v3 lines with one `O_APPEND` write, upgrading
/// an older file first so formats never mix.
fn appendRaw(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) Error!void {
    if (bytes.len == 0) return;
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
            if (formatOf(start[0..got]) != .v3) {
                if (converted) return error.HistoryFileUnwritable;
                try upgrade(allocator, path);
                converted = true;
                continue;
            }
        }

        if (empty) {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            try out.appendSlice(allocator, header ++ "\n");
            try out.appendSlice(allocator, bytes);
            if (sys.writeAll(fd, out.items) != .ok) return error.HistoryFileUnwritable;
        } else if (sys.writeAll(fd, bytes) != .ok) return error.HistoryFileUnwritable;
        return;
    }
}

/// Appends plain entries, without metadata, to a history file.
pub fn appendEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const []const u8) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (entries) |entry| try writeEntryLine(allocator, &out, entry, .{});
    try appendRaw(allocator, path, out.items);
}

/// Rewrites a v2 or plain file as v3.
fn upgrade(allocator: std.mem.Allocator, path: []const u8) Error!void {
    const data = (readFile(allocator, path) catch return error.HistoryFileUnwritable) orelse return;
    defer allocator.free(data);
    var lines = try fileLines(allocator, data);
    defer lines.deinit(allocator);
    try rewriteLines(allocator, path, &lines, 0, null);
}

/// Drops the newest occurrence of each of `texts` from the history file,
/// with its status line, and returns how many entries the file keeps.
pub fn forgetInFile(allocator: std.mem.Allocator, path: []const u8, texts: []const []const u8) Error!usize {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const data = (readFile(arena, path) catch return error.HistoryFileUnwritable) orelse return 0;
    var lines = try fileLines(arena, data);
    const total = lines.list.items.len;
    var decoded = try arena.alloc([]const u8, total);
    for (0..total) |index| decoded[index] = try entryText(arena, &lines, index);
    const dropped = try arena.alloc(bool, total);
    @memset(dropped, false);
    var kept = total;
    for (texts) |text| {
        var i = total;
        while (i > 0) {
            i -= 1;
            if (dropped[i] or !std.mem.eql(u8, decoded[i], text)) continue;
            dropped[i] = true;
            kept -= 1;
            break;
        }
    }
    if (kept != total) try rewriteLines(allocator, path, &lines, 0, dropped);
    return kept;
}

/// Replaces the history file with `entries` (plain, unencoded text).
pub fn writeEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const []const u8) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, header ++ "\n");
    for (entries) |entry| try writeEntryLine(allocator, &out, entry, .{});
    try replaceFile(allocator, path, out.items);
}

/// Replaces the file with the entries of `lines` from `start` on, minus any
/// marked in `dropped`, as v3. v3 lines keep their metadata and status lines.
fn rewriteLines(allocator: std.mem.Allocator, path: []const u8, lines: *const Lines, start: usize, dropped: ?[]const bool) Error!void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, header ++ "\n");
    for (start..lines.list.items.len) |index| {
        if (dropped) |marks| if (marks[index]) continue;
        if (lines.format == .v3) {
            try out.appendSlice(allocator, lines.list.items[index]);
            try out.append(allocator, '\n');
            if (lines.status.items[index]) |status| {
                try out.appendSlice(allocator, status);
                try out.append(allocator, '\n');
            }
        } else {
            const text = try entryText(allocator, lines, index);
            defer allocator.free(text);
            try writeEntryLine(allocator, &out, text, .{});
        }
    }
    try replaceFile(allocator, path, out.items);
}

/// Replaces the file through a temporary file and `rename`, so readers and a
/// crash only ever see the old or the new history.
fn replaceFile(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) Error!void {
    const target = try allocator.dupeZ(u8, path);
    defer allocator.free(target);
    const temp = try std.fmt.allocPrintSentinel(allocator, "{s}.{d}.tmp", .{ path, sys.getpid() }, 0);
    defer allocator.free(temp);

    const fd = openHistory(temp, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }) orelse
        return error.HistoryFileUnwritable;
    const written = sys.writeAll(fd, bytes) == .ok and linux.errno(linux.fsync(fd)) == .SUCCESS;
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

test "suggestions rank by directory, previous command and status" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);

    // Entered in /srv after `cd /srv`, in /srv after something else, and in /tmp.
    _ = try h.recordEntered(a, "cd /srv", .{}, "/home");
    const after_cd = (try h.recordEntered(a, "make deploy", .{}, "/srv")).?;
    try h.finishEntered(a, "", after_cd, 0, 5);
    _ = try h.recordEntered(a, "ls", .{}, "/srv");
    _ = try h.recordEntered(a, "make test", .{}, "/srv");
    _ = try h.recordEntered(a, "make clean", .{}, "/tmp");

    // Recency alone takes the newest match.
    try std.testing.expectEqualStrings("make clean", h.get(h.suggest("make", "/srv", .recent).?));
    // In /srv the directory wins over recency.
    try std.testing.expectEqualStrings("make test", h.get(h.suggest("make", "/srv", .context).?));
    // Right after `cd /srv`, the command that followed it there wins.
    _ = try h.recordEntered(a, "cd /srv", .{}, "/home");
    try std.testing.expectEqualStrings("make deploy", h.get(h.suggest("make", "/srv", .context).?));
    // Elsewhere, only recency is left.
    try std.testing.expectEqualStrings("make clean", h.get(h.suggest("make", "/opt", .context).?));
    // A suggestion must add something.
    try std.testing.expect(h.suggest("make clean", "/tmp", .context) == null);
    try std.testing.expect(h.suggest("", "/tmp", .context) == null);
}

test "a command whose latest run failed is suggested last" {
    const a = std.testing.allocator;
    var h = History{};
    defer h.deinit(a);

    const ok = (try h.recordEntered(a, "git push origin", .{}, "/r")).?;
    try h.finishEntered(a, "", ok, 0, 1);
    const typo = (try h.recordEntered(a, "git psuh", .{}, "/r")).?;
    try h.finishEntered(a, "", typo, 1, 1);
    try std.testing.expectEqualStrings("git push origin", h.get(h.suggest("git p", "/r", .context).?));
    // Failed but alone: still offered.
    try std.testing.expectEqualStrings("git psuh", h.get(h.suggest("git ps", "/r", .context).?));

    // An older successful copy follows the newest run's failure.
    var g = History{};
    defer g.deinit(a);
    const first = (try g.recordEntered(a, "npm test", .{}, "/w")).?;
    try g.finishEntered(a, "", first, 0, 1);
    _ = try g.recordEntered(a, "npm install", .{}, "/x");
    const again = (try g.recordEntered(a, "npm test", .{}, "/w")).?;
    try g.finishEntered(a, "", again, 1, 1);
    try std.testing.expectEqualStrings("npm install", g.get(g.suggest("npm ", "/w", .context).?));
}

test "v3 history keeps metadata and status lines across rewrites" {
    const a = std.testing.allocator;
    var dir_buf: [128]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "zig-cache-history-v3-{d}", .{sys.getpid()});
    var path_buf: [192]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/history", .{dir});
    const path_z = try a.dupeZ(u8, path);
    defer a.free(path_z);
    defer {
        _ = fs.removeFile(path_z);
        var top_buf: [160]u8 = undefined;
        if (std.fmt.bufPrintZ(&top_buf, "{s}", .{dir})) |top| _ = linux.unlinkat(linux.AT.FDCWD, top.ptr, linux.AT.REMOVEDIR) else |_| {}
    }

    // A v2 file is upgraded on the first append and its entries kept.
    try makeParents(a, path);
    try std.testing.expect(fs.writeFile(path_z, header_v2 ++ "\nold one\nprintf 'a\\nb'\n"));
    var w = History{};
    defer w.deinit(a);
    try w.load(a, path);
    const entry = (try w.recordEntered(a, "make\ttest", .{}, "/a\tdir")).?;
    try w.appendToFile(a, path, entry);
    try w.finishEntered(a, path, entry, 2, 40);
    const done = (try w.recordEntered(a, "echo done", .{}, "/b")).?;
    try w.appendToFile(a, path, done);

    var r = History{};
    defer r.deinit(a);
    try r.load(a, path);
    try std.testing.expectEqual(@as(usize, 4), r.count());
    try std.testing.expectEqualStrings("printf 'a\nb'", r.get(1));
    try std.testing.expectEqualStrings("make\ttest", r.get(2));
    try std.testing.expectEqualStrings("/a\tdir", r.meta.items[2].cwd);
    try std.testing.expect(r.meta.items[2].failed);
    try std.testing.expect(r.meta.items[2].time != 0);
    try std.testing.expect(!r.meta.items[3].failed);
    try std.testing.expectEqual(fingerprint("make\ttest"), r.meta.items[3].prev);

    // Forgetting an entry keeps the others' metadata and status.
    try std.testing.expectEqual(@as(usize, 3), try forgetInFile(a, path, &.{"echo done"}));
    var f = History{};
    defer f.deinit(a);
    try f.load(a, path);
    try std.testing.expectEqual(@as(usize, 3), f.count());
    try std.testing.expect(f.meta.items[2].failed);

    // `history -w` keeps a known failure.
    try f.writeFile(a, path);
    var again = History{};
    defer again.deinit(a);
    try again.load(a, path);
    try std.testing.expect(again.meta.items[2].failed);
    try std.testing.expectEqualStrings("/a\tdir", again.meta.items[2].cwd);
}
