const std = @import("std");
const builtins = @import("../builtins.zig");
const command_suggest = @import("../command_suggest.zig");
const expand_mod = @import("../expand.zig");
const fs = @import("../fs.zig");
const lexer = @import("../lexer.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;
const RunSource = *const fn (*Shell, []const u8) u8;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ CommandNotFound, ExecutionFailed };

pub const Runtime = struct {
    run_source: RunSource,
    run_function: *const fn (*Shell, []const u8, []const u8, []const []const u8) u8,
};

pub fn isInternal(sh: *Shell, name: []const u8) bool {
    return isExecBuiltin(name) or builtins.isBuiltin(name) or sh.getFunc(name) != null;
}

pub fn resolveAliases(sh: *Shell, arena: std.mem.Allocator, words: []const []const u8) Error![]const []const u8 {
    var current = words;
    var depth: usize = 0;
    while (depth < 16) : (depth += 1) {
        if (current.len == 0) break;
        const body = sh.getAlias(current[0]) orelse break;
        const body_words = try wordsFromSource(arena, body);
        if (body_words.len == 0) break;
        var combined: std.ArrayList([]const u8) = .empty;
        try combined.appendSlice(arena, body_words);
        try combined.appendSlice(arena, current[1..]);
        current = try combined.toOwnedSlice(arena);
    }
    return current;
}

pub fn dispatch(sh: *Shell, argv: []const []const u8, runtime: Runtime) u8 {
    if (argv.len == 0) return 0;
    const name = argv[0];

    if (std.mem.eql(u8, name, "source") or std.mem.eql(u8, name, ".")) return builtinSource(sh, argv, runtime.run_source);
    if (std.mem.eql(u8, name, "eval")) return builtinEval(sh, argv, runtime.run_source);

    if (builtins.lookup(name)) |builtin| {
        const ctx = builtins.Ctx{
            .sh = sh,
            .argv = argv,
            .stdin = sh.default_in,
            .stdout = sh.default_out,
            .stderr = sh.default_err,
        };
        return builtin.run(ctx);
    }

    if (sh.getFunc(name)) |source| return runtime.run_function(sh, name, source, argv);

    reportCommandNotFound(sh, sh.scratch(), name);
    return 127;
}

pub fn commandNotFoundMessage(sh: *Shell, arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    var message: std.ArrayList(u8) = .empty;
    const initial = try std.fmt.allocPrint(arena, "wsh: command not found: {s}\n", .{name});
    try message.appendSlice(arena, initial);

    const matches = if (sh.command_cache.lookup(name)) |cached| cached.matches else blk: {
        const found = command_suggest.find(sh, arena, name) catch return try message.toOwnedSlice(arena);
        if (sh.interactive) sh.command_cache.remember(sh.gpa, name, found) catch {
            try message.appendSlice(arena, "wsh: unable to cache command suggestions\n");
        };
        break :blk found;
    };
    if (matches.len > 0) {
        try message.appendSlice(arena, "wsh: did you mean: ");
        for (matches, 0..) |match, index| {
            if (index != 0) try message.appendSlice(arena, ", ");
            try message.appendSlice(arena, match.name);
        }
        try message.appendSlice(arena, "?\n");
    }
    return try message.toOwnedSlice(arena);
}

fn isExecBuiltin(name: []const u8) bool {
    return std.mem.eql(u8, name, "source") or
        std.mem.eql(u8, name, "eval") or
        std.mem.eql(u8, name, ".");
}

fn builtinSource(sh: *Shell, argv: []const []const u8, run_source: RunSource) u8 {
    if (argv.len < 2) {
        sys.writeStr(sh.default_err, "wsh: source: expected a file name\n");
        return 1;
    }
    const arena = sh.scratch();
    const path = sh.tildeExpand(arena, argv[1]) catch argv[1];
    const z = arena.dupeZ(u8, path) catch return 1;
    const data = (fs.readFileAlloc(arena, z, 16 << 20) catch null) orelse {
        var buf: [512]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "wsh: source: {s}: cannot read file\n", .{path}) catch return 1;
        sys.writeStr(sh.default_err, msg);
        return 1;
    };
    return run_source(sh, data);
}

fn builtinEval(sh: *Shell, argv: []const []const u8, run_source: RunSource) u8 {
    if (argv.len < 2) return 0;
    const arena = sh.scratch();
    var joined: std.ArrayList(u8) = .empty;
    for (argv[1..], 0..) |part, index| {
        if (index != 0) joined.append(arena, ' ') catch return 1;
        joined.appendSlice(arena, part) catch return 1;
    }
    return run_source(sh, joined.items);
}

fn reportCommandNotFound(sh: *Shell, arena: std.mem.Allocator, name: []const u8) void {
    const message = commandNotFoundMessage(sh, arena, name) catch return;
    sys.writeStr(sh.default_err, message);
}

fn wordsFromSource(arena: std.mem.Allocator, source: []const u8) Error![]const []const u8 {
    var lexer_instance = lexer.Lexer.init(source);
    var words: std.ArrayList([]const u8) = .empty;
    while (true) {
        const token = lexer_instance.next();
        switch (token.tag) {
            .eof, .newline => break,
            .word => try words.append(arena, token.text),
            else => break,
        }
    }
    return words.toOwnedSlice(arena);
}
