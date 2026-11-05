//! Warnings for common Bash mistakes, printed by `wsh --check`.
//!
//! The checks read the raw word text. A word keeps its quotes, so `"$f"`
//! never looks like the bare `$f` that word splitting and globbing change.

const std = @import("std");
const ast = @import("ast.zig");
const parser_mod = @import("parser.zig");

pub const Kind = enum {
    /// An unquoted `$var` argument of a command that changes files.
    unquoted_path,
    /// An unquoted `$var` operand of `[ ]` or `test`.
    unquoted_test,
    /// `for NAME in $(ls ...)`.
    for_over_ls,
    /// A `cd` whose status nothing tests.
    unchecked_cd,
};

pub const Warning = struct {
    line: u32,
    kind: Kind,
    /// The variable name, borrowed from the AST.
    name: []const u8 = "",
    /// The command name of `unquoted_path`, borrowed from the AST.
    command: []const u8 = "",

    /// The warning text. The caller owns the result.
    pub fn text(self: Warning, allocator: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return switch (self.kind) {
            .unquoted_path => std.fmt.allocPrint(allocator, "unquoted ${s} in a {s} argument can split or glob; quote it", .{ self.name, self.command }),
            .unquoted_test => std.fmt.allocPrint(allocator, "unquoted ${s} in [ ]; quote it or use [[ ]]", .{self.name}),
            .for_over_ls => allocator.dupe(u8, "for loop over $(ls) breaks on spaces; use a glob"),
            .unchecked_cd => allocator.dupe(u8, "cd without a check; use cd DIR || exit"),
        };
    }
};

/// Commands where a split or globbed argument can hit the wrong files.
const path_commands = [_][]const u8{ "rm", "mv", "cp", "rmdir", "chmod", "chown" };

/// Appends a warning for each common Bash mistake in `stmts` to `out`, in
/// source order. The warnings borrow from the AST, so they are valid only
/// while the AST is.
pub fn check(gpa: std.mem.Allocator, stmts: []const ast.Stmt, out: *std.ArrayList(Warning)) error{OutOfMemory}!void {
    const linter = Linter{ .gpa = gpa, .out = out };
    try linter.walkStmts(stmts, false);
}

const Linter = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(Warning),

    fn add(self: Linter, warning: Warning) error{OutOfMemory}!void {
        try self.out.append(self.gpa, warning);
    }

    /// `tested` is true where a status test covers the statements: in an
    /// `if`, `while` or `until` condition, or in a `&&`/`||` chain.
    fn walkStmts(self: Linter, list: []const ast.Stmt, tested: bool) error{OutOfMemory}!void {
        for (list) |item| try self.walkStmt(item, tested);
    }

    fn walkStmt(self: Linter, item: ast.Stmt, tested: bool) error{OutOfMemory}!void {
        switch (item) {
            .pipeline => |p| try self.walkPipeline(p, tested),
            .fn_decl => |decl| try self.walkStmts(decl.body.stmts, false),
            else => {},
        }
    }

    fn walkPipeline(self: Linter, p: ast.Pipeline, tested: bool) error{OutOfMemory}!void {
        const chained = tested or p.links.len != 0;
        for (p.commands) |cmd| try self.walkCommand(cmd, p.line, chained);
        for (p.links) |link| try self.walkPipeline(link.pipeline, true);
    }

    fn walkCommand(self: Linter, cmd: ast.Command, line: u32, tested: bool) error{OutOfMemory}!void {
        if (cmd.subshell) |body| try self.walkStmts(body, tested);
        if (cmd.group) |body| try self.walkStmts(body, tested);
        if (cmd.compound) |c| try self.walkCompound(c.kind, line, tested);
        if (cmd.words.len == 0) return;
        const name = cmd.words[0];
        if (isOneOf(name, &path_commands)) {
            for (cmd.words[1..]) |word| {
                if (bareVariable(word)) |variable| try self.add(.{ .line = line, .kind = .unquoted_path, .name = variable, .command = name });
            }
        } else if (std.mem.eql(u8, name, "[") or std.mem.eql(u8, name, "test")) {
            for (cmd.words[1..]) |word| {
                if (bareVariable(word)) |variable| try self.add(.{ .line = line, .kind = .unquoted_test, .name = variable });
            }
        } else if (std.mem.eql(u8, name, "cd") and !tested) {
            try self.add(.{ .line = line, .kind = .unchecked_cd });
        }
    }

    fn walkCompound(self: Linter, kind: ast.Compound.Kind, line: u32, tested: bool) error{OutOfMemory}!void {
        switch (kind) {
            .if_ => |branch| {
                if (branch.cond.list) |list| try self.walkStmts(list, true);
                try self.walkStmts(branch.then.stmts, tested);
                if (branch.else_) |other| try self.walkStmts(other.stmts, tested);
            },
            .for_ => |loop| {
                for (loop.items) |word| {
                    if (isLsSubstitution(word)) {
                        try self.add(.{ .line = line, .kind = .for_over_ls });
                        break;
                    }
                }
                try self.walkStmts(loop.body.stmts, tested);
            },
            .select_ => |loop| try self.walkStmts(loop.body.stmts, tested),
            .while_ => |loop| {
                if (loop.cond.list) |list| try self.walkStmts(list, true);
                try self.walkStmts(loop.body.stmts, tested);
            },
            .case_ => |c| for (c.items) |entry| {
                try self.walkStmts(entry.body, tested);
            },
            .statement => |inner| try self.walkStmt(inner, tested),
            .arith_for => |loop| try self.walkStmts(loop.body.stmts, tested),
            .cond, .arith => {},
        }
    }
};

fn isOneOf(word: []const u8, options: []const []const u8) bool {
    for (options) |option| {
        if (std.mem.eql(u8, word, option)) return true;
    }
    return false;
}

/// The name in a word that is only `$name` or `${name}`, with no quotes.
fn bareVariable(word: []const u8) ?[]const u8 {
    if (word.len < 2 or word[0] != '$') return null;
    const name = if (word[1] == '{' and word[word.len - 1] == '}') word[2 .. word.len - 1] else word[1..];
    return if (parser_mod.isIdentifier(name)) name else null;
}

/// True for an unquoted word that starts with `$(ls` or `` `ls `` as a
/// whole command name.
fn isLsSubstitution(word: []const u8) bool {
    const rest = if (std.mem.startsWith(u8, word, "$(ls"))
        word[4..]
    else if (std.mem.startsWith(u8, word, "`ls"))
        word[3..]
    else
        return false;
    if (rest.len == 0) return false;
    return rest[0] == ' ' or rest[0] == '\t' or rest[0] == ')' or rest[0] == '`';
}

fn lintSource(arena: std.mem.Allocator, src: []const u8, out: *std.ArrayList(Warning)) !void {
    var p = parser_mod.Parser.init(arena, src);
    const prog = try p.parseProgram();
    try check(std.testing.allocator, prog.stmts, out);
}

test "unquoted variables in file commands and [ ] are reported" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    defer warnings.deinit(std.testing.allocator);
    const src =
        \\rm -rf $dir
        \\mv "$a" ${b} $1 "${c}"
        \\if [ $x = y ]; then echo; fi
        \\test -n "$y" && test -z $z
    ;
    try lintSource(arena_state.allocator(), src, &warnings);

    try std.testing.expectEqual(@as(usize, 4), warnings.items.len);
    try std.testing.expectEqual(Kind.unquoted_path, warnings.items[0].kind);
    try std.testing.expectEqualStrings("dir", warnings.items[0].name);
    try std.testing.expectEqual(@as(u32, 1), warnings.items[0].line);
    try std.testing.expectEqualStrings("b", warnings.items[1].name);
    try std.testing.expectEqualStrings("mv", warnings.items[1].command);
    try std.testing.expectEqual(Kind.unquoted_test, warnings.items[2].kind);
    try std.testing.expectEqualStrings("x", warnings.items[2].name);
    try std.testing.expectEqual(@as(u32, 3), warnings.items[2].line);
    try std.testing.expectEqualStrings("z", warnings.items[3].name);
    try std.testing.expectEqual(@as(u32, 4), warnings.items[3].line);

    const first = try warnings.items[0].text(std.testing.allocator);
    defer std.testing.allocator.free(first);
    try std.testing.expectEqualStrings("unquoted $dir in a rm argument can split or glob; quote it", first);
    const third = try warnings.items[2].text(std.testing.allocator);
    defer std.testing.allocator.free(third);
    try std.testing.expectEqualStrings("unquoted $x in [ ]; quote it or use [[ ]]", third);
}

test "unchecked cd and for over ls are reported in nested blocks" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    defer warnings.deinit(std.testing.allocator);
    const src =
        \\cd /tmp
        \\cd /tmp || exit 1
        \\if cd /tmp; then :; fi
        \\f() { cd "$1"; }
        \\(cd sub; make)
        \\for f in $(ls *.txt); do echo "$f"; done
        \\for f in "$(ls)" *.txt; do :; done
        \\case x in x) for g in `ls`; do :; done;; esac
    ;
    try lintSource(arena_state.allocator(), src, &warnings);

    try std.testing.expectEqual(@as(usize, 5), warnings.items.len);
    const lines = [_]u32{ 1, 4, 5, 6, 8 };
    const kinds = [_]Kind{ .unchecked_cd, .unchecked_cd, .unchecked_cd, .for_over_ls, .for_over_ls };
    for (warnings.items, lines, kinds) |warning, line, kind| {
        try std.testing.expectEqual(line, warning.line);
        try std.testing.expectEqual(kind, warning.kind);
    }
}

test "quoted words and tested commands give no warning" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var warnings: std.ArrayList(Warning) = .empty;
    defer warnings.deinit(std.testing.allocator);
    const src =
        \\rm -rf "$dir" "${dir}/x" '$dir' $dir/x
        \\[ "$x" = y ] && echo same
        \\[[ $x = y ]]
        \\for f in *.txt "$(ls)" $(lsof); do :; done
        \\cd /tmp && pwd
        \\while cd /tmp; do break; done
        \\echo $x
    ;
    try lintSource(arena_state.allocator(), src, &warnings);
    try std.testing.expectEqual(@as(usize, 0), warnings.items.len);
}
