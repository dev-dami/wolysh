//! The prompt.

const std = @import("std");
const shellmod = @import("../shell.zig");
const expand_mod = @import("../expand.zig");
const highlight = @import("highlight.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

/// The `❯` marker, coloured by the previous command's status.
const marker = "\u{276f}";

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

    const cwd = try sh.shortCwd(arena);
    try out.writeAll(highlight.bold);
    try out.writeAll(highlight.cyan);
    try out.writeAll(cwd);
    try out.writeAll(highlight.reset);

    if (sh.config.git_prompt) {
        if (try sh.gitBranch(arena)) |branch| {
            try out.writeByte(' ');
            try out.writeAll(highlight.magenta);
            try out.writeAll(branch);
            try out.writeAll(highlight.reset);
        }
    }

    try out.writeByte(' ');
    try out.writeAll(if (sh.last_status == 0) highlight.green else highlight.red);
    try out.writeAll(marker);
    try out.writeAll(highlight.reset);
    try out.writeByte(' ');
}

/// Prompt shown while a multi-line construct is still open.
pub fn writeContinuation(out: *std.Io.Writer, sh: *Shell, depth: usize) !void {
    _ = sh;
    try out.writeAll(highlight.dim);
    var i: usize = 0;
    while (i < depth and i < 8) : (i += 1) try out.writeAll("  ");
    try out.writeAll("… ");
    try out.writeAll(highlight.reset);
}

test "prompt includes the marker" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    sh.cwd = try std.testing.allocator.dupe(u8, "/tmp");

    var allocating: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer allocating.deinit();
    try write(&allocating.writer, &sh);

    const text = allocating.writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, text, marker) != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "/tmp") != null);
}
