//! Aggregates the unit tests. `zig build test` runs this.

test {
    _ = @import("lexer.zig");
    _ = @import("parser.zig");
    _ = @import("value.zig");
    _ = @import("fs.zig");
    _ = @import("glob.zig");
    _ = @import("jobs.zig");
    _ = @import("proc.zig");
    _ = @import("command_cache.zig");
    _ = @import("fuzzy.zig");
    _ = @import("command_suggest.zig");
    _ = @import("history.zig");
    _ = @import("shell.zig");
    _ = @import("expand.zig");
    _ = @import("arith.zig");
    _ = @import("builtins.zig");
    _ = @import("builtins/cd.zig");
    _ = @import("builtins/set.zig");
    _ = @import("builtins/trap.zig");
    _ = @import("quote.zig");
    _ = @import("strict.zig");
    _ = @import("exec.zig");
    _ = @import("executor/assign.zig");
    _ = @import("executor/command.zig");
    _ = @import("executor/operations.zig");
    _ = @import("main.zig");
    _ = @import("login.zig");
    _ = @import("stdin_script.zig");
    _ = @import("interactive/editor.zig");
    _ = @import("interactive/prompt.zig");
    _ = @import("interactive/localtime.zig");
    _ = @import("interactive/session.zig");
}
