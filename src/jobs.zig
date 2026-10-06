//! Job table for wolysh.

const std = @import("std");

pub const State = enum {
    running,
    stopped,
    done,

    pub fn label(self: State) []const u8 {
        return switch (self) {
            .running => "Running",
            .stopped => "Stopped",
            .done => "Done",
        };
    }
};

pub const Job = struct {
    /// The number the user types as `%1`.
    id: u32,
    /// Process group of the whole pipeline.
    pgid: i32,
    /// Every process in the pipeline, in pipeline order.
    pids: []i32,
    /// Retained after reaping so `wait $!` can consume a completed job.
    last_pid: i32,
    state: State,
    /// Exit status of the last process in the pipeline.
    status: u8 = 0,
    /// Signal that killed or stopped the job, when applicable.
    signal: ?u32 = null,
    /// Original command text, shown by `jobs`.
    command: []const u8,
    foreground: bool = false,
    /// Set once the user has been told the job finished.
    notified: bool = false,
    /// True while this job owns the terminal.
    owns_terminal: bool = false,
    /// Set by `disown -h`: the shell does not forward SIGHUP to this job.
    no_hup: bool = false,
};

pub const Table = struct {
    jobs: std.ArrayList(Job) = .empty,

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.jobs.items) |job| {
            allocator.free(job.pids);
            allocator.free(job.command);
        }
        self.jobs.deinit(allocator);
    }

    pub fn count(self: *const Table) usize {
        return self.jobs.items.len;
    }

    pub fn add(
        self: *Table,
        allocator: std.mem.Allocator,
        pgid: i32,
        pids: []const i32,
        command: []const u8,
        foreground: bool,
    ) std.mem.Allocator.Error!*Job {
        const owned_pids = try allocator.dupe(i32, pids);
        errdefer allocator.free(owned_pids);
        const owned_command = try allocator.dupe(u8, command);
        errdefer allocator.free(owned_command);
        // Like bash: one past the highest live job number, so numbers are
        // reused once earlier jobs finish.
        var id: u32 = 1;
        for (self.jobs.items) |job| id = @max(id, job.id + 1);
        try self.jobs.append(allocator, .{
            .id = id,
            .pgid = pgid,
            .pids = owned_pids,
            .last_pid = if (pids.len != 0) pids[pids.len - 1] else 0,
            .state = .running,
            .command = owned_command,
            .foreground = foreground,
        });
        return &self.jobs.items[self.jobs.items.len - 1];
    }

    pub fn findByPgid(self: *Table, pgid: i32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.pgid == pgid) return job;
        }
        return null;
    }

    pub fn findById(self: *Table, id: u32) ?*Job {
        for (self.jobs.items) |*job| {
            if (job.id == id) return job;
        }
        return null;
    }

    pub fn findByCommandPrefix(self: *Table, prefix: []const u8) ?*Job {
        for (self.jobs.items) |*job| {
            if (std.mem.startsWith(u8, job.command, prefix)) return job;
        }
        return null;
    }

    pub fn indexOf(self: *Table, job: *const Job) ?usize {
        for (self.jobs.items, 0..) |*j, i| {
            if (j == job) return i;
        }
        return null;
    }

    pub fn removeAt(self: *Table, allocator: std.mem.Allocator, index: usize) void {
        allocator.free(self.jobs.items[index].pids);
        allocator.free(self.jobs.items[index].command);
        _ = self.jobs.orderedRemove(index);
    }

    /// Drops jobs that finished and have already been reported.
    pub fn sweep(self: *Table, allocator: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.jobs.items.len) {
            const job = &self.jobs.items[i];
            if (job.state == .done and job.notified) {
                allocator.free(job.pids);
                allocator.free(job.command);
                _ = self.jobs.orderedRemove(i);
                continue;
            }
            i += 1;
        }
    }

    /// The most recently added job, which is what a bare `fg`/`bg` targets.
    pub fn mostRecent(self: *Table) ?*Job {
        if (self.jobs.items.len == 0) return null;
        return &self.jobs.items[self.jobs.items.len - 1];
    }

    /// The job `fg`/`bg` act on by default (`%+`): the most recent job that
    /// has not finished.
    pub fn current(self: *Table) ?*Job {
        var index = self.jobs.items.len;
        while (index > 0) {
            index -= 1;
            if (self.jobs.items[index].state != .done) return &self.jobs.items[index];
        }
        return null;
    }

    /// The job before the current one (`%-`).
    pub fn previous(self: *Table) ?*Job {
        const top = self.current() orelse return null;
        var index = self.indexOf(top).?;
        while (index > 0) {
            index -= 1;
            if (self.jobs.items[index].state != .done) return &self.jobs.items[index];
        }
        return null;
    }

    pub const Lookup = union(enum) {
        found: *Job,
        none,
        /// More than one job matches a `%name` or `%?text` spec.
        ambiguous,
    };

    /// Resolves a job spec: `%N`, `%+`/`%%`/`%`, `%-`, `%name` (command
    /// prefix) and `%?text` (command substring). The leading `%` is optional
    /// for a number or a prefix.
    pub fn lookup(self: *Table, spec: []const u8) Lookup {
        if (spec.len == 0 or std.mem.eql(u8, spec, "%") or std.mem.eql(u8, spec, "%%") or std.mem.eql(u8, spec, "%+")) {
            return if (self.current()) |job| .{ .found = job } else .none;
        }
        if (std.mem.eql(u8, spec, "%-")) {
            return if (self.previous()) |job| .{ .found = job } else .none;
        }
        const bare = if (spec[0] == '%') spec[1..] else spec;
        if (std.fmt.parseInt(u32, bare, 10)) |id| {
            return if (self.findById(id)) |job| .{ .found = job } else .none;
        } else |_| {}
        const substring = bare.len != 0 and bare[0] == '?';
        const needle = if (substring) bare[1..] else bare;
        var match: ?*Job = null;
        for (self.jobs.items) |*job| {
            const hit = if (substring)
                std.mem.indexOf(u8, job.command, needle) != null
            else
                std.mem.startsWith(u8, job.command, needle);
            if (!hit) continue;
            if (match != null) return .ambiguous;
            match = job;
        }
        return if (match) |job| .{ .found = job } else .none;
    }

    pub fn hasRunning(self: *const Table) bool {
        for (self.jobs.items) |job| {
            if (job.state != .done) return true;
        }
        return false;
    }

    pub fn runningCount(self: *const Table) usize {
        var n: usize = 0;
        for (self.jobs.items) |job| {
            if (job.state != .done) n += 1;
        }
        return n;
    }
};

test "table add and lookup" {
    const a = std.testing.allocator;
    var table = Table{};
    defer table.deinit(a);

    const job = try table.add(a, 100, &.{ 100, 101 }, "sleep 10", false);
    try std.testing.expectEqual(@as(u32, 1), job.id);
    try std.testing.expectEqual(@as(i32, 100), job.pgid);
    try std.testing.expectEqual(@as(usize, 2), job.pids.len);
    try std.testing.expect(table.findByPgid(100) != null);
    try std.testing.expect(table.findById(1) != null);
    try std.testing.expect(table.findByCommandPrefix("sleep") != null);
    try std.testing.expect(table.hasRunning());

    job.state = .done;
    job.notified = true;
    table.sweep(a);
    try std.testing.expectEqual(@as(usize, 0), table.count());
}

test "job specs resolve current, previous, prefixes and substrings" {
    const a = std.testing.allocator;
    var table = Table{};
    defer table.deinit(a);

    _ = try table.add(a, 10, &.{10}, "sleep 5", false);
    _ = try table.add(a, 20, &.{20}, "sleep 6 | cat", false);
    _ = try table.add(a, 30, &.{30}, "vim notes", false);

    try std.testing.expectEqual(@as(u32, 3), table.lookup("%+").found.id);
    try std.testing.expectEqual(@as(u32, 3), table.lookup("%%").found.id);
    try std.testing.expectEqual(@as(u32, 2), table.lookup("%-").found.id);
    try std.testing.expectEqual(@as(u32, 1), table.lookup("%1").found.id);
    try std.testing.expectEqual(@as(u32, 3), table.lookup("%vim").found.id);
    try std.testing.expectEqual(@as(u32, 2), table.lookup("%?cat").found.id);
    try std.testing.expect(table.lookup("%sle") == .ambiguous);
    try std.testing.expect(table.lookup("%9") == .none);

    table.findById(3).?.state = .done;
    try std.testing.expectEqual(@as(u32, 2), table.current().?.id);
    try std.testing.expectEqual(@as(u32, 1), table.previous().?.id);
}
