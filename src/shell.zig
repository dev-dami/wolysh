//! Shell state: variables, environment, functions, aliases, jobs and the
//! controlling terminal.
//!
//! Ownership rule: anything that outlives a single command line (a variable, an
//! environment entry, a function body, an alias) is owned by the shell's
//! long-lived allocator and is deep-copied on the way in. Anything used only
//! while evaluating one command line lives in the per-line arena and is
//! released wholesale.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");
const value = @import("value.zig");
const jobs = @import("jobs.zig");
const history = @import("history.zig");
const fs = @import("fs.zig");
const proc = @import("proc.zig");
const command_cache = @import("command_cache.zig");

/// Runs `$(...)` and returns its stdout. Installed by `exec.zig`, which breaks
/// the otherwise circular dependency between expansion and execution.
pub const SubstFn = *const fn (*Shell, []const u8, std.mem.Allocator) anyerror![]const u8;

pub const Config = struct {
    /// Prompt prefix override; empty means the built-in prompt is used.
    prompt: []const u8 = "",
    autosuggest: bool = true,
    highlight: bool = true,
    completion: bool = true,
    git_prompt: bool = true,
    history_limit: usize = 5000,
};

pub const Shell = struct {
    gpa: std.mem.Allocator,

    vars: std.StringHashMap(value.Value),
    env: std.StringHashMap([]const u8),
    /// Function name -> source text of its `fn` declaration.
    funcs: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),

    jobs: jobs.Table,
    hist: history.History,
    command_cache: command_cache.Cache = .{},

    cwd: []u8,
    last_status: u8 = 0,
    last_bg_pid: i32 = 0,

    interactive: bool = false,
    login: bool = false,
    should_exit: bool = false,
    exit_code: u8 = 0,

    pid: i32 = 0,
    shell_pgid: i32 = 0,
    tty_fd: i32 = -1,
    job_control: bool = false,

    /// Descriptors inherited by commands that do not redirect them. `func >
    /// file` works because the body's commands pick these up.
    default_in: i32 = 0,
    default_out: i32 = 1,
    default_err: i32 = 2,

    /// Loop-control flags.
    break_pending: bool = false,
    continue_pending: bool = false,
    /// Status produced by `return`.
    return_code: u8 = 0,
    /// Swap-in allocator used for loop bodies so iterations can be reclaimed.
    scratch_override: ?std.mem.Allocator = null,

    /// Guards against unbounded recursion through functions, `source` and
    /// command substitution.
    call_depth: u32 = 0,
    /// Non-zero while nested execution is running; only the outermost command
    /// may reset the line arena.
    exec_depth: u32 = 0,
    /// Set while executing a function, so `return` knows where to stop.
    return_pending: bool = false,

    /// Positional parameters (`$1`, `$2`, ...) for the current function or
    /// script. Owned by the caller's arena and saved/restored around calls.
    positional: []const []const u8 = &.{},
    /// `$0`.
    script_name: []const u8 = "",

    line_arena: std.heap.ArenaAllocator,

    config: Config = .{},
    hostname: []const u8 = "",
    history_path: []const u8 = "",
    config_path: []const u8 = "",

    subst_runner: ?SubstFn = null,

    pub const max_call_depth = 256;

    fn blank(gpa: std.mem.Allocator) Shell {
        return .{
            .gpa = gpa,
            .vars = std.StringHashMap(value.Value).init(gpa),
            .env = std.StringHashMap([]const u8).init(gpa),
            .funcs = std.StringHashMap([]const u8).init(gpa),
            .aliases = std.StringHashMap([]const u8).init(gpa),
            .jobs = .{},
            .hist = .{},
            .cwd = &.{},
            .line_arena = std.heap.ArenaAllocator.init(gpa),
            .pid = sys.getpid(),
        };
    }

    /// A shell with no environment, for tests and for embedding.
    pub fn initBare(gpa: std.mem.Allocator) !Shell {
        var sh = blank(gpa);
        errdefer sh.deinit();
        sh.cwd = try gpa.dupe(u8, ".");
        sh.hostname = try gpa.dupe(u8, "localhost");
        return sh;
    }

    pub fn init(gpa: std.mem.Allocator, init_args: std.process.Init.Minimal) !Shell {
        var sh = blank(gpa);
        errdefer sh.deinit();

        sh.cwd = (try fs.getCwd(gpa)) orelse (try gpa.dupe(u8, "/"));
        sh.shell_pgid = sys.getpgid(0) orelse sh.pid;

        var env_map = try std.process.Environ.createMap(init_args.environ, gpa);
        defer env_map.deinit();
        var it = env_map.iterator();
        while (it.next()) |entry| {
            try sh.setEnv(entry.key_ptr.*, entry.value_ptr.*);
        }

        if (sh.env.get("PATH") == null) try sh.setEnv("PATH", "/usr/local/bin:/usr/bin:/bin");
        try sh.setEnv("PWD", sh.cwd);
        if (sh.env.get("SHELL") == null) try sh.setEnv("SHELL", "/usr/local/bin/wsh");

        var host_buf: [linux.HOST_NAME_MAX]u8 = undefined;
        if (std.posix.gethostname(&host_buf) catch null) |name| {
            sh.hostname = try gpa.dupe(u8, name);
        } else {
            sh.hostname = try gpa.dupe(u8, "localhost");
        }

        return sh;
    }

    pub fn deinit(self: *Shell) void {
        var vit = self.vars.iterator();
        while (vit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            freeValue(self.gpa, entry.value_ptr.*);
        }
        self.vars.deinit();

        var eit = self.env.iterator();
        while (eit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.env.deinit();

        var fit = self.funcs.iterator();
        while (fit.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.funcs.deinit();

        var ait = self.aliases.iterator();
        while (ait.next()) |entry| {
            self.gpa.free(entry.key_ptr.*);
            self.gpa.free(entry.value_ptr.*);
        }
        self.aliases.deinit();

        self.jobs.deinit(self.gpa);
        self.hist.deinit(self.gpa);
        self.command_cache.deinit(self.gpa);
        if (self.cwd.len != 0) self.gpa.free(self.cwd);
        if (self.hostname.len != 0) self.gpa.free(self.hostname);
        if (self.history_path.len != 0) self.gpa.free(self.history_path);
        if (self.config_path.len != 0) self.gpa.free(self.config_path);
        self.line_arena.deinit();
    }

    /// Allocator for values and expansions that only need to survive the
    /// current command line.
    pub fn scratch(self: *Shell) std.mem.Allocator {
        return self.scratch_override orelse self.line_arena.allocator();
    }

    pub fn resetLineArena(self: *Shell) void {
        _ = self.line_arena.reset(.free_all);
    }

    // --- variables ----------------------------------------------------------

    pub fn getVar(self: *const Shell, name: []const u8) ?value.Value {
        return self.vars.get(name);
    }

    pub fn hasVar(self: *const Shell, name: []const u8) bool {
        return self.vars.contains(name);
    }

    /// Stores `val`, deep-copying it so the caller's arena can be reset.
    pub fn setVar(self: *Shell, name: []const u8, val: value.Value) !void {
        const owned = try cloneValue(self.gpa, val);
        errdefer freeValue(self.gpa, owned);
        const gop = try self.vars.getOrPut(name);
        if (gop.found_existing) {
            freeValue(self.gpa, gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = owned;
    }

    pub fn unsetVar(self: *Shell, name: []const u8) bool {
        if (self.vars.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            freeValue(self.gpa, kv.value);
            return true;
        }
        return false;
    }

    /// Variable names, for completion.
    pub fn varNames(self: *const Shell, out: *std.ArrayList([]const u8)) !void {
        var it = self.vars.iterator();
        while (it.next()) |entry| try out.append(self.gpa, entry.key_ptr.*);
    }

    // --- environment --------------------------------------------------------

    pub fn getEnv(self: *const Shell, name: []const u8) ?[]const u8 {
        return self.env.get(name);
    }

    pub fn setEnv(self: *Shell, name: []const u8, val: []const u8) !void {
        const owned_val = try self.gpa.dupe(u8, val);
        errdefer self.gpa.free(owned_val);
        const gop = try self.env.getOrPut(name);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = owned_val;
    }

    pub fn unsetEnv(self: *Shell, name: []const u8) bool {
        if (self.env.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            self.gpa.free(kv.value);
            return true;
        }
        return false;
    }

    pub fn pathEnv(self: *const Shell) []const u8 {
        return self.env.get("PATH") orelse "/usr/local/bin:/usr/bin:/bin";
    }

    pub fn envNames(self: *const Shell, out: *std.ArrayList([]const u8)) !void {
        var it = self.env.iterator();
        while (it.next()) |entry| try out.append(self.gpa, entry.key_ptr.*);
    }

    /// Builds the `envp` array passed to children.
    pub fn buildEnvp(self: *const Shell, arena: std.mem.Allocator) ![*:null]const ?[*:0]const u8 {
        const arr = try arena.alloc(?[*:0]const u8, self.env.count() + 1);
        var i: usize = 0;
        var it = self.env.iterator();
        while (it.next()) |entry| {
            const pair = try std.fmt.allocPrint(arena, "{s}={s}", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            });
            arr[i] = (try arena.dupeZ(u8, pair)).ptr;
            i += 1;
        }
        arr[i] = null;
        return @ptrCast(arr.ptr);
    }

    // --- functions and aliases ---------------------------------------------

    pub fn defineFunc(self: *Shell, name: []const u8, source: []const u8) !void {
        const owned = try self.gpa.dupe(u8, source);
        errdefer self.gpa.free(owned);
        const gop = try self.funcs.getOrPut(name);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = owned;
    }

    pub fn getFunc(self: *const Shell, name: []const u8) ?[]const u8 {
        return self.funcs.get(name);
    }

    pub fn setAlias(self: *Shell, name: []const u8, val: []const u8) !void {
        const owned = try self.gpa.dupe(u8, val);
        errdefer self.gpa.free(owned);
        const gop = try self.aliases.getOrPut(name);
        if (gop.found_existing) {
            self.gpa.free(gop.value_ptr.*);
        } else {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
        }
        gop.value_ptr.* = owned;
    }

    pub fn getAlias(self: *const Shell, name: []const u8) ?[]const u8 {
        return self.aliases.get(name);
    }

    // --- working directory --------------------------------------------------

    /// Re-reads the process working directory and keeps `PWD` in sync.
    pub fn updateCwd(self: *Shell) !void {
        const cwd = (try fs.getCwd(self.gpa)) orelse return;
        self.gpa.free(self.cwd);
        self.cwd = cwd;
        try self.setEnv("PWD", cwd);
    }

    pub fn setCwd(self: *Shell, path: [:0]const u8) !bool {
        if (!fs.chdir(path)) return false;
        try self.updateCwd();
        return true;
    }

    /// `~/src` -> `<HOME>/src`, leaving other paths untouched.
    pub fn tildeExpand(self: *const Shell, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        if (path.len == 0 or path[0] != '~') return path;
        if (path.len == 1 or path[1] == '/') {
            const home = self.getEnv("HOME") orelse return path;
            if (path.len == 1) return home;
            return std.fmt.allocPrint(arena, "{s}{s}", .{ home, path[1..] });
        }
        return path;
    }

    /// The path shown in the prompt, with `$HOME` collapsed to `~`.
    pub fn shortCwd(self: *const Shell, arena: std.mem.Allocator) ![]const u8 {
        const cwd = self.cwd;
        const home = self.getEnv("HOME");

        // Prefer `~` for the home directory or anything beneath it.
        if (home) |h| {
            if (cwd.len == h.len and std.mem.eql(u8, cwd, h)) return arena.dupe(u8, "~");
            if (cwd.len > h.len and std.mem.startsWith(u8, cwd, h) and cwd[h.len] == '/') {
                return std.fmt.allocPrint(arena, "~{s}", .{cwd[h.len..]});
            }
        }

        // Otherwise show the trailing components when the path is deep.
        const parts = [_][]const u8{ "/", "tmp", "usr", "var", "opt", "home", "dev", "etc" };
        for (parts) |p| {
            if (cwd.len == p.len + 1 and cwd[0] == '/' and std.mem.eql(u8, cwd[1..], p)) {
                return std.fmt.allocPrint(arena, "/{s}", .{p});
            }
        }

        var depth: usize = 0;
        for (cwd) |c| {
            if (c == '/') depth += 1;
        }
        if (depth >= 3) {
            const last = std.mem.lastIndexOfScalar(u8, cwd, '/').?;
            const prev = std.mem.lastIndexOfScalar(u8, cwd[0..last], '/') orelse 0;
            return std.fmt.allocPrint(arena, "…{s}", .{cwd[prev..]});
        }
        return arena.dupe(u8, cwd);
    }

    /// Name of the current git branch, or null when not inside a repository.
    /// Reads `.git/HEAD` directly so no `git` process is needed.
    pub fn gitBranch(self: *const Shell, arena: std.mem.Allocator) !?[]const u8 {
        var dir_buf: [linux.PATH_MAX]u8 = undefined;
        var current: []const u8 = self.cwd;

        var levels: usize = 0;
        while (levels < 32) : (levels += 1) {
            const head_path = try std.fmt.allocPrint(arena, "{s}/.git/HEAD", .{current});
            const z = try arena.dupeZ(u8, head_path);
            if (try fs.readFileAlloc(arena, z, 4096)) |data| {
                const trimmed = std.mem.trim(u8, data, " \t\r\n");
                const prefix = "ref: refs/heads/";
                if (std.mem.startsWith(u8, trimmed, prefix)) {
                    return try arena.dupe(u8, trimmed[prefix.len..]);
                }
                if (trimmed.len >= 7) return try arena.dupe(u8, trimmed[0..7]);
                return null;
            }

            // Walk up one directory.
            const parent = std.fs.path.dirname(current) orelse return null;
            if (parent.len == 0 or std.mem.eql(u8, parent, current)) return null;
            if (parent.len >= dir_buf.len) return null;
            @memcpy(dir_buf[0..parent.len], parent);
            current = dir_buf[0..parent.len];
        }
        return null;
    }

    // --- job control --------------------------------------------------------

    /// Puts the shell in its own process group and takes over the terminal.
    pub fn setupJobControl(self: *Shell, tty_fd: i32) void {
        if (!sys.isTty(tty_fd)) return;
        self.tty_fd = tty_fd;
        self.job_control = true;

        while (true) {
            const fg = sys.tcgetpgrp(tty_fd) orelse break;
            const mine = sys.getpgid(0) orelse break;
            if (fg == mine) break;
            proc.signalGroup(mine, .TTOU);
        }
    }

    pub fn giveTerminal(self: *Shell, pgid: i32) void {
        if (!self.job_control or self.tty_fd < 0) return;
        sys.tcsetpgrp(self.tty_fd, pgid);
    }

    pub fn takeTerminal(self: *Shell) void {
        if (!self.job_control or self.tty_fd < 0) return;
        sys.tcsetpgrp(self.tty_fd, self.shell_pgid);
    }

    pub const WaitOutcome = struct {
        status: u8,
        signal: ?u32 = null,
        stopped: bool = false,
        stopped_signal: ?u32 = null,
    };

    /// Waits for every process in a foreground job, handing it the terminal
    /// first. Pids are zeroed as they are reaped, so a stopped job can be
    /// resumed without losing track of the survivors.
    pub fn waitForeground(self: *Shell, job: *jobs.Job) WaitOutcome {
        self.giveTerminal(job.pgid);

        var last_status: u8 = 0;
        var last_signal: ?u32 = null;
        var stopped_signal: ?u32 = null;

        while (true) {
            var reaped_any = false;
            for (job.pids, 0..) |pid, idx| {
                if (pid == 0) continue;
                const st = proc.waitPid(pid, linux.W.UNTRACED) orelse continue;
                reaped_any = true;
                switch (st.kind) {
                    .exited, .signaled => {
                        if (idx + 1 == job.pids.len) {
                            last_status = st.exitCode();
                            last_signal = if (st.kind == .signaled) st.sig else null;
                        }
                        job.pids[idx] = 0;
                    },
                    .stopped => {
                        stopped_signal = st.sig;
                    },
                    .continued => {},
                }
                break;
            }

            if (stopped_signal) |sig| {
                // Stop the rest of the pipeline too, so the job is coherent.
                proc.signalGroup(job.pgid, .STOP);
                self.takeTerminal();
                return .{
                    .status = 128 +% @as(u8, @intCast(@min(sig, 127))),
                    .stopped = true,
                    .stopped_signal = sig,
                };
            }

            if (!reaped_any) {
                var all_gone = true;
                for (job.pids) |pid| {
                    if (pid != 0) {
                        all_gone = false;
                        break;
                    }
                }
                if (all_gone) break;
            }
        }

        self.takeTerminal();
        return .{ .status = last_status, .signal = last_signal };
    }

    /// Copies well-known shell variables into `config`. Called after the
    /// configuration file runs and after every interactive command, so
    /// `let autosuggest = false` takes effect immediately.
    pub fn applyConfig(self: *Shell) void {
        if (self.getVar("prompt")) |v| {
            if (std.meta.activeTag(v) == .string) self.config.prompt = v.string;
        }
        if (self.getVar("git_prompt")) |v| self.config.git_prompt = v.truthy();
        if (self.getVar("autosuggest")) |v| self.config.autosuggest = v.truthy();
        if (self.getVar("highlight")) |v| self.config.highlight = v.truthy();
        if (self.getVar("completion")) |v| self.config.completion = v.truthy();
        if (self.getVar("history_limit")) |v| {
            if (v.asInt()) |n| {
                if (n > 0) {
                    self.config.history_limit = @intCast(n);
                    self.hist.limit = @intCast(n);
                }
            }
        }
    }

    /// Reaps finished and stopped background jobs without blocking.
    pub fn reapJobs(self: *Shell) void {
        for (self.jobs.jobs.items) |*job| {
            if (job.state == .done) continue;
            var any_stopped = false;

            for (job.pids, 0..) |*pid, idx| {
                if (pid.* == 0) continue;
                const st = proc.waitPid(pid.*, linux.W.NOHANG | linux.W.UNTRACED) orelse continue;
                switch (st.kind) {
                    .exited, .signaled => {
                        if (idx + 1 == job.pids.len) {
                            job.status = st.exitCode();
                            job.signal = if (st.kind == .signaled) st.sig else null;
                        }
                        pid.* = 0;
                    },
                    .stopped => {
                        any_stopped = true;
                        job.signal = st.sig;
                    },
                    .continued => {},
                }
            }

            var all_gone = true;
            for (job.pids) |pid| {
                if (pid != 0) {
                    all_gone = false;
                    break;
                }
            }
            if (all_gone) {
                job.state = .done;
            } else if (any_stopped) {
                job.state = .stopped;
            }
        }
    }

    /// Prints a line for every job that finished since the last call.
    pub fn notifyFinishedJobs(self: *Shell, fd: i32) void {
        for (self.jobs.jobs.items) |*job| {
            if (job.state != .done or job.notified) continue;
            job.notified = true;
            var buf: [512]u8 = undefined;
            const line = std.fmt.bufPrint(&buf, "[{d}] Done  {s}\n", .{ job.id, job.command }) catch continue;
            sys.writeStr(fd, line);
        }
    }
};

pub fn cloneValue(allocator: std.mem.Allocator, v: value.Value) !value.Value {
    return switch (v) {
        .string => |s| value.Value{ .string = try allocator.dupe(u8, s) },
        .list => |items| blk: {
            const out = try allocator.alloc(value.Value, items.len);
            for (items, 0..) |item, i| out[i] = try cloneValue(allocator, item);
            break :blk value.Value{ .list = out };
        },
        else => v,
    };
}

pub fn freeValue(allocator: std.mem.Allocator, v: value.Value) void {
    switch (v) {
        .string => |s| if (s.len != 0) allocator.free(s),
        .list => |items| {
            if (items.len == 0) return;
            for (items) |item| freeValue(allocator, item);
            allocator.free(items);
        },
        else => {},
    }
}

test "variables are deep-copied and freed" {
    const a = std.testing.allocator;
    var vars = std.StringHashMap(value.Value).init(a);
    defer {
        var it = vars.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            freeValue(a, e.value_ptr.*);
        }
        vars.deinit();
    }

    const source = try a.dupe(u8, "hello");
    const owned = try cloneValue(a, value.Value{ .string = source });
    try vars.put(try a.dupe(u8, "greeting"), owned);
    a.free(source);

    try std.testing.expectEqualStrings("hello", vars.get("greeting").?.string);
}
