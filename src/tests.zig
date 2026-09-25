//! Aggregates the unit tests. `zig build test` runs this.

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("value.zig");
    _ = @import("fs.zig");
    _ = @import("glob.zig");
    _ = @import("jobs.zig");
    _ = @import("proc.zig");
    _ = @import("history.zig");
    _ = @import("shell.zig");
    _ = @import("expand.zig");
    _ = @import("builtins.zig");
    _ = @import("exec.zig");
}
