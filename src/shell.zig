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
const strict = @import("strict.zig");

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

/// Behaviour switches set by `set` and `shopt`; the executor and expander read
/// them.
pub const Options = struct {
    errexit: bool = false, // set -e
    nounset: bool = false, // set -u
    xtrace: bool = false, // set -x
    pipefail: bool = false, // set -o pipefail
    noglob: bool = false, // set -f
    noclobber: bool = false, // set -C
    allexport: bool = false, // set -a
    vi: bool = false, // set -o vi
    nullglob: bool = false, // shopt -s nullglob
    failglob: bool = false, // shopt -s failglob
    dotglob: bool = false, // shopt -s dotglob
    nocaseglob: bool = false, // shopt -s nocaseglob
    nocasematch: bool = false, // shopt -s nocasematch
    globstar: bool = true, // shopt -s globstar
    extglob: bool = true, // shopt -s extglob
    histexpand: bool = true, // set -H
    ignoreeof: bool = false, // set -o ignoreeof
    errtrace: bool = false, // set -E
};

/// Bit `N` is set when signal `N + 1` arrives. Written only from a signal
/// handler, which is why it is a lock-free atomic rather than shell state.
var trap_pending: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Handler installed for every trapped signal. Must stay async-signal-safe:
/// it only sets a bit for `Shell.runPendingTraps` to pick up later.
pub fn trapHandler(sig: linux.SIG) callconv(.c) void {
    const number = @intFromEnum(sig);
    if (number >= 1 and number <= Shell.max_signal) {
        _ = trap_pending.fetchOr(@as(u64, 1) << @intCast(number - 1), .monotonic);
    }
}

pub fn signalPending(sig: u32) bool {
    return trap_pending.load(.monotonic) & (@as(u64, 1) << @intCast(sig - 1)) != 0;
}

/// Forgets a caught signal that has not been handled yet.
pub fn discardPendingSignal(sig: u32) void {
    _ = trap_pending.fetchAnd(~(@as(u64, 1) << @intCast(sig - 1)), .monotonic);
}

pub const Shell = struct {
    gpa: std.mem.Allocator,

    vars: std.StringHashMap(value.Value),
    env: std.StringHashMap([]const u8),
    /// Function name -> source text of its `fn` declaration.
    funcs: std.StringHashMap([]const u8),
    aliases: std.StringHashMap([]const u8),
    /// Names locked by `readonly`; `setVar`/`setEnv` refuse to rebind them.
    readonly: std.StringHashMap(void),
    /// Saved bindings for nested `local` scopes, outermost frame first.
    scopes: std.ArrayList(Scope) = .empty,
    /// Trap handler source per trap id: `exit_trap`, the signal numbers, then
    /// the DEBUG, ERR and RETURN pseudo-signals. An empty handler ignores.
    traps: [trap_count]?[]const u8 = [_]?[]const u8{null} ** trap_count,
    /// Runs a trap handler's source; installed by `exec.zig` (see `install`).
    trap_runner: ?*const fn (*Shell, []const u8) u8 = null,
    /// Directories saved by `pushd`; index 0 is the most recent.
    dir_stack: std.ArrayList([]const u8) = .empty,

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
    /// Set when an interactive `exit` was refused because jobs are stopped;
    /// an immediately repeated `exit` or Ctrl-D then leaves anyway.
    exit_warned: bool = false,

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
    /// The allocation behind `positional` when `set --` created it; each
    /// function call or `source` saves and restores its own.
    positional_owned: ?[]const []const u8 = null,
    /// `$0`.
    script_name: []const u8 = "",

    line_arena: std.heap.ArenaAllocator,

    config: Config = .{},
    options: Options = .{},
    /// Source line of the statement being executed, for `$LINENO`.
    current_line: u32 = 0,
    /// Non-zero while running a condition: an `if`/`while`/`until` test, a
    /// non-final part of an `&&`/`||` list, or a `!` pipeline. `set -e` and the
    /// ERR trap do not fire there.
    condition_depth: u32 = 0,
    /// Set when Ctrl-C interrupts the running command line. Statement lists and
    /// loops stop while it is set; the REPL clears it before the next prompt.
    interrupted: bool = false,
    hostname: []const u8 = "",
    history_path: []const u8 = "",
    config_path: []const u8 = "",

    subst_runner: ?SubstFn = null,
    /// Status of the most recent command substitution, so `x=$(cmd)` can
    /// report it.
    subst_status: ?u8 = null,

    pub const max_call_depth = 256;
    pub const max_signal = 64;
    pub const exit_trap: u32 = 0;
    pub const debug_trap: u32 = max_signal + 1;
    pub const err_trap: u32 = max_signal + 2;
    pub const return_trap: u32 = max_signal + 3;
    pub const trap_count = max_signal + 4;
    pub const max_dirs = 32;

    /// One `local` scope: the bindings it shadowed, innermost last.
    pub const Scope = struct {
        saved: std.ArrayList(SavedVar) = .empty,
    };

    pub const SavedVar = struct {
        name: []const u8,
        was_set: bool,
        previous: value.Value = .none,
    };

    fn blank(gpa: std.mem.Allocator) Shell {
        return .{
            .gpa = gpa,
            .vars = std.StringHashMap(value.Value).init(gpa),
            .env = std.StringHashMap([]const u8).init(gpa),
            .funcs = std.StringHashMap([]const u8).init(gpa),
            .aliases = std.StringHashMap([]const u8).init(gpa),
            .readonly = std.StringHashMap(void).init(gpa),
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

        var rit = self.readonly.iterator();
        while (rit.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.readonly.deinit();

        for (self.scopes.items) |*scope| {
            for (scope.saved.items) |saved| {
                self.gpa.free(saved.name);
                freeValue(self.gpa, saved.previous);
            }
            scope.saved.deinit(self.gpa);
        }
        self.scopes.deinit(self.gpa);

        for (self.traps) |maybe| {
            if (maybe) |text| self.gpa.free(text);
        }
        self.freeOwnedPositional();

        for (self.dir_stack.items) |dir| self.gpa.free(dir);
        self.dir_stack.deinit(self.gpa);

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
        if (self.isReadonly(name)) return false;
        if (self.vars.fetchRemove(name)) |kv| {
            self.gpa.free(kv.key);
            freeValue(self.gpa, kv.value);
            return true;
        }
        return false;
    }

    // --- readonly -----------------------------------------------------------

    pub fn markReadonly(self: *Shell, name: []const u8) !void {
        if (self.readonly.contains(name)) return;
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        try self.readonly.put(owned, {});
    }

    pub fn isReadonly(self: *const Shell, name: []const u8) bool {
        return self.readonly.contains(name);
    }

    /// `setVar` for a name the user asked for: refuses a `readonly` binding.
    /// Builtins use this; the internal assignment paths do not, so restoring a
    /// shadowed binding still works.
    pub fn assignVar(self: *Shell, name: []const u8, val: value.Value) !void {
        if (self.isReadonly(name)) return error.ReadonlyVariable;
        return self.setVar(name, val);
    }

    /// `setEnv` counterpart of `assignVar`.
    pub fn assignEnv(self: *Shell, name: []const u8, val: []const u8) !void {
        if (self.isReadonly(name)) return error.ReadonlyVariable;
        return self.setEnv(name, val);
    }

    // --- local scopes -------------------------------------------------------

    /// Pushes a scope for `local`. The function executor calls this on entry to
    /// a function body and `endScope` on the way out.
    pub fn beginScope(self: *Shell) !void {
        try self.scopes.append(self.gpa, .{});
    }

    /// Restores every binding the innermost scope shadowed.
    pub fn endScope(self: *Shell) void {
        if (self.scopes.items.len == 0) return;
        var scope = self.scopes.pop().?;
        while (scope.saved.pop()) |saved| {
            if (saved.was_set) {
                self.setVar(saved.name, saved.previous) catch {};
            } else if (self.vars.fetchRemove(saved.name)) |kv| {
                self.gpa.free(kv.key);
                freeValue(self.gpa, kv.value);
            }
            self.gpa.free(saved.name);
            freeValue(self.gpa, saved.previous);
        }
        scope.saved.deinit(self.gpa);
    }

    /// `local name=value`: remembers the enclosing binding, then assigns.
    pub fn setLocal(self: *Shell, name: []const u8, val: value.Value) !void {
        if (self.scopes.items.len != 0) try self.rememberLocal(name);
        try self.setVar(name, val);
    }

    fn rememberLocal(self: *Shell, name: []const u8) !void {
        const scope = &self.scopes.items[self.scopes.items.len - 1];
        for (scope.saved.items) |saved| {
            if (std.mem.eql(u8, saved.name, name)) return;
        }
        const owned = try self.gpa.dupe(u8, name);
        errdefer self.gpa.free(owned);
        const previous = self.getVar(name);
        const copy = if (previous) |v| try cloneValue(self.gpa, v) else value.Value.none;
        errdefer if (previous != null) freeValue(self.gpa, copy);
        try scope.saved.append(self.gpa, .{
            .name = owned,
            .was_set = previous != null,
            .previous = copy,
        });
    }

    // --- traps --------------------------------------------------------------

    /// `id` is a signal number or one of `exit_trap`, `debug_trap`,
    /// `err_trap` and `return_trap`.
    pub fn setTrap(self: *Shell, id: u32, handler: []const u8) !void {
        if (id >= trap_count) return error.InvalidSignal;
        self.putTrap(id, try self.gpa.dupe(u8, handler));
    }

    pub fn getTrap(self: *const Shell, id: u32) ?[]const u8 {
        if (id >= trap_count) return null;
        return self.traps[id];
    }

    pub fn clearTrap(self: *Shell, id: u32) bool {
        const old = self.takeTrap(id) orelse return false;
        self.gpa.free(old);
        return true;
    }

    /// Removes a handler and hands its ownership to the caller.
    pub fn takeTrap(self: *Shell, id: u32) ?[]const u8 {
        if (id >= trap_count) return null;
        const old = self.traps[id];
        self.traps[id] = null;
        return old;
    }

    /// Installs a handler the shell's allocator already owns.
    pub fn putTrap(self: *Shell, id: u32, owned: []const u8) void {
        std.debug.assert(id < trap_count);
        if (self.traps[id]) |old| self.gpa.free(old);
        self.traps[id] = owned;
    }

    /// Runs handlers for signals caught since the last call. Safe to call
    /// between statements.
    pub fn runPendingTraps(self: *Shell) void {
        const bits = trap_pending.swap(0, .monotonic);
        if (bits == 0) return;
        var sig: u32 = 1;
        while (sig <= max_signal) : (sig += 1) {
            const bit: u6 = @intCast(sig - 1);
            if ((bits >> bit) & 1 == 0) continue;
            strict.signalArrived(self, sig);
        }
    }

    // --- positional parameters ----------------------------------------------

    /// `set -- args`: replaces the positional parameters with copies the
    /// shell owns, so they outlive the command line that set them.
    pub fn setPositional(self: *Shell, args: []const []const u8) !void {
        const items = try self.gpa.alloc([]const u8, args.len);
        var copied: usize = 0;
        errdefer {
            for (items[0..copied]) |item| self.gpa.free(item);
            self.gpa.free(items);
        }
        for (args, 0..) |arg, index| {
            items[index] = try self.gpa.dupe(u8, arg);
            copied = index + 1;
        }
        self.freeOwnedPositional();
        self.positional_owned = items;
        self.positional = items;
    }

    pub const SavedPositional = struct {
        positional: []const []const u8,
        owned: ?[]const []const u8,
    };

    /// Gives a function call or `source` its own positional parameters.
    pub fn pushPositional(self: *Shell, args: []const []const u8) SavedPositional {
        const saved = SavedPositional{ .positional = self.positional, .owned = self.positional_owned };
        self.positional = args;
        self.positional_owned = null;
        return saved;
    }

    pub fn popPositional(self: *Shell, saved: SavedPositional) void {
        self.freeOwnedPositional();
        self.positional = saved.positional;
        self.positional_owned = saved.owned;
    }

    fn freeOwnedPositional(self: *Shell) void {
        const items = self.positional_owned orelse return;
        for (items) |item| self.gpa.free(item);
        self.gpa.free(items);
        self.positional_owned = null;
    }

    // --- directory stack ----------------------------------------------------

    /// `pushd <dir>`: remembers the current directory, then changes to `dir`.
    pub fn pushDir(self: *Shell, path: [:0]const u8) !bool {
        const previous = (try fs.getCwd(self.gpa)) orelse (try self.gpa.dupe(u8, self.cwd));
        errdefer self.gpa.free(previous);
        if (!try self.setCwd(path)) {
            self.gpa.free(previous);
            return false;
        }
        if (self.dir_stack.items.len >= max_dirs) {
            const oldest = self.dir_stack.orderedRemove(self.dir_stack.items.len - 1);
            self.gpa.free(oldest);
        }
        try self.dir_stack.insert(self.gpa, 0, previous);
        return true;
    }

    /// `pushd` with no argument: swaps the current directory with the top.
    pub fn swapDirs(self: *Shell) !bool {
        if (self.dir_stack.items.len == 0) return false;
        const top = self.dir_stack.items[0];
        const z = try self.gpa.dupeZ(u8, top);
        defer self.gpa.free(z);
        const previous = (try fs.getCwd(self.gpa)) orelse (try self.gpa.dupe(u8, self.cwd));
        errdefer self.gpa.free(previous);
        if (!try self.setCwd(z)) {
            self.gpa.free(previous);
            return false;
        }
        self.gpa.free(self.dir_stack.items[0]);
        self.dir_stack.items[0] = previous;
        return true;
    }

    /// `popd`: drops the top of the stack and changes to it.
    pub fn popDir(self: *Shell) !bool {
        if (self.dir_stack.items.len == 0) return false;
        const top = self.dir_stack.orderedRemove(0);
        defer self.gpa.free(top);
        const z = try self.gpa.dupeZ(u8, top);
        defer self.gpa.free(z);
        return self.setCwd(z);
    }

    /// Replaces a leading `$HOME` with `~`, for `dirs` and the prompt.
    pub fn shortenHome(self: *const Shell, arena: std.mem.Allocator, path: []const u8) ![]const u8 {
        const home = self.getEnv("HOME") orelse return path;
        if (home.len == 0) return path;
        if (std.mem.eql(u8, path, home)) return "~";
        if (path.len > home.len and std.mem.startsWith(u8, path, home) and path[home.len] == '/') {
            return std.fmt.allocPrint(arena, "~{s}", .{path[home.len..]});
        }
        return path;
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
            const pair = try std.fmt.allocPrintSentinel(arena, "{s}={s}", .{
                entry.key_ptr.*,
                entry.value_ptr.*,
            }, 0);
            arr[i] = pair.ptr;
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
        return self.waitForegroundStages(job, null);
    }

    /// `waitForeground` that also records each process's status, in pipeline
    /// order, for PIPESTATUS and `set -o pipefail`.
    pub fn waitForegroundStages(self: *Shell, job: *jobs.Job, statuses: ?[]u8) WaitOutcome {
        self.giveTerminal(job.pgid);

        var last_status: u8 = job.status;
        var last_signal: ?u32 = job.signal;
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
                        if (statuses) |out| {
                            if (idx < out.len) out[idx] = st.exitCode();
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
                const status = 128 +% @as(u8, @intCast(@min(sig, 127)));
                if (statuses) |out| {
                    for (job.pids, 0..) |pid, idx| {
                        if (pid != 0 and idx < out.len) out[idx] = status;
                    }
                }
                return .{
                    .status = status,
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

    /// Block in the kernel until a child changes state, preserving statuses
    /// for jobs other than the one a caller is waiting for.
    pub fn waitJobEvent(self: *Shell) bool {
        const event = proc.waitAny(linux.W.UNTRACED | linux.W.CONTINUED) orelse return false;
        for (self.jobs.jobs.items) |*job| {
            for (job.pids, 0..) |*pid, index| {
                if (pid.* != event.pid) continue;
                const status = event.status;
                switch (status.kind) {
                    .exited, .signaled => {
                        if (index + 1 == job.pids.len) {
                            job.status = status.exitCode();
                            job.signal = if (status.kind == .signaled) status.sig else null;
                        }
                        pid.* = 0;
                        var alive = false;
                        for (job.pids) |candidate| {
                            if (candidate != 0) alive = true;
                        }
                        if (!alive) job.state = .done;
                    },
                    .stopped => {
                        job.state = .stopped;
                        job.signal = status.sig;
                    },
                    .continued => job.state = .running,
                }
                return true;
            }
        }
        return true;
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

test "local scopes restore shadowed bindings" {
    const a = std.testing.allocator;
    var sh = try Shell.initBare(a);
    defer sh.deinit();

    try sh.setVar("x", .{ .string = "outer" });
    try sh.beginScope();
    try sh.setLocal("x", .{ .string = "inner" });
    try sh.setLocal("y", .{ .string = "fresh" });
    try std.testing.expectEqualStrings("inner", sh.getVar("x").?.string);
    try std.testing.expectEqualStrings("fresh", sh.getVar("y").?.string);
    sh.endScope();

    try std.testing.expectEqualStrings("outer", sh.getVar("x").?.string);
    try std.testing.expect(sh.getVar("y") == null);
}

test "readonly names reject writes and removal" {
    const a = std.testing.allocator;
    var sh = try Shell.initBare(a);
    defer sh.deinit();

    try sh.setVar("locked", .{ .string = "kept" });
    try sh.markReadonly("locked");
    try std.testing.expectError(error.ReadonlyVariable, sh.assignVar("locked", .{ .string = "no" }));
    try std.testing.expectError(error.ReadonlyVariable, sh.assignEnv("locked", "no"));
    try std.testing.expect(!sh.unsetVar("locked"));
    try std.testing.expectEqualStrings("kept", sh.getVar("locked").?.string);
}

test "traps are stored and cleared by signal number" {
    const a = std.testing.allocator;
    var sh = try Shell.initBare(a);
    defer sh.deinit();

    try sh.setTrap(2, "echo interrupted");
    try std.testing.expectEqualStrings("echo interrupted", sh.getTrap(2).?);
    try std.testing.expect(sh.clearTrap(2));
    try std.testing.expect(sh.getTrap(2) == null);
    try sh.setTrap(Shell.exit_trap, "echo bye");
    const taken = sh.takeTrap(Shell.exit_trap).?;
    defer a.free(taken);
    try std.testing.expectEqualStrings("echo bye", taken);
    try std.testing.expect(sh.getTrap(Shell.exit_trap) == null);
    try std.testing.expectError(error.InvalidSignal, sh.setTrap(Shell.trap_count, "x"));
}

test "set -- positional parameters are owned and restored around calls" {
    const a = std.testing.allocator;
    var sh = try Shell.initBare(a);
    defer sh.deinit();

    try sh.setPositional(&.{ "a", "b" });
    const saved = sh.pushPositional(&.{"call"});
    try sh.setPositional(&.{"inner"});
    try std.testing.expectEqualStrings("inner", sh.positional[0]);
    sh.popPositional(saved);
    try std.testing.expectEqual(@as(usize, 2), sh.positional.len);
    try std.testing.expectEqualStrings("b", sh.positional[1]);
    try sh.setPositional(&.{});
    try std.testing.expectEqual(@as(usize, 0), sh.positional.len);
}

test "shortenHome collapses the home prefix" {
    const a = std.testing.allocator;
    var sh = try Shell.initBare(a);
    defer sh.deinit();
    try sh.setEnv("HOME", "/home/dev");

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("~", try sh.shortenHome(arena, "/home/dev"));
    try std.testing.expectEqualStrings("~/src", try sh.shortenHome(arena, "/home/dev/src"));
    try std.testing.expectEqualStrings("/home/devother", try sh.shortenHome(arena, "/home/devother"));
}
