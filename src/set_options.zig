//! The `set -o` option table, shared by `set`, `shopt -o` and `$SHELLOPTS`.

const std = @import("std");
const shellmod = @import("shell.zig");

const Options = shellmod.Options;

pub const Option = struct {
    name: []const u8,
    letter: u8 = 0,
    field: []const u8,
    /// `emacs` is the inverse of `vi`.
    inverted: bool = false,
};

/// Alphabetical, the order `set -o` lists them in.
pub const options = [_]Option{
    .{ .name = "allexport", .letter = 'a', .field = "allexport" },
    .{ .name = "braceexpand", .letter = 'B', .field = "braceexpand" },
    .{ .name = "emacs", .field = "emacs" },
    .{ .name = "errexit", .letter = 'e', .field = "errexit" },
    .{ .name = "errtrace", .letter = 'E', .field = "errtrace" },
    .{ .name = "functrace", .letter = 'T', .field = "functrace" },
    .{ .name = "hashall", .letter = 'h', .field = "hashall" },
    .{ .name = "histexpand", .letter = 'H', .field = "histexpand" },
    .{ .name = "history", .field = "history" },
    .{ .name = "ignoreeof", .field = "ignoreeof" },
    .{ .name = "interactive-comments", .field = "interactive_comments" },
    .{ .name = "keyword", .letter = 'k', .field = "keyword" },
    .{ .name = "monitor", .letter = 'm', .field = "monitor" },
    .{ .name = "noclobber", .letter = 'C', .field = "noclobber" },
    .{ .name = "noexec", .letter = 'n', .field = "noexec" },
    .{ .name = "noglob", .letter = 'f', .field = "noglob" },
    .{ .name = "nolog", .field = "nolog" },
    .{ .name = "notify", .letter = 'b', .field = "notify" },
    .{ .name = "nounset", .letter = 'u', .field = "nounset" },
    .{ .name = "onecmd", .letter = 't', .field = "onecmd" },
    .{ .name = "physical", .letter = 'P', .field = "physical" },
    .{ .name = "pipefail", .field = "pipefail" },
    .{ .name = "posix", .field = "posix" },
    .{ .name = "privileged", .letter = 'p', .field = "privileged" },
    .{ .name = "verbose", .letter = 'v', .field = "verbose" },
    .{ .name = "vi", .field = "vi" },
    .{ .name = "xtrace", .letter = 'x', .field = "xtrace" },
};

pub fn get(opts: *const Options, index: usize) bool {
    inline for (options, 0..) |option, i| {
        if (i == index) return @field(opts, option.field) != option.inverted;
    }
    unreachable;
}

pub fn put(opts: *Options, index: usize, on: bool) void {
    inline for (options, 0..) |option, i| {
        if (i == index) @field(opts, option.field) = on != option.inverted;
    }
    // The two editing modes exclude each other.
    if (on and std.mem.eql(u8, options[index].name, "vi")) opts.emacs = false;
    if (on and std.mem.eql(u8, options[index].name, "emacs")) opts.vi = false;
}

pub fn byName(name: []const u8) ?usize {
    for (options, 0..) |option, index| {
        if (std.mem.eql(u8, option.name, name)) return index;
    }
    return null;
}

pub fn byLetter(letter: u8) ?usize {
    for (options, 0..) |option, index| {
        if (option.letter == letter) return index;
    }
    return null;
}
