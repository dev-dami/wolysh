//! The prompt: wolysh's built-in prompt, the `prompt` config string, or a
//! bash-style `PS1`/`PS2` with its backslash escapes.

const std = @import("std");
const linux = std.os.linux;
const build_options = @import("build_options");
const shellmod = @import("../shell.zig");
const expand_mod = @import("../expand.zig");
const highlight = @import("highlight.zig");
const sys = @import("../sys.zig");
const fs = @import("../fs.zig");
const localtime = @import("localtime.zig");

const Shell = shellmod.Shell;

/// The `❯` marker, coloured by the previous command's status.
const marker = "\u{276f}";

/// `\#`: the number of the command about to be entered. The REPL advances it.
pub var command_number: usize = 1;

pub fn write(out: *std.Io.Writer, sh: *Shell) !void {
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (sh.config.prompt.len != 0) {
        // A custom prompt is expanded like a shell word, so `$USER` and
        // `$(...)` work in it.
        const text = expand_mod.expandLiteral(sh, arena, sh.config.prompt) catch sh.config.prompt;
        try out.writeAll(text);
        return;
    }

    if (try textVar(sh, arena, "PS1")) |ps1| {
        try out.writeAll(try render(sh, arena, ps1, "PS1"));
        return;
    }

    const color = colors(sh);
    const cwd = try sh.shortCwd(arena);
    try out.writeAll(color.pick(highlight.bold));
    try out.writeAll(color.pick(highlight.cyan));
    try out.writeAll(cwd);
    try out.writeAll(color.pick(highlight.reset));

    if (sh.config.git_prompt) {
        if (try sh.gitBranch(arena)) |branch| {
            try out.writeByte(' ');
            try out.writeAll(color.pick(highlight.magenta));
            try out.writeAll(branch);
            try out.writeAll(color.pick(highlight.reset));
        }
    }

    try out.writeByte(' ');
    try out.writeAll(color.pick(if (sh.last_status == 0) highlight.green else highlight.red));
    try out.writeAll(marker);
    try out.writeAll(color.pick(highlight.reset));
    try out.writeByte(' ');
}

/// Prompt shown while a multi-line construct is still open.
pub fn writeContinuation(out: *std.Io.Writer, sh: *Shell, depth: usize) !void {
    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    if (try textVar(sh, arena, "PS2")) |ps2| {
        try out.writeAll(try render(sh, arena, ps2, "PS2"));
        return;
    }

    const color = colors(sh);
    try out.writeAll(color.pick(highlight.dim));
    var i: usize = 0;
    while (i < depth and i < 8) : (i += 1) try out.writeAll("  ");
    try out.writeAll("… ");
    try out.writeAll(color.pick(highlight.reset));
}

const Colors = struct {
    enabled: bool,

    fn pick(self: Colors, code: []const u8) []const u8 {
        return if (self.enabled) code else "";
    }
};

/// https://no-color.org: a non-empty `NO_COLOR` turns off the built-in
/// prompt's colours. Colours written into `PS1` are the user's own and stay.
fn colors(sh: *const Shell) Colors {
    if (sh.getVar("NO_COLOR")) |v| return .{ .enabled = v.isNull() };
    const no_color = sh.getEnv("NO_COLOR") orelse return .{ .enabled = true };
    return .{ .enabled = no_color.len == 0 };
}

/// A shell variable, or else an environment variable, as text.
pub fn textVar(sh: *const Shell, arena: std.mem.Allocator, name: []const u8) !?[]const u8 {
    if (sh.getVar(name)) |v| return try v.renderAlloc(arena);
    return sh.getEnv(name);
}

/// Decodes the backslash escapes of a bash prompt string, then expands
/// parameters, command substitutions and arithmetic in the result, as bash
/// does with `promptvars` on.
pub fn render(sh: *Shell, arena: std.mem.Allocator, text: []const u8, name: []const u8) ![]const u8 {
    var decoded: std.ArrayList(u8) = .empty;
    try decode(sh, arena, &decoded, text);
    return expand_mod.expandHereDoc(sh, arena, decoded.items) catch |err| {
        var buf: [160]u8 = undefined;
        const message = std.fmt.bufPrint(&buf, "wsh: {s}: {s}\n", .{ name, @errorName(err) }) catch "wsh: prompt expansion failed\n";
        sys.writeStr(2, message);
        return decoded.items;
    };
}

/// Appends a value that comes from outside the prompt string (a directory,
/// the user name) with `$`, `` ` `` and `\` quoted, so the expansion that
/// follows shows it instead of running it.
fn appendQuoted(arena: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    for (value) |c| {
        if (c == '$' or c == '`' or c == '\\') try out.append(arena, '\\');
        try out.append(arena, c);
    }
}

fn appendTime(arena: std.mem.Allocator, out: *std.ArrayList(u8), sh: *Shell, spec: []const u8) !void {
    const tz = try textVar(sh, arena, "TZ");
    const now = localtime.now(tz);
    var allocating: std.Io.Writer.Allocating = .init(arena);
    try localtime.format(&allocating.writer, spec, now);
    try appendQuoted(arena, out, allocating.writer.buffered());
}

pub fn decode(sh: *Shell, arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '\\' or i + 1 == text.len) {
            try out.append(arena, c);
            continue;
        }
        i += 1;
        const escape = text[i];
        switch (escape) {
            'a' => try out.append(arena, 0x07),
            'e' => try out.append(arena, 0x1b),
            'n' => try out.append(arena, '\n'),
            'r' => try out.append(arena, '\r'),
            // A lone backslash still quotes the next character when the
            // result is expanded, as in bash.
            '\\' => try out.append(arena, '\\'),
            '[', ']' => {},
            '$' => try out.appendSlice(arena, if (linux.geteuid() == 0) "#" else "\\$"),
            'u' => try appendQuoted(arena, out, try userName(sh, arena)),
            'h' => {
                const dot = std.mem.indexOfScalar(u8, sh.hostname, '.') orelse sh.hostname.len;
                try appendQuoted(arena, out, sh.hostname[0..dot]);
            },
            'H' => try appendQuoted(arena, out, sh.hostname),
            'w' => try appendQuoted(arena, out, try sh.shortenHome(arena, sh.cwd)),
            'W' => {
                const short = try sh.shortenHome(arena, sh.cwd);
                const base = if (std.mem.eql(u8, short, "~") or std.mem.eql(u8, short, "/"))
                    short
                else
                    std.fs.path.basename(short);
                try appendQuoted(arena, out, base);
            },
            's' => try appendQuoted(arena, out, if (sh.script_name.len != 0) std.fs.path.basename(sh.script_name) else "wsh"),
            'v' => {
                const version = build_options.version;
                const second_dot = if (std.mem.indexOfScalar(u8, version, '.')) |dot|
                    std.mem.indexOfScalarPos(u8, version, dot + 1, '.') orelse version.len
                else
                    version.len;
                try out.appendSlice(arena, version[0..second_dot]);
            },
            'V' => try out.appendSlice(arena, build_options.version),
            'j' => {
                var running: usize = 0;
                for (sh.jobs.jobs.items) |job| {
                    if (job.state != .done) running += 1;
                }
                try out.print(arena, "{d}", .{running});
            },
            'l' => try appendQuoted(arena, out, try ttyName(arena)),
            '!' => try out.print(arena, "{d}", .{sh.hist.count() + 1}),
            '#' => try out.print(arena, "{d}", .{command_number}),
            'd' => try appendTime(arena, out, sh, "%a %b %d"),
            't' => try appendTime(arena, out, sh, "%H:%M:%S"),
            'T' => try appendTime(arena, out, sh, "%I:%M:%S"),
            '@' => try appendTime(arena, out, sh, "%I:%M %p"),
            'A' => try appendTime(arena, out, sh, "%H:%M"),
            'D' => {
                const close = if (i + 1 < text.len and text[i + 1] == '{')
                    std.mem.indexOfScalarPos(u8, text, i + 2, '}')
                else
                    null;
                if (close) |end| {
                    const spec = text[i + 2 .. end];
                    try appendTime(arena, out, sh, if (spec.len == 0) "%X" else spec);
                    i = end;
                } else {
                    try out.appendSlice(arena, "\\D");
                }
            },
            '0'...'7' => {
                var value: u32 = 0;
                var digits: usize = 0;
                while (digits < 3 and i + digits < text.len and text[i + digits] >= '0' and text[i + digits] <= '7') : (digits += 1) {
                    value = value * 8 + (text[i + digits] - '0');
                }
                if (value == 0) {
                    try out.append(arena, '\\');
                    try out.appendSlice(arena, text[i .. i + digits]);
                } else {
                    try out.append(arena, @truncate(value));
                }
                i += digits - 1;
            },
            else => {
                try out.append(arena, '\\');
                try out.append(arena, escape);
            },
        }
    }
}

/// `\u`: `$USER`, else the password-file entry for the real uid.
fn userName(sh: *const Shell, arena: std.mem.Allocator) ![]const u8 {
    if (sh.getEnv("USER")) |user| if (user.len != 0) return user;
    const uid = linux.getuid();
    const data = (try fs.readFileAlloc(arena, "/etc/passwd", 4 << 20)) orelse return "";
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, ':');
        const name = fields.next() orelse continue;
        _ = fields.next() orelse continue;
        const id = fields.next() orelse continue;
        if ((std.fmt.parseInt(u32, id, 10) catch continue) == uid) return name;
    }
    return "";
}

/// `\l`: basename of the terminal on standard input, or `tty`.
fn ttyName(arena: std.mem.Allocator) ![]const u8 {
    if (!sys.isTty(0)) return "tty";
    const target = (try fs.readLink(arena, "/proc/self/fd/0")) orelse return "tty";
    return std.fs.path.basename(target);
}

test "prompt includes the marker" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    std.testing.allocator.free(sh.cwd);
    sh.cwd = try std.testing.allocator.dupe(u8, "/tmp");

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try write(&allocating.writer, &sh);

    const text = allocating.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/tmp") != null);
}

test "NO_COLOR drops the built-in prompt colours" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    sh.config.git_prompt = false;
    try sh.setEnv("NO_COLOR", "1");

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try write(&allocating.writer, &sh);
    try std.testing.expect(std.mem.indexOfScalar(u8, allocating.writer.buffered(), 0x1b) == null);
}

test "PS1 escapes decode like bash" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    std.testing.allocator.free(sh.cwd);
    sh.cwd = try std.testing.allocator.dupe(u8, "/home/dev/a$(x)");
    try sh.setEnv("HOME", "/home/dev");
    try sh.setEnv("USER", "dami");
    std.testing.allocator.free(sh.hostname);
    sh.hostname = try std.testing.allocator.dupe(u8, "box.example.org");

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try render(&sh, arena, "[\\u@\\h \\W]\\[\\e[1m\\]\\101\\q\\\\x \\H \\w", "PS1");
    try std.testing.expectEqualStrings("[dami@box a$(x)]\x1b[1mA\\q\\x box.example.org ~/a$(x)", text);

    command_number = 7;
    const counters = try render(&sh, arena, "\\#|\\!|\\j|\\s", "PS1");
    try std.testing.expectEqualStrings("7|1|0|wsh", counters);
}
