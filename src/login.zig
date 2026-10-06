//! Login-shell initialisation, and the environment capture it shares with
//! `import-env`: a POSIX shell sources a script, then writes its exit status,
//! working directory and exported environment to a private descriptor that wsh
//! reads back. The script's own output still reaches the terminal.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const sys = @import("sys.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const shellmod = @import("shell.zig");
const exec = @import("exec.zig");
const builtins = @import("builtins.zig");

const Shell = shellmod.Shell;

/// Descriptor the helper shell writes its report to.
const report_fd = 9;

/// Appended to every capture script. Each field ends in a NUL, and a final
/// empty field marks a complete report, so a helper killed half-way through
/// writing is never mistaken for one whose environment is empty.
pub const report_epilogue =
    \\printf '%s\0' "$?" >&9
    \\pwd -P >&9
    \\printf '\0' >&9
    \\command -p env -0 >&9 && printf '\0' >&9
    \\
;

/// Set in the profile shell's environment, so a `wsh -l` started by a profile
/// does not import that profile again.
const recursion_marker = "WSH_PROFILE_IMPORT";

/// The profile helper is killed when it has not finished by then.
const profile_timeout_ms = 5000;

const profile_script =
    \\{ if [ -r /etc/profile ]; then . /etc/profile; fi
    \\  if [ -n "${HOME-}" ] && [ -r "$HOME/.profile" ]; then . "$HOME/.profile"; fi
    \\} 9>&-
    \\
++ report_epilogue;

/// Variables every shell maintains for itself. Importing them from a helper
/// would replace the values that describe this shell.
const shell_managed = [_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_", recursion_marker };

fn isShellManaged(name: []const u8) bool {
    for (shell_managed) |managed| {
        if (std.mem.eql(u8, name, managed)) return true;
    }
    return false;
}

/// Login initialisation: imports the environment the POSIX profile exports,
/// then runs the wsh login file. `--noprofile` or `WSH_NO_PROFILE=1` skips it.
pub fn initialise(sh: *Shell, no_profile: bool) void {
    if (no_profile) return;
    if (sh.getEnv("WSH_NO_PROFILE")) |flag| {
        if (std.mem.eql(u8, flag, "1")) return;
    }
    if (sh.getEnv(recursion_marker) != null) return;

    var arena_state = std.heap.ArenaAllocator.init(sh.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    importProfile(sh, arena) catch sys.writeStr(2, "wsh: login: out of memory while importing the profile\n");
    runLoginFile(sh, arena) catch sys.writeStr(2, "wsh: login: out of memory while reading the login file\n");
}

fn importProfile(sh: *Shell, arena: std.mem.Allocator) !void {
    const shell_path = "/bin/sh";
    if (!fs.isExecutable(shell_path)) {
        sys.writeStr(2, "wsh: login: /bin/sh is missing; the profile environment was not imported\n");
        return;
    }
    const null_fd = sys.openRead("/dev/null") orelse {
        sys.writeStr(2, "wsh: login: cannot open /dev/null; the profile environment was not imported\n");
        return;
    };
    defer sys.closeFd(null_fd);

    const envp = try environmentWith(sh, arena, recursion_marker ++ "=1");
    const result = capture(arena, shell_path, &.{ "sh", "-c", profile_script }, envp, .{
        .stdio = .{ .in = null_fd },
        .timeout_ms = profile_timeout_ms,
    }) catch |err| {
        if (err == error.OutOfMemory) return error.OutOfMemory;
        sys.writeStr(2, "wsh: login: cannot start /bin/sh; the profile environment was not imported\n");
        return;
    };
    if (result.timed_out) {
        sys.writeStr(2, "wsh: login: the profile did not finish within 5 seconds; its environment was not imported (WSH_NO_PROFILE=1 skips it)\n");
        return;
    }
    const report = parseReport(result.output) orelse {
        sys.writeStr(2, "wsh: login: the profile exited before its environment could be read\n");
        return;
    };
    // A login shell keeps everything it inherited: only additions and changes
    // are taken from the profile.
    try applyEnvironment(sh, arena, report.environment, .keep_missing, "login", 2);
}

fn runLoginFile(sh: *Shell, arena: std.mem.Allocator) !void {
    const path = (try loginFilePath(sh, arena)) orelse return;
    const z = try arena.dupeZ(u8, path);
    if (!fs.exists(z)) return;
    const data = (try fs.readFileAlloc(sh.gpa, z, 1 << 20)) orelse {
        var buf: [600]u8 = undefined;
        sys.writeStr(2, std.fmt.bufPrint(&buf, "wsh: login: {s}: cannot read the login file\n", .{path}) catch "wsh: login: cannot read the login file\n");
        return;
    };
    defer sh.gpa.free(data);
    _ = exec.runSource(sh, data);
    if (!sh.should_exit) sh.last_status = 0;
}

/// `$XDG_CONFIG_HOME/wsh/login`, falling back to `~/.config/wsh/login`.
fn loginFilePath(sh: *Shell, arena: std.mem.Allocator) !?[]const u8 {
    if (sh.getEnv("XDG_CONFIG_HOME")) |dir| {
        if (dir.len != 0) return try std.fmt.allocPrint(arena, "{s}/wsh/login", .{dir});
    }
    const home = sh.getEnv("HOME") orelse return null;
    if (home.len == 0) return null;
    return try std.fmt.allocPrint(arena, "{s}/.config/wsh/login", .{home});
}

/// The shell's environment plus one extra `NAME=value` entry.
fn environmentWith(sh: *Shell, arena: std.mem.Allocator, extra: []const u8) ![*:null]const ?[*:0]const u8 {
    const arr = try arena.alloc(?[*:0]const u8, sh.env.count() + 2);
    var i: usize = 0;
    var it = sh.env.iterator();
    while (it.next()) |entry| {
        arr[i] = (try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{ entry.key_ptr.*, entry.value_ptr.* }, 0)).ptr;
        i += 1;
    }
    arr[i] = (try arena.dupeZ(u8, extra)).ptr;
    arr[i + 1] = null;
    return @ptrCast(arr.ptr);
}

// --- capture ----------------------------------------------------------------

pub const Capture = struct {
    /// Everything the helper wrote to `report_fd`.
    output: []const u8,
    /// The helper's own exit status.
    status: u8,
    timed_out: bool,
};

pub const CaptureOptions = struct {
    stdio: proc.Stdio = .{},
    /// Kill the helper's process group when it is still running by then.
    timeout_ms: ?u64 = null,
    /// Run the helper like a foreground command of this shell: in its own
    /// group holding the terminal under job control, otherwise in the
    /// shell's group, so Ctrl-C reaches it and it can prompt.
    sh: ?*Shell = null,
};

const ChildSetup = struct { exe: proc.Exec, own_group: bool };

/// Runs in the forked helper, after its descriptors are in place.
fn execHelper(ctx: *anyopaque) noreturn {
    const setup: *const ChildSetup = @ptrCast(@alignCast(ctx));
    // `launch` leaves a single process's group to the parent; set it here too
    // so the group exists for a timeout kill whichever side runs first.
    if (setup.own_group) _ = linux.setpgid(0, 0);
    // The shell cannot resume a stopped helper, and a helper without the
    // terminal must not stop when it touches it (`stty` in a profile).
    proc.installHandler(.TSTP, linux.SIG.IGN);
    proc.installHandler(.TTIN, linux.SIG.IGN);
    proc.installHandler(.TTOU, linux.SIG.IGN);
    _ = linux.execve(setup.exe.path, setup.exe.argv, setup.exe.envp);
    const msg = "wsh: could not execute the helper shell\n";
    _ = linux.write(2, msg.ptr, msg.len);
    linux.exit(127);
}

/// Starts `path` with `argv` and `envp`, gives it a pipe as descriptor
/// `report_fd`, and collects what it writes there.
pub fn capture(
    arena: std.mem.Allocator,
    path: [:0]const u8,
    argv: []const []const u8,
    envp: [*:null]const ?[*:0]const u8,
    options: CaptureOptions,
) !Capture {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) != .SUCCESS) return error.PipeFailed;
    defer _ = linux.close(fds[0]);
    // Moved above `report_fd`: a `dup2` onto itself would leave close-on-exec set.
    const write_end = sys.duplicateAbove(fds[1], report_fd + 1);
    _ = linux.close(fds[1]);
    const writer = write_end orelse return error.PipeFailed;

    // A timeout kills a whole group, which must not be the shell's own.
    const job_control = if (options.sh) |sh| sh.job_control else false;
    const own_group = options.timeout_ms != null or job_control;
    const setup = try arena.create(ChildSetup);
    setup.* = .{
        .exe = .{ .path = path, .argv = try proc.buildArgv(arena, argv), .envp = envp },
        .own_group = own_group,
    };
    const redirects = [_]proc.Redirection{.{ .target = report_fd, .source = writer }};
    const launched = proc.launch(arena, &.{.{
        .child_fn = execHelper,
        .child_ctx = setup,
        .stdio = options.stdio,
        .redirects = &redirects,
    }}, .{ .new_group = own_group }) catch |err| {
        _ = linux.close(writer);
        return err;
    };
    _ = linux.close(writer);
    const pid = launched.pids[0];
    if (job_control) options.sh.?.giveTerminal(launched.pgid);
    defer if (job_control) options.sh.?.takeTerminal();

    var output: std.ArrayList(u8) = .empty;
    var timed_out = false;
    const deadline: ?u64 = if (options.timeout_ms) |ms| monotonicMs() + ms else null;
    var buf: [8192]u8 = undefined;
    while (true) {
        var wait_ms: i32 = -1;
        if (deadline) |end| {
            const now = monotonicMs();
            if (now >= end) {
                timed_out = true;
                break;
            }
            wait_ms = @intCast(@min(end - now, std.math.maxInt(i32)));
        }
        var poll_fds = [_]posix.pollfd{.{ .fd = fds[0], .events = posix.POLL.IN, .revents = 0 }};
        const ready = posix.poll(&poll_fds, wait_ms) catch break;
        if (ready == 0) continue;
        const n = sys.readSome(fds[0], &buf) orelse break;
        if (n == 0) break;
        try output.appendSlice(arena, buf[0..n]);
    }
    // The whole group: a hung grandchild would keep the shell's output open.
    if (timed_out) proc.signalGroup(pid, .KILL);
    const status = proc.waitPid(pid, 0);
    return .{
        .output = output.items,
        .status = if (status) |st| st.exitCode() else 1,
        .timed_out = timed_out,
    };
}

fn monotonicMs() u64 {
    var time: linux.timespec = undefined;
    if (linux.errno(linux.clock_gettime(.MONOTONIC, &time)) != .SUCCESS) return 0;
    return @as(u64, @intCast(time.sec)) * std.time.ms_per_s + @as(u64, @intCast(time.nsec)) / std.time.ns_per_ms;
}

// --- report -----------------------------------------------------------------

pub const Report = struct {
    /// `$?` after the sourced script.
    status: u8,
    /// Physical working directory the script left behind.
    cwd: []const u8,
    /// `NAME=value` entries separated by NULs.
    environment: []const u8,
};

/// Splits what `report_epilogue` wrote. Null when the report is incomplete.
pub fn parseReport(bytes: []const u8) ?Report {
    if (!std.mem.endsWith(u8, bytes, "\x00\x00")) return null;
    var fields = std.mem.splitScalar(u8, bytes[0 .. bytes.len - 2], 0);
    const status_text = fields.next() orelse return null;
    const cwd_line = fields.next() orelse return null;
    const status = std.fmt.parseInt(u8, status_text, 10) catch return null;
    const cwd = if (std.mem.endsWith(u8, cwd_line, "\n")) cwd_line[0 .. cwd_line.len - 1] else cwd_line;
    return .{ .status = status, .cwd = cwd, .environment = fields.rest() };
}

pub const Missing = enum {
    /// Variables absent from the report stay (login import).
    keep_missing,
    /// Variables absent from the report were unset by the script.
    remove_missing,
};

/// Brings the shell's environment in line with `environment` (NUL-separated
/// `NAME=value` entries). Shell-managed names are never touched, and readonly
/// names are reported and left alone.
pub fn applyEnvironment(
    sh: *Shell,
    arena: std.mem.Allocator,
    environment: []const u8,
    missing: Missing,
    who: []const u8,
    err_fd: i32,
) !void {
    var seen = std.StringHashMap(void).init(arena);
    var it = std.mem.splitScalar(u8, environment, 0);
    while (it.next()) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue;
        const name = entry[0..eq];
        const value = entry[eq + 1 ..];
        if (name.len == 0 or isShellManaged(name)) continue;
        try seen.put(name, {});
        if (sh.getEnv(name)) |current| {
            if (std.mem.eql(u8, current, value)) continue;
        }
        sh.assignEnv(name, value) catch |err| switch (err) {
            error.ReadonlyVariable => reportReadonly(err_fd, who, name),
            else => |e| return e,
        };
    }
    if (missing == .keep_missing) return;

    // Only valid names: other shells may drop odd ones like `A-B` on the way
    // through, which is not the same as the script unsetting them.
    var removed: std.ArrayList([]const u8) = .empty;
    var env_it = sh.env.iterator();
    while (env_it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (seen.contains(name) or isShellManaged(name) or !builtins.validName(name)) continue;
        try removed.append(arena, try arena.dupe(u8, name));
    }
    for (removed.items) |name| {
        if (sh.isReadonly(name)) {
            reportReadonly(err_fd, who, name);
            continue;
        }
        _ = sh.unsetEnv(name);
    }
}

fn reportReadonly(err_fd: i32, who: []const u8, name: []const u8) void {
    var buf: [512]u8 = undefined;
    sys.writeStr(err_fd, std.fmt.bufPrint(&buf, "wsh: {s}: {s}: readonly variable\n", .{ who, name }) catch return);
}

const testing = std.testing;

test "complete reports are split into status, directory and environment" {
    const report = parseReport("3\x00/tmp/x\n\x00A=1\x00B=two words\x00\x00").?;
    try testing.expectEqual(@as(u8, 3), report.status);
    try testing.expectEqualStrings("/tmp/x", report.cwd);
    try testing.expectEqualStrings("A=1\x00B=two words", report.environment);

    const empty = parseReport("0\x00/\n\x00\x00").?;
    try testing.expectEqualStrings("", empty.environment);

    // Cut off before the end marker: not a report.
    try testing.expect(parseReport("0\x00/\n\x00A=1\x00") == null);
    try testing.expect(parseReport("") == null);
}

test "applying a report adds, changes and removes variables" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try sh.setEnv("KEEP", "same");
    try sh.setEnv("CHANGE", "old");
    try sh.setEnv("GONE", "x");
    try sh.setEnv("ODD-NAME", "y");
    try sh.setEnv("PWD", "/here");

    try applyEnvironment(&sh, arena, "KEEP=same\x00CHANGE=new\x00ADDED=1\x00PWD=/elsewhere", .keep_missing, "test", -1);
    try testing.expectEqualStrings("new", sh.getEnv("CHANGE").?);
    try testing.expectEqualStrings("1", sh.getEnv("ADDED").?);
    try testing.expectEqualStrings("x", sh.getEnv("GONE").?);
    try testing.expectEqualStrings("/here", sh.getEnv("PWD").?);

    try sh.setEnv("LOCKED", "fixed");
    try sh.markReadonly("LOCKED");
    try applyEnvironment(&sh, arena, "KEEP=same\x00CHANGE=new", .remove_missing, "test", -1);
    try testing.expectEqualStrings("fixed", sh.getEnv("LOCKED").?);
    try testing.expect(sh.getEnv("GONE") == null);
    try testing.expect(sh.getEnv("ADDED") == null);
    try testing.expectEqualStrings("y", sh.getEnv("ODD-NAME").?);
    try testing.expectEqualStrings("/here", sh.getEnv("PWD").?);
}

test "capture collects the report written to the private descriptor" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const envp = try proc.buildArgv(arena, &.{ "PATH=/usr/bin:/bin", "FROM_TEST=1" });
    const script = "export ADDED=yes; cd /; (exit 4)\n" ++ report_epilogue;
    const result = try capture(arena, "/bin/sh", &.{ "sh", "-c", script }, envp, .{ .timeout_ms = 5000 });
    try testing.expect(!result.timed_out);
    const report = parseReport(result.output).?;
    try testing.expectEqual(@as(u8, 4), report.status);
    try testing.expectEqualStrings("/", report.cwd);
    try testing.expect(std.mem.indexOf(u8, report.environment, "ADDED=yes") != null);
    try testing.expect(std.mem.indexOf(u8, report.environment, "FROM_TEST=1") != null);
}

test "capture kills a helper that runs past its deadline" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const envp = try proc.buildArgv(arena, &.{"PATH=/usr/bin:/bin"});
    const result = try capture(arena, "/bin/sh", &.{ "sh", "-c", "exec sleep 5" }, envp, .{ .timeout_ms = 100 });
    try testing.expect(result.timed_out);
    try testing.expect(parseReport(result.output) == null);
}
