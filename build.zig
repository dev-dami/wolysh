const std = @import("std");

/// Single source of truth for the version string; keep in step with
/// `build.zig.zon`.
const version = "0.3.0";

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    // Not `single_threaded`: wolysh never starts a thread, but it does use
    // `std.heap.smp_allocator`, which is compiled out of single-threaded builds.
    const exe = b.addExecutable(.{
        .name = "wsh",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize != .Debug,
        }),
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run wolysh").dependOn(&run_cmd.step);

    // `-Dtest-filter=name` narrows the run, like `zig test --test-filter`.
    // The slice must be built before the step is created: assigning a stack
    // temporary to `filters` afterwards leaves it dangling.
    const test_filters: []const []const u8 = if (b.option(
        []const u8,
        "test-filter",
        "only run tests whose name contains this",
    )) |filter| blk: {
        const one = b.allocator.alloc([]const u8, 1) catch @panic("out of memory");
        one[0] = filter;
        break :blk one;
    } else &.{};

    const unit_tests = b.addTest(.{
        .filters = test_filters,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    unit_tests.root_module.addOptions("build_options", options);
    // Executed as a plain process rather than through `addRunArtifact`.
    //
    // `addRunArtifact` drives the test binary with the build runner's
    // listen-mode protocol, which this test suite deadlocks: the binary blocks
    // reading its command pipe after the last test while the build runner waits
    // on a futex. `zig test src/tests.zig` and running the binary directly both
    // pass, so the tests themselves are fine; invoking it plainly avoids the
    // protocol entirely. `sh -c 'exec "$0"' <binary>` is just "run this file".
    const run_unit_tests = b.addSystemCommand(&.{ "sh", "-c", "exec \"$0\"" });
    run_unit_tests.addArtifactArg(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    // ReleaseSmall "tiny" build target, for the size budget.
    const small = b.addExecutable(.{
        .name = "wsh-small",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
            .strip = true,
        }),
    });
    small.root_module.addOptions("build_options", options);
    b.step("small", "Build a size-optimized binary").dependOn(&b.addInstallArtifact(small, .{}).step);

    // `zig fmt --check` over the sources; also the gate CI runs.
    const fmt_check = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check" });
    fmt_check.setCwd(b.path("."));
    fmt_check.addArgs(&.{ "src", "build.zig", "build.zig.zon" });
    const fmt_step = b.step("fmt", "Check formatting with `zig fmt --check`");
    fmt_step.dependOn(&fmt_check.step);

    const check_step = b.step("check", "Check formatting and run unit tests");
    check_step.dependOn(&fmt_check.step);
    check_step.dependOn(test_step);
}
