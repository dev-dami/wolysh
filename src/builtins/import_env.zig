//! `import-env [--shell PATH] FILE [ARGS...]`: sources a bash or POSIX script
//! in that shell, then brings its exported environment and working directory
//! into wsh. This is how `.venv/bin/activate`, `~/.cargo/env` or a ROS
//! `setup.bash` are used from wsh.

const std = @import("std");
const builtins = @import("../builtins.zig");
const login = @import("../login.zig");
const proc = @import("../proc.zig");
const fs = @import("../fs.zig");
const sys = @import("../sys.zig");

const Ctx = builtins.Ctx;

const usage = "wsh: import-env: usage: import-env [--shell PATH] FILE [ARGS...]\n";

/// `$1` is the file and the rest are its arguments; `$0` stays the shell's
/// name so scripts that compare `$0` with `BASH_SOURCE` know they are sourced.
const source_script =
    \\__wsh_import_file=$1
    \\shift
    \\. "$__wsh_import_file" 9>&-
    \\
++ login.report_epilogue;

pub fn run(ctx: Ctx) u8 {
    var shell_arg: ?[]const u8 = null;
    var i: usize = 1;
    while (i < ctx.argv.len) {
        const arg = ctx.argv[i];
        if (std.mem.eql(u8, arg, "--")) {
            i += 1;
            break;
        }
        if (std.mem.eql(u8, arg, "--shell")) {
            shell_arg = ctx.arg(i + 1) orelse {
                ctx.err(usage);
                return 2;
            };
            i += 2;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--shell=")) {
            shell_arg = arg["--shell=".len..];
            i += 1;
            continue;
        }
        if (arg.len > 1 and arg[0] == '-') {
            ctx.errFmt("wsh: import-env: {s}: unknown option\n", .{arg});
            ctx.err(usage);
            return 2;
        }
        break;
    }
    const file = ctx.arg(i) orelse {
        ctx.err(usage);
        return 2;
    };

    var arena_state = std.heap.ArenaAllocator.init(ctx.sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    return importFile(ctx, arena, shell_arg, file, ctx.argv[i + 1 ..]) catch |err| {
        ctx.errFmt("wsh: import-env: {s}\n", .{@errorName(err)});
        return 1;
    };
}

fn importFile(ctx: Ctx, arena: std.mem.Allocator, shell_arg: ?[]const u8, file: []const u8, args: []const []const u8) !u8 {
    const sh = ctx.sh;
    const shell_path = (try resolveShell(ctx, arena, shell_arg)) orelse return 127;

    // A bare name means the file in this directory, not a `PATH` search.
    const path = if (std.mem.indexOfScalar(u8, file, '/') == null)
        try std.fmt.allocPrint(arena, "./{s}", .{file})
    else
        file;
    const path_z = try arena.dupeZ(u8, path);
    const kind = fs.kindFollow(path_z);
    if (kind == null or kind == .dir or !sys.canAccess(path_z, 4)) {
        ctx.errFmt("wsh: import-env: {s}: cannot read file\n", .{file});
        return 1;
    }

    var argv: std.ArrayList([]const u8) = .empty;
    const name = std.fs.path.basename(shell_path);
    try argv.appendSlice(arena, &.{ name, "-c", source_script, name, path });
    try argv.appendSlice(arena, args);

    const envp = try sh.buildEnvp(arena);
    const result = try login.capture(arena, try arena.dupeZ(u8, shell_path), argv.items, envp, .{
        .stdio = .{ .in = ctx.stdin, .out = ctx.stdout, .err = ctx.stderr },
        .sh = sh,
    });
    const report = login.parseReport(result.output) orelse {
        ctx.errFmt("wsh: import-env: {s} exited before its environment could be read; nothing was imported\n", .{file});
        return if (result.status != 0) result.status else 1;
    };

    try login.applyEnvironment(sh, arena, report.environment, .remove_missing, "import-env", ctx.stderr);
    if (report.cwd.len != 0 and !std.mem.eql(u8, report.cwd, sh.cwd)) {
        const previous = try arena.dupe(u8, sh.cwd);
        const cwd_z = try arena.dupeZ(u8, report.cwd);
        if (try sh.setCwd(cwd_z)) {
            try sh.setEnv("OLDPWD", previous);
        } else {
            ctx.errFmt("wsh: import-env: cannot change to {s}\n", .{report.cwd});
            return 1;
        }
    }
    return report.status;
}

/// `--shell PATH` (a name is looked up on `PATH`), else `bash`, else `/bin/sh`.
fn resolveShell(ctx: Ctx, arena: std.mem.Allocator, shell_arg: ?[]const u8) !?[]const u8 {
    const search = ctx.sh.pathEnv();
    if (shell_arg) |wanted| {
        if (try proc.resolve(arena, wanted, search)) |found| return found;
        ctx.errFmt("wsh: import-env: {s}: shell not found\n", .{wanted});
        return null;
    }
    if (try proc.resolve(arena, "bash", search)) |found| return found;
    if (fs.isExecutable("/bin/sh")) return "/bin/sh";
    ctx.err("wsh: import-env: neither bash nor /bin/sh is available\n");
    return null;
}
