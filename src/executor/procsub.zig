//! Process substitution: `<(list)` and `>(list)` run `list` in a child joined
//! to the shell by a pipe, and the word becomes `/dev/fd/N`, the shell's end.
//!
//! The shell's end is inherited by the command (it is not close-on-exec) and
//! closed once the command is done with it; see `mark`/`release`. Children are
//! reaped without blocking, because one may legitimately outlive the command
//! (`exec 3< <(producer)`), exactly as in bash.

const std = @import("std");
const linux = std.os.linux;
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");

const Shell = shellmod.Shell;

pub const RunSource = *const fn (*Shell, []const u8) u8;

/// Runs the substituted list in the child. Installed by `exec.install`.
pub var run_source: ?RunSource = null;

/// `<(list)`: the command reads what `list` writes. `>(list)`: the reverse.
pub const Direction = enum { read, write };

const Pending = struct { fd: i32, pid: i32 };

/// The lists are tiny and live as long as the process, so they use the page
/// allocator rather than any one shell's.
const list_allocator = std.heap.page_allocator;

/// Substitutions whose descriptor the shell still holds, oldest first.
var pending: std.ArrayList(Pending) = .empty;
/// Children whose descriptor is closed but which have not been reaped yet.
var unreaped: std.ArrayList(i32) = .empty;

/// Substitutions are numbered from here, below the redirection temporaries.
const fd_floor = 63;

pub const Mark = usize;

/// Remembers how many substitutions are open, so `release` closes only those
/// the command being run created.
pub fn mark() Mark {
    return pending.items.len;
}

/// Closes the shell's end of every substitution opened since `m`, then reaps
/// whichever substitution children have finished.
pub fn release(m: Mark) void {
    while (pending.items.len > m) {
        const entry = pending.pop().?;
        _ = linux.close(entry.fd);
        unreaped.append(list_allocator, entry.pid) catch {};
    }
    var index: usize = 0;
    while (index < unreaped.items.len) {
        var status: u32 = 0;
        const rc = linux.waitpid(unreaped.items[index], &status, linux.W.NOHANG);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        // Still running: try again after a later command.
        if (err == .SUCCESS and rc == 0) {
            index += 1;
            continue;
        }
        // Reaped now, or already collected by `wait`.
        _ = unreaped.swapRemove(index);
    }
}

const Payload = struct {
    sh: *Shell,
    src: []const u8,
    run_source: RunSource,
    /// The pipe ends the child must not keep: its own original descriptor
    /// (already copied onto 0 or 1) and the shell's end.
    child_end: i32,
    shell_end: i32,
};

fn child(ctx_ptr: *anyopaque) noreturn {
    const payload: *Payload = @ptrCast(@alignCast(ctx_ptr));
    // A stray copy of any pipe end would keep the other side from seeing EOF
    // or SIGPIPE, so only the descriptor now on 0 or 1 survives.
    if (payload.child_end > 2) _ = linux.close(payload.child_end);
    _ = linux.close(payload.shell_end);
    for (pending.items) |entry| _ = linux.close(entry.fd);
    pending.items.len = 0;

    const sh = payload.sh;
    sh.default_in = 0;
    sh.default_out = 1;
    sh.default_err = 2;
    sh.job_control = false;
    sh.tty_fd = -1;
    sh.should_exit = false;
    linux.exit(payload.run_source(sh, payload.src));
}

pub const Error = error{ProcessSubstitutionFailed} || std.mem.Allocator.Error;

/// Starts `list` and returns `/dev/fd/N` for the shell's end of its pipe.
pub fn open(sh: *Shell, arena: std.mem.Allocator, list: []const u8, direction: Direction) Error![]const u8 {
    const runner = run_source orelse return error.ProcessSubstitutionFailed;
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.ProcessSubstitutionFailed;
    const near_end = if (direction == .read) fds[0] else fds[1];
    const child_end = if (direction == .read) fds[1] else fds[0];

    // The command inherits this copy, and it sits high so that the command's
    // own redirections never land on it.
    const shared_rc = linux.fcntl(near_end, linux.F.DUPFD, fd_floor);
    _ = linux.close(near_end);
    if (linux.errno(shared_rc) != .SUCCESS) {
        _ = linux.close(child_end);
        return error.ProcessSubstitutionFailed;
    }
    const shared: i32 = @intCast(shared_rc);
    errdefer _ = linux.close(shared);

    const payload = try arena.create(Payload);
    payload.* = .{ .sh = sh, .src = list, .run_source = runner, .child_end = child_end, .shell_end = shared };
    const stdio: proc.Stdio = switch (direction) {
        .read => .{ .in = sh.default_in, .out = child_end, .err = sh.default_err },
        .write => .{ .in = child_end, .out = sh.default_out, .err = sh.default_err },
    };
    const launched = proc.launch(arena, &.{.{ .child_fn = child, .child_ctx = payload, .stdio = stdio }}, .{ .new_group = false }) catch {
        _ = linux.close(child_end);
        return error.ProcessSubstitutionFailed;
    };
    _ = linux.close(child_end);
    pending.append(list_allocator, .{ .fd = shared, .pid = launched.pids[0] }) catch |err| {
        unreaped.append(list_allocator, launched.pids[0]) catch {};
        return err;
    };
    return std.fmt.allocPrint(arena, "/dev/fd/{d}", .{shared});
}

const testing = std.testing;

test "a read substitution carries the list's output and is released" {
    const exec = @import("../exec.zig");
    const fs = @import("../fs.zig");
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    exec.install(&sh);
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const before = mark();
    const path = try open(&sh, arena, "echo from-list", .read);
    try testing.expect(std.mem.startsWith(u8, path, "/dev/fd/"));
    const data = (try fs.readFileAlloc(arena, try arena.dupeZ(u8, path), 64)) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("from-list\n", data);
    const fd = pending.items[pending.items.len - 1].fd;
    release(before);
    try testing.expectEqual(before, pending.items.len);
    try testing.expect(linux.errno(linux.fcntl(fd, linux.F.GETFD, 0)) != .SUCCESS);
}
