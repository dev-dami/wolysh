//! Option parsing for builtins, following bash's `internal_getopt`: flags may
//! be bundled (`-rs`), an option argument may be attached (`-n1`, `-d:`) or
//! the next word, `--` ends the options and so does any word that is not an
//! option (including a lone `-`).

const std = @import("std");

pub const Result = union(enum) {
    option: u8,
    /// No more options; operands start at `Parser.index`.
    end,
    invalid: u8,
    /// The option needs an argument and none was given.
    missing: u8,
};

pub const Parser = struct {
    argv: []const []const u8,
    /// Letters that are options; a letter followed by `:` takes an argument.
    spec: []const u8,
    index: usize = 1,
    pos: usize = 0,
    optarg: []const u8 = "",

    pub fn init(argv: []const []const u8, spec: []const u8) Parser {
        return .{ .argv = argv, .spec = spec };
    }

    pub fn next(self: *Parser) Result {
        if (self.pos == 0) {
            if (self.index >= self.argv.len) return .end;
            const word = self.argv[self.index];
            if (std.mem.eql(u8, word, "--")) {
                self.index += 1;
                return .end;
            }
            if (word.len < 2 or word[0] != '-') return .end;
            self.pos = 1;
        }

        const word = self.argv[self.index];
        const c = word[self.pos];
        self.pos += 1;
        const at = if (c == ':') null else std.mem.indexOfScalar(u8, self.spec, c);
        const takes_arg = if (at) |i| i + 1 < self.spec.len and self.spec[i + 1] == ':' else false;

        if (at == null or !takes_arg) {
            if (self.pos >= word.len) self.advance();
            return if (at == null) .{ .invalid = c } else .{ .option = c };
        }
        if (self.pos < word.len) {
            self.optarg = word[self.pos..];
            self.advance();
            return .{ .option = c };
        }
        self.advance();
        if (self.index >= self.argv.len) return .{ .missing = c };
        self.optarg = self.argv[self.index];
        self.index += 1;
        return .{ .option = c };
    }

    fn advance(self: *Parser) void {
        self.index += 1;
        self.pos = 0;
    }

    /// Operands after the options.
    pub fn rest(self: *const Parser) []const []const u8 {
        return self.argv[self.index..];
    }
};

test "bundled flags, attached and separate arguments" {
    const argv = [_][]const u8{ "read", "-rs", "-n1", "-d", ":", "--", "-x" };
    var parser = Parser.init(&argv, "rsn:d:");
    try std.testing.expectEqual(Result{ .option = 'r' }, parser.next());
    try std.testing.expectEqual(Result{ .option = 's' }, parser.next());
    try std.testing.expectEqual(Result{ .option = 'n' }, parser.next());
    try std.testing.expectEqualStrings("1", parser.optarg);
    try std.testing.expectEqual(Result{ .option = 'd' }, parser.next());
    try std.testing.expectEqualStrings(":", parser.optarg);
    try std.testing.expectEqual(Result.end, parser.next());
    try std.testing.expectEqual(@as(usize, 1), parser.rest().len);

    const bad = [_][]const u8{ "x", "-q", "-n" };
    var other = Parser.init(&bad, "n:");
    try std.testing.expectEqual(Result{ .invalid = 'q' }, other.next());
    try std.testing.expectEqual(Result{ .missing = 'n' }, other.next());
}
