//! `help [-ds] [pattern ...]`: the language overview and builtin reference.

const std = @import("std");
const builtins = @import("../builtins.zig");
const options = @import("options.zig");
const describe = @import("describe.zig");

const Ctx = builtins.Ctx;

const overview =
    \\wolysh language overview
    \\
    \\  let name = "value"             bind a variable
    \\  env PATH += "/opt/bin"         change the environment
    \\  if count > 10 { ... } else { ... }
    \\  for f in src/*.zig { ... }
    \\  while n < 10 { let n = n + 1 }
    \\  fn build(mode = "debug") { zig build -Doptimize=$mode }
    \\  cmd1 | cmd2 && cmd3 || cmd4    pipelines and lists
    \\  (cd /tmp; pwd)                 run in a subshell
    \\  { cmd; cmd; } > file           group in the current shell
    \\  cmd 2>&1 > out <<< "input"     redirections
    \\
    \\Type `help NAME` for one builtin, `help -s NAME` for its synopsis. The full
    \\guide is docs/language.md in the wolysh repository.
    \\
    \\Builtins:
    \\
;

/// Synopses; a builtin without one prints only its summary.
const synopses = [_]struct { []const u8, []const u8 }{
    .{ ":", ": [arguments]" },
    .{ ".", ". file [arguments]" },
    .{ "source", "source file [arguments]" },
    .{ "eval", "eval [arg ...]" },
    .{ "cd", "cd [dir]" },
    .{ "pwd", "pwd" },
    .{ "pushd", "pushd [-n] [+N | -N | dir]" },
    .{ "popd", "popd [-n] [+N | -N]" },
    .{ "dirs", "dirs [-clpv] [+N] [-N]" },
    .{ "echo", "echo [-neE] [arg ...]" },
    .{ "print", "print [-neE] [arg ...]" },
    .{ "printf", "printf [-v var] format [arguments]" },
    .{ "exit", "exit [n]" },
    .{ "logout", "logout [n]" },
    .{ "export", "export [-n] [name[=value] ...] or export -p" },
    .{ "unset", "unset [name ...]" },
    .{ "readonly", "readonly [name[=value] ...] or readonly -p" },
    .{ "local", "local name[=value] ..." },
    .{ "alias", "alias [-p] [name[=value] ...]" },
    .{ "unalias", "unalias [-a] name [name ...]" },
    .{ "jobs", "jobs [-lprs] [jobspec ...]" },
    .{ "disown", "disown [-h] [-ar] [jobspec ... | pid ...]" },
    .{ "fg", "fg [jobspec]" },
    .{ "bg", "bg [jobspec]" },
    .{ "wait", "wait [-n] [id ...]" },
    .{ "kill", "kill [-s sigspec | -sigspec] pid | jobspec ..." },
    .{ "trap", "trap [-p] [[handler] signal ...]" },
    .{ "read", "read [-rs] [-a array] [-d delim] [-n nchars] [-N nchars] [-p prompt] [-t timeout] [-u fd] [name ...]" },
    .{ "mapfile", "mapfile [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]" },
    .{ "readarray", "readarray [-d delim] [-n count] [-O origin] [-s count] [-t] [-u fd] [-C callback] [-c quantum] [array]" },
    .{ "getopts", "getopts optstring name [arg ...]" },
    .{ "type", "type [-afptP] name [name ...]" },
    .{ "command", "command [-pVv] command [arg ...]" },
    .{ "builtin", "builtin shell-builtin [arg ...]" },
    .{ "hash", "hash [-lr] [-dt] [name ...]" },
    .{ "help", "help [-ds] [pattern ...]" },
    .{ "shift", "shift [n]" },
    .{ "umask", "umask [-p] [-S] [mode]" },
    .{ "ulimit", "ulimit [-SHacdefilmnpqrstuvx] [limit]" },
    .{ "times", "times" },
    .{ "exec", "exec [command [arg ...]]" },
    .{ "test", "test [expr]" },
    .{ "[", "[ arg... ]" },
    .{ "history", "history [n | clear]" },
    .{ "which", "which name [name ...]" },
    .{ "parallel", "parallel [-j N] [--fail-fast] [--report file] command ..." },
};

/// Summaries for the builtins the executor runs itself.
const executor_summaries = [_]struct { []const u8, []const u8 }{
    .{ "source", "run a file in the current shell" },
    .{ ".", "run a file in the current shell" },
    .{ "eval", "run arguments as a command line" },
};

fn synopsis(name: []const u8) ?[]const u8 {
    for (synopses) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

const Topic = struct { name: []const u8, summary: []const u8 };

fn forEachTopic(context: anytype, comptime visit: fn (@TypeOf(context), Topic) void) void {
    for (builtins.all()) |b| visit(context, .{ .name = b.name, .summary = b.summary });
    for (executor_summaries) |entry| visit(context, .{ .name = entry[0], .summary = entry[1] });
}

/// `*` and `?` wildcards, enough for `help 'r*'`.
fn wildcard(pattern: []const u8, name: []const u8) bool {
    if (pattern.len == 0) return name.len == 0;
    return switch (pattern[0]) {
        '*' => wildcard(pattern[1..], name) or (name.len != 0 and wildcard(pattern, name[1..])),
        '?' => name.len != 0 and wildcard(pattern[1..], name[1..]),
        else => name.len != 0 and name[0] == pattern[0] and wildcard(pattern[1..], name[1..]),
    };
}

const Style = enum { full, short, description };

const Query = struct {
    ctx: Ctx,
    pattern: []const u8,
    style: Style,
    matched: bool = false,
};

fn showTopic(query: *Query, topic: Topic) void {
    if (!wildcard(query.pattern, topic.name)) return;
    query.matched = true;
    const ctx = query.ctx;
    const usage = synopsis(topic.name) orelse topic.name;
    switch (query.style) {
        .short => ctx.outFmt("{s}: {s}\n", .{ topic.name, usage }),
        .description => ctx.outFmt("{s} - {s}\n", .{ topic.name, topic.summary }),
        .full => ctx.outFmt("{s}: {s}\n    {s}\n", .{ topic.name, usage, topic.summary }),
    }
}

fn listTopic(ctx: Ctx, topic: Topic) void {
    ctx.outFmt("  {s: <12}{s}\n", .{ topic.name, topic.summary });
}

pub fn run(ctx: Ctx) u8 {
    var style = Style.full;
    var parser = options.Parser.init(ctx.argv, "dms");
    while (true) {
        switch (parser.next()) {
            .end => break,
            .invalid, .missing => |c| {
                ctx.errFmt("wsh: help: -{c}: invalid option\n", .{c});
                ctx.err("wsh: help: usage: help [-ds] [pattern ...]\n");
                return 2;
            },
            .option => |c| switch (c) {
                'd' => style = .description,
                's' => style = .short,
                'm' => style = .full,
                else => unreachable,
            },
        }
    }

    const patterns = parser.rest();
    if (patterns.len == 0) {
        ctx.out(overview);
        forEachTopic(ctx, listTopic);
        ctx.out("\nKeywords: ");
        for (describe.keywords, 0..) |word, i| {
            if (i != 0) ctx.out(" ");
            ctx.out(word);
        }
        ctx.out("\n");
        return 0;
    }

    var status: u8 = 0;
    for (patterns) |pattern| {
        var query = Query{ .ctx = ctx, .pattern = pattern, .style = style };
        forEachTopic(&query, showTopic);
        if (!query.matched and describe.isKeyword(pattern)) {
            query.matched = true;
            ctx.outFmt("{s}: shell keyword; see `help` for the language overview\n", .{pattern});
        }
        if (!query.matched) {
            ctx.errFmt("wsh: help: no help topics match `{s}'\n", .{pattern});
            status = 1;
        }
    }
    return status;
}

test "wildcards match help topics" {
    try std.testing.expect(wildcard("r*", "readarray"));
    try std.testing.expect(wildcard("?d", "cd"));
    try std.testing.expect(!wildcard("r*", "printf"));
}
