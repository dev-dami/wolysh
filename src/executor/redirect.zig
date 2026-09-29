const std = @import("std");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ExecutionFailed};

/// Descriptors the shell tracks while applying a command's redirects. Higher
/// numbers are passed through to the child untouched.
const max_fd = 32;

pub const Fds = struct {
    in: i32,
    out: i32,
    err: i32,
};

pub const Prepared = struct {
    fds: Fds,
    redirects: []const proc.Redirection,
};

pub fn apply(
    sh: *Shell,
    arena: std.mem.Allocator,
    cmd: ast.Command,
    opened: *std.ArrayList(i32),
) Error!Prepared {
    // Logical descriptor -> the descriptor it currently names, in order.
    var table: [max_fd]i32 = undefined;
    for (&table) |*entry| entry.* = -1;
    table[0] = sh.default_in;
    table[1] = sh.default_out;
    table[2] = sh.default_err;
    if (cmd.redirects.len == 0) return .{ .fds = current(table), .redirects = &.{} };

    var actions: std.ArrayList(proc.Redirection) = .empty;

    for (cmd.redirects) |redirect| {
        const target_fd = redirect.targetFd();
        if (target_fd < 0 or target_fd >= max_fd) return error.ExecutionFailed;

        if (redirect.kind.duplicates()) {
            try duplicate(arena, redirect, target_fd, &table, opened, &actions);
            continue;
        }

        const target = try expand_mod.expandLiteral(sh, arena, redirect.target);
        const z = try arena.dupeZ(u8, target);

        const opened_fd = if (redirect.kind == .here_doc)
            sys.createAnonymousFile(try hereDocBody(sh, arena, redirect))
        else if (redirect.kind == .here_string)
            sys.createAnonymousFile(try std.fmt.allocPrint(arena, "{s}\n", .{target}))
        else if (redirect.kind.isInput())
            sys.openRead(z.ptr)
        else
            sys.openWrite(z.ptr, redirect.kind.append());

        if (opened_fd == null) {
            if (redirect.kind == .here_doc or redirect.kind == .here_string) {
                sys.writeStr(sh.default_err, "wsh: cannot prepare here-document\n");
                return error.ExecutionFailed;
            }
            var buf: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "wsh: {s}: cannot open file\n", .{target}) catch return error.ExecutionFailed;
            sys.writeStr(sh.default_err, message);
            return error.ExecutionFailed;
        }

        var source = opened_fd.?;
        if (source < max_fd) {
            // Keep temporary files outside every supported logical descriptor.
            const moved = sys.duplicateAbove(source, max_fd) orelse {
                sys.closeFd(source);
                return error.ExecutionFailed;
            };
            sys.closeFd(source);
            source = moved;
        }
        table[@intCast(target_fd)] = source;
        try opened.append(arena, source);
        // Dup the file onto its target, then release the temporary descriptor
        // immediately: later duplications name a descriptor by its logical
        // number, which the child has already put in place by then.
        try actions.append(arena, .{ .target = target_fd, .source = source });
        try actions.append(arena, .{ .target = source, .source = source, .close_source = true });
    }

    return .{ .fds = current(table), .redirects = try actions.toOwnedSlice(arena) };
}

fn hereDocBody(sh: *Shell, arena: std.mem.Allocator, redirect: ast.Redirect) Error![]const u8 {
    if (redirect.expand_body) return expand_mod.expandHereDoc(sh, arena, redirect.body);
    return redirect.body;
}

/// `N>&M` / `N<&M`: point descriptor N at whatever M currently names. A `-`
/// target closes N.
fn duplicate(
    arena: std.mem.Allocator,
    redirect: ast.Redirect,
    target_fd: i32,
    table: *[max_fd]i32,
    opened: *std.ArrayList(i32),
    actions: *std.ArrayList(proc.Redirection),
) Error!void {
    if (redirect.target.len == 1 and redirect.target[0] == '-') {
        if (target_fd > 2) {
            // Closing N in the child is `dup2(N, N)` followed by closing N.
            table[@intCast(target_fd)] = -1;
            try actions.append(arena, .{ .target = target_fd, .source = target_fd, .close_source = true });
            return;
        }
        // `dup2` cannot close 0/1/2, so those point at /dev/null instead.
        const null_fd = if (redirect.kind.isInput())
            sys.openRead("/dev/null")
        else
            sys.openWrite("/dev/null", false);
        const fd = null_fd orelse return error.ExecutionFailed;
        table[@intCast(target_fd)] = fd;
        try opened.append(arena, fd);
        try actions.append(arena, .{ .target = target_fd, .source = fd });
        try actions.append(arena, .{ .target = fd, .source = fd, .close_source = true });
        return;
    }

    const source_fd = parseFd(redirect.target) orelse return error.ExecutionFailed;
    // A descriptor the shell never opened cannot be duplicated: `2>&9` is an
    // error rather than a silent no-op.
    if (table[@intCast(source_fd)] < 0) return error.ExecutionFailed;
    const actual = table[@intCast(source_fd)];
    table[@intCast(target_fd)] = actual;
    // The child applies this after its own descriptors are wired (pipeline pipes,
    // earlier in this list), so keep the logical descriptor rather than the
    // concrete one the parent resolved.
    try actions.append(arena, .{ .target = target_fd, .source = source_fd });
}

fn current(table: [max_fd]i32) Fds {
    return .{ .in = table[0], .out = table[1], .err = table[2] };
}

fn parseFd(text: []const u8) ?i32 {
    if (text.len == 0) return null;
    var value: i32 = 0;
    for (text) |c| {
        if (c < '0' or c > '9') return null;
        value = value * 10 + (c - '0');
        if (value >= max_fd) return null;
    }
    return value;
}
