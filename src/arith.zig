//! Integer arithmetic for `$(( ))`. Variables resolve through the shell, so
//! `n` and `$n` both read the current value.

const std = @import("std");
const shell = @import("shell.zig");

pub const Error = error{
    InvalidArithmetic,
    DivisionByZero,
} || std.mem.Allocator.Error;

/// Evaluates `src`, the text between `$((` and `))`. Empty input is 0.
pub fn evaluate(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8) Error!i64 {
    var arith = Arith{ .sh = sh, .arena = arena, .src = src };
    return arith.evaluate();
}

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Index of the `)` matching the `(` at `open_index`.
fn matchingParen(s: []const u8, open_index: usize) ?usize {
    var depth: usize = 0;
    var i = open_index;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

const Arith = struct {
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    fn evaluate(self: *Arith) Error!i64 {
        self.skipSpace();
        if (self.pos == self.src.len) return 0;
        const n = try self.sum();
        self.skipSpace();
        if (self.pos != self.src.len) return Error.InvalidArithmetic;
        return n;
    }

    fn skipSpace(self: *Arith) void {
        while (self.pos < self.src.len and isSpaceByte(self.src[self.pos])) self.pos += 1;
    }

    fn sum(self: *Arith) Error!i64 {
        var lhs = try self.product();
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            const op = self.src[self.pos];
            if (op != '+' and op != '-') break;
            self.pos += 1;
            const rhs = try self.product();
            lhs = if (op == '+') lhs +% rhs else lhs -% rhs;
        }
        return lhs;
    }

    fn product(self: *Arith) Error!i64 {
        var lhs = try self.factor();
        while (true) {
            self.skipSpace();
            if (self.pos >= self.src.len) break;
            const op = self.src[self.pos];
            if (op != '*' and op != '/' and op != '%') break;
            self.pos += 1;
            const rhs = try self.factor();
            switch (op) {
                '*' => lhs = lhs *% rhs,
                '/' => {
                    if (rhs == 0) return Error.DivisionByZero;
                    lhs = @divTrunc(lhs, rhs);
                },
                else => {
                    if (rhs == 0) return Error.DivisionByZero;
                    lhs = @rem(lhs, rhs);
                },
            }
        }
        return lhs;
    }

    fn factor(self: *Arith) Error!i64 {
        self.skipSpace();
        if (self.pos >= self.src.len) return Error.InvalidArithmetic;
        const c = self.src[self.pos];
        switch (c) {
            '+' => {
                self.pos += 1;
                return self.factor();
            },
            '-' => {
                self.pos += 1;
                return -%try self.factor();
            },
            '(' => {
                self.pos += 1;
                const n = try self.sum();
                self.skipSpace();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return Error.InvalidArithmetic;
                self.pos += 1;
                return n;
            },
            '$' => {
                if (self.pos + 2 < self.src.len and self.src[self.pos + 1] == '(' and self.src[self.pos + 2] == '(') {
                    const open = self.pos + 1;
                    const close = matchingParen(self.src, open) orelse return Error.InvalidArithmetic;
                    var sub = Arith{ .sh = self.sh, .arena = self.arena, .src = self.src[open + 2 .. close - 1] };
                    self.pos = close + 1;
                    return sub.evaluate();
                }
                self.pos += 1;
                return self.variable();
            },
            else => {
                if (std.ascii.isDigit(c)) return self.number();
                if (isIdentStart(c)) return self.variable();
                return Error.InvalidArithmetic;
            },
        }
    }

    fn variable(self: *Arith) Error!i64 {
        if (self.pos < self.src.len and self.src[self.pos] == '{') {
            const close = std.mem.indexOfScalarPos(u8, self.src, self.pos, '}') orelse return Error.InvalidArithmetic;
            const var_name = self.src[self.pos + 1 .. close];
            self.pos = close + 1;
            return self.lookup(var_name);
        }
        if (self.pos >= self.src.len or !isIdentStart(self.src[self.pos])) return Error.InvalidArithmetic;
        const start = self.pos;
        self.pos += 1;
        while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
        return self.lookup(self.src[start..self.pos]);
    }

    fn number(self: *Arith) Error!i64 {
        const start = self.pos;
        if (self.src[start] == '0' and start + 1 < self.src.len and std.ascii.isAlphabetic(self.src[start + 1])) {
            self.pos = start + 2;
            while (self.pos < self.src.len and std.ascii.isAlphanumeric(self.src[self.pos])) self.pos += 1;
        } else {
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) self.pos += 1;
        }
        return std.fmt.parseInt(i64, self.src[start..self.pos], 0) catch Error.InvalidArithmetic;
    }

    fn lookup(self: *Arith, name: []const u8) i64 {
        if (self.sh.getVar(name)) |v| {
            switch (v) {
                .int => |n| return n,
                .boolean => |b| return if (b) 1 else 0,
                .string => |s| return parseInteger(s),
                else => return 0,
            }
        }
        if (self.sh.getEnv(name)) |s| return parseInteger(s);
        return 0;
    }
};

fn parseInteger(text: []const u8) i64 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return 0;
    return std.fmt.parseInt(i64, trimmed, 0) catch 0;
}

test "evaluate integer expressions" {
    var sh = try shell.Shell.initBare(std.testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("n", .{ .int = 10 });
    try std.testing.expectEqual(@as(i64, 5), try evaluate(&sh, arena, "1 + 2 * 2"));
    try std.testing.expectEqual(@as(i64, 12), try evaluate(&sh, arena, "n + 2"));
    try std.testing.expectEqual(@as(i64, 0), try evaluate(&sh, arena, "  "));
    try std.testing.expectError(error.DivisionByZero, evaluate(&sh, arena, "1 / 0"));
}
