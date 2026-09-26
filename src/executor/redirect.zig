const std = @import("std");
const ast = @import("../ast.zig");
const expand_mod = @import("../expand.zig");
const proc = @import("../proc.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Shell = shellmod.Shell;

pub const Error = expand_mod.Error || std.Io.Writer.Error || error{ExecutionFailed};

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
    var fds = Fds{ .in = sh.default_in, .out = sh.default_out, .err = sh.default_err };
    if (cmd.redirects.len == 0) return .{ .fds = fds, .redirects = &.{} };
    var actions: std.ArrayList(proc.Redirection) = .empty;

    for (cmd.redirects) |redirect| {
        if (redirect.kind.duplicates()) {
            const source = redirect.target[0] - '0';
            const mapped_source = switch (source) {
                0 => fds.in,
                1 => fds.out,
                2 => fds.err,
                else => return error.ExecutionFailed,
            };
            switch (redirect.kind.fd()) {
                1 => fds.out = mapped_source,
                2 => fds.err = mapped_source,
                else => return error.ExecutionFailed,
            }
            try actions.append(arena, .{ .target = redirect.kind.fd(), .source = source });
            continue;
        }
        const target = try expand_mod.expandLiteral(sh, arena, redirect.target);
        const z = try arena.dupeZ(u8, target);

        const fd = if (redirect.kind == .here_doc) blk: {
            const body = if (redirect.expand_body)
                try expand_mod.expandHereDoc(sh, arena, redirect.body)
            else
                redirect.body;
            break :blk sys.createAnonymousFile(body);
        } else if (redirect.kind.isInput())
            sys.openRead(z.ptr)
        else
            sys.openWrite(z.ptr, redirect.kind.append());

        if (fd == null) {
            if (redirect.kind == .here_doc) {
                sys.writeStr(sh.default_err, "wsh: cannot prepare here-document\n");
                return error.ExecutionFailed;
            }
            var buf: [512]u8 = undefined;
            const message = std.fmt.bufPrint(&buf, "wsh: {s}: cannot open file\n", .{target}) catch return error.ExecutionFailed;
            sys.writeStr(sh.default_err, message);
            return error.ExecutionFailed;
        }

        switch (redirect.kind) {
            .in, .here_doc => fds.in = fd.?,
            .err_out, .err_append => fds.err = fd.?,
            else => fds.out = fd.?,
        }
        try opened.append(arena, fd.?);
        try actions.append(arena, .{ .target = redirect.kind.fd(), .source = fd.?, .close_source = true });
    }

    return .{ .fds = fds, .redirects = try actions.toOwnedSlice(arena) };
}
