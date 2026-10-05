//! Command-prefix assignments: `NAME=value cmd` applies the assignments to that
//! command's environment only, and `NAME=value` alone keeps them in the shell.

const std = @import("std");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const shellmod = @import("../shell.zig");

const Shell = shellmod.Shell;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ ExecutionFailed, ReadonlyVariable };

const Saved = struct {
    name: []const u8,
    /// The environment value the assignment shadowed, or null when there was
    /// none.
    value: ?[]const u8,
    assigned: []const u8,
};

pub const State = struct {
    sh: *Shell,
    saved: []const Saved,

    pub fn apply(self: State) !void {
        for (self.saved) |entry| try self.sh.setEnv(entry.name, entry.assigned);
    }

    /// Puts the shadowed environment back. Call after the command has been
    /// launched, so children still inherit the temporary values.
    pub fn restore(self: State) void {
        var index = self.saved.len;
        while (index > 0) {
            index -= 1;
            const entry = self.saved[index];
            if (entry.value) |value| {
                self.sh.setEnv(entry.name, value) catch {};
            } else {
                _ = self.sh.unsetEnv(entry.name);
            }
        }
    }
};

/// Applies `cmd`'s prefix assignments to the shell environment. The caller
/// restores them once the command has started.
pub fn enter(sh: *Shell, arena: std.mem.Allocator, cmd: ast.Command) Error!State {
    var saved: std.ArrayList(Saved) = .empty;
    // A failure part-way through must not leave half the assignments applied.
    errdefer {
        var index = saved.items.len;
        while (index > 0) {
            index -= 1;
            const entry = saved.items[index];
            if (entry.value) |value| {
                sh.setEnv(entry.name, value) catch {};
            } else {
                _ = sh.unsetEnv(entry.name);
            }
        }
    }
    for (cmd.assigns) |assignment| {
        if (sh.isReadonly(assignment.name)) return error.ReadonlyVariable;
        const previous = if (sh.getEnv(assignment.name)) |old| try arena.dupe(u8, old) else null;
        const assigned = try expand_mod.expandLiteral(sh, arena, assignment.value);
        try saved.append(arena, .{ .name = assignment.name, .value = previous, .assigned = assigned });
        try sh.setEnv(assignment.name, assigned);
    }
    return .{ .sh = sh, .saved = saved.items };
}

/// `NAME=value` with no command word: the assignment outlives the line. It
/// sets the shell variable, and reaches the environment only when NAME is
/// already exported or `set -a` is on.
pub fn persist(sh: *Shell, arena: std.mem.Allocator, assigns: []const ast.PrefixAssign) Error!void {
    for (assigns) |assignment| {
        const text = try expand_mod.expandLiteral(sh, arena, assignment.value);
        const exported = sh.options.allexport or sh.getEnv(assignment.name) != null;
        try sh.assignVar(assignment.name, .{ .string = text });
        if (exported) try sh.assignEnv(assignment.name, text);
    }
}

test "temporary assignments shadow the environment and are restored" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setEnv("KEEP", "old");
    var assigns = [_]ast.PrefixAssign{
        .{ .name = "KEEP", .value = "new" },
        .{ .name = "FRESH", .value = "1" },
    };
    const cmd = ast.Command{
        .words = &.{},
        .redirects = &.{},
        .assigns = &assigns,
    };
    const scope = try enter(&sh, arena, cmd);
    try std.testing.expectEqualStrings("new", sh.getEnv("KEEP").?);
    try std.testing.expectEqualStrings("1", sh.getEnv("FRESH").?);
    scope.restore();
    try std.testing.expectEqualStrings("old", sh.getEnv("KEEP").?);
    try std.testing.expect(sh.getEnv("FRESH") == null);
}

test "persistent assignments become a shell variable" {
    var sh = try Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try persist(&sh, arena, &.{.{ .name = "ONLY", .value = "yes" }});
    try std.testing.expectEqualStrings("yes", sh.getVar("ONLY").?.string);
    try std.testing.expect(sh.getEnv("ONLY") == null);

    // An exported name keeps its environment entry in step.
    try sh.setEnv("SHARED", "old");
    try persist(&sh, arena, &.{.{ .name = "SHARED", .value = "new" }});
    try std.testing.expectEqualStrings("new", sh.getEnv("SHARED").?);

    sh.options.allexport = true;
    try persist(&sh, arena, &.{.{ .name = "AUTO", .value = "1" }});
    try std.testing.expectEqualStrings("1", sh.getEnv("AUTO").?);
}
