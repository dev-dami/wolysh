const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const builtins = @import("../builtins.zig");
const command_suggest = @import("../command_suggest.zig");
const expand_mod = @import("../expand.zig");
const fs = @import("../fs.zig");
const lexer = @import("../lexer.zig");
const parser_mod = @import("../parser.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");
const strict = @import("../strict.zig");

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

/// A command's words after alias expansion.
pub const Resolved = struct {
    /// The words to run; when `body` is set, only the arguments that follow
    /// the alias.
    words: []const []const u8,
    /// Body of an alias that needs the parser (a pipeline, list, redirection,
    /// assignment or keyword). It runs as source text with `words` appended.
    body: ?[]const u8 = null,
    /// Every alias expanded on the way; none of them expands again while the
    /// body runs, so `alias ls='ls --color | less'` does not recurse.
    names: []const []const u8 = &.{},
};

/// Alias names whose bodies are running. Module state like the loop counters
/// in `exec.zig`; forked stages inherit it.
var suppressed: [max_suppressed][]const u8 = undefined;
var suppressed_len: usize = 0;
const max_suppressed = 64;

fn isSuppressed(name: []const u8) bool {
    for (suppressed[0..suppressed_len]) |active| {
        if (std.mem.eql(u8, active, name)) return true;
    }
    return false;
}

/// Marks `names` as expanding until `restoreAliases(mark)`. The names must
/// outlive that call.
pub fn suppressAliases(names: []const []const u8) error{AliasNestingTooDeep}!usize {
    const mark = suppressed_len;
    if (names.len > max_suppressed - suppressed_len) return error.AliasNestingTooDeep;
    for (names) |name| {
        suppressed[suppressed_len] = name;
        suppressed_len += 1;
    }
    return mark;
}

pub fn restoreAliases(mark: usize) void {
    suppressed_len = mark;
}

pub fn resolveAliases(sh: *Shell, arena: std.mem.Allocator, words: []const []const u8) Error!Resolved {
    var current = words;
    var names: std.ArrayList([]const u8) = .empty;
    while (current.len > 0) {
        const name = current[0];
        if (isSuppressed(name) or contains(names.items, name)) break;
        const body = sh.getAlias(name) orelse break;
        // Copies: running the body may `unalias` and free the originals.
        try names.append(arena, try arena.dupe(u8, name));
        const body_words = try plainWords(arena, body) orelse {
            return .{ .words = current[1..], .body = try arena.dupe(u8, body), .names = names.items };
        };
        var combined: std.ArrayList([]const u8) = .empty;
        try combined.appendSlice(arena, body_words);
        try combined.appendSlice(arena, current[1..]);
        current = try combined.toOwnedSlice(arena);
    }
    return .{ .words = current, .names = names.items };
}

fn contains(list: []const []const u8, name: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, name)) return true;
    }
    return false;
}

/// The words of an alias body that is one plain command, or null when the
/// body needs the parser to run (or does not parse).
fn plainWords(arena: std.mem.Allocator, body: []const u8) Error!?[]const []const u8 {
    // The parser drops a trailing `;`, but `alias x='a;'` runs `x`'s
    // arguments as a second command, so any operator token disqualifies.
    var lex = lexer.Lexer.init(body);
    while (true) {
        const token = lex.next();
        if (token.tag == .eof) break;
        if (token.tag != .word) return null;
    }
    var parser = parser_mod.Parser.init(arena, body);
    const program = parser.parseProgram() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (program.stmts.len == 0) return &.{};
    if (program.stmts.len != 1) return null;
    const chain = switch (program.stmts[0]) {
        .pipeline => |pipeline| pipeline,
        else => return null,
    };
    if (chain.commands.len != 1 or chain.links.len != 0 or chain.background or chain.negate) return null;
    const cmd = chain.commands[0];
    if (cmd.redirects.len != 0 or cmd.assigns.len != 0 or cmd.subshell != null or cmd.group != null) return null;
    return cmd.words;
}

/// Parses an alias body followed by the expanded, re-quoted arguments into
/// the statements that replace the command. Null once a syntax error has
/// been reported.
pub fn aliasStatements(sh: *Shell, arena: std.mem.Allocator, resolved: Resolved) Error!?[]ast.Stmt {
    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena, resolved.body.?);
    var fields: std.ArrayList([]const u8) = .empty;
    for (resolved.words) |word| try expand_mod.expandWord(sh, arena, word, &fields);
    for (fields.items) |field| {
        try text.append(arena, ' ');
        try appendQuoted(arena, &text, field);
    }
    var parser = parser_mod.Parser.init(arena, text.items);
    const program = parser.parseProgram() catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            reportSyntaxError(sh, &parser);
            return null;
        },
    };
    return program.stmts;
}

/// Single-quotes `text` so the parser reads it back as one literal word.
fn appendQuoted(arena: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(arena, '\'');
    for (text) |c| {
        if (c == '\'') {
            try out.appendSlice(arena, "'\\''");
        } else {
            try out.append(arena, c);
        }
    }
    try out.append(arena, '\'');
}

fn reportSyntaxError(sh: *Shell, parser: *const parser_mod.Parser) void {
    var buf: [512]u8 = undefined;
    const msg = parser.message(&buf);
    var line: [640]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "wsh: {s}\n", .{msg}) catch msg;
    sys.writeStr(sh.default_err, text);
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
            .run_source = runtime.run_source,
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
        sys.writeStr(sh.default_err, "wsh: source: filename argument required\n");
        return 2;
    }
    if (sh.call_depth >= Shell.max_call_depth) {
        sys.writeStr(sh.default_err, "wsh: source: maximum nesting depth reached\n");
        return 1;
    }
    const arena = sh.scratch();
    const name = argv[1];
    const path = sourcePath(sh, arena, name) catch return 1;
    const z = arena.dupeZ(u8, path) catch return 1;
    if (fs.isDir(z)) return sourceError(sh, name, "is a directory");
    const readable = linux.errno(linux.access(z.ptr, linux.R_OK));
    if (readable != .SUCCESS) return sourceError(sh, name, proc.errorText(readable));
    const data = (fs.readFileAlloc(arena, z, 16 << 20) catch null) orelse return sourceError(sh, name, "cannot read file");

    // Arguments become the file's positional parameters for the duration of
    // the run; without them the file shares the caller's, so its `set --`
    // reaches the caller. `$0` is left alone.
    const saved_positional: ?Shell.SavedPositional = if (argv.len > 2) sh.pushPositional(argv[2..]) else null;
    defer if (saved_positional) |saved| sh.popPositional(saved);

    // `return` ends the sourced file only, with its status.
    const saved_return = sh.return_pending;
    const saved_code = sh.return_code;
    sh.return_pending = false;
    sh.call_depth += 1;
    defer {
        sh.call_depth -= 1;
        sh.return_pending = saved_return;
        sh.return_code = saved_code;
    }
    strict.traceDeeper();
    const status = run_source(sh, data);
    strict.traceShallower();
    strict.runReturnTrap(sh);
    return if (sh.return_pending) sh.return_code else status;
}

/// bash's lookup: a name with a `/` is used as is; otherwise the first
/// readable file of that name on `PATH`, then the current directory.
fn sourcePath(sh: *Shell, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '/') != null) return name;
    var it = std.mem.splitScalar(u8, sh.pathEnv(), ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir, name });
        const z = try arena.dupeZ(u8, full);
        if (fs.kind(z) == .file and linux.errno(linux.access(z.ptr, linux.R_OK)) == .SUCCESS) return full;
    }
    return name;
}

fn sourceError(sh: *Shell, name: []const u8, reason: []const u8) u8 {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "wsh: source: {s}: {s}\n", .{ name, reason }) catch "wsh: source: cannot read file\n";
    sys.writeStr(sh.default_err, msg);
    return 1;
}

fn builtinEval(sh: *Shell, argv: []const []const u8, run_source: RunSource) u8 {
    if (argv.len < 2) return 0;
    const arena = sh.scratch();
    var joined: std.ArrayList(u8) = .empty;
    for (argv[1..], 0..) |part, index| {
        if (index != 0) joined.append(arena, ' ') catch return 1;
        joined.appendSlice(arena, part) catch return 1;
    }
    strict.traceDeeper();
    defer strict.traceShallower();
    return run_source(sh, joined.items);
}

fn reportCommandNotFound(sh: *Shell, arena: std.mem.Allocator, name: []const u8) void {
    const message = commandNotFoundMessage(sh, arena, name) catch return;
    sys.writeStr(sh.default_err, message);
}

test "alias bodies are plain words or need the parser" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const plain = (try plainWords(arena, "ls -la # listing")).?;
    try std.testing.expectEqual(@as(usize, 2), plain.len);
    try std.testing.expectEqualStrings("-la", plain[1]);
    try std.testing.expectEqual(@as(usize, 0), (try plainWords(arena, "")).?.len);
    for ([_][]const u8{ "ps aux | grep", "a && b", "a; b", "echo a;", "echo hi > out", "FOO=1 env", "let x = 1", "sleep 1 &", "! true", "{ ls; }" }) |body| {
        try std.testing.expect(try plainWords(arena, body) == null);
    }
}

test "operator aliases keep their body and stop at repeated names" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setAlias("ls", "ls --color");
    const looped = try resolveAliases(&sh, arena, &.{ "ls", "dir" });
    try std.testing.expectEqual(@as(usize, 3), looped.words.len);
    try std.testing.expect(looped.body == null);

    try sh.setAlias("psg", "ps aux | grep");
    try sh.setAlias("p", "psg -i");
    const piped = try resolveAliases(&sh, arena, &.{ "p", "wsh" });
    try std.testing.expectEqualStrings("ps aux | grep", piped.body.?);
    try std.testing.expectEqual(@as(usize, 2), piped.words.len);
    try std.testing.expectEqualStrings("-i", piped.words[0]);
    try std.testing.expectEqual(@as(usize, 2), piped.names.len);

    const mark = try suppressAliases(piped.names);
    defer restoreAliases(mark);
    const inner = try resolveAliases(&sh, arena, &.{"psg"});
    try std.testing.expect(inner.body == null);
    try std.testing.expectEqualStrings("psg", inner.words[0]);
}

test "arguments are re-quoted literally" {
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try appendQuoted(arena, &out, "it's $HOME");
    try std.testing.expectEqualStrings("'it'\\''s $HOME'", out.items);
}
