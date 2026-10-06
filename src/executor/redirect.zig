const std = @import("std");
const linux = std.os.linux;
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ExecutionFailed};

/// Temporary descriptors live at or above this number, clear of the ones
/// scripts name, so the child can put each redirection in place without
/// overwriting the source of a later one.
const temp_floor = 64;
/// `{name}>file` descriptors are allocated from here, as in bash.
const named_floor = 10;

pub const Fds = struct {
    in: i32,
    out: i32,
    err: i32,
};

/// A logical descriptor above 2 and what backs it while an in-process command
/// runs; `actual` is -1 when the command closes it.
pub const High = struct {
    fd: i32,
    actual: i32,
};

pub const Prepared = struct {
    fds: Fds,
    redirects: []const proc.Redirection,
    high: []const High = &.{},

    /// Puts the descriptors above 2 in place for a builtin, function or group
    /// that runs in the shell itself. Standard descriptors travel through
    /// `Shell.default_*` instead. Call `restore` on the result afterwards.
    pub fn enter(self: Prepared, arena: std.mem.Allocator) Error!Saved {
        var saved: std.ArrayList(SavedFd) = .empty;
        errdefer (Saved{ .entries = saved.items }).restore();
        for (self.high) |entry| {
            var previous: i32 = -1;
            var cloexec = false;
            const flags = linux.fcntl(entry.fd, linux.F.GETFD, 0);
            if (linux.errno(flags) == .SUCCESS) {
                cloexec = flags & linux.FD_CLOEXEC != 0;
                previous = sys.duplicateAbove(entry.fd, temp_floor) orelse return error.ExecutionFailed;
            }
            try saved.append(arena, .{ .fd = entry.fd, .saved = previous, .cloexec = cloexec });
            if (entry.actual < 0) {
                _ = linux.close(entry.fd);
            } else if (linux.errno(linux.dup3(entry.actual, entry.fd, 0)) != .SUCCESS) {
                return error.ExecutionFailed;
            }
        }
        return .{ .entries = saved.items };
    }
};

const SavedFd = struct { fd: i32, saved: i32, cloexec: bool };

pub const Saved = struct {
    entries: []const SavedFd,

    pub fn restore(self: Saved) void {
        var index = self.entries.len;
        while (index > 0) {
            index -= 1;
            const entry = self.entries[index];
            if (entry.saved < 0) {
                _ = linux.close(entry.fd);
                continue;
            }
            const flags: u32 = if (entry.cloexec) @bitCast(linux.O{ .CLOEXEC = true }) else 0;
            _ = linux.dup3(entry.saved, entry.fd, flags);
            _ = linux.close(entry.saved);
        }
    }
};

/// Logical descriptor -> the descriptor that currently backs it, in the order
/// the command's redirections set them.
const Map = struct {
    entries: std.ArrayList(High) = .empty,

    fn set(self: *Map, arena: std.mem.Allocator, fd: i32, actual: i32) Error!void {
        for (self.entries.items) |*entry| {
            if (entry.fd == fd) {
                entry.actual = actual;
                return;
            }
        }
        try self.entries.append(arena, .{ .fd = fd, .actual = actual });
    }

    fn get(self: *const Map, fd: i32) ?i32 {
        for (self.entries.items) |entry| {
            if (entry.fd == fd) return entry.actual;
        }
        return null;
    }

    /// What `fd` names right now: an earlier redirection of this command, or
    /// a descriptor the shell keeps open for scripts.
    fn resolve(self: *const Map, fd: i32) ?i32 {
        if (self.get(fd)) |actual| return if (actual >= 0) actual else null;
        if (fd > 2 and isScriptFd(fd)) return fd;
        return null;
    }

    fn high(self: *const Map, arena: std.mem.Allocator) Error![]const High {
        var out: std.ArrayList(High) = .empty;
        for (self.entries.items) |entry| {
            if (entry.fd > 2) try out.append(arena, entry);
        }
        return out.toOwnedSlice(arena);
    }
};

/// True for an open descriptor a script may name. The shell's own descriptors
/// are close-on-exec; `exec 3>file`, `{fd}>file` and inherited ones are not.
fn isScriptFd(fd: i32) bool {
    const flags = linux.fcntl(fd, linux.F.GETFD, 0);
    if (linux.errno(flags) != .SUCCESS) return false;
    return flags & linux.FD_CLOEXEC == 0;
}

pub fn apply(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    opened: *std.ArrayList(i32),
) Error!Prepared {
    var map: Map = .{};
    try map.set(arena, 0, sh.default_in);
    try map.set(arena, 1, sh.default_out);
    try map.set(arena, 2, sh.default_err);
    if (cmd.redirects.len == 0) return .{ .fds = current(&map), .redirects = &.{} };

    const floor = tempFloor(cmd.redirects);
    var actions: std.ArrayList(proc.Redirection) = .empty;

    for (cmd.redirects) |redirect| {
        if (redirect.fd_var.len != 0) {
            try openNamed(sh, arena, redirect);
            continue;
        }
        const target_fd = redirect.targetFd();
        try checkTarget(sh, target_fd);

        if (redirect.kind.duplicates()) {
            try duplicate(sh, arena, redirect, target_fd, floor, &map, opened, &actions);
            continue;
        }

        const source = try openTarget(sh, arena, redirect, floor);
        try opened.append(arena, source);
        try bind(arena, &map, &actions, target_fd, source);
    }

    return .{ .fds = current(&map), .redirects = try actions.toOwnedSlice(arena), .high = try map.high(arena) };
}

/// Dups `source` onto `target_fd` in the child, then releases the temporary
/// descriptor immediately: later duplications name a descriptor by its
/// logical number, which the child has already put in place by then.
fn bind(arena: std.mem.Allocator, map: *Map, actions: *std.ArrayList(proc.Redirection), target_fd: i32, source: i32) Error!void {
    try map.set(arena, target_fd, source);
    try actions.append(arena, .{ .target = target_fd, .source = source });
    try actions.append(arena, .{ .target = source, .source = source, .close_source = true });
}

/// `N>&M` / `N<&M`: point descriptor N at whatever M currently names. `-`
/// closes N, `M-` moves M to N, and `>&file` is `&>file`.
fn duplicate(
    sh: *Shell,
    arena: std.mem.Allocator,
    redirect: ast.Redirect,
    target_fd: i32,
    floor: i32,
    map: *Map,
    opened: *std.ArrayList(i32),
    actions: *std.ArrayList(proc.Redirection),
) Error!void {
    const text = try expand_mod.expandLiteral(sh, arena, redirect.target);
    const spec = parseDupTarget(text) orelse {
        if (redirect.kind != .out_dup or target_fd != 1) return reportAmbiguous(sh, text);
        const source = try openPath(sh, arena, .out, text, floor);
        try opened.append(arena, source);
        try bind(arena, map, actions, 1, source);
        try map.set(arena, 2, source);
        try actions.append(arena, .{ .target = 2, .source = 1 });
        return;
    };

    switch (spec) {
        .close => try closeLogical(sh, arena, target_fd, floor, map, opened, actions),
        .fd, .move => |source_fd| {
            // A descriptor the shell never opened cannot be duplicated: `2>&9`
            // is an error rather than a silent no-op.
            const actual = map.resolve(source_fd) orelse return reportFd(sh, source_fd, "Bad file descriptor");
            // Later redirections of this command may repoint `source_fd`; the
            // copy keeps what it names now for in-process commands.
            const snapshot = sys.duplicateAbove(actual, @intCast(floor)) orelse return reportFd(sh, source_fd, "Bad file descriptor");
            try opened.append(arena, snapshot);
            try map.set(arena, target_fd, snapshot);
            // The child applies this after its own descriptors are wired
            // (pipeline pipes, earlier in this list), so it names the logical
            // descriptor rather than the concrete one the parent resolved.
            try actions.append(arena, .{ .target = target_fd, .source = source_fd });
            if (spec == .move and source_fd != target_fd) {
                try closeLogical(sh, arena, source_fd, floor, map, opened, actions);
            }
        },
    }
}

fn closeLogical(
    sh: *Shell,
    arena: std.mem.Allocator,
    fd: i32,
    floor: i32,
    map: *Map,
    opened: *std.ArrayList(i32),
    actions: *std.ArrayList(proc.Redirection),
) Error!void {
    if (fd > 2) {
        // Closing N in the child is `dup2(N, N)` followed by closing N.
        try map.set(arena, fd, -1);
        try actions.append(arena, .{ .target = fd, .source = fd, .close_source = true });
        return;
    }
    // The child cannot close 0/1/2 through `proc.Redirection`, so they get an
    // `O_PATH` descriptor instead: reading or writing it fails with EBADF,
    // just as a closed descriptor would.
    const rc = linux.openat(linux.AT.FDCWD, "/", .{ .PATH = true, .CLOEXEC = true }, 0);
    const err = linux.errno(rc);
    if (err != .SUCCESS) return reportFd(sh, fd, errnoText(err));
    const source = try moveAbove(sh, @intCast(rc), floor);
    try opened.append(arena, source);
    try bind(arena, map, actions, fd, source);
}

fn current(map: *const Map) Fds {
    return .{ .in = map.get(0).?, .out = map.get(1).?, .err = map.get(2).? };
}

/// Temporaries go above every descriptor the command names explicitly.
fn tempFloor(redirects: []const ast.Redirect) i32 {
    var floor: i32 = temp_floor;
    for (redirects) |redirect| {
        if (redirect.fd >= floor) floor = redirect.fd + 1;
    }
    return floor;
}

const DupTarget = union(enum) {
    close,
    fd: i32,
    /// `N>&M-`: duplicate M, then close it.
    move: i32,
};

fn parseDupTarget(text: []const u8) ?DupTarget {
    if (std.mem.eql(u8, text, "-")) return .close;
    if (text.len > 1 and text[text.len - 1] == '-') {
        return .{ .move = parseFd(text[0 .. text.len - 1]) orelse return null };
    }
    return .{ .fd = parseFd(text) orelse return null };
}

fn parseFd(text: []const u8) ?i32 {
    if (text.len == 0 or text.len > 9) return null;
    var value: i32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
    }
    return value;
}

/// A target descriptor must exist in the process's descriptor table.
fn checkTarget(sh: *Shell, fd: i32) Error!void {
    var limit: linux.rlimit = undefined;
    const too_big = fd >= 0 and linux.errno(linux.getrlimit(.NOFILE, &limit)) == .SUCCESS and
        @as(u64, @intCast(fd)) >= limit.cur;
    if (fd >= 0 and !too_big) return;
    return reportFd(sh, fd, "Bad file descriptor");
}

fn reportFd(sh: *Shell, fd: i32, reason: []const u8) Error {
    var buf: [128]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "wsh: {d}: {s}\n", .{ fd, reason }) catch "wsh: bad file descriptor\n";
    sys.writeStr(sh.default_err, message);
    return error.ExecutionFailed;
}

fn reportAmbiguous(sh: *Shell, text: []const u8) Error {
    reportPath(sh, text, "ambiguous redirect");
    return error.ExecutionFailed;
}

fn reportPath(sh: *Shell, path: []const u8, reason: []const u8) void {
    var buf: [640]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "wsh: {s}: {s}\n", .{ path, reason }) catch "wsh: cannot open file\n";
    sys.writeStr(sh.default_err, message);
}

/// The text bash prints for the errors a redirection can hit.
pub fn errnoText(err: linux.E) []const u8 {
    return switch (err) {
        .NOENT => "No such file or directory",
        .ACCES => "Permission denied",
        .ISDIR => "Is a directory",
        .NOTDIR => "Not a directory",
        .BADF => "Bad file descriptor",
        .EXIST => "File exists",
        .MFILE, .NFILE => "Too many open files",
        .ROFS => "Read-only file system",
        .NOSPC => "No space left on device",
        .LOOP => "Too many levels of symbolic links",
        .NAMETOOLONG => "File name too long",
        .PERM => "Operation not permitted",
        .TXTBSY => "Text file busy",
        .NXIO => "No such device or address",
        .NODEV => "No such device",
        else => "cannot open file",
    };
}

/// Opens the file, here-document or here-string a redirection names, as a
/// close-on-exec descriptor at or above `floor`.
fn openTarget(sh: *Shell, arena: std.mem.Allocator, redirect: ast.Redirect, floor: i32) Error!i32 {
    switch (redirect.kind) {
        .here_doc, .here_string => {
            const body = if (redirect.kind == .here_doc)
                try hereDocBody(sh, arena, redirect)
            else
                try std.fmt.allocPrint(arena, "{s}\n", .{try expand_mod.expandLiteral(sh, arena, redirect.target)});
            const fd = sys.createAnonymousFile(body) orelse {
                sys.writeStr(sh.default_err, "wsh: cannot prepare here-document\n");
                return error.ExecutionFailed;
            };
            return moveAbove(sh, fd, floor);
        },
        else => {
            const path = try expand_mod.expandLiteral(sh, arena, redirect.target);
            return openPath(sh, arena, redirect.kind, path, floor);
        },
    }
}

fn openPath(sh: *Shell, arena: std.mem.Allocator, kind: ast.RedirectKind, path: []const u8, floor: i32) Error!i32 {
    const z = try arena.dupeZ(u8, path);
    const base: linux.O = .{ .CLOEXEC = true };
    var flags = base;
    switch (kind) {
        .in, .in_dup => flags.ACCMODE = .RDONLY,
        .read_write => {
            flags.ACCMODE = .RDWR;
            flags.CREAT = true;
        },
        .out_append, .err_append => {
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.APPEND = true;
        },
        .out, .err_out, .out_dup => {
            if (sh.options.noclobber) return openNoClobber(sh, z, floor);
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.TRUNC = true;
        },
        else => {
            flags.ACCMODE = .WRONLY;
            flags.CREAT = true;
            flags.TRUNC = true;
        },
    }
    const rc = linux.openat(linux.AT.FDCWD, z.ptr, flags, 0o644);
    const err = linux.errno(rc);
    if (err != .SUCCESS) {
        reportPath(sh, path, errnoText(err));
        return error.ExecutionFailed;
    }
    return moveAbove(sh, @intCast(rc), floor);
}

/// `set -C`: `>` creates a new file but refuses to truncate an existing
/// regular one. Devices such as /dev/null stay writable.
fn openNoClobber(sh: *Shell, z: [:0]const u8, floor: i32) Error!i32 {
    const create: linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true };
    const rc = linux.openat(linux.AT.FDCWD, z.ptr, create, 0o644);
    var err = linux.errno(rc);
    if (err == .SUCCESS) return moveAbove(sh, @intCast(rc), floor);
    if (err == .EXIST) {
        var st: linux.Statx = undefined;
        if (linux.errno(linux.statx(linux.AT.FDCWD, z.ptr, 0, .{ .TYPE = true, .MODE = true }, &st)) == .SUCCESS and
            st.mode & linux.S.IFMT == linux.S.IFREG)
        {
            reportPath(sh, z, "cannot overwrite existing file");
            return error.ExecutionFailed;
        }
        const existing = linux.openat(linux.AT.FDCWD, z.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true }, 0);
        err = linux.errno(existing);
        if (err == .SUCCESS) return moveAbove(sh, @intCast(existing), floor);
    }
    reportPath(sh, z, errnoText(err));
    return error.ExecutionFailed;
}

fn moveAbove(sh: *Shell, fd: i32, floor: i32) Error!i32 {
    if (fd >= floor) return fd;
    const moved = sys.duplicateAbove(fd, @intCast(floor));
    _ = linux.close(fd);
    return moved orelse return reportFd(sh, floor, "Too many open files");
}

fn hereDocBody(sh: *Shell, arena: std.mem.Allocator, redirect: ast.Redirect) Error![]const u8 {
    if (redirect.expand_body) return expand_mod.expandHereDoc(sh, arena, redirect.body);
    return redirect.body;
}

// --- persistent redirections ------------------------------------------------

/// The descriptor that stands for logical `fd` in this shell right now: a
/// braced group or function call may have pointed 0-2 elsewhere.
fn shellFd(sh: *const Shell, fd: i32) i32 {
    return switch (fd) {
        0 => sh.default_in,
        1 => sh.default_out,
        2 => sh.default_err,
        else => fd,
    };
}

/// `exec` with redirections: each one changes the shell's own descriptors, in
/// order, so builtins and every later child see the result.
pub fn applyPersistent(sh: *Shell, arena: std.mem.Allocator, redirects: []const ast.Redirect) Error!void {
    for (redirects) |redirect| try persistOne(sh, arena, redirect);
}

fn persistOne(sh: *Shell, arena: std.mem.Allocator, redirect: ast.Redirect) Error!void {
    if (redirect.fd_var.len != 0) return openNamed(sh, arena, redirect);
    const target_fd = redirect.targetFd();
    try checkTarget(sh, target_fd);

    if (!redirect.kind.duplicates()) {
        const source = try openTarget(sh, arena, redirect, temp_floor);
        defer _ = linux.close(source);
        return install(sh, source, target_fd);
    }

    const text = try expand_mod.expandLiteral(sh, arena, redirect.target);
    const spec = parseDupTarget(text) orelse {
        if (redirect.kind != .out_dup or target_fd != 1) return reportAmbiguous(sh, text);
        const source = try openPath(sh, arena, .out, text, temp_floor);
        defer _ = linux.close(source);
        try install(sh, source, 1);
        return install(sh, source, 2);
    };
    switch (spec) {
        .close => _ = linux.close(shellFd(sh, target_fd)),
        .fd, .move => |source_fd| {
            const source = shellFd(sh, source_fd);
            const usable = if (source_fd > 2) isScriptFd(source) else linux.errno(linux.fcntl(source, linux.F.GETFD, 0)) == .SUCCESS;
            if (!usable) return reportFd(sh, source_fd, "Bad file descriptor");
            try install(sh, source, target_fd);
            if (spec == .move and source_fd != target_fd) _ = linux.close(source);
        },
    }
}

/// Points logical descriptor `target_fd` at `source` for good.
fn install(sh: *Shell, source: i32, target_fd: i32) Error!void {
    const real = shellFd(sh, target_fd);
    if (real == source) return;
    const err = linux.errno(linux.dup3(source, real, 0));
    if (err != .SUCCESS) return reportFd(sh, target_fd, errnoText(err));
    // A descriptor standing in for 0-2 inside a group stays private to the
    // shell, like the one it replaced.
    if (target_fd <= 2 and real != target_fd) _ = linux.fcntl(real, linux.F.SETFD, linux.FD_CLOEXEC);
}

/// `{name}>file`: a fresh descriptor at 10 or above, recorded in `name` and
/// left open after the command. `{name}>&-` closes the one `name` holds.
fn openNamed(sh: *Shell, arena: std.mem.Allocator, redirect: ast.Redirect) Error!void {
    var source: i32 = -1;
    var owned = false;
    if (redirect.kind.duplicates()) {
        const text = try expand_mod.expandLiteral(sh, arena, redirect.target);
        const spec = parseDupTarget(text) orelse return reportAmbiguous(sh, text);
        switch (spec) {
            .close => {
                const fd = namedFd(sh, arena, redirect.fd_var) orelse return reportAmbiguous(sh, redirect.fd_var);
                _ = linux.close(fd);
                return;
            },
            .fd, .move => |source_fd| {
                source = shellFd(sh, source_fd);
                const usable = if (source_fd > 2) isScriptFd(source) else linux.errno(linux.fcntl(source, linux.F.GETFD, 0)) == .SUCCESS;
                if (!usable) return reportFd(sh, source_fd, "Bad file descriptor");
            },
        }
    } else {
        source = try openTarget(sh, arena, redirect, temp_floor);
        owned = true;
    }
    defer if (owned) {
        _ = linux.close(source);
    };

    const rc = linux.fcntl(source, linux.F.DUPFD, named_floor);
    const err = linux.errno(rc);
    if (err != .SUCCESS) return reportFd(sh, named_floor, errnoText(err));
    const fd: i32 = @intCast(rc);
    var buf: [16]u8 = undefined;
    const digits = std.fmt.bufPrint(&buf, "{d}", .{fd}) catch unreachable;
    sh.assignVar(redirect.fd_var, .{ .string = digits }) catch {
        _ = linux.close(fd);
        reportPath(sh, redirect.fd_var, "readonly variable");
        return error.ExecutionFailed;
    };
}

fn namedFd(sh: *Shell, arena: std.mem.Allocator, name: []const u8) ?i32 {
    const text = if (sh.getVar(name)) |v| v.renderAlloc(arena) catch return null else sh.getEnv(name) orelse return null;
    return parseFd(std.mem.trim(u8, text, " \t"));
}

// --- tests ------------------------------------------------------------------

const testing = std.testing;
const exec = @import("../exec.zig");
const fs = @import("../fs.zig");

/// A shell whose error output goes to /dev/null, so expected failures stay
/// quiet. The descriptors used below sit well above anything the test runner
/// holds open.
fn quietShell() !Shell {
    var sh = try Shell.initBare(testing.allocator);
    exec.install(&sh);
    sh.default_err = sys.openWrite("/dev/null", false) orelse return error.SkipZigTest;
    return sh;
}

fn expectFile(path: [:0]const u8, expected: []const u8) !void {
    const data = (try fs.readFileAlloc(testing.allocator, path, 4096)) orelse return error.TestUnexpectedResult;
    defer testing.allocator.free(data);
    try testing.expectEqualStrings(expected, data);
}

test "noclobber refuses to truncate an existing regular file" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    const path = "zig-cache-noclobber-test.txt";
    defer _ = fs.removeFile(path);

    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "echo one > zig-cache-noclobber-test.txt\n"));
    sh.options.noclobber = true;
    try testing.expectEqual(@as(u8, 1), exec.runSource(&sh, "echo two > zig-cache-noclobber-test.txt\n"));
    try testing.expectEqual(@as(u8, 1), exec.runSource(&sh, "echo two &> zig-cache-noclobber-test.txt\n"));
    try expectFile(path, "one\n");
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "echo three >> zig-cache-noclobber-test.txt\n"));
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "echo quiet > /dev/null\n"));
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "echo four >| zig-cache-noclobber-test.txt\n"));
    try expectFile(path, "four\n");
}

// The children write through /dev/fd because dash, Ubuntu's /bin/sh, only
// accepts descriptors 0-9 in a redirection.
test "exec redirections persist for builtins and children" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    const path = "zig-cache-exec-redirect-test.txt";
    defer _ = fs.removeFile(path);

    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "exec 47>zig-cache-exec-redirect-test.txt\n"));
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "echo builtin >&47\n/bin/sh -c 'echo child >>/dev/fd/47'\n"));
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "exec 47>&-\n"));
    try expectFile(path, "builtin\nchild\n");
    try testing.expectEqual(@as(u8, 1), exec.runSource(&sh, "echo gone >&47\n"));
}

test "named descriptors are allocated, recorded and closed" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    const path = "zig-cache-named-fd-test.txt";
    defer _ = fs.removeFile(path);

    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "exec {wshfd}>zig-cache-named-fd-test.txt\necho named >&$wshfd\n"));
    const fd = try std.fmt.parseInt(i32, sh.getVar("wshfd").?.string, 10);
    try testing.expect(fd >= named_floor);
    try testing.expect(isScriptFd(fd));
    try testing.expectEqual(@as(u8, 0), exec.runSource(&sh, "exec {wshfd}>&-\n"));
    try testing.expect(!isScriptFd(fd));
    try expectFile(path, "named\n");
}

test "a group's numbered descriptor reaches the commands inside it" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    const path = "zig-cache-group-fd-test.txt";
    defer _ = fs.removeFile(path);

    const status = exec.runSource(&sh, "{ echo inner >&48; /bin/sh -c 'echo child >>/dev/fd/48'; } 48>zig-cache-group-fd-test.txt\n");
    try testing.expectEqual(@as(u8, 0), status);
    try expectFile(path, "inner\nchild\n");
    // The descriptor does not outlive the group.
    try testing.expect(!isScriptFd(48));
}

test "exec inside a redirected group changes only the group's output" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    const outer = "zig-cache-exec-group-outer.txt";
    const inner = "zig-cache-exec-group-inner.txt";
    defer _ = fs.removeFile(outer);
    defer _ = fs.removeFile(inner);

    const status = exec.runSource(&sh, "{ echo first; exec >zig-cache-exec-group-inner.txt; echo second; } >zig-cache-exec-group-outer.txt\n");
    try testing.expectEqual(@as(u8, 0), status);
    try expectFile(outer, "first\n");
    try expectFile(inner, "second\n");
    try testing.expectEqual(@as(i32, 1), sh.default_out);
}

test "duplicating an unopened descriptor fails" {
    var sh = try quietShell();
    defer sh.deinit();
    defer _ = linux.close(sh.default_err);
    try testing.expectEqual(@as(u8, 1), exec.runSource(&sh, "echo hi >&49\n"));
    // Only `>&word` (descriptor 1) means `&>word`; elsewhere a word is ambiguous.
    try testing.expectEqual(@as(u8, 1), exec.runSource(&sh, "echo hi 2>&not-a-descriptor\n"));
}
