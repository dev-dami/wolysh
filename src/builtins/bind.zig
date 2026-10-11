//! `bind`: show and change the line editor's key bindings.
//!
//! Bindings are single keys (`"\C-x"`, `"\ex"`) mapped to one of the editor's
//! named functions (`bind -l`) or, with `-x`, to a shell command. Key
//! sequences longer than one key and keyboard macros are not supported.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const bindings = @import("../interactive/bindings.zig");
const fs = @import("../fs.zig");

const Ctx = builtins.Ctx;
const Chord = bindings.Chord;

const usage = "wsh: bind: usage: bind [-lpsvPSVX] [-m keymap] [-f filename] [-q name] [-u name] [-r keyseq] [-x keyseq:shell-command] [keyseq:readline-function]\n";

pub fn run(ctx: Ctx) u8 {
    var parser = options.Parser.init(ctx.argv, "lpsvPSVXm:f:q:u:r:x:");
    var status: u8 = 0;
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid => |c| {
                ctx.errFmt("wsh: bind: -{c}: invalid option\n", .{c});
                ctx.err(usage);
                return 2;
            },
            .missing => |c| {
                ctx.errFmt("wsh: bind: -{c}: option requires an argument\n", .{c});
                ctx.err(usage);
                return 2;
            },
            .option => |c| {
                switch (c) {
                    'l' => for (bindings.functionNames()) |name| {
                        ctx.out(name);
                        ctx.out("\n");
                    },
                    'p' => printBindings(ctx, true),
                    'P' => printBindings(ctx, false),
                    'X' => printCommands(ctx),
                    'v' => printVariables(ctx, true),
                    'V' => printVariables(ctx, false),
                    // No macros exist, so there is nothing to list.
                    's', 'S' => {},
                    // The one keymap is the editor's current mode.
                    'm' => {},
                    'f' => if (!readFile(ctx, parser.optarg)) {
                        status = 1;
                    },
                    'q' => if (!query(ctx, parser.optarg)) {
                        status = 1;
                    },
                    'u' => if (!unbindFunction(ctx, parser.optarg)) {
                        status = 1;
                    },
                    'r' => if (!unbindKey(ctx, parser.optarg)) {
                        status = 1;
                    },
                    'x' => if (!bindCommand(ctx, parser.optarg)) {
                        status = 1;
                    },
                    else => unreachable,
                }
            },
        }
    }

    for (parser.rest()) |binding| {
        if (!bindFunction(ctx, binding)) status = 1;
    }
    return status;
}

// --- reading specifications ----------------------------------------------------------------

/// Splits `"keyseq": rest` (or `keyseq: rest`) at the colon that ends the key.
fn splitKey(text: []const u8) ?struct { key: []const u8, rest: []const u8 } {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    if (trimmed[0] == '"') {
        var i: usize = 1;
        while (i < trimmed.len) : (i += 1) {
            if (trimmed[i] == '\\') {
                i += 1;
                continue;
            }
            if (trimmed[i] == '"') break;
        }
        if (i >= trimmed.len) return null;
        const after = std.mem.trimStart(u8, trimmed[i + 1 ..], " \t");
        if (after.len == 0 or after[0] != ':') return null;
        return .{ .key = trimmed[1..i], .rest = std.mem.trim(u8, after[1..], " \t") };
    }
    const colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    return .{ .key = std.mem.trim(u8, trimmed[0..colon], " \t"), .rest = std.mem.trim(u8, trimmed[colon + 1 ..], " \t") };
}

fn chordOf(ctx: Ctx, key: []const u8) ?Chord {
    return bindings.parseKeySequence(key) orelse {
        ctx.errFmt("wsh: bind: {s}: unsupported key sequence (use one key such as \"\\C-x\" or \"\\ex\")\n", .{key});
        return null;
    };
}

fn bindFunction(ctx: Ctx, text: []const u8) bool {
    const parts = splitKey(text) orelse {
        ctx.errFmt("wsh: bind: {s}: expected keyseq:function-name\n", .{text});
        return false;
    };
    const chord = chordOf(ctx, parts.key) orelse return false;
    if (parts.rest.len > 0 and parts.rest[0] == '"') {
        ctx.err("wsh: bind: keyboard macros are not supported\n");
        return false;
    }
    const function = bindings.functionByName(parts.rest) orelse {
        ctx.errFmt("wsh: bind: `{s}': unknown function name\n", .{parts.rest});
        return false;
    };
    bindings.set(ctx.sh.gpa, chord, .{ .function = function }) catch {
        ctx.err("wsh: bind: out of memory\n");
        return false;
    };
    return true;
}

/// `-x 'keyseq:command'`; the command may be quoted.
fn bindCommand(ctx: Ctx, text: []const u8) bool {
    const parts = splitKey(text) orelse {
        ctx.errFmt("wsh: bind: {s}: expected keyseq:shell-command\n", .{text});
        return false;
    };
    const chord = chordOf(ctx, parts.key) orelse return false;
    var command = parts.rest;
    if (command.len >= 2 and (command[0] == '"' or command[0] == '\'') and command[command.len - 1] == command[0]) {
        command = command[1 .. command.len - 1];
    }
    if (command.len == 0) {
        ctx.errFmt("wsh: bind: {s}: expected keyseq:shell-command\n", .{text});
        return false;
    }
    bindings.set(ctx.sh.gpa, chord, .{ .command = command }) catch {
        ctx.err("wsh: bind: out of memory\n");
        return false;
    };
    return true;
}

/// `-f file`: lines of `"keyseq": function`. Comments, `$` directives and
/// `set` lines are accepted and ignored.
fn readFile(ctx: Ctx, path: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const z = arena.dupeZ(u8, path) catch return false;
    const text = (fs.readFileAlloc(arena, z, 1 << 20) catch null) orelse {
        ctx.errFmt("wsh: bind: {s}: cannot read: No such file or directory\n", .{path});
        return false;
    };
    var ok = true;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '$') continue;
        if (std.mem.startsWith(u8, line, "set ")) continue;
        if (!bindFunction(ctx, line)) ok = false;
    }
    return ok;
}

// --- removing -------------------------------------------------------------------------------------

fn defaultFunction(chord: Chord) ?bindings.Function {
    for (bindings.defaults) |entry| {
        if (entry[0].eql(chord)) return entry[1];
    }
    return null;
}

/// `-r keyseq`: the key does nothing afterwards.
fn unbindKey(ctx: Ctx, key: []const u8) bool {
    const chord = chordOf(ctx, key) orelse return false;
    _ = bindings.remove(chord);
    if (defaultFunction(chord) != null) {
        bindings.set(ctx.sh.gpa, chord, .unbound) catch return false;
    }
    return true;
}

/// `-u function`: every key bound to the function stops doing it.
fn unbindFunction(ctx: Ctx, name: []const u8) bool {
    const function = bindings.functionByName(name) orelse {
        ctx.errFmt("wsh: bind: `{s}': unknown function name\n", .{name});
        return false;
    };
    var index: usize = 0;
    while (index < bindings.list().len) {
        const binding = bindings.list()[index];
        if (binding.target == .function and binding.target.function == function) {
            _ = bindings.remove(binding.chord);
        } else {
            index += 1;
        }
    }
    for (bindings.defaults) |entry| {
        if (entry[1] != function or bindings.lookup(entry[0]) != null) continue;
        bindings.set(ctx.sh.gpa, entry[0], .unbound) catch return false;
    }
    return true;
}

// --- listing --------------------------------------------------------------------------------------

/// The function a key runs now: a rebinding, else its default.
fn effective(chord: Chord) ?bindings.Function {
    if (bindings.lookup(chord)) |target| {
        return switch (target) {
            .function => |function| function,
            else => null,
        };
    }
    return defaultFunction(chord);
}

const Bound = struct { chord: Chord, function: bindings.Function };

/// Every key that currently runs a named function, defaults first.
fn boundKeys(arena: std.mem.Allocator) ![]Bound {
    var found: std.ArrayList(Bound) = .empty;
    for (bindings.defaults) |entry| {
        if (effective(entry[0])) |function| try found.append(arena, .{ .chord = entry[0], .function = function });
    }
    for (bindings.list()) |binding| {
        if (binding.target != .function or defaultFunction(binding.chord) != null) continue;
        try found.append(arena, .{ .chord = binding.chord, .function = binding.target.function });
    }
    return found.items;
}

fn chordText(arena: std.mem.Allocator, chord: Chord) ![]const u8 {
    var line: std.Io.Writer.Allocating = .init(arena);
    try bindings.writeChord(&line.writer, chord);
    return line.writer.buffered();
}

/// `-p` (reusable lines) and `-P` (readable lines).
fn printBindings(ctx: Ctx, reusable: bool) void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bound = boundKeys(arena) catch return;

    if (reusable) {
        for (bindings.functionNames()) |name| {
            const function = bindings.functionByName(name).?;
            var any = false;
            for (bound) |entry| {
                if (entry.function != function) continue;
                any = true;
                const key = chordText(arena, entry.chord) catch return;
                ctx.outFmt("\"{s}\": {s}\n", .{ key, name });
            }
            if (!any) ctx.outFmt("# {s} (not bound)\n", .{name});
        }
        return;
    }
    for (bindings.functionNames()) |name| {
        const function = bindings.functionByName(name).?;
        var line: std.ArrayList(u8) = .empty;
        var count: usize = 0;
        for (bound) |entry| {
            if (entry.function != function) continue;
            const key = chordText(arena, entry.chord) catch return;
            line.print(arena, "{s}\"{s}\"", .{ if (count == 0) "" else ", ", key }) catch return;
            count += 1;
        }
        if (count == 0) {
            ctx.outFmt("{s} is not bound to any keys\n", .{name});
        } else {
            ctx.outFmt("{s} can be found on {s}.\n", .{ name, line.items });
        }
    }
}

/// `-X`: the `-x` bindings, reusable.
fn printCommands(ctx: Ctx) void {
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (bindings.list()) |binding| {
        if (binding.target != .command) continue;
        const key = chordText(arena, binding.chord) catch return;
        ctx.outFmt("\"{s}\": \"{s}\"\n", .{ key, binding.target.command });
    }
}

/// `-q function`: where it can be invoked. False when no key runs it.
fn query(ctx: Ctx, name: []const u8) bool {
    const function = bindings.functionByName(name) orelse {
        ctx.errFmt("wsh: bind: `{s}': unknown function name\n", .{name});
        return false;
    };
    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const bound = boundKeys(arena) catch return false;
    var line: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (bound) |entry| {
        if (entry.function != function) continue;
        const key = chordText(arena, entry.chord) catch return false;
        line.print(arena, "{s}\"{s}\"", .{ if (count == 0) "" else ", ", key }) catch return false;
        count += 1;
    }
    if (count == 0) {
        ctx.outFmt("{s} is not bound to any keys.\n", .{name});
        return false;
    }
    ctx.outFmt("{s} can be invoked via {s}.\n", .{ name, line.items });
    return true;
}

/// `-v` (reusable) and `-V` (readable): the readline variables wsh has.
fn printVariables(ctx: Ctx, reusable: bool) void {
    const mode: []const u8 = if (ctx.sh.options.vi) "vi" else "emacs";
    if (reusable) {
        ctx.outFmt("set editing-mode {s}\n", .{mode});
    } else {
        ctx.outFmt("editing-mode is set to `{s}'\n", .{mode});
    }
}
