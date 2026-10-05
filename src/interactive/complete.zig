//! Tab completion: commands, files, directories and variables; programmable
//! completion registered with `complete`; and built-in argument completion
//! for `cd`/`pushd`, `git`, `make`, the ssh family, job specs, `~user` and
//! `--long-options`.
//!
//! External helpers (`git`, `cmd --help`) run with stdin and stderr on
//! /dev/null and a one-second timeout, so a slow or hung program never
//! blocks the editor for long. Completion never runs while it is disabled.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const shellmod = @import("../shell.zig");
const builtins = @import("../builtins.zig");
const compspec = @import("../builtins/complete.zig");
const fs = @import("../fs.zig");
const sys = @import("../sys.zig");
const proc = @import("../proc.zig");
const glob = @import("../glob.zig");
const value = @import("../value.zig");
const expand = @import("../expand.zig");
const command_suggest = @import("../command_suggest.zig");

const Shell = shellmod.Shell;
const Allocator = std.mem.Allocator;
const Spec = compspec.Spec;

pub const Result = struct {
    /// Offset in the line where the replacement begins.
    start: usize,
    /// Complete replacement words, in the order they should be shown.
    items: []const []const u8,
};

const helper_timeout_ms = 1000;
const command_spec_timeout_ms = 2000;
const helper_output_max = 1 << 20;

fn startsWithIgnoreCase(text: []const u8, prefix: []const u8) bool {
    if (prefix.len > text.len) return false;
    for (text[0..prefix.len], prefix) |text_byte, prefix_byte| {
        if (std.ascii.toLower(text_byte) != std.ascii.toLower(prefix_byte)) return false;
    }
    return true;
}

// --- parsing the line ---------------------------------------------------------------

/// The simple command around the cursor.
pub const Context = struct {
    /// Words of the command, unquoted, including any after the cursor.
    words: []const []const u8,
    /// Index of the word being completed.
    cword: usize,
    /// Offset in the line where the word being completed starts.
    start: usize,
    /// The word being completed as typed, up to the cursor.
    raw: []const u8,
    /// `raw` without its quoting.
    word: []const u8,
    /// Index of the command name in `words`; null when the word being
    /// completed is the command name itself.
    command_index: ?usize,
    /// The word follows a redirection operator.
    redirect: bool,
    /// The command's span in the line, for COMP_LINE and COMP_POINT.
    line_start: usize,
    line_end: usize,
};

fn isBlankByte(c: u8) bool {
    return c == ' ' or c == '\t';
}

fn isCommandSeparator(c: u8) bool {
    return c == ';' or c == '|' or c == '&' or c == '(' or c == ')' or c == '\n';
}

/// End of the word starting at `start`: the next unquoted blank or operator.
fn scanWord(line: []const u8, start: usize) usize {
    var i = start;
    while (i < line.len) {
        const c = line[i];
        switch (c) {
            ' ', '\t', '\n', ';', '|', '&', '(', ')', '<', '>' => return i,
            '\\' => i = @min(i + 2, line.len),
            '\'' => i = if (std.mem.indexOfScalarPos(u8, line, i + 1, '\'')) |end| end + 1 else line.len,
            '"' => {
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '\\') i += 1;
                }
                i = @min(i + 1, line.len);
            },
            '$' => {
                if (i + 1 < line.len and (line[i + 1] == '(' or line[i + 1] == '{')) {
                    const open = line[i + 1];
                    const close: u8 = if (open == '(') ')' else '}';
                    var depth: usize = 0;
                    i += 1;
                    while (i < line.len) : (i += 1) {
                        if (line[i] == open) depth += 1;
                        if (line[i] == close) {
                            depth -= 1;
                            if (depth == 0) break;
                        }
                    }
                    i = @min(i + 1, line.len);
                } else {
                    i += 1;
                }
            },
            else => i += 1,
        }
    }
    return i;
}

/// Removes quotes and backslashes; an unterminated quote runs to the end.
pub fn dequote(arena: Allocator, raw: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfAny(u8, raw, "'\"\\") == null) return raw;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        switch (c) {
            '\\' => {
                if (i + 1 < raw.len) try out.append(arena, raw[i + 1]);
                i += 2;
            },
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, raw, i + 1, '\'') orelse raw.len;
                try out.appendSlice(arena, raw[i + 1 .. end]);
                i = end + 1;
            },
            '"' => {
                i += 1;
                while (i < raw.len and raw[i] != '"') : (i += 1) {
                    if (raw[i] == '\\' and i + 1 < raw.len and std.mem.indexOfScalar(u8, "\"\\$`", raw[i + 1]) != null) i += 1;
                    try out.append(arena, raw[i]);
                }
                i += 1;
            },
            else => {
                try out.append(arena, c);
                i += 1;
            },
        }
    }
    return out.items;
}

/// Quote character still open at the end of `raw`, if any.
fn openQuote(raw: []const u8) ?u8 {
    var open: ?u8 = null;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (open) |q| {
            if (c == q) {
                open = null;
            } else if (q == '"' and c == '\\') {
                i += 1;
            }
            continue;
        }
        switch (c) {
            '\\' => i += 1,
            '\'', '"' => open = c,
            else => {},
        }
    }
    return open;
}

/// Words that put the next word in command position.
const command_prefixes = [_][]const u8{
    "then", "do",   "else",    "elif",    "if",   "while", "until", "time", "!",     "{",
    "sudo", "doas", "command", "builtin", "exec", "nohup", "nice",  "env",  "xargs",
};

fn isCommandPrefix(word: []const u8) bool {
    for (command_prefixes) |prefix| {
        if (std.mem.eql(u8, prefix, word)) return true;
    }
    return false;
}

fn isAssignment(word: []const u8) bool {
    const eq = std.mem.indexOfScalar(u8, word, '=') orelse return false;
    return eq > 0 and builtins.validName(word[0..eq]);
}

pub fn parseLine(arena: Allocator, line: []const u8, cursor: usize) Allocator.Error!Context {
    var words: std.ArrayList([]const u8) = .empty;
    var starts: std.ArrayList(usize) = .empty;
    var cword: ?usize = null;
    var start = cursor;
    var redirect_pending = false;
    var redirect = false;
    var line_start: usize = 0;
    var line_end: usize = line.len;

    var i: usize = 0;
    while (i < line.len) {
        const c = line[i];
        if (isBlankByte(c)) {
            i += 1;
            continue;
        }
        if (isCommandSeparator(c) and !(c == '&' and i + 1 < line.len and line[i + 1] == '>')) {
            if (i >= cursor) {
                line_end = i;
                break;
            }
            words.clearRetainingCapacity();
            starts.clearRetainingCapacity();
            redirect_pending = false;
            i += 1;
            line_start = i;
            continue;
        }
        if (c == '<' or c == '>' or c == '&') {
            i += 1;
            while (i < line.len and (line[i] == '>' or line[i] == '<' or line[i] == '&' or line[i] == '|')) i += 1;
            if (i <= cursor) redirect_pending = true;
            continue;
        }

        const word_start = i;
        const word_end = scanWord(line, i);
        i = word_end;
        // `2>file`: a descriptor number glued to a redirection.
        if (word_end < line.len and (line[word_end] == '<' or line[word_end] == '>') and
            std.mem.indexOfNone(u8, line[word_start..word_end], "0123456789") == null)
        {
            continue;
        }
        const raw = line[word_start..word_end];
        const is_brace = std.mem.eql(u8, raw, "{") or std.mem.eql(u8, raw, "}");
        const contains_cursor = cword == null and cursor >= word_start and cursor <= word_end;
        if (is_brace and !contains_cursor) {
            if (word_start >= cursor) {
                line_end = word_start;
                break;
            }
            words.clearRetainingCapacity();
            starts.clearRetainingCapacity();
            line_start = word_end;
            continue;
        }
        if (redirect_pending) {
            redirect_pending = false;
            if (!contains_cursor) continue;
            redirect = true;
        }
        if (contains_cursor) {
            cword = words.items.len;
            start = word_start;
        }
        try words.append(arena, try dequote(arena, raw));
        try starts.append(arena, word_start);
    }

    if (cword == null) {
        // The cursor is on a blank: complete a new, empty word there.
        var index: usize = 0;
        while (index < starts.items.len and starts.items[index] < cursor) index += 1;
        try words.insert(arena, index, "");
        cword = index;
        start = cursor;
        redirect = redirect_pending;
    }

    const raw = line[start..cursor];
    var command_index: ?usize = null;
    for (words.items[0..cword.?], 0..) |word, index| {
        if (isAssignment(word) or isCommandPrefix(word)) continue;
        command_index = index;
        break;
    }

    return .{
        .words = words.items,
        .cword = cword.?,
        .start = start,
        .raw = raw,
        .word = try dequote(arena, raw),
        .command_index = command_index,
        .redirect = redirect,
        .line_start = line_start,
        .line_end = @max(line_end, cursor),
    };
}

// --- entry point ----------------------------------------------------------------------

pub fn complete(sh: *Shell, arena: Allocator, line: []const u8, cursor: usize) !Result {
    const ctx = try parseLine(arena, line, cursor);
    var items: std.ArrayList([]const u8) = .empty;
    var sort = true;

    if (variableReference(ctx.raw)) |dollar| {
        const at_start = dollar == 0;
        try completeVariables(sh, arena, ctx.raw[dollar + 1 ..], if (at_start) " " else "", &items);
        sortItems(items.items);
        return .{ .start = ctx.start + dollar, .items = try dedupe(arena, items.items) };
    }

    if (ctx.command_index == null and !ctx.redirect) {
        const word = ctx.raw;
        const command_count = items.items.len;
        try completeCommands(sh, arena, word, &items);
        if (items.items.len == command_count and word.len >= 2 and std.mem.indexOfScalar(u8, word, '/') == null) {
            if (sh.command_cache.lookup(word)) |cached| {
                for (cached.matches) |match| try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{match.name}));
            } else {
                const matches = try command_suggest.find(sh, arena, word);
                for (matches) |match| try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{match.name}));
            }
        }
        try completePaths(sh, arena, ctx.raw, .all, &items);
    } else {
        sort = try completeArgument(sh, arena, line, cursor, ctx, &items);
    }

    if (sort) sortItems(items.items);
    return .{ .start = ctx.start, .items = try dedupe(arena, items.items) };
}

/// Index of a trailing `$name` reference in `raw`, if the word ends in one.
fn variableReference(raw: []const u8) ?usize {
    const dollar = std.mem.lastIndexOfScalar(u8, raw, '$') orelse return null;
    if (dollar > 0 and raw[dollar - 1] == '\\') return null;
    if (openQuote(raw[0..dollar]) == '\'') return null;
    for (raw[dollar + 1 ..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return null;
    }
    return dollar;
}

fn sortItems(items: [][]const u8) void {
    std.mem.sort([]const u8, items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
}

/// Drops repeated candidates, keeping the first of each.
fn dedupe(arena: Allocator, items: []const []const u8) ![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    for (items) |item| {
        const gop = try seen.getOrPut(arena, item);
        if (gop.found_existing) continue;
        try out.append(arena, item);
    }
    return out.items;
}

/// Escapes a path so it can be typed back into a command line.
fn quote(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        switch (c) {
            ' ', '\t', '"', '\'', '$', '*', '?', '[', ']', '\\', '(', ')', '{', '}', '&', '|', ';', '<', '>', '#', '!', '~', '`' => {
                try out.append(arena, '\\');
                try out.append(arena, c);
            },
            else => try out.append(arena, c),
        }
    }
    return out.toOwnedSlice(arena);
}

/// Escapes `text` for the inside of an open `quote_char` quote.
fn quoteInside(arena: Allocator, text: []const u8, quote_char: u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (text) |c| {
        if (quote_char == '\'' and c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else if (quote_char == '"' and std.mem.indexOfScalar(u8, "\"\\$`", c) != null) {
            try out.append(arena, '\\');
            try out.append(arena, c);
        } else {
            try out.append(arena, c);
        }
    }
    return out.items;
}

/// Quotes a whole path, keeping a leading `~` or `~user` unescaped.
fn quotePath(arena: Allocator, path: []const u8) ![]const u8 {
    if (path.len > 0 and path[0] == '~') {
        const slash = std.mem.indexOfScalar(u8, path, '/') orelse return path;
        return std.mem.concat(arena, u8, &.{ path[0..slash], try quote(arena, path[slash..]) });
    }
    return quote(arena, path);
}

// --- variables and commands -------------------------------------------------------------

fn completeVariables(sh: *Shell, arena: Allocator, prefix: []const u8, suffix: []const u8, items: *std.ArrayList([]const u8)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    try variableNames(sh, arena, prefix, &names);
    for (names.items) |name| try items.append(arena, try std.fmt.allocPrint(arena, "${s}{s}", .{ name, suffix }));
}

fn variableNames(sh: *Shell, arena: Allocator, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(sh.gpa);
    try sh.varNames(&names);
    try sh.envNames(&names);
    for (names.items) |name| {
        if (std.mem.startsWith(u8, name, prefix)) try out.append(arena, try arena.dupe(u8, name));
    }
}

/// Every command name starting with `prefix`: builtins, functions, aliases,
/// and executables on PATH (only for a non-empty prefix).
fn commandNames(sh: *Shell, arena: Allocator, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    var seen: std.StringHashMap(void) = .init(sh.gpa);
    defer seen.deinit();

    for (builtins.all()) |b| {
        if (!std.mem.startsWith(u8, b.name, prefix)) continue;
        try seen.put(b.name, {});
        try out.append(arena, b.name);
    }

    var func_it = sh.funcs.keyIterator();
    while (func_it.next()) |name| {
        if (!std.mem.startsWith(u8, name.*, prefix) or seen.contains(name.*)) continue;
        try seen.put(name.*, {});
        try out.append(arena, try arena.dupe(u8, name.*));
    }

    var alias_it = sh.aliases.keyIterator();
    while (alias_it.next()) |name| {
        if (!std.mem.startsWith(u8, name.*, prefix) or seen.contains(name.*)) continue;
        try seen.put(name.*, {});
        try out.append(arena, try arena.dupe(u8, name.*));
    }

    if (prefix.len == 0) return;

    var dirs = std.mem.splitScalar(u8, sh.pathEnv(), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0 or dir.len + 1 > linux.PATH_MAX) continue;
        var buf: [linux.PATH_MAX]u8 = undefined;
        @memcpy(buf[0..dir.len], dir);
        buf[dir.len] = 0;
        var handle = fs.openDir(buf[0..dir.len :0]) orelse continue;
        defer handle.close();

        while (handle.next()) |entry| {
            if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
            if (entry.kind != .file and entry.kind != .unknown and entry.kind != .symlink) continue;
            if (seen.contains(entry.name)) continue;
            const full = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, entry.name }, 0);
            if (!fs.isExecutable(full)) continue;
            const name = try arena.dupe(u8, entry.name);
            try seen.put(name, {});
            try out.append(arena, name);
        }
    }
}

fn completeCommands(sh: *Shell, arena: Allocator, prefix: []const u8, items: *std.ArrayList([]const u8)) !void {
    var names: std.ArrayList([]const u8) = .empty;
    try commandNames(sh, arena, prefix, &names);
    for (names.items) |name| try items.append(arena, try std.fmt.allocPrint(arena, "{s} ", .{name}));
}

// --- paths -------------------------------------------------------------------------------

const PathKind = enum { all, dirs };

fn entryIsDir(arena: Allocator, dir: []const u8, entry: fs.Entry) bool {
    switch (entry.kind) {
        .dir => return true,
        .symlink, .unknown => {
            const full = std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ dir, entry.name }, 0) catch return false;
            return fs.isDir(full);
        },
        else => return false,
    }
}

/// Completes the path in `raw` (as typed) against the filesystem. Matching is
/// case-insensitive; the replacement keeps the quoting the word started.
fn completePaths(sh: *Shell, arena: Allocator, raw: []const u8, kind: PathKind, items: *std.ArrayList([]const u8)) !void {
    const word = try dequote(arena, raw);
    const quote_char = openQuote(raw);
    const raw_slash = std.mem.lastIndexOfScalar(u8, raw, '/');
    const raw_dir = if (raw_slash) |s| raw[0 .. s + 1] else if (quote_char != null and raw.len > 0 and raw[0] == quote_char.?) raw[0..1] else "";

    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |s| word[0 .. s + 1] else "";
    const base = if (slash) |s| word[s + 1 ..] else word;

    const dir = if (dir_part.len == 0) "." else try sh.tildeExpand(arena, dir_part);
    const dir_z = try arena.dupeZ(u8, dir);
    var handle = fs.openDir(dir_z) orelse return;
    defer handle.close();

    const allow_hidden = base.len > 0 and base[0] == '.';
    while (handle.next()) |entry| {
        if (!allow_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!startsWithIgnoreCase(entry.name, base)) continue;
        const is_dir = entryIsDir(arena, dir, entry);
        if (kind == .dirs and !is_dir) continue;

        const name = if (quote_char) |q| try quoteInside(arena, entry.name, q) else try quote(arena, entry.name);
        const suffix: []const u8 = if (is_dir) "/" else if (quote_char) |q| (if (q == '"') "\" " else "' ") else " ";
        try items.append(arena, try std.mem.concat(arena, u8, &.{ raw_dir, name, suffix }));
    }
}

/// Plain path names for `-f`/`-d` actions: unquoted, no suffixes.
fn pathNames(sh: *Shell, arena: Allocator, word: []const u8, kind: PathKind, out: *std.ArrayList([]const u8)) !void {
    const slash = std.mem.lastIndexOfScalar(u8, word, '/');
    const dir_part = if (slash) |s| word[0 .. s + 1] else "";
    const base = if (slash) |s| word[s + 1 ..] else word;
    const dir = if (dir_part.len == 0) "." else try sh.tildeExpand(arena, dir_part);
    var handle = fs.openDir(try arena.dupeZ(u8, dir)) orelse return;
    defer handle.close();

    const allow_hidden = base.len > 0 and base[0] == '.';
    while (handle.next()) |entry| {
        if (!allow_hidden and entry.name.len > 0 and entry.name[0] == '.') continue;
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        if (!std.mem.startsWith(u8, entry.name, base)) continue;
        if (kind == .dirs and !entryIsDir(arena, dir, entry)) continue;
        try out.append(arena, try std.mem.concat(arena, u8, &.{ dir_part, entry.name }));
    }
}

// --- arguments ---------------------------------------------------------------------------

fn basename(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    return path[slash + 1 ..];
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn appendWithSuffix(arena: Allocator, items: *std.ArrayList([]const u8), names: []const []const u8, prefix: []const u8, suffix: []const u8) !void {
    for (names) |name| {
        if (!std.mem.startsWith(u8, name, prefix)) continue;
        try items.append(arena, try std.mem.concat(arena, u8, &.{ name, suffix }));
    }
}

/// Completes a word in argument position. Returns false when the candidates
/// must keep their generated order (`-o nosort`).
fn completeArgument(sh: *Shell, arena: Allocator, line: []const u8, cursor: usize, ctx: Context, items: *std.ArrayList([]const u8)) !bool {
    if (ctx.redirect) {
        try completePaths(sh, arena, ctx.raw, .all, items);
        return true;
    }
    const command = ctx.words[ctx.command_index.?];
    const name = basename(command);
    const word = ctx.word;

    if (word.len > 0 and word[0] == '~' and std.mem.indexOfScalar(u8, word, '/') == null) {
        var users: std.ArrayList([]const u8) = .empty;
        try passwdNames(arena, "/etc/passwd", word[1..], &users);
        for (users.items) |user| try items.append(arena, try std.fmt.allocPrint(arena, "~{s}/", .{user}));
        return true;
    }

    if (compspec.lookup(command) orelse compspec.lookup(name)) |spec| {
        return programmable(sh, arena, line, cursor, ctx, spec, items);
    }

    if (eql(name, "cd") or eql(name, "pushd")) {
        try completePaths(sh, arena, ctx.raw, .dirs, items);
        return true;
    }
    if (eql(name, "git")) {
        try completeGit(sh, arena, ctx, items);
        return true;
    }
    if ((eql(name, "make") or eql(name, "gmake")) and !std.mem.startsWith(u8, word, "-")) {
        var targets: std.ArrayList([]const u8) = .empty;
        try makeTargets(sh, arena, ctx, &targets);
        try appendWithSuffix(arena, items, targets.items, word, " ");
        if (items.items.len == 0) try completePaths(sh, arena, ctx.raw, .all, items);
        return true;
    }
    if (eql(name, "ssh") or eql(name, "sftp") or eql(name, "scp") or eql(name, "rsync")) {
        if (!std.mem.startsWith(u8, word, "-")) {
            try completeHosts(sh, arena, ctx, name, items);
            return true;
        }
    }
    if (eql(name, "fg") or eql(name, "bg") or eql(name, "wait") or eql(name, "disown") or
        (eql(name, "kill") and std.mem.startsWith(u8, word, "%")))
    {
        try completeJobs(sh, arena, word, items);
        return true;
    }
    if (std.mem.startsWith(u8, word, "--") and std.mem.indexOfScalar(u8, command, '/') == null and isExternal(sh, command)) {
        const options = try longOptions(sh, arena, command, &.{ command, "--help" });
        try appendOptions(arena, items, options, word);
        if (items.items.len > 0) return true;
    }
    try completePaths(sh, arena, ctx.raw, .all, items);
    return true;
}

fn isExternal(sh: *Shell, name: []const u8) bool {
    if (builtins.isBuiltin(name) or sh.getFunc(name) != null or sh.getAlias(name) != null) return false;
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const resolved = proc.resolve(arena_state.allocator(), name, sh.pathEnv()) catch return false;
    return resolved != null;
}

/// Adds `--option` candidates; ones that take a value (`--file=`) get no
/// trailing space.
fn appendOptions(arena: Allocator, items: *std.ArrayList([]const u8), options: []const []const u8, word: []const u8) !void {
    for (options) |option| {
        if (!std.mem.startsWith(u8, option, word)) continue;
        const suffix: []const u8 = if (std.mem.endsWith(u8, option, "=")) "" else " ";
        try items.append(arena, try std.mem.concat(arena, u8, &.{ option, suffix }));
    }
}

// --- programmable completion -------------------------------------------------------------

pub const Request = struct {
    command: []const u8 = "",
    word: []const u8 = "",
    previous: []const u8 = "",
    line: []const u8 = "",
    point: usize = 0,
    words: []const []const u8 = &.{},
    cword: usize = 0,
};

fn programmable(sh: *Shell, arena: Allocator, line: []const u8, cursor: usize, ctx: Context, spec: Spec, items: *std.ArrayList([]const u8)) !bool {
    const command = ctx.words[ctx.command_index.?];
    const relative = ctx.words[ctx.command_index.?..];
    const request = Request{
        .command = command,
        .word = ctx.word,
        .previous = if (ctx.cword > ctx.command_index.?) ctx.words[ctx.cword - 1] else "",
        .line = line[ctx.line_start..ctx.line_end],
        .point = cursor - ctx.line_start,
        .words = relative,
        .cword = ctx.cword - ctx.command_index.?,
    };
    var candidates: std.ArrayList([]const u8) = .empty;
    try generate(sh, arena, spec, request, &candidates);
    if (spec.options.plusdirs) try pathNames(sh, arena, ctx.word, .dirs, &candidates);

    const filenames = spec.options.filenames or spec.actions.file or spec.actions.directory or spec.options.plusdirs;
    for (candidates.items) |candidate| {
        if (filenames) {
            const expanded = try sh.tildeExpand(arena, candidate);
            const is_dir = fs.isDir(try arena.dupeZ(u8, expanded));
            const text = if (spec.options.noquote) candidate else try quotePath(arena, candidate);
            const suffix: []const u8 = if (is_dir) "/" else if (spec.options.nospace) "" else " ";
            try items.append(arena, try std.mem.concat(arena, u8, &.{ text, suffix }));
        } else {
            const suffix: []const u8 = if (spec.options.nospace) "" else " ";
            try items.append(arena, try std.mem.concat(arena, u8, &.{ candidate, suffix }));
        }
    }

    if (items.items.len == 0) {
        if (spec.options.dirnames) {
            try completePaths(sh, arena, ctx.raw, .dirs, items);
        } else if (spec.options.default or spec.options.bashdefault) {
            try completePaths(sh, arena, ctx.raw, .all, items);
        }
    }
    return !spec.options.nosort;
}

/// The candidates a specification produces for `request.word`, in bash's
/// order: actions, `-G`, `-W`, `-F`, `-C`, then the `-X` filter and the
/// `-P`/`-S` affixes. Shared by Tab and `compgen`.
pub fn generate(sh: *Shell, arena: Allocator, spec: Spec, request: Request, out: *std.ArrayList([]const u8)) !void {
    const word = request.word;
    const actions = spec.actions;
    var generated: std.ArrayList([]const u8) = .empty;

    if (actions.alias) {
        var it = sh.aliases.keyIterator();
        while (it.next()) |name| if (std.mem.startsWith(u8, name.*, word)) try generated.append(arena, try arena.dupe(u8, name.*));
    }
    if (actions.builtin) {
        for (builtins.all()) |b| if (std.mem.startsWith(u8, b.name, word)) try generated.append(arena, b.name);
        for ([_][]const u8{ ".", "eval", "source" }) |name| if (std.mem.startsWith(u8, name, word)) try generated.append(arena, name);
    }
    if (actions.command) try commandNames(sh, arena, word, &generated);
    if (actions.directory) try pathNames(sh, arena, word, .dirs, &generated);
    if (actions.@"export") {
        var it = sh.env.keyIterator();
        while (it.next()) |name| if (std.mem.startsWith(u8, name.*, word)) try generated.append(arena, try arena.dupe(u8, name.*));
    }
    if (actions.file) try pathNames(sh, arena, word, .all, &generated);
    if (actions.function) {
        var it = sh.funcs.keyIterator();
        while (it.next()) |name| if (std.mem.startsWith(u8, name.*, word)) try generated.append(arena, try arena.dupe(u8, name.*));
    }
    if (actions.group) try passwdNames(arena, "/etc/group", word, &generated);
    if (actions.hostname) try hostNames(sh, arena, word, &generated);
    if (actions.job or actions.running or actions.stopped) {
        for (sh.jobs.jobs.items) |job| {
            if (job.state == .done) continue;
            if (!actions.job and !(actions.running and job.state == .running) and !(actions.stopped and job.state == .stopped)) continue;
            const job_name = std.mem.sliceTo(job.command, ' ');
            if (std.mem.startsWith(u8, job_name, word)) try generated.append(arena, job_name);
        }
    }
    if (actions.keyword) {
        const keywords = [_][]const u8{ "!", "case", "do", "done", "elif", "else", "esac", "fi", "fn", "for", "function", "if", "in", "let", "return", "select", "then", "time", "until", "while", "{", "}" };
        for (keywords) |keyword| if (std.mem.startsWith(u8, keyword, word)) try generated.append(arena, keyword);
    }
    if (actions.signal) {
        var number: u32 = 1;
        while (number < 32) : (number += 1) {
            const signal_name = proc.signalName(number);
            if (signal_name.len == 0 or std.ascii.isDigit(signal_name[0])) continue;
            const full = try std.fmt.allocPrint(arena, "SIG{s}", .{signal_name});
            if (std.mem.startsWith(u8, full, word)) try generated.append(arena, full);
        }
    }
    if (actions.user) try passwdNames(arena, "/etc/passwd", word, &generated);
    if (actions.variable) try variableNames(sh, arena, word, &generated);

    if (spec.glob) |pattern| {
        var matches: std.ArrayList([]const u8) = .empty;
        if (try glob.glob(arena, pattern, &matches)) try generated.appendSlice(arena, matches.items);
    }
    if (spec.words) |list| {
        const expanded = if (std.mem.indexOfAny(u8, list, "$`") != null)
            expand.expandLiteral(sh, arena, list) catch list
        else
            list;
        var it = std.mem.tokenizeAny(u8, expanded, " \t\n");
        while (it.next()) |candidate| if (std.mem.startsWith(u8, candidate, word)) try generated.append(arena, candidate);
    }
    if (spec.function) |function| try callFunction(sh, arena, function, request, &generated);
    if (spec.command) |command| try runCompletionCommand(sh, arena, command, request, &generated);

    for (generated.items) |candidate| {
        if (spec.filter) |filter| {
            if (filterRemoves(arena, filter, word, candidate)) continue;
        }
        if (spec.prefix != null or spec.suffix != null) {
            try out.append(arena, try std.mem.concat(arena, u8, &.{ spec.prefix orelse "", candidate, spec.suffix orelse "" }));
        } else {
            try out.append(arena, candidate);
        }
    }
}

/// `-X pattern` removes matching candidates; a leading `!` inverts it, and
/// `&` stands for the word being completed.
fn filterRemoves(arena: Allocator, filter: []const u8, word: []const u8, candidate: []const u8) bool {
    var pattern = filter;
    var negate = false;
    if (pattern.len > 0 and pattern[0] == '!') {
        negate = true;
        pattern = pattern[1..];
    }
    const with_word = std.mem.replaceOwned(u8, arena, pattern, "&", word) catch pattern;
    const matched = glob.matchSegment(with_word, candidate);
    return if (negate) !matched else matched;
}

/// Quotes `text` as one wsh word.
fn shellQuote(arena: Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '\'');
    for (text) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
    return out.items;
}

/// Sets COMP_LINE and COMP_POINT in the environment, and COMP_WORDS and
/// COMP_CWORD as shell variables, for the duration of a completion call.
const CompletionVariables = struct {
    sh: *Shell,

    fn set(sh: *Shell, arena: Allocator, request: Request) !CompletionVariables {
        try sh.setEnv("COMP_LINE", request.line);
        try sh.setEnv("COMP_POINT", try std.fmt.allocPrint(arena, "{d}", .{request.point}));
        const list = try arena.alloc(value.Value, request.words.len);
        for (request.words, list) |word, *item| item.* = .{ .string = word };
        try sh.setVar("COMP_WORDS", .{ .list = list });
        try sh.setVar("COMP_CWORD", .{ .int = @intCast(request.cword) });
        return .{ .sh = sh };
    }

    fn clear(self: CompletionVariables) void {
        _ = self.sh.unsetEnv("COMP_LINE");
        _ = self.sh.unsetEnv("COMP_POINT");
        _ = self.sh.unsetVar("COMP_WORDS");
        _ = self.sh.unsetVar("COMP_CWORD");
    }
};

/// `-F function`: runs the function with the command, the word and the
/// previous word as `$1 $2 $3`, then reads COMPREPLY (a list, or a string
/// with one candidate per line).
fn callFunction(sh: *Shell, arena: Allocator, function: []const u8, request: Request, out: *std.ArrayList([]const u8)) !void {
    if (sh.getFunc(function) == null) {
        var buf: [256]u8 = undefined;
        sys.writeStr(sh.default_err, std.fmt.bufPrint(&buf, "\nwsh: completion: function `{s}' not found\n", .{function}) catch "\nwsh: completion: function not found\n");
        return;
    }
    const run = sh.trap_runner orelse return;

    const variables = try CompletionVariables.set(sh, arena, request);
    defer variables.clear();
    _ = sh.unsetVar("COMPREPLY");
    defer _ = sh.unsetVar("COMPREPLY");

    const source = try std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{
        function,
        try shellQuote(arena, request.command),
        try shellQuote(arena, request.word),
        try shellQuote(arena, request.previous),
    });
    const saved_status = sh.last_status;
    _ = run(sh, source);
    sh.last_status = saved_status;

    const reply = sh.getVar("COMPREPLY") orelse return;
    switch (reply) {
        .list => |entries| for (entries) |entry| {
            try out.append(arena, try entry.renderAlloc(arena));
        },
        .string => |text| {
            var lines = std.mem.splitScalar(u8, text, '\n');
            while (lines.next()) |candidate| if (candidate.len > 0) try out.append(arena, try arena.dupe(u8, candidate));
        },
        .none => {},
        else => try out.append(arena, try reply.renderAlloc(arena)),
    }
}

/// `-C command`: runs the command with the command name, the word and the
/// previous word as arguments; each output line is a candidate.
fn runCompletionCommand(sh: *Shell, arena: Allocator, command: []const u8, request: Request, out: *std.ArrayList([]const u8)) !void {
    const variables = try CompletionVariables.set(sh, arena, request);
    defer variables.clear();

    var output: ?[]const u8 = null;
    const simple = std.mem.indexOfAny(u8, command, "'\"\\$`;|&<>(){}*?[]~") == null;
    var parts: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, command, " \t");
    while (it.next()) |part| try parts.append(arena, part);
    if (parts.items.len == 0) return;

    if (simple and isExternal(sh, parts.items[0])) {
        try parts.appendSlice(arena, &.{ request.command, request.word, request.previous });
        output = runHelper(sh, arena, parts.items, command_spec_timeout_ms, false);
    } else {
        // A function, alias or shell text: run it through the shell, with
        // stdin off the terminal.
        const runner = sh.subst_runner orelse return;
        const source = try std.fmt.allocPrint(arena, "{s} {s} {s} {s}", .{
            command,
            try shellQuote(arena, request.command),
            try shellQuote(arena, request.word),
            try shellQuote(arena, request.previous),
        });
        const null_fd = sys.openRead("/dev/null") orelse return;
        defer sys.closeFd(null_fd);
        const saved_in = sh.default_in;
        const saved_status = sh.last_status;
        sh.default_in = null_fd;
        defer {
            sh.default_in = saved_in;
            sh.last_status = saved_status;
        }
        output = runner(sh, source, arena) catch null;
    }

    var lines = std.mem.splitScalar(u8, output orelse return, '\n');
    while (lines.next()) |candidate| if (candidate.len > 0) try out.append(arena, candidate);
}

// --- helper processes ----------------------------------------------------------------------

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}

/// Runs `argv` with stdin on /dev/null and returns what it printed, or null
/// when it cannot start or runs past `timeout_ms` (it is killed then).
/// stderr goes to /dev/null unless `merge_stderr` sends it to the output.
fn runHelper(sh: *Shell, arena: Allocator, argv: []const []const u8, timeout_ms: i64, merge_stderr: bool) ?[]const u8 {
    const path = (proc.resolve(arena, argv[0], sh.pathEnv()) catch return null) orelse return null;
    const null_fd = sys.openRead("/dev/null") orelse return null;
    defer sys.closeFd(null_fd);
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return null;
    var read_open = true;
    defer if (read_open) sys.closeFd(fds[0]);

    const exec = arena.create(proc.Exec) catch {
        sys.closeFd(fds[1]);
        return null;
    };
    exec.* = .{
        .path = (arena.dupeZ(u8, path) catch return null).ptr,
        .argv = proc.buildArgv(arena, argv) catch return null,
        .envp = sh.buildEnvp(arena) catch return null,
    };
    const stage = proc.Stage{
        .exec = exec,
        .stdio = .{ .in = null_fd, .out = fds[1], .err = if (merge_stderr) fds[1] else null_fd },
    };
    const launched = proc.launch(arena, &.{stage}, .{ .new_group = true }) catch {
        sys.closeFd(fds[1]);
        return null;
    };
    sys.closeFd(fds[1]);
    const pid = launched.pids[0];

    var output: std.ArrayList(u8) = .empty;
    const deadline = nowMs() + timeout_ms;
    var timed_out = false;
    var buf: [4096]u8 = undefined;
    while (true) {
        const remaining = deadline - nowMs();
        if (remaining <= 0) {
            timed_out = true;
            break;
        }
        var poll_fds = [_]posix.pollfd{.{ .fd = fds[0], .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&poll_fds, @intCast(remaining)) catch 0;
        if (ready == 0) continue;
        const n = sys.readSome(fds[0], &buf) orelse break;
        if (n == 0) break;
        if (output.items.len + n > helper_output_max) break;
        output.appendSlice(arena, buf[0..n]) catch break;
    }
    sys.closeFd(fds[0]);
    read_open = false;
    if (timed_out) {
        proc.signalGroup(launched.pgid, .KILL);
        proc.signalProcess(pid, .KILL);
    }
    _ = proc.waitPid(pid, 0);
    if (timed_out) return null;
    return output.items;
}

/// Caches that live for the session, owned by `cache_gpa`.
var cache_gpa: ?Allocator = null;
var git_commands: ?[]const []const u8 = null;
var option_cache: std.StringHashMapUnmanaged([]const []const u8) = .empty;

fn ownLines(gpa: Allocator, names: []const []const u8) ![]const []const u8 {
    const owned = try gpa.alloc([]const u8, names.len);
    for (names, owned) |name, *slot| slot.* = try gpa.dupe(u8, name);
    return owned;
}

fn freeLines(gpa: Allocator, names: []const []const u8) void {
    for (names) |name| gpa.free(name);
    gpa.free(names);
}

/// Frees the session caches (git subcommands, parsed `--help` output).
pub fn resetCaches() void {
    const gpa = cache_gpa orelse return;
    if (git_commands) |names| freeLines(gpa, names);
    git_commands = null;
    var it = option_cache.iterator();
    while (it.next()) |entry| {
        gpa.free(entry.key_ptr.*);
        freeLines(gpa, entry.value_ptr.*);
    }
    option_cache.deinit(gpa);
    option_cache = .empty;
    cache_gpa = null;
}

/// `--long-options` from `argv`'s help output, run once per `key`.
fn longOptions(sh: *Shell, arena: Allocator, key: []const u8, argv: []const []const u8) ![]const []const u8 {
    if (option_cache.get(key)) |cached| return cached;
    const output = runHelper(sh, arena, argv, helper_timeout_ms, true) orelse "";
    const options = try parseLongOptions(arena, output);
    if (cache_gpa == null) cache_gpa = sh.gpa;
    const gpa = cache_gpa.?;
    const owned = try ownLines(gpa, options);
    const owned_key = try gpa.dupe(u8, key);
    try option_cache.put(gpa, owned_key, owned);
    return owned;
}

/// Removes CSI and OSC escape sequences; some programs style `--help` even
/// when it goes to a pipe.
fn stripEscapes(arena: Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0x1b) == null) return text;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] != 0x1b) {
            try out.append(arena, text[i]);
            i += 1;
            continue;
        }
        i += 1;
        if (i >= text.len) break;
        if (text[i] == '[') {
            i += 1;
            while (i < text.len and !(text[i] >= 0x40 and text[i] <= 0x7e)) i += 1;
            i += 1;
        } else if (text[i] == ']') {
            while (i < text.len) : (i += 1) {
                if (text[i] == 0x07) break;
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') {
                    i += 1;
                    break;
                }
            }
            i += 1;
        } else {
            i += 1;
        }
    }
    return out.items;
}

/// Extracts `--name` and `--name=` from help text, in order of appearance.
pub fn parseLongOptions(arena: Allocator, help: []const u8) ![]const []const u8 {
    const text = try stripEscapes(arena, help);
    var options: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, text, i, "--")) |at| {
        i = at + 2;
        if (at > 0 and !(isBlankByte(text[at - 1]) or text[at - 1] == '\n' or text[at - 1] == ',' or text[at - 1] == '[' or text[at - 1] == '(' or text[at - 1] == '|')) continue;
        var end = i;
        if (end >= text.len or !std.ascii.isAlphanumeric(text[end])) continue;
        while (end < text.len and (std.ascii.isAlphanumeric(text[end]) or text[end] == '-' or text[end] == '_')) end += 1;
        const takes_value = end < text.len and text[end] == '=';
        const option = if (takes_value) text[at .. end + 1] else text[at..end];
        i = end;
        const gop = try seen.getOrPut(arena, option);
        if (gop.found_existing) continue;
        try options.append(arena, option);
    }
    return options.items;
}

// --- git ----------------------------------------------------------------------------------

const ref_subcommands = [_][]const u8{
    "checkout",     "switch",     "merge",    "rebase",      "branch",    "log",      "diff",     "reset",
    "show",         "revert",     "tag",      "cherry-pick", "rev-parse", "rev-list", "describe", "shortlog",
    "format-patch", "range-diff", "difftool", "whatchanged", "bisect",    "worktree",
};
const remote_subcommands = [_][]const u8{ "push", "pull", "fetch" };

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

fn gitLines(sh: *Shell, arena: Allocator, argv: []const []const u8) ![]const []const u8 {
    const output = runHelper(sh, arena, argv, helper_timeout_ms, false) orelse return &.{};
    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, output, "\r\n");
    while (it.next()) |line| try lines.append(arena, std.mem.trim(u8, line, " \t"));
    return lines.items;
}

fn gitSubcommands(sh: *Shell, arena: Allocator) ![]const []const u8 {
    if (git_commands) |names| return names;
    const names = try gitLines(sh, arena, &.{ "git", "--list-cmds=main,others,alias,nohelpers" });
    // Cache only a real answer, so a timeout is retried next time.
    if (names.len == 0) return names;
    if (cache_gpa == null) cache_gpa = sh.gpa;
    git_commands = try ownLines(cache_gpa.?, names);
    return git_commands.?;
}

fn completeGit(sh: *Shell, arena: Allocator, ctx: Context, items: *std.ArrayList([]const u8)) !void {
    const words = ctx.words;
    const word = ctx.word;
    var subcommand_index: ?usize = null;
    var i = ctx.command_index.? + 1;
    while (i < ctx.cword) : (i += 1) {
        const arg = words[i];
        if (eql(arg, "-C") or eql(arg, "-c") or eql(arg, "--git-dir") or eql(arg, "--work-tree") or eql(arg, "--namespace")) {
            i += 1;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') continue;
        subcommand_index = i;
        break;
    }

    const sub_index = subcommand_index orelse {
        if (std.mem.startsWith(u8, word, "-")) return;
        try appendWithSuffix(arena, items, try gitSubcommands(sh, arena), word, " ");
        return;
    };
    const subcommand = words[sub_index];
    for (words[sub_index + 1 .. ctx.cword]) |arg| {
        if (eql(arg, "--")) return completePaths(sh, arena, ctx.raw, .all, items);
    }
    if (std.mem.startsWith(u8, word, "--")) {
        const key = try std.fmt.allocPrint(arena, "git {s}", .{subcommand});
        const options = try longOptions(sh, arena, key, &.{ "git", subcommand, "-h" });
        try appendOptions(arena, items, options, word);
        return;
    }

    if (contains(&remote_subcommands, subcommand)) {
        var positional: usize = 0;
        for (words[sub_index + 1 .. ctx.cword]) |arg| {
            if (arg.len > 0 and arg[0] != '-') positional += 1;
        }
        if (positional == 0) {
            try appendWithSuffix(arena, items, try gitLines(sh, arena, &.{ "git", "remote" }), word, " ");
        } else {
            try appendWithSuffix(arena, items, try gitRefs(sh, arena), word, " ");
        }
        return;
    }
    if (contains(&ref_subcommands, subcommand)) {
        try appendWithSuffix(arena, items, try gitRefs(sh, arena), word, " ");
        if (items.items.len > 0) return;
    }
    try completePaths(sh, arena, ctx.raw, .all, items);
}

fn gitRefs(sh: *Shell, arena: Allocator) ![]const []const u8 {
    return gitLines(sh, arena, &.{ "git", "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/tags", "refs/remotes" });
}

// --- make, hosts, jobs, users ---------------------------------------------------------------

fn makeTargets(sh: *Shell, arena: Allocator, ctx: Context, out: *std.ArrayList([]const u8)) !void {
    var directory: ?[]const u8 = null;
    var file: ?[]const u8 = null;
    var i = ctx.command_index.? + 1;
    while (i < ctx.words.len) : (i += 1) {
        if (i == ctx.cword) continue;
        const arg = ctx.words[i];
        if ((eql(arg, "-f") or eql(arg, "--file") or eql(arg, "--makefile")) and i + 1 < ctx.words.len) {
            file = ctx.words[i + 1];
            i += 1;
        } else if ((eql(arg, "-C") or eql(arg, "--directory")) and i + 1 < ctx.words.len) {
            directory = ctx.words[i + 1];
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--file=")) {
            file = arg["--file=".len..];
        } else if (std.mem.startsWith(u8, arg, "--directory=")) {
            directory = arg["--directory=".len..];
        }
    }
    const base = if (directory) |dir| try sh.tildeExpand(arena, dir) else ".";
    const names: []const []const u8 = if (file) |f| &.{f} else &.{ "GNUmakefile", "makefile", "Makefile" };
    for (names) |name| {
        const path = if (name.len > 0 and name[0] == '/') name else try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name });
        const text = (fs.readFileAlloc(arena, try arena.dupeZ(u8, path), helper_output_max) catch null) orelse continue;
        try parseMakeTargets(arena, text, out);
        return;
    }
}

/// Explicit targets of a makefile: rule heads that are not special
/// (`.PHONY`), pattern (`%.o`) or variable-built targets.
pub fn parseMakeTargets(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0 or raw_line[0] == '\t' or raw_line[0] == '#') continue;
        const line = if (std.mem.indexOfScalar(u8, raw_line, '#')) |hash| raw_line[0..hash] else raw_line;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.mem.indexOfScalar(u8, line[0..colon], '=') != null) continue;
        var after = colon + 1;
        if (after < line.len and line[after] == ':') after += 1;
        if (after < line.len and line[after] == '=') continue;
        var targets = std.mem.tokenizeAny(u8, line[0..colon], " \t");
        while (targets.next()) |target| {
            if (target[0] == '.' or std.mem.indexOfAny(u8, target, "%$()") != null) continue;
            const gop = try seen.getOrPut(arena, target);
            if (gop.found_existing) continue;
            try out.append(arena, target);
        }
    }
}

fn completeHosts(sh: *Shell, arena: Allocator, ctx: Context, name: []const u8, items: *std.ArrayList([]const u8)) !void {
    const word = ctx.word;
    const copies = eql(name, "scp") or eql(name, "rsync");
    // `host:path` is remote; local paths are not completed for it.
    if (copies and std.mem.indexOfScalar(u8, word, ':') != null) return;
    const at = std.mem.indexOfScalar(u8, word, '@');
    const user = if (at) |index| word[0 .. index + 1] else "";
    const host_prefix = if (at) |index| word[index + 1 ..] else word;

    var hosts: std.ArrayList([]const u8) = .empty;
    try hostNames(sh, arena, host_prefix, &hosts);
    const suffix: []const u8 = if (copies) ":" else " ";
    for (hosts.items) |host| try items.append(arena, try std.mem.concat(arena, u8, &.{ user, host, suffix }));
    if (copies and at == null) try completePaths(sh, arena, ctx.raw, .all, items);
}

/// Host names from ~/.ssh/config `Host` lines (without wildcards) and the
/// unhashed entries of ~/.ssh/known_hosts.
fn hostNames(sh: *Shell, arena: Allocator, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const home = sh.getEnv("HOME") orelse return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var found: std.ArrayList([]const u8) = .empty;

    const config_path = try std.fmt.allocPrintSentinel(arena, "{s}/.ssh/config", .{home}, 0);
    if (fs.readFileAlloc(arena, config_path, helper_output_max) catch null) |text| try parseSshConfigHosts(arena, text, &found);
    const known_path = try std.fmt.allocPrintSentinel(arena, "{s}/.ssh/known_hosts", .{home}, 0);
    if (fs.readFileAlloc(arena, known_path, helper_output_max) catch null) |text| try parseKnownHosts(arena, text, &found);

    for (found.items) |host| {
        if (!std.mem.startsWith(u8, host, prefix)) continue;
        const gop = try seen.getOrPut(arena, host);
        if (gop.found_existing) continue;
        try out.append(arena, host);
    }
}

pub fn parseSshConfigHosts(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len < 5 or !std.ascii.eqlIgnoreCase(line[0..4], "host")) continue;
        if (!isBlankByte(line[4]) and line[4] != '=') continue;
        var patterns = std.mem.tokenizeAny(u8, line[5..], " \t=");
        while (patterns.next()) |pattern| {
            if (std.mem.indexOfAny(u8, pattern, "*?!") != null) continue;
            try out.append(arena, pattern);
        }
    }
}

pub fn parseKnownHosts(arena: Allocator, text: []const u8, out: *std.ArrayList([]const u8)) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '|') continue;
        if (line[0] == '@') {
            const space = std.mem.indexOfAny(u8, line, " \t") orelse continue;
            line = std.mem.trimStart(u8, line[space..], " \t");
        }
        const field_end = std.mem.indexOfAny(u8, line, " \t") orelse line.len;
        var hosts = std.mem.splitScalar(u8, line[0..field_end], ',');
        while (hosts.next()) |entry| {
            var host = entry;
            if (host.len > 0 and host[0] == '[') {
                const close = std.mem.indexOfScalar(u8, host, ']') orelse continue;
                host = host[1..close];
            }
            if (host.len == 0 or host[0] == '|' or std.mem.indexOfAny(u8, host, "*?!") != null) continue;
            try out.append(arena, try arena.dupe(u8, host));
        }
    }
}

fn completeJobs(sh: *Shell, arena: Allocator, word: []const u8, items: *std.ArrayList([]const u8)) !void {
    for (sh.jobs.jobs.items) |job| {
        if (job.state == .done) continue;
        const spec = try std.fmt.allocPrint(arena, "%{d}", .{job.id});
        if (std.mem.startsWith(u8, spec, word)) try items.append(arena, try std.mem.concat(arena, u8, &.{ spec, " " }));
    }
}

/// First field of each line of a passwd-format file (`/etc/passwd`,
/// `/etc/group`) that starts with `prefix`.
fn passwdNames(arena: Allocator, path: [:0]const u8, prefix: []const u8, out: *std.ArrayList([]const u8)) !void {
    const text = (fs.readFileAlloc(arena, path, helper_output_max) catch null) orelse return;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        const name = line[0..colon];
        if (name.len == 0 or name[0] == '#' or name[0] == '+' or name[0] == '-') continue;
        if (std.mem.startsWith(u8, name, prefix)) try out.append(arena, name);
    }
}

/// Longest prefix shared by every candidate. The editor inserts this before
/// deciding whether the completion is unambiguous.
pub fn commonPrefix(items: []const []const u8) usize {
    if (items.len == 0) return 0;
    var len = items[0].len;
    for (items[1..]) |item| {
        var i: usize = 0;
        const limit = @min(len, item.len);
        while (i < limit and items[0][i] == item[i]) i += 1;
        len = i;
        if (len == 0) break;
    }
    return len;
}

// --- tests ----------------------------------------------------------------------------------

const testing = std.testing;

test "completion finds files and commands" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A command position completes against PATH, so `echo` must appear.
    const commands = try complete(&sh, arena, "ech", 3);
    var found_echo = false;
    for (commands.items) |item| {
        if (std.mem.startsWith(u8, item, "echo")) found_echo = true;
    }
    try testing.expect(found_echo);

    // A path position completes against the filesystem.
    const paths = try complete(&sh, arena, "cat src/lex", 11);
    try testing.expect(paths.items.len >= 1);
    try testing.expectEqualStrings("src/lexer.zig ", paths.items[0]);
    try testing.expectEqual(@as(usize, 4), paths.start);

    const case_paths = try complete(&sh, arena, "cat readme", 10);
    try testing.expectEqual(@as(usize, 1), case_paths.items.len);
    try testing.expectEqualStrings("README.md ", case_paths.items[0]);

    // A word that opened a quote keeps it and gets it closed.
    const quoted = try complete(&sh, arena, "cat \"READ", 9);
    try testing.expectEqualStrings("\"README.md\" ", quoted.items[0]);

    // cd completes directories only.
    const dirs = try complete(&sh, arena, "cd s", 4);
    try testing.expectEqual(@as(usize, 1), dirs.items.len);
    try testing.expectEqualStrings("src/", dirs.items[0]);
}

test "completion of variables" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setVar("greeting", .{ .string = "hi" });

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try complete(&sh, arena_state.allocator(), "echo $gree", 10);
    try testing.expectEqualStrings("$greeting ", res.items[0]);

    const inner = try complete(&sh, arena_state.allocator(), "echo --name=$gree", 17);
    try testing.expectEqualStrings("$greeting", inner.items[0]);
    try testing.expectEqual(@as(usize, 12), inner.start);
}

test "common prefix" {
    const items = [_][]const u8{ "src/main.zig", "src/main_test.zig" };
    try testing.expectEqual(@as(usize, 8), commonPrefix(&items));
}

test "line parsing finds the command and the current word" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = try parseLine(arena, "ls -la", 6);
    try testing.expectEqual(@as(usize, 1), ctx.cword);
    try testing.expectEqual(@as(usize, 3), ctx.start);
    try testing.expectEqual(@as(?usize, 0), ctx.command_index);

    ctx = try parseLine(arena, "ls | gr", 7);
    try testing.expectEqual(@as(?usize, null), ctx.command_index);
    try testing.expectEqualStrings("gr", ctx.word);

    ctx = try parseLine(arena, "FOO=1 sudo git che x", 18);
    try testing.expectEqual(@as(?usize, 2), ctx.command_index);
    try testing.expectEqual(@as(usize, 3), ctx.cword);
    try testing.expectEqual(@as(usize, 5), ctx.words.len);

    ctx = try parseLine(arena, "cat 'my fi", 10);
    try testing.expectEqualStrings("my fi", ctx.word);
    try testing.expectEqual(@as(usize, 4), ctx.start);

    ctx = try parseLine(arena, "git commit ", 11);
    try testing.expectEqual(@as(usize, 2), ctx.cword);
    try testing.expectEqualStrings("", ctx.word);

    ctx = try parseLine(arena, "echo hi > ou", 12);
    try testing.expect(ctx.redirect);
    ctx = try parseLine(arena, "cmd 2>/dev/nu", 13);
    try testing.expect(ctx.redirect);
    try testing.expectEqualStrings("/dev/nu", ctx.word);
}

test "programmable completion with word lists and functions" {
    const exec = @import("../exec.zig");
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    exec.install(&sh);
    defer compspec.reset();

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    _ = exec.runSource(&sh, "complete -W 'alpha beta alps' deploy");
    var res = try complete(&sh, arena, "deploy al", 9);
    try testing.expectEqual(@as(usize, 2), res.items.len);
    try testing.expectEqualStrings("alpha ", res.items[0]);
    try testing.expectEqualStrings("alps ", res.items[1]);

    _ = exec.runSource(&sh, "fn _greet() { let COMPREPLY = [\"$2-one\", \"$3-two\", \"$1\"] }");
    _ = exec.runSource(&sh, "complete -o nospace -F _greet greet");
    res = try complete(&sh, arena, "greet first x", 13);
    try testing.expectEqual(@as(usize, 3), res.items.len);
    try testing.expectEqualStrings("first-two", res.items[0]);
    try testing.expectEqualStrings("greet", res.items[1]);
    try testing.expectEqualStrings("x-one", res.items[2]);
    // The COMP_ variables only exist during the call.
    try testing.expect(sh.getVar("COMP_WORDS") == null);
    try testing.expect(sh.getEnv("COMP_LINE") == null);

    _ = exec.runSource(&sh, "fn _words() { let COMPREPLY = \"$COMP_CWORD:$COMP_POINT\" }");
    _ = exec.runSource(&sh, "complete -F _words w");
    res = try complete(&sh, arena, "w a b", 3);
    try testing.expectEqualStrings("1:3 ", res.items[0]);
}

test "make targets and ssh hosts are parsed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var targets: std.ArrayList([]const u8) = .empty;
    const makefile = "CC := gcc\nVERSION = 1:2\n.PHONY: all clean\nall: build test\n" ++
        "build test: deps ## comment\n\techo recipe: not a target\n%.o: %.c\ninstall:: all\n$(OUT): x\n";
    try parseMakeTargets(arena, makefile, &targets);
    const expected = [_][]const u8{ "all", "build", "test", "install" };
    try testing.expectEqual(expected.len, targets.items.len);
    for (expected, targets.items) |want, got| try testing.expectEqualStrings(want, got);

    var hosts: std.ArrayList([]const u8) = .empty;
    try parseSshConfigHosts(arena, "Host web db\n  HostName 10.0.0.1\nHost *.internal\nhost=jump\n", &hosts);
    try parseKnownHosts(arena, "alpha,10.1.1.1 ssh-ed25519 AAAA\n[beta]:2222 ssh-rsa AAAA\n|1|hash= ssh-rsa AAAA\n@cert-authority gamma ssh-rsa AAAA\n", &hosts);
    const expected_hosts = [_][]const u8{ "web", "db", "jump", "alpha", "10.1.1.1", "beta", "gamma" };
    try testing.expectEqual(expected_hosts.len, hosts.items.len);
    for (expected_hosts, hosts.items) |want, got| try testing.expectEqualStrings(want, got);
}

test "long options are read from help text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const options = try parseLongOptions(arena_state.allocator(),
        \\  -a, --all                  do not ignore entries
        \\      --color[=WHEN]         colorize the output
        \\      --block-size=SIZE      scale sizes
        \\  -h, --help                 this help (also --help)
        \\ not--an-option
        \\
    ++ " \x1b]8;;https://example.org\x1b\\\x1b[1m--styled[=WHEN]\x1b[0m\x1b]8;;\x1b\\\n");
    const expected = [_][]const u8{ "--all", "--color", "--block-size=", "--help", "--styled" };
    try testing.expectEqual(expected.len, options.len);
    for (expected, options) |want, got| try testing.expectEqualStrings(want, got);
}

test "job specs complete for fg" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    _ = try sh.jobs.add(sh.gpa, 4242, &.{4242}, "sleep 30", false);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try complete(&sh, arena_state.allocator(), "fg %", 4);
    try testing.expectEqual(@as(usize, 1), res.items.len);
    try testing.expectEqualStrings("%1 ", res.items[0]);
}

test "helper processes time out" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setEnv("PATH", "/usr/bin:/bin");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("hi\n", runHelper(&sh, arena, &.{ "echo", "hi" }, 1000, false).?);
    const started = nowMs();
    try testing.expect(runHelper(&sh, arena, &.{ "sleep", "5" }, 100, false) == null);
    try testing.expect(nowMs() - started < 2000);
}

test "long options of a command come from its --help" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    defer resetCaches();
    try sh.setEnv("PATH", "/usr/bin:/bin");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const res = try complete(&sh, arena_state.allocator(), "ls --almost-a", 13);
    try testing.expectEqual(@as(usize, 1), res.items.len);
    try testing.expectEqualStrings("--almost-all ", res.items[0]);
    try testing.expect(option_cache.get("ls") != null);
}
