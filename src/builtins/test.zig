//! `test` and `[`. Up to four arguments follow the POSIX argument-count rules;
//! longer expressions use bash's grammar (`!`, `( )`, `-a` binding tighter than
//! `-o`). The unary and binary primitives are public so `[[ ]]` can share them.

const std = @import("std");
const linux = std.os.linux;
const builtins = @import("../builtins.zig");
const shellmod = @import("../shell.zig");
const sys = @import("../sys.zig");

const Ctx = builtins.Ctx;
const Shell = shellmod.Shell;

pub const IntegerError = error{IntegerExpected};

/// `test EXPR`.
pub fn run(ctx: Ctx) u8 {
    return evaluateArgs(ctx, ctx.argv[1..]);
}

/// `[ EXPR ]`.
pub fn runBracket(ctx: Ctx) u8 {
    const args = ctx.argv[1..];
    if (args.len == 0 or !std.mem.eql(u8, args[args.len - 1], "]")) {
        ctx.err("wsh: [: missing `]'\n");
        return 2;
    }
    return evaluateArgs(ctx, args[0 .. args.len - 1]);
}

fn evaluateArgs(ctx: Ctx, args: []const []const u8) u8 {
    var ev = Evaluator{ .sh = ctx.sh, .args = args };
    const result = ev.evaluate() catch {
        ctx.errFmt("wsh: {s}: {s}\n", .{ ctx.argv[0], ev.message() });
        return 2;
    };
    return if (result) 0 else 1;
}

pub fn isUnaryOp(op: []const u8) bool {
    if (op.len != 2 or op[0] != '-') return false;
    return std.mem.indexOfScalar(u8, "abcdefghknoprstuvwxzGLNOS", op[1]) != null;
}

pub fn isBinaryOp(op: []const u8) bool {
    const ops = [_][]const u8{ "=", "==", "!=", "<", ">", "-nt", "-ot", "-ef", "-eq", "-ne", "-lt", "-le", "-gt", "-ge" };
    for (ops) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return true;
    }
    return false;
}

pub fn isIntegerOp(op: []const u8) bool {
    const ops = [_][]const u8{ "-eq", "-ne", "-lt", "-le", "-gt", "-ge" };
    for (ops) |candidate| {
        if (std.mem.eql(u8, op, candidate)) return true;
    }
    return false;
}

/// A decimal integer with optional sign and surrounding whitespace, as bash's
/// `test` accepts; null when the text is anything else or overflows.
pub fn parseInteger(text: []const u8) ?i64 {
    const trimmed = std.mem.trim(u8, text, " \t\n\r\x0b\x0c");
    var digits = trimmed;
    if (digits.len > 0 and (digits[0] == '+' or digits[0] == '-')) digits = digits[1..];
    if (digits.len == 0) return null;
    for (digits) |c| if (!std.ascii.isDigit(c)) return null;
    return std.fmt.parseInt(i64, trimmed, 10) catch null;
}

/// Applies an integer comparison operator (`isIntegerOp`).
pub fn compareIntegers(op: []const u8, a: i64, b: i64) bool {
    if (std.mem.eql(u8, op, "-eq")) return a == b;
    if (std.mem.eql(u8, op, "-ne")) return a != b;
    if (std.mem.eql(u8, op, "-lt")) return a < b;
    if (std.mem.eql(u8, op, "-le")) return a <= b;
    if (std.mem.eql(u8, op, "-gt")) return a > b;
    if (std.mem.eql(u8, op, "-ge")) return a >= b;
    unreachable;
}

/// Evaluates a unary primary (`isUnaryOp`). Only `-t` with a non-integer
/// operand fails.
pub fn unary(sh: *const Shell, op: []const u8, operand: []const u8) IntegerError!bool {
    switch (op[1]) {
        'z' => return operand.len == 0,
        'n' => return operand.len != 0,
        'v' => return sh.getVar(operand) != null or sh.getEnv(operand) != null,
        'o' => return optionEnabled(sh, operand),
        't' => {
            const fd = parseInteger(operand) orelse return error.IntegerExpected;
            if (fd < 0 or fd > std.math.maxInt(i32)) return false;
            var termios: linux.termios = undefined;
            return linux.errno(linux.tcgetattr(@intCast(fd), &termios)) == .SUCCESS;
        },
        'r', 'w', 'x' => {
            var buf: [linux.PATH_MAX]u8 = undefined;
            const path = pathZ(&buf, operand) orelse return false;
            const mode: u32 = switch (op[1]) {
                'r' => 4,
                'w' => 2,
                else => 1,
            };
            return sys.canAccess(path, mode);
        },
        'h', 'L' => {
            const st = statPath(operand, false) orelse return false;
            return linux.S.ISLNK(st.mode);
        },
        else => {},
    }
    const st = statPath(operand, true) orelse return false;
    return switch (op[1]) {
        'a', 'e' => true,
        'f' => linux.S.ISREG(st.mode),
        'd' => linux.S.ISDIR(st.mode),
        'b' => linux.S.ISBLK(st.mode),
        'c' => linux.S.ISCHR(st.mode),
        'p' => linux.S.ISFIFO(st.mode),
        'S' => linux.S.ISSOCK(st.mode),
        's' => st.size > 0,
        'g' => st.mode & linux.S.ISGID != 0,
        'u' => st.mode & linux.S.ISUID != 0,
        'k' => st.mode & linux.S.ISVTX != 0,
        'O' => st.uid == linux.geteuid(),
        'G' => st.gid == linux.getegid(),
        'N' => timeOrder(st.mtime, st.atime) == .gt,
        else => unreachable,
    };
}

/// Evaluates a binary primary (`isBinaryOp`). Integer operators fail on an
/// operand `parseInteger` rejects.
pub fn binary(lhs: []const u8, op: []const u8, rhs: []const u8) IntegerError!bool {
    if (std.mem.eql(u8, op, "=") or std.mem.eql(u8, op, "==")) return std.mem.eql(u8, lhs, rhs);
    if (std.mem.eql(u8, op, "!=")) return !std.mem.eql(u8, lhs, rhs);
    if (std.mem.eql(u8, op, "<")) return std.mem.order(u8, lhs, rhs) == .lt;
    if (std.mem.eql(u8, op, ">")) return std.mem.order(u8, lhs, rhs) == .gt;
    if (std.mem.eql(u8, op, "-nt") or std.mem.eql(u8, op, "-ot")) {
        // A file that exists is newer than one that does not.
        const left = statPath(lhs, true);
        const right = statPath(rhs, true);
        const newer = std.mem.eql(u8, op, "-nt");
        const a = (if (newer) left else right) orelse return false;
        const b = (if (newer) right else left) orelse return true;
        return timeOrder(a.mtime, b.mtime) == .gt;
    }
    if (std.mem.eql(u8, op, "-ef")) {
        const a = statPath(lhs, true) orelse return false;
        const b = statPath(rhs, true) orelse return false;
        return a.dev_major == b.dev_major and a.dev_minor == b.dev_minor and a.ino == b.ino;
    }
    const a = parseInteger(lhs) orelse return error.IntegerExpected;
    const b = parseInteger(rhs) orelse return error.IntegerExpected;
    return compareIntegers(op, a, b);
}

/// `set -o` names that `test -o` can query.
fn optionEnabled(sh: *const Shell, name: []const u8) bool {
    const names = [_][]const u8{ "errexit", "nounset", "xtrace", "pipefail", "noglob", "noclobber", "allexport", "vi", "ignoreeof", "histexpand" };
    inline for (names) |field| {
        if (std.mem.eql(u8, name, field)) return @field(sh.options, field);
    }
    return false;
}

fn timeOrder(a: linux.statx_timestamp, b: linux.statx_timestamp) std.math.Order {
    const by_sec = std.math.order(a.sec, b.sec);
    return if (by_sec != .eq) by_sec else std.math.order(a.nsec, b.nsec);
}

fn pathZ(buf: []u8, path: []const u8) ?[:0]const u8 {
    if (path.len == 0 or path.len + 1 > buf.len) return null;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    return buf[0..path.len :0];
}

fn statPath(path: []const u8, follow: bool) ?linux.Statx {
    var buf: [linux.PATH_MAX]u8 = undefined;
    const z = pathZ(&buf, path) orelse return null;
    var st: linux.Statx = undefined;
    const flags: u32 = if (follow) 0 else linux.AT.SYMLINK_NOFOLLOW;
    const mask = linux.STATX{ .TYPE = true, .MODE = true, .UID = true, .GID = true, .INO = true, .SIZE = true, .ATIME = true, .MTIME = true };
    if (linux.errno(linux.statx(linux.AT.FDCWD, z.ptr, flags, mask, &st)) != .SUCCESS) return null;
    return st;
}

const Evaluator = struct {
    sh: *const Shell,
    args: []const []const u8,
    pos: usize = 0,
    depth: u32 = 0,
    msg_buf: [256]u8 = undefined,
    msg_len: usize = 0,

    const Error = error{Syntax};
    const max_depth = 256;

    fn message(self: *const Evaluator) []const u8 {
        return self.msg_buf[0..self.msg_len];
    }

    fn fail(self: *Evaluator, comptime fmt: []const u8, args: anytype) Error {
        var w = std.Io.Writer.fixed(&self.msg_buf);
        w.print(fmt, args) catch {};
        self.msg_len = w.buffered().len;
        return error.Syntax;
    }

    fn is(self: *const Evaluator, index: usize, text: []const u8) bool {
        return index < self.args.len and std.mem.eql(u8, self.args[index], text);
    }

    fn evaluate(self: *Evaluator) Error!bool {
        const args = self.args;
        switch (args.len) {
            0 => return false,
            1 => return args[0].len != 0,
            2 => return self.two(0),
            3 => return self.three(0),
            4 => {
                if (self.is(0, "!")) return !try self.three(1);
                if (self.is(0, "(") and self.is(3, ")")) return self.two(1);
            },
            else => {},
        }
        const result = try self.disjunction();
        if (self.pos < args.len) {
            const extra = args[self.pos];
            if (extra.len > 0 and extra[0] == '-') return self.fail("syntax error: `{s}' unexpected", .{extra});
            return self.fail("too many arguments", .{});
        }
        return result;
    }

    fn two(self: *Evaluator, i: usize) Error!bool {
        const first = self.args[i];
        if (std.mem.eql(u8, first, "!")) return self.args[i + 1].len == 0;
        if (isUnaryOp(first)) return self.unaryPrimary(first, self.args[i + 1]);
        return self.fail("{s}: unary operator expected", .{first});
    }

    fn three(self: *Evaluator, i: usize) Error!bool {
        const left = self.args[i];
        const op = self.args[i + 1];
        const right = self.args[i + 2];
        if (isBinaryOp(op)) return self.binaryPrimary(left, op, right);
        if (std.mem.eql(u8, op, "-a")) return left.len != 0 and right.len != 0;
        if (std.mem.eql(u8, op, "-o")) return left.len != 0 or right.len != 0;
        if (std.mem.eql(u8, left, "!")) return !try self.two(i + 1);
        if (std.mem.eql(u8, left, "(") and std.mem.eql(u8, right, ")")) return op.len != 0;
        return self.fail("{s}: binary operator expected", .{op});
    }

    fn disjunction(self: *Evaluator) Error!bool {
        var value = try self.conjunction();
        while (self.is(self.pos, "-o")) {
            self.pos += 1;
            const rhs = try self.conjunction();
            value = value or rhs;
        }
        return value;
    }

    fn conjunction(self: *Evaluator) Error!bool {
        var value = try self.term();
        while (self.is(self.pos, "-a")) {
            self.pos += 1;
            const rhs = try self.term();
            value = value and rhs;
        }
        return value;
    }

    fn term(self: *Evaluator) Error!bool {
        const args = self.args;
        if (self.pos >= args.len) return self.fail("argument expected", .{});
        if (self.is(self.pos, "!")) {
            var negate = false;
            while (self.is(self.pos, "!")) {
                self.pos += 1;
                negate = !negate;
            }
            return negate != try self.term();
        }
        if (self.is(self.pos, "(")) {
            if (self.depth >= max_depth) return self.fail("expression nested too deeply", .{});
            self.depth += 1;
            defer self.depth -= 1;
            self.pos += 1;
            if (self.pos >= args.len) return self.fail("argument expected", .{});
            const value = try self.disjunction();
            if (self.pos >= args.len) return self.fail("`)' expected", .{});
            if (!self.is(self.pos, ")")) return self.fail("`)' expected, found {s}", .{args[self.pos]});
            self.pos += 1;
            return value;
        }
        const first = args[self.pos];
        if (self.pos + 3 <= args.len and isBinaryOp(args[self.pos + 1])) {
            const value = try self.binaryPrimary(first, args[self.pos + 1], args[self.pos + 2]);
            self.pos += 3;
            return value;
        }
        if (self.pos + 2 <= args.len and isUnaryOp(first)) {
            const value = try self.unaryPrimary(first, args[self.pos + 1]);
            self.pos += 2;
            return value;
        }
        self.pos += 1;
        return first.len != 0;
    }

    fn unaryPrimary(self: *Evaluator, op: []const u8, operand: []const u8) Error!bool {
        return unary(self.sh, op, operand) catch self.fail("{s}: integer expression expected", .{operand});
    }

    fn binaryPrimary(self: *Evaluator, lhs: []const u8, op: []const u8, rhs: []const u8) Error!bool {
        return binary(lhs, op, rhs) catch {
            const bad = if (parseInteger(lhs) == null) lhs else rhs;
            return self.fail("{s}: integer expression expected", .{bad});
        };
    }
};

// --- tests -----------------------------------------------------------------

const testing = std.testing;

fn status(sh: *Shell, argv: []const []const u8) u8 {
    const ctx = Ctx{ .sh = sh, .argv = argv, .stderr = -1 };
    return if (std.mem.eql(u8, argv[0], "[")) runBracket(ctx) else run(ctx);
}

fn expectStatus(sh: *Shell, argv: []const []const u8, want: u8) !void {
    const got = status(sh, argv);
    if (got != want) {
        for (argv) |arg| std.debug.print("'{s}' ", .{arg});
        std.debug.print("-> {d}, want {d}\n", .{ got, want });
    }
    try testing.expectEqual(want, got);
}

test "test builtin" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    try testing.expectEqual(@as(u8, 0), status(&sh, &.{ "test", "-d", "." }));
    try testing.expectEqual(@as(u8, 1), status(&sh, &.{ "test", "-f", "." }));
    try testing.expectEqual(@as(u8, 0), status(&sh, &.{ "test", "a", "=", "a" }));
    try testing.expectEqual(@as(u8, 0), status(&sh, &.{ "test", "2", "-lt", "10" }));
}

test "test groups, negates and brackets" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    const cases = [_]struct { argv: []const []const u8, want: u8 }{
        .{ .argv = &.{ "[", "a", "=", "a", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-f", ".", "]" }, .want = 1 },
        .{ .argv = &.{ "[", "-d", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-e", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-z", "", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-n", "x", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "-x", "/bin/sh", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "!", "-f", ".", "]" }, .want = 0 },
        .{ .argv = &.{ "test", "a", "=", "a", "-a", "b", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "a", "=", "b", "-a", "b", "=", "b" }, .want = 1 },
        .{ .argv = &.{ "test", "a", "=", "b", "-o", "b", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "!", "a", "=", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "a", ")", "-a", "c", "=", "c" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "b", "-o", "c", "=", "c", ")" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "a", "=", "b", ")", "-o", "c", "=", "c" }, .want = 0 },
        .{ .argv = &.{ "test", "3", "-ge", "3" }, .want = 0 },
        .{ .argv = &.{ "test", "3", "-ne", "3" }, .want = 1 },
        // POSIX: one argument is true when it is non-empty.
        .{ .argv = &.{ "test", "-f" }, .want = 0 },
        .{ .argv = &.{ "test", "" }, .want = 1 },
        .{ .argv = &.{"test"}, .want = 1 },
        .{ .argv = &.{ "[", "a", "=", "a" }, .want = 2 },
        .{ .argv = &.{ "test", "(", "a", "=", "a" }, .want = 2 },
    };
    for (cases) |case| try expectStatus(&sh, case.argv, case.want);
}

test "argument-count rules decide how operands are read" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    const cases = [_]struct { argv: []const []const u8, want: u8 }{
        .{ .argv = &.{ "test", "!" }, .want = 0 },
        .{ .argv = &.{ "test", "-n" }, .want = 0 },
        .{ .argv = &.{ "test", "!", "x" }, .want = 1 },
        .{ .argv = &.{ "test", "!", "" }, .want = 0 },
        .{ .argv = &.{ "test", "x", "y" }, .want = 2 },
        .{ .argv = &.{ "test", "!", "=", "x" }, .want = 1 },
        .{ .argv = &.{ "test", "!", "=", "!" }, .want = 0 },
        .{ .argv = &.{ "test", "-n", "=", "-n" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "=", "(" }, .want = 0 },
        .{ .argv = &.{ "test", "-f", "-a", "-f" }, .want = 0 },
        .{ .argv = &.{ "test", "", "-o", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "(", "", ")" }, .want = 1 },
        .{ .argv = &.{ "test", "a", "b", "c" }, .want = 2 },
        .{ .argv = &.{ "test", "!", "a", "=", "a" }, .want = 1 },
        .{ .argv = &.{ "test", "(", "-n", "x", ")" }, .want = 0 },
        .{ .argv = &.{ "test", "a", "b", "c", "d" }, .want = 2 },
        .{ .argv = &.{ "test", "!", "!", "!", "x" }, .want = 1 },
        .{ .argv = &.{ "test", "1", "-lt", "2", "-lt", "3" }, .want = 2 },
        .{ .argv = &.{ "test", "x", "-a", "(", "y", "-o", "", ")" }, .want = 0 },
        .{ .argv = &.{ "test", "", "-o", "", "-o", "x" }, .want = 0 },
        .{ .argv = &.{ "[", "a", "=", "a", "]", "]" }, .want = 2 },
        .{ .argv = &.{ "[", "]", "]" }, .want = 0 },
        .{ .argv = &.{ "[", "]" }, .want = 1 },
    };
    for (cases) |case| try expectStatus(&sh, case.argv, case.want);
}

test "integers, strings, variables and files" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();
    try sh.setVar("set_var", .{ .string = "" });
    try sh.setEnv("SET_ENV", "1");
    sh.options.errexit = true;

    const cases = [_]struct { argv: []const []const u8, want: u8 }{
        .{ .argv = &.{ "test", " 5 ", "-eq", "5" }, .want = 0 },
        .{ .argv = &.{ "test", "+5", "-eq", "5" }, .want = 0 },
        .{ .argv = &.{ "test", "-5", "-lt", "0" }, .want = 0 },
        .{ .argv = &.{ "test", "08", "-eq", "8" }, .want = 0 },
        .{ .argv = &.{ "test", "-9223372036854775808", "-lt", "9223372036854775807" }, .want = 0 },
        .{ .argv = &.{ "test", "abc", "-eq", "1" }, .want = 2 },
        .{ .argv = &.{ "test", "", "-eq", "0" }, .want = 2 },
        .{ .argv = &.{ "test", "0x10", "-eq", "16" }, .want = 2 },
        .{ .argv = &.{ "test", "5 5", "-eq", "5" }, .want = 2 },
        .{ .argv = &.{ "test", "- 5", "-eq", "-5" }, .want = 2 },
        .{ .argv = &.{ "test", "99999999999999999999", "-eq", "1" }, .want = 2 },
        .{ .argv = &.{ "test", "a", "<", "b" }, .want = 0 },
        .{ .argv = &.{ "test", "b", "<", "a" }, .want = 1 },
        .{ .argv = &.{ "test", "B", "<", "a" }, .want = 0 },
        .{ .argv = &.{ "test", "a", ">", "a" }, .want = 1 },
        .{ .argv = &.{ "test", "-v", "set_var" }, .want = 0 },
        .{ .argv = &.{ "test", "-v", "SET_ENV" }, .want = 0 },
        .{ .argv = &.{ "test", "-v", "unset_name" }, .want = 1 },
        .{ .argv = &.{ "test", "-o", "errexit" }, .want = 0 },
        .{ .argv = &.{ "test", "-o", "nounset" }, .want = 1 },
        .{ .argv = &.{ "test", "-o", "bogus" }, .want = 1 },
        .{ .argv = &.{ "test", "-c", "/dev/null" }, .want = 0 },
        .{ .argv = &.{ "test", "-b", "/dev/null" }, .want = 1 },
        .{ .argv = &.{ "test", "-p", "/dev/null" }, .want = 1 },
        .{ .argv = &.{ "test", "-S", "/dev/null" }, .want = 1 },
        .{ .argv = &.{ "test", "-s", "/dev/null" }, .want = 1 },
        .{ .argv = &.{ "test", "-e", "" }, .want = 1 },
        .{ .argv = &.{ "test", "-a", "/" }, .want = 0 },
        .{ .argv = &.{ "test", "-O", "/" }, .want = if (linux.geteuid() == 0) 0 else 1 },
        .{ .argv = &.{ "test", "-t", "99" }, .want = 1 },
        .{ .argv = &.{ "test", "-t", "abc" }, .want = 2 },
        .{ .argv = &.{ "test", "/", "-ef", "/" }, .want = 0 },
        .{ .argv = &.{ "test", "/", "-ef", "/dev" }, .want = 1 },
        .{ .argv = &.{ "test", "/nope", "-ef", "/nope" }, .want = 1 },
        .{ .argv = &.{ "test", "/", "-nt", "/nope" }, .want = 0 },
        .{ .argv = &.{ "test", "/nope", "-nt", "/" }, .want = 1 },
        .{ .argv = &.{ "test", "/nope", "-ot", "/" }, .want = 0 },
        .{ .argv = &.{ "test", "/", "-ot", "/nope" }, .want = 1 },
        .{ .argv = &.{ "test", "/nope", "-nt", "/nope" }, .want = 1 },
        .{ .argv = &.{ "test", "-q", "x" }, .want = 2 },
    };
    for (cases) |case| try expectStatus(&sh, case.argv, case.want);
}

test "errors name the problem" {
    var sh = try Shell.initBare(testing.allocator);
    defer sh.deinit();

    const cases = [_]struct { args: []const []const u8, message: []const u8 }{
        .{ .args = &.{ "x", "y" }, .message = "x: unary operator expected" },
        .{ .args = &.{ "a", "b", "c" }, .message = "b: binary operator expected" },
        .{ .args = &.{ "a", "b", "c", "d" }, .message = "too many arguments" },
        .{ .args = &.{ "abc", "-eq", "1" }, .message = "abc: integer expression expected" },
        .{ .args = &.{ "1", "-eq", "x" }, .message = "x: integer expression expected" },
        .{ .args = &.{ "-t", "abc" }, .message = "abc: integer expression expected" },
        .{ .args = &.{ "(", "a", "=", "a" }, .message = "`)' expected" },
        .{ .args = &.{ "(", "a", "=", "a", "b" }, .message = "`)' expected, found b" },
        .{ .args = &.{ "1", "-lt", "2", "-lt", "3" }, .message = "syntax error: `-lt' unexpected" },
        .{ .args = &.{ "x", "-a", "y", "-o" }, .message = "argument expected" },
    };
    for (cases) |case| {
        var ev = Evaluator{ .sh = &sh, .args = case.args };
        try testing.expectError(error.Syntax, ev.evaluate());
        try testing.expectEqualStrings(case.message, ev.message());
    }
}

test "integer parsing follows test's rules" {
    try testing.expectEqual(@as(?i64, 5), parseInteger(" 5\n"));
    try testing.expectEqual(@as(?i64, -5), parseInteger("-5"));
    try testing.expectEqual(@as(?i64, 5), parseInteger("+5"));
    try testing.expectEqual(@as(?i64, null), parseInteger("+"));
    try testing.expectEqual(@as(?i64, null), parseInteger("1_000"));
    try testing.expectEqual(@as(?i64, null), parseInteger("--5"));
    try testing.expectEqual(@as(?i64, std.math.minInt(i64)), parseInteger("-9223372036854775808"));
}
