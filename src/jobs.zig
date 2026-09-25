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
};

pub const Table = struct {
    jobs: std.ArrayList(Job) = .empty,
    next_id: u32 = 1,

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
        try self.jobs.append(allocator, .{
            .id = self.next_id,
            .pgid = pgid,
            .pids = owned_pids,
            .state = .running,
            .command = owned_command,
            .foreground = foreground,
        });
        self.next_id += 1;
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
