//! Shell arithmetic for `$(( ))`, and for `(( ))`, `let` and `for ((;;))`.
//! Follows bash: 64-bit wrapping integers, the C operators plus `**`,
//! assignment operators, `base#digits` literals, and variables whose values
//! are themselves expressions.

const std = @import("std");
const shell = @import("shell.zig");
const expand = @import("expand.zig");

pub const Error = error{
    InvalidArithmetic,
    DivisionByZero,
} || expand.Error;

/// Evaluates `src`, the text between `$((` and `))`. As in bash, `$`
/// expansions and command substitutions in it run first and double quotes are
/// dropped. Empty input is 0. On failure `errorMessage` says why.
pub fn evaluate(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8) Error!i64 {
    message_len = 0;
    const text = try expandText(sh, arena, src);
    return evaluateExpanded(sh, arena, text);
}

/// Evaluates text whose expansions already happened, such as an argument of
/// `let`; a `$` left in it is a syntax error.
pub fn evaluateExpanded(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8) Error!i64 {
    message_len = 0;
    var arith = Arith{ .sh = sh, .arena = arena, .src = src };
    return arith.run();
}

/// Why the last evaluation failed, worded like bash:
/// `1 / 0 : division by 0 (error token is "0 ")`.
pub fn errorMessage() []const u8 {
    if (message_len == 0) return "arithmetic syntax error";
    return message_buf[0..message_len];
}

/// Takes the message of a failed `$(( ))` evaluation, or null when the
/// pending error came from elsewhere (a `let` expression, say).
pub fn takeErrorMessage() ?[]const u8 {
    if (message_len == 0) return null;
    const len = message_len;
    message_len = 0;
    return message_buf[0..len];
}

// The shell is single-threaded and reports an error right after the
// evaluation that raised it, so one buffer is enough.
var message_buf: [1024]u8 = undefined;
var message_len: usize = 0;

fn setMessage(comptime fmt: []const u8, args: anytype) void {
    var w = std.Io.Writer.fixed(&message_buf);
    w.print(fmt, args) catch {};
    message_len = w.buffered().len;
}

/// Bound on nested parentheses, operators and variable evaluation, so
/// pathological input fails cleanly instead of exhausting the stack.
const max_depth = 1024;

fn isSpaceByte(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r';
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Replaces `$` expansions and command substitutions with their values and
/// drops double quotes, leaving everything else for the evaluator.
fn expandText(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, src, "$`\"\\") == null) return src;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const c = src[i];
        switch (c) {
            '"' => i += 1,
            '\\' => {
                if (i + 1 < src.len and std.mem.indexOfScalar(u8, "$`\"\\\n", src[i + 1]) != null) {
                    if (src[i + 1] != '\n') try out.append(arena, src[i + 1]);
                    i += 2;
                } else {
                    try out.append(arena, c);
                    i += 1;
                }
            },
            '$', '`' => {
                const end = expansionEnd(src, i) orelse return error.UnterminatedSubstitution;
                if (end == i + 1) {
                    try out.append(arena, c);
                } else {
                    try out.appendSlice(arena, try expand.expandLiteral(sh, arena, src[i..end]));
                }
                i = end;
            },
            else => {
                try out.append(arena, c);
                i += 1;
            },
        }
    }
    return out.items;
}

/// End of the expansion or backtick substitution starting at `i`, or null when
/// its closing delimiter is missing. A `$` that starts nothing ends at `i + 1`.
fn expansionEnd(s: []const u8, i: usize) ?usize {
    if (s[i] == '`') {
        var j = i + 1;
        while (j < s.len) : (j += 1) {
            if (s[j] == '\\') {
                j += 1;
            } else if (s[j] == '`') {
                return j + 1;
            }
        }
        return null;
    }
    if (i + 1 >= s.len) return i + 1;
    const c = s[i + 1];
    if (c == '{' or c == '(') {
        const close = matchingClose(s, i + 1) orelse return null;
        return close + 1;
    }
    if (isIdentStart(c)) {
        var j = i + 2;
        while (j < s.len and isIdentChar(s[j])) j += 1;
        return j;
    }
    if (std.ascii.isDigit(c) or std.mem.indexOfScalar(u8, "?$!#@*-", c) != null) return i + 2;
    return i + 1;
}

/// Index of the delimiter closing the `(` or `{` at `open`, skipping quoted
/// text and nested pairs.
fn matchingClose(s: []const u8, open: usize) ?usize {
    const open_c = s[open];
    const close_c: u8 = if (open_c == '(') ')' else '}';
    var depth: usize = 0;
    var i = open;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        if (c == '\\') {
            i += 1;
        } else if (c == '\'') {
            i = std.mem.indexOfScalarPos(u8, s, i + 1, '\'') orelse return null;
        } else if (c == '"') {
            i += 1;
            while (i < s.len and s[i] != '"') : (i += 1) {
                if (s[i] == '\\') i += 1;
            }
            if (i >= s.len) return null;
        } else if (c == open_c) {
            depth += 1;
        } else if (c == close_c) {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

const Kind = enum {
    eof,
    num,
    ident,
    lparen,
    rparen,
    comma,
    question,
    colon,
    assign,
    op_assign,
    pre_inc,
    pre_dec,
    post_inc,
    post_dec,
    not,
    bnot,
    lor,
    land,
    bor,
    bxor,
    band,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    shl,
    shr,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    invalid,
};

const Token = struct {
    kind: Kind = .eof,
    start: usize = 0,
    end: usize = 0,
    value: i64 = 0,
    /// The operator of an `op_assign` token: `.add` for `+=`.
    op: Kind = .eof,
};

/// Binding strength of a binary operator; 0 for anything else.
fn precedence(kind: Kind) u8 {
    return switch (kind) {
        .lor => 1,
        .land => 2,
        .bor => 3,
        .bxor => 4,
        .band => 5,
        .eq, .ne => 6,
        .lt, .le, .gt, .ge => 7,
        .shl, .shr => 8,
        .add, .sub => 9,
        .mul, .div, .mod => 10,
        .pow => 11,
        else => 0,
    };
}

/// Value of a digit in a `base#digits` literal: `0-9`, then `a-z`, then `A-Z`
/// (which equal `a-z` up to base 36), `@` and `_`.
fn digitValue(c: u8, base: i64) i64 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => if (base <= 36) c - 'A' + 10 else c - 'A' + 36,
        '@' => 62,
        '_' => 63,
        else => 64,
    };
}

/// Recursive descent over the token stream, evaluating as it parses like
/// bash's evaluator. `noeval` parses the skipped side of `&&`, `||` and `?:`
/// without side effects.
const Arith = struct {
    sh: *shell.Shell,
    arena: std.mem.Allocator,
    src: []const u8,
    depth: u32 = 0,
    noeval: u32 = 0,
    pos: usize = 0,
    cur: Token = .{},
    /// Kind of the token before `cur`; `++` right after a name is postfix.
    prev: Kind = .eof,
    /// Set after `++name`, where another `++` is an error as in bash.
    after_prefix: bool = false,
    /// Start of the last token read before end of input; error messages
    /// quote the text from here.
    last_start: usize = 0,

    const State = struct {
        pos: usize,
        cur: Token,
        prev: Kind,
        after_prefix: bool,
        last_start: usize,
    };

    fn run(self: *Arith) Error!i64 {
        if (self.depth > max_depth) return self.fail("expression recursion level exceeded");
        try self.advance();
        if (self.cur.kind == .eof) return 0;
        const v = try self.comma();
        return switch (self.cur.kind) {
            .eof => v,
            .invalid => self.fail("arithmetic syntax error: invalid arithmetic operator"),
            else => self.fail("arithmetic syntax error in expression"),
        };
    }

    fn fail(self: *Arith, msg: []const u8) Error {
        const expr = std.mem.trimStart(u8, self.src, " \t\r\n");
        setMessage("{s}: {s} (error token is \"{s}\")", .{ expr, msg, self.src[self.last_start..] });
        return error.InvalidArithmetic;
    }

    fn enter(self: *Arith) Error!void {
        self.depth += 1;
        if (self.depth > max_depth) return self.fail("expression recursion level exceeded");
    }

    fn save(self: *const Arith) State {
        return .{ .pos = self.pos, .cur = self.cur, .prev = self.prev, .after_prefix = self.after_prefix, .last_start = self.last_start };
    }

    fn restore(self: *Arith, state: State) void {
        self.pos = state.pos;
        self.cur = state.cur;
        self.prev = state.prev;
        self.after_prefix = state.after_prefix;
        self.last_start = state.last_start;
    }

    fn text(self: *const Arith, tok: Token) []const u8 {
        return self.src[tok.start..tok.end];
    }

    // --- lexing -----------------------------------------------------------

    fn advance(self: *Arith) Error!void {
        self.prev = self.cur.kind;
        self.cur = try self.lex();
    }

    fn lex(self: *Arith) Error!Token {
        const s = self.src;
        var i = self.pos;
        while (i < s.len and isSpaceByte(s[i])) i += 1;
        const after_prefix = self.after_prefix;
        self.after_prefix = false;
        if (i >= s.len) {
            self.pos = i;
            return .{ .kind = .eof, .start = i, .end = i };
        }
        self.last_start = i;
        const c = s[i];
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            while (j < s.len and (std.ascii.isAlphanumeric(s[j]) or s[j] == '#' or s[j] == '@' or s[j] == '_')) j += 1;
            self.pos = j;
            return .{ .kind = .num, .start = i, .end = j, .value = try self.number(s[i..j]) };
        }
        if (isIdentStart(c)) {
            var j = i + 1;
            while (j < s.len and isIdentChar(s[j])) j += 1;
            self.pos = j;
            return .{ .kind = .ident, .start = i, .end = j };
        }

        const c1: u8 = if (i + 1 < s.len) s[i + 1] else 0;
        const c2: u8 = if (i + 2 < s.len) s[i + 2] else 0;
        var tok = Token{ .start = i };
        var width: usize = 1;
        switch (c) {
            '(' => tok.kind = .lparen,
            ')' => tok.kind = .rparen,
            ',' => tok.kind = .comma,
            '?' => tok.kind = .question,
            ':' => tok.kind = .colon,
            '~' => tok.kind = .bnot,
            '=', '!' => {
                if (c1 == '=') {
                    tok.kind = if (c == '=') .eq else .ne;
                    width = 2;
                } else {
                    tok.kind = if (c == '=') .assign else .not;
                }
            },
            '<', '>' => {
                const shift: Kind = if (c == '<') .shl else .shr;
                if (c1 == c and c2 == '=') {
                    tok.kind = .op_assign;
                    tok.op = shift;
                    width = 3;
                } else if (c1 == c) {
                    tok.kind = shift;
                    width = 2;
                } else if (c1 == '=') {
                    tok.kind = if (c == '<') .le else .ge;
                    width = 2;
                } else {
                    tok.kind = if (c == '<') .lt else .gt;
                }
            },
            '&', '|' => {
                const single: Kind = if (c == '&') .band else .bor;
                if (c1 == c) {
                    tok.kind = if (c == '&') .land else .lor;
                    width = 2;
                } else if (c1 == '=') {
                    tok.kind = .op_assign;
                    tok.op = single;
                    width = 2;
                } else {
                    tok.kind = single;
                }
            },
            '*' => {
                if (c1 == '*') {
                    tok.kind = .pow;
                    width = 2;
                } else if (c1 == '=') {
                    tok.kind = .op_assign;
                    tok.op = .mul;
                    width = 2;
                } else {
                    tok.kind = .mul;
                }
            },
            '/', '%', '^' => {
                const single: Kind = switch (c) {
                    '/' => .div,
                    '%' => .mod,
                    else => .bxor,
                };
                if (c1 == '=') {
                    tok.kind = .op_assign;
                    tok.op = single;
                    width = 2;
                } else {
                    tok.kind = single;
                }
            },
            '+', '-' => {
                const single: Kind = if (c == '+') .add else .sub;
                if (c1 == c) {
                    if (after_prefix) {
                        self.pos = i;
                        return self.fail(if (c == '+') "++: assignment requires lvalue" else "--: assignment requires lvalue");
                    }
                    if (self.prev == .ident) {
                        tok.kind = if (c == '+') .post_inc else .post_dec;
                        width = 2;
                    } else if (identFollows(s, i + 2)) {
                        tok.kind = if (c == '+') .pre_inc else .pre_dec;
                        width = 2;
                    } else {
                        // `++5` is two unary pluses, as in bash.
                        tok.kind = single;
                    }
                } else if (c1 == '=') {
                    tok.kind = .op_assign;
                    tok.op = single;
                    width = 2;
                } else {
                    tok.kind = single;
                }
            },
            else => tok.kind = .invalid,
        }
        tok.end = i + width;
        self.pos = tok.end;
        return tok;
    }

    fn identFollows(s: []const u8, from: usize) bool {
        var i = from;
        while (i < s.len and isSpaceByte(s[i])) i += 1;
        return i < s.len and isIdentStart(s[i]);
    }

    /// Converts a literal: decimal, `0x` hex, leading-zero octal or
    /// `base#digits`. Overflow wraps, as in bash.
    fn number(self: *Arith, digits: []const u8) Error!i64 {
        var base: i64 = 10;
        var based = false;
        var i: usize = 0;
        if (digits[0] == '0') {
            if (digits.len == 1) return 0;
            based = true;
            if (digits[1] == 'x' or digits[1] == 'X') {
                base = 16;
                i = 2;
            } else {
                base = 8;
                i = 1;
            }
        }
        var val: i64 = 0;
        while (i < digits.len) : (i += 1) {
            const c = digits[i];
            if (c == '#') {
                if (based) return self.fail("invalid number");
                if (val < 2 or val > 64) return self.fail("invalid arithmetic base");
                base = val;
                val = 0;
                based = true;
                if (i + 1 == digits.len or digits[i + 1] == '#') return self.fail("invalid integer constant");
                continue;
            }
            const d = digitValue(c, base);
            if (d >= base) return self.fail("value too great for base");
            val = val *% base +% d;
        }
        return val;
    }

    // --- grammar, lowest precedence first ---------------------------------

    fn comma(self: *Arith) Error!i64 {
        var v = try self.assignment();
        while (self.cur.kind == .comma) {
            try self.advance();
            v = try self.assignment();
        }
        return v;
    }

    fn assignment(self: *Arith) Error!i64 {
        try self.enter();
        defer self.depth -= 1;
        if (self.cur.kind == .ident) {
            const state = self.save();
            const name = self.text(self.cur);
            try self.advance();
            switch (self.cur.kind) {
                .assign => {
                    try self.advance();
                    const v = try self.assignment();
                    try self.store(name, v);
                    return v;
                },
                .op_assign => {
                    const op = self.cur.op;
                    const lhs = try self.lookup(name);
                    try self.advance();
                    const rhs = try self.assignment();
                    const v = try self.apply(op, lhs, rhs);
                    try self.store(name, v);
                    return v;
                },
                else => self.restore(state),
            }
        }
        const v = try self.conditional();
        if (self.cur.kind == .assign or self.cur.kind == .op_assign) {
            return self.fail("attempted assignment to non-variable");
        }
        return v;
    }

    fn conditional(self: *Arith) Error!i64 {
        const c = try self.binary(1);
        if (self.cur.kind != .question) return c;
        try self.advance();
        if (self.cur.kind == .eof or self.cur.kind == .colon) return self.fail("expression expected");
        if (c == 0) self.noeval += 1;
        const yes = try self.comma();
        if (c == 0) self.noeval -= 1;
        if (self.cur.kind != .colon) return self.fail("`:' expected for conditional expression");
        try self.advance();
        if (self.cur.kind == .eof) return self.fail("expression expected");
        if (c != 0) self.noeval += 1;
        const no = try self.conditional();
        if (c != 0) self.noeval -= 1;
        return if (c != 0) yes else no;
    }

    /// Binary operators by precedence climbing; `**` is right-associative.
    fn binary(self: *Arith, min_prec: u8) Error!i64 {
        try self.enter();
        defer self.depth -= 1;
        var lhs = try self.unary();
        while (true) {
            const op = self.cur.kind;
            const prec = precedence(op);
            if (prec == 0 or prec < min_prec) return lhs;
            try self.advance();
            switch (op) {
                .land, .lor => {
                    // The right side is parsed but not evaluated when the left decides.
                    const skip = (lhs != 0) == (op == .lor);
                    if (skip) self.noeval += 1;
                    const rhs = try self.binary(prec + 1);
                    if (skip) self.noeval -= 1;
                    lhs = @intFromBool(if (op == .land) lhs != 0 and rhs != 0 else lhs != 0 or rhs != 0);
                },
                .pow => lhs = try self.power(lhs, try self.binary(prec)),
                else => lhs = try self.apply(op, lhs, try self.binary(prec + 1)),
            }
        }
    }

    fn unary(self: *Arith) Error!i64 {
        try self.enter();
        defer self.depth -= 1;
        switch (self.cur.kind) {
            .not => {
                try self.advance();
                return @intFromBool(try self.unary() == 0);
            },
            .bnot => {
                try self.advance();
                return ~(try self.unary());
            },
            .sub => {
                try self.advance();
                return 0 -% try self.unary();
            },
            .add => {
                try self.advance();
                return self.unary();
            },
            else => return self.primary(),
        }
    }

    fn primary(self: *Arith) Error!i64 {
        switch (self.cur.kind) {
            .num => {
                const v = self.cur.value;
                try self.advance();
                return v;
            },
            .lparen => {
                try self.advance();
                const v = try self.comma();
                if (self.cur.kind != .rparen) return self.fail("missing `)'");
                try self.advance();
                return v;
            },
            .pre_inc, .pre_dec => {
                const delta: i64 = if (self.cur.kind == .pre_inc) 1 else -1;
                try self.advance();
                // The lexer only produces a prefix operator before a name.
                std.debug.assert(self.cur.kind == .ident);
                const name = self.text(self.cur);
                const v = (try self.lookup(name)) +% delta;
                try self.store(name, v);
                self.after_prefix = true;
                try self.advance();
                return v;
            },
            .ident => {
                const name = self.text(self.cur);
                try self.advance();
                // `1 + x = 2`: the caller reports the bad assignment, and bash
                // does not read `x` first.
                if (self.cur.kind == .assign) return 0;
                const v = try self.lookup(name);
                if (self.cur.kind == .post_inc or self.cur.kind == .post_dec) {
                    try self.store(name, if (self.cur.kind == .post_inc) v +% 1 else v -% 1);
                    try self.advance();
                }
                return v;
            },
            else => return self.fail("arithmetic syntax error: operand expected"),
        }
    }

    // --- semantics --------------------------------------------------------

    fn apply(self: *Arith, op: Kind, a: i64, b: i64) Error!i64 {
        return switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .div, .mod => {
                if (b == 0) {
                    if (self.noeval != 0) return 0;
                    const expr = std.mem.trimStart(u8, self.src, " \t\r\n");
                    setMessage("{s}: division by 0 (error token is \"{s}\")", .{ expr, self.src[self.last_start..] });
                    return error.DivisionByZero;
                }
                // minInt / -1 overflows; bash yields minInt and 0.
                if (b == -1) return if (op == .div) 0 -% a else 0;
                return if (op == .div) @divTrunc(a, b) else @rem(a, b);
            },
            .shl => @bitCast(@as(u64, @bitCast(a)) << @intCast(b & 63)),
            .shr => a >> @intCast(b & 63),
            .band => a & b,
            .bor => a | b,
            .bxor => a ^ b,
            .eq => @intFromBool(a == b),
            .ne => @intFromBool(a != b),
            .lt => @intFromBool(a < b),
            .le => @intFromBool(a <= b),
            .gt => @intFromBool(a > b),
            .ge => @intFromBool(a >= b),
            else => unreachable,
        };
    }

    fn power(self: *Arith, base: i64, exponent: i64) Error!i64 {
        if (exponent < 0) {
            if (self.noeval != 0) return 0;
            return self.fail("exponent less than 0");
        }
        var result: i64 = 1;
        var b = base;
        var e = exponent;
        while (e != 0) : (e >>= 1) {
            if (e & 1 != 0) result *%= b;
            b *%= b;
        }
        return result;
    }

    /// Current value of a variable: unset or empty is 0, and text that is not
    /// a plain number is evaluated as an expression in turn.
    fn lookup(self: *Arith, name: []const u8) Error!i64 {
        if (self.noeval != 0) return 0;
        if (self.sh.getVar(name)) |v| switch (v) {
            .int => |n| return n,
            .boolean => |b| return @intFromBool(b),
            .none => return 0,
            .string => |s| return self.nested(s),
            // The allocating writer fails only when allocation does.
            .float, .list => return self.nested(v.renderAlloc(self.arena) catch return error.OutOfMemory),
        };
        if (self.sh.getEnv(name)) |s| return self.nested(s);
        // Dynamic parameters the expander computes are not stored variables.
        const brace = try std.fmt.allocPrint(self.arena, "${{{s}}}", .{name});
        const dynamic = try expand.expandLiteral(self.sh, self.arena, brace);
        if (dynamic.len != 0) return self.nested(dynamic);
        if (self.sh.options.nounset) {
            setMessage("{s}: unbound variable", .{name});
            return error.InvalidArithmetic;
        }
        return 0;
    }

    fn nested(self: *Arith, src: []const u8) Error!i64 {
        var sub = Arith{ .sh = self.sh, .arena = self.arena, .src = src, .depth = self.depth + 1 };
        return sub.run();
    }

    /// Assigns through `assignVar` (so `readonly` holds) and keeps an exported
    /// variable's environment entry in step.
    fn store(self: *Arith, name: []const u8, v: i64) Error!void {
        if (self.noeval != 0) return;
        self.sh.assignVar(name, .{ .int = v }) catch |err| switch (err) {
            error.ReadonlyVariable => {
                setMessage("{s}: readonly variable", .{name});
                return error.InvalidArithmetic;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (self.sh.options.allexport or self.sh.env.contains(name)) {
            var buf: [24]u8 = undefined;
            const digits = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try self.sh.setEnv(name, digits);
        }
    }
};

const testing = std.testing;

fn expectValue(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8, want: i64) !void {
    const got = evaluate(sh, arena, src) catch |err| {
        std.debug.print("{s}: {s} ({s})\n", .{ src, @errorName(err), errorMessage() });
        return err;
    };
    if (got != want) std.debug.print("{s}: got {d}, want {d}\n", .{ src, got, want });
    try testing.expectEqual(want, got);
}

fn expectFailure(sh: *shell.Shell, arena: std.mem.Allocator, src: []const u8, message: []const u8) !void {
    if (evaluate(sh, arena, src)) |v| {
        std.debug.print("{s}: expected an error, got {d}\n", .{ src, v });
        return error.TestUnexpectedResult;
    } else |_| {}
    try testing.expectEqualStrings(message, errorMessage());
}

test "evaluate integer expressions" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("n", .{ .int = 10 });
    try expectValue(&sh, arena, "1 + 2 * 2", 5);
    try expectValue(&sh, arena, "n + 2", 12);
    try expectValue(&sh, arena, "  ", 0);
    try testing.expectError(error.DivisionByZero, evaluate(&sh, arena, "1 / 0"));
}

test "operators and precedence follow bash" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const cases = [_]struct { []const u8, i64 }{
        .{ "2 ** 3 ** 2", 512 },
        .{ "-2 ** 2", 4 },
        .{ "2 ** 0", 1 },
        .{ "2 ** 63", std.math.minInt(i64) },
        .{ "3 ** 40", -6289078614652622815 },
        .{ "1 < 2 == 1", 1 },
        .{ "5 & 3 | 8 ^ 2", 11 },
        .{ "1 + 2 << 1", 6 },
        .{ "!0 + ~0", 0 },
        .{ "7 % -3", 1 },
        .{ "-7 / 2", -3 },
        .{ "-7 % 3", -1 },
        .{ "1 || 0 && 0", 1 },
        .{ "2 && 3", 1 },
        .{ "0 || 5", 1 },
        .{ "1, 2, 3", 3 },
        .{ "1 ? 2 : 3 ? 4 : 5", 2 },
        .{ "0 ? 2 : 0 ? 4 : 5", 5 },
        .{ "5 > 3 > 0", 1 },
        .{ "10 / 3 * 3", 9 },
        .{ "++5", 5 },
        .{ "--5", 5 },
        .{ "- -5", 5 },
        .{ "!!7", 1 },
        .{ "~5", -6 },
        .{ "(1 + 2) * 3", 9 },
        .{ "1 << 64", 1 },
        .{ "1 << 65", 2 },
        .{ "1 << -1", std.math.minInt(i64) },
        .{ "-8 >> 1", -4 },
        .{ "\t1\t+\n2", 3 },
        .{ "9223372036854775807 + 1", std.math.minInt(i64) },
        .{ "(-9223372036854775807-1) / -1", std.math.minInt(i64) },
        .{ "(-9223372036854775807-1) % -1", 0 },
        .{ "-(-9223372036854775807-1)", std.math.minInt(i64) },
        .{ "9223372036854775807 * 2", -2 },
        .{ "0 && 1 / 0", 0 },
        .{ "1 || 1 / 0", 1 },
        .{ "0 ? 1 / 0 : 2", 2 },
        .{ "0 && 2 ** -1", 0 },
    };
    for (cases) |case| try expectValue(&sh, arena, case[0], case[1]);
}

test "literals in every base" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const cases = [_]struct { []const u8, i64 }{
        .{ "0xff", 255 },
        .{ "0X1F", 31 },
        .{ "017", 15 },
        .{ "0", 0 },
        .{ "0x", 0 },
        .{ "16#ff", 255 },
        .{ "2#1010", 10 },
        .{ "10#09", 9 },
        .{ "36#z", 35 },
        .{ "36#Z", 35 },
        .{ "37#z", 35 },
        .{ "37#A", 36 },
        .{ "64#@", 62 },
        .{ "64#_", 63 },
        .{ "9223372036854775808", std.math.minInt(i64) },
        .{ "99999999999999999999", 7766279631452241919 },
    };
    for (cases) |case| try expectValue(&sh, arena, case[0], case[1]);
}

test "assignments update variables" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("i", .{ .string = "5" });
    try expectValue(&sh, arena, "i++", 5);
    try testing.expectEqual(@as(i64, 6), sh.getVar("i").?.int);
    try expectValue(&sh, arena, "++i", 7);
    try expectValue(&sh, arena, "i--", 7);
    try expectValue(&sh, arena, "--i", 5);
    try expectValue(&sh, arena, "i ++", 5);
    try testing.expectEqual(@as(i64, 6), sh.getVar("i").?.int);

    try sh.setVar("x", .{ .int = 3 });
    try expectValue(&sh, arena, "x+++1", 4);
    try expectValue(&sh, arena, "x---1", 3);
    try expectValue(&sh, arena, "- --x", -2);

    try expectValue(&sh, arena, "a = b = 5", 5);
    try testing.expectEqual(@as(i64, 5), sh.getVar("b").?.int);
    try sh.setVar("a", .{ .int = 7 });
    const compound = [_]struct { []const u8, i64 }{
        .{ "a /= 2", 3 },  .{ "a %= 2", 1 },  .{ "a <<= 4", 16 }, .{ "a >>= 1", 8 },
        .{ "a &= 12", 8 }, .{ "a ^= 5", 13 }, .{ "a |= 16", 29 }, .{ "a += 1", 30 },
        .{ "a -= 2", 28 }, .{ "a *= 2", 56 },
    };
    for (compound) |case| try expectValue(&sh, arena, case[0], case[1]);
    try testing.expectEqual(@as(i64, 56), sh.getVar("a").?.int);

    try expectValue(&sh, arena, "c = 1, c += 2, c *= 3, c", 9);
    try expectValue(&sh, arena, "1 ? d = 2 : 3", 2);
    try testing.expectEqual(@as(i64, 2), sh.getVar("d").?.int);
}

test "skipped operands have no side effects" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try expectValue(&sh, arena, "0 && (y = 5)", 0);
    try expectValue(&sh, arena, "1 || y++", 1);
    try expectValue(&sh, arena, "1 ? 2 : (y += 1)", 2);
    try expectValue(&sh, arena, "0 ? y-- : 3", 3);
    try testing.expect(sh.getVar("y") == null);

    // A variable that would fail to evaluate is not read when skipped.
    try sh.setVar("bad", .{ .string = "1/0" });
    try expectValue(&sh, arena, "0 && bad", 0);
}

test "variables hold expressions" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("x", .{ .string = "2+3" });
    try sh.setVar("y", .{ .string = "x" });
    try expectValue(&sh, arena, "y * 2", 10);
    // `$x` is substituted as text before evaluation, like bash.
    try expectValue(&sh, arena, "$x * 2", 8);
    try expectValue(&sh, arena, "${x} * 2", 8);
    try sh.setVar("pad", .{ .string = " 7 " });
    try expectValue(&sh, arena, "pad + 1", 8);
    try sh.setVar("empty", .{ .string = "" });
    try expectValue(&sh, arena, "empty + 1", 1);
    try sh.setVar("oct", .{ .string = "010" });
    try expectValue(&sh, arena, "oct", 8);
    try sh.setEnv("FROM_ENV", "4");
    try expectValue(&sh, arena, "FROM_ENV * 2", 8);
    try expectValue(&sh, arena, "\"1\" + 2", 3);

    try sh.setVar("self", .{ .string = "self" });
    try expectFailure(&sh, arena, "self", "self: expression recursion level exceeded (error token is \"self\")");
}

test "assignments respect readonly and keep exports in step" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    try sh.setVar("r", .{ .int = 1 });
    try sh.markReadonly("r");
    try expectFailure(&sh, arena, "r = 2", "r: readonly variable");
    try testing.expectEqual(@as(i64, 1), sh.getVar("r").?.int);

    try sh.setEnv("EXPORTED", "1");
    try expectValue(&sh, arena, "EXPORTED += 41", 42);
    try testing.expectEqualStrings("42", sh.getEnv("EXPORTED").?);
    try expectValue(&sh, arena, "local_only = 3", 3);
    try testing.expect(sh.getEnv("local_only") == null);

    sh.options.nounset = true;
    try expectFailure(&sh, arena, "missing + 1", "missing: unbound variable");
    sh.options.nounset = false;
    try expectValue(&sh, arena, "missing + 1", 1);
}

test "errors are worded like bash" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const cases = [_]struct { []const u8, []const u8 }{
        .{ "1 +", "1 +: arithmetic syntax error: operand expected (error token is \"+\")" },
        .{ " 1 2 ", "1 2 : arithmetic syntax error in expression (error token is \"2 \")" },
        .{ "1 / 0", "1 / 0: division by 0 (error token is \"0\")" },
        .{ "a /= 0", "a /= 0: division by 0 (error token is \"0\")" },
        .{ "2 ** -1", "2 ** -1: exponent less than 0 (error token is \"1\")" },
        .{ "08", "08: value too great for base (error token is \"08\")" },
        .{ "2#2", "2#2: value too great for base (error token is \"2#2\")" },
        .{ "65#1", "65#1: invalid arithmetic base (error token is \"65#1\")" },
        .{ "0#1", "0#1: invalid number (error token is \"0#1\")" },
        .{ "2#", "2#: invalid integer constant (error token is \"2#\")" },
        .{ "1 ? 2", "1 ? 2: `:' expected for conditional expression (error token is \"2\")" },
        .{ "1 ? : 3", "1 ? : 3: expression expected (error token is \": 3\")" },
        .{ "5 = 3", "5 = 3: attempted assignment to non-variable (error token is \"= 3\")" },
        .{ "1 + a = 3", "1 + a = 3: attempted assignment to non-variable (error token is \"= 3\")" },
        .{ "--x = 7", "--x = 7: attempted assignment to non-variable (error token is \"= 7\")" },
        .{ "0 ? 1 : b = 3", "0 ? 1 : b = 3: attempted assignment to non-variable (error token is \"= 3\")" },
        .{ "1 @ 2", "1 @ 2: arithmetic syntax error: invalid arithmetic operator (error token is \"@ 2\")" },
        .{ "'1' + 2", "'1' + 2: arithmetic syntax error: operand expected (error token is \"'1' + 2\")" },
        .{ "5++", "5++: arithmetic syntax error: operand expected (error token is \"+\")" },
        .{ "++x++", "++x++: ++: assignment requires lvalue (error token is \"++\")" },
        .{ "()", "(): arithmetic syntax error: operand expected (error token is \")\")" },
        .{ "(1", "(1: missing `)' (error token is \"1\")" },
        .{ "1.5", "1.5: arithmetic syntax error: invalid arithmetic operator (error token is \".5\")" },
    };
    for (cases) |case| try expectFailure(&sh, arena, case[0], case[1]);

    try sh.setVar("partial", .{ .string = "1 +" });
    try expectFailure(&sh, arena, "partial + 1", "1 +: arithmetic syntax error: operand expected (error token is \"+\")");
}

test "deep nesting fails cleanly" {
    var sh = try shell.Shell.initBare(testing.allocator);
    defer sh.deinit();
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    const depth = 5000;
    const deep = try arena.alloc(u8, depth * 2 + 1);
    @memset(deep[0..depth], '(');
    deep[depth] = '1';
    @memset(deep[depth + 1 ..], ')');
    try testing.expectError(error.InvalidArithmetic, evaluate(&sh, arena, deep));

    const negations = try arena.alloc(u8, depth + 1);
    @memset(negations[0..depth], '!');
    negations[depth] = '1';
    try testing.expectError(error.InvalidArithmetic, evaluate(&sh, arena, negations));
}
