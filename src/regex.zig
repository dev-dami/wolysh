//! POSIX extended regular expressions, for `[[ string =~ regex ]]`.
//!
//! Matching runs a Pike VM: all threads advance over the text in lock step, so
//! time is linear in the text for a given pattern and nothing backtracks. The
//! overall match is the leftmost, then the longest, as POSIX requires. Among
//! equally good matches the captures follow the earlier alternative and greedy
//! repetition, which is also what glibc reports. Beyond POSIX, the GNU escapes
//! `\w \W \s \S \b \B \< \> \` \'` are understood; back-references are not,
//! since they cannot be matched in linear time.
//!
//! Text and pattern are read as UTF-8, so `.` and bracket expressions match
//! whole characters and ranges use code point order. Character classes and
//! case folding cover ASCII.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Error = error{
    BadRepetition,
    UnmatchedBrace,
    BadInterval,
    UnmatchedParen,
    UnmatchedBracket,
    BadClass,
    BadCollation,
    BadRange,
    TrailingBackslash,
    TooBig,
    BackReference,
} || Allocator.Error;

/// glibc's wording for each compile error.
pub fn errorMessage(err: Error) []const u8 {
    return switch (err) {
        error.BadRepetition => "Invalid preceding regular expression",
        error.UnmatchedBrace => "Unmatched \\{",
        error.BadInterval => "Invalid content of \\{\\}",
        error.UnmatchedParen => "Unmatched ( or \\(",
        error.UnmatchedBracket => "Unmatched [, [^, [:, [., or [=",
        error.BadClass => "Invalid character class name",
        error.BadCollation => "Invalid collation character",
        error.BadRange => "Invalid range end",
        error.TrailingBackslash => "Trailing backslash",
        error.TooBig => "Regular expression too big",
        error.BackReference => "Back-references are not supported",
        error.OutOfMemory => "Memory exhausted",
    };
}

pub const Options = struct {
    /// Case-insensitive matching, for `shopt -s nocasematch`.
    icase: bool = false,
};

pub const Span = struct {
    start: usize,
    end: usize,
};

pub const Match = struct {
    /// `groups[0]` is the whole match and `groups[n]` the nth parenthesised
    /// group; null for a group that took no part in the match.
    groups: []const ?Span,
};

pub const Regex = struct {
    /// Holds the program, and the result of every `match`.
    allocator: Allocator,
    insts: []const Inst,
    sets: []const Set,
    /// Number of parenthesised groups.
    groups: usize,
    /// Per-thread state: two capture slots per group (group 0 is the whole
    /// match), then two progress-check slots per nullable loop.
    slots: usize,
    icase: bool,

    /// The leftmost-longest match anywhere in `text`, or null.
    pub fn match(self: *const Regex, text: []const u8) Allocator.Error!?Match {
        var vm = try Vm.init(self, text);
        defer vm.deinit();
        return vm.run();
    }
};

pub fn compile(arena: Allocator, pattern: []const u8) Error!Regex {
    return compileOptions(arena, pattern, .{});
}

pub fn compileOptions(arena: Allocator, pattern: []const u8, options: Options) Error!Regex {
    var parser = Parser{ .arena = arena, .src = pattern };
    const root = try parser.parseAlternation();
    // Outside a group an unmatched `)` is a literal, so nothing is left over.
    std.debug.assert(parser.pos == pattern.len);

    var compiler = Compiler{ .arena = arena, .loop_base = 2 * (parser.groups + 1) };
    _ = try compiler.emit(.{ .save = 0 });
    try compiler.gen(root);
    _ = try compiler.emit(.{ .save = 1 });
    _ = try compiler.emit(.match);
    return .{
        .allocator = arena,
        .insts = compiler.insts.items,
        .sets = parser.sets.items,
        .groups = parser.groups,
        .slots = compiler.loop_base + 2 * parser.loops,
        .icase = options.icase,
    };
}

/// Patterns that nest or stack quantifiers deeper than this are rejected,
/// which bounds recursion in the parser and code generator.
const max_nesting = 1000;
/// Program size limit; counted repetition multiplies a pattern's size.
const max_insts = 100_000;
/// Largest `{m,n}` bound, as in glibc.
const dup_max = 0x7fff;

const Assert = enum { start, end, word_boundary, not_word_boundary, word_start, word_end };

const Class = enum { alpha, digit, alnum, upper, lower, space, blank, punct, print, graph, cntrl, xdigit, word };

const class_names = [_]struct { []const u8, Class }{
    .{ "alpha", .alpha }, .{ "digit", .digit }, .{ "alnum", .alnum }, .{ "upper", .upper },
    .{ "lower", .lower }, .{ "space", .space }, .{ "blank", .blank }, .{ "punct", .punct },
    .{ "print", .print }, .{ "graph", .graph }, .{ "cntrl", .cntrl }, .{ "xdigit", .xdigit },
};

const Range = struct { lo: u21, hi: u21 };

const Set = struct {
    ranges: []const Range,
    classes: std.EnumSet(Class) = .initEmpty(),
    negated: bool = false,

    fn contains(self: Set, c: u21) bool {
        for (self.ranges) |r| {
            if (c >= r.lo and c <= r.hi) return true;
        }
        var it = self.classes.iterator();
        while (it.next()) |class| {
            if (classContains(class, c)) return true;
        }
        return false;
    }

    fn matches(self: Set, c: u21, icase: bool) bool {
        var hit = self.contains(c);
        if (!hit and icase) hit = self.contains(foldLower(c)) or self.contains(foldUpper(c));
        return hit != self.negated;
    }
};

fn classContains(class: Class, c: u21) bool {
    if (c > 0x7f) return false;
    const b: u8 = @intCast(c);
    return switch (class) {
        .alpha => std.ascii.isAlphabetic(b),
        .digit => std.ascii.isDigit(b),
        .alnum => std.ascii.isAlphanumeric(b),
        .upper => std.ascii.isUpper(b),
        .lower => std.ascii.isLower(b),
        .space => std.ascii.isWhitespace(b),
        .blank => b == ' ' or b == '\t',
        .punct => std.ascii.isPunctuation(b),
        .print => std.ascii.isPrint(b),
        .graph => std.ascii.isGraphical(b),
        .cntrl => std.ascii.isControl(b),
        .xdigit => std.ascii.isHex(b),
        .word => std.ascii.isAlphanumeric(b) or b == '_',
    };
}

fn foldLower(c: u21) u21 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

fn foldUpper(c: u21) u21 {
    return if (c >= 'a' and c <= 'z') c - 32 else c;
}

const Char = struct { cp: u21, len: usize };

/// The character at `pos`. A byte that does not start valid UTF-8 stands for
/// itself, mapped above the Unicode range so it only equals the same byte.
fn decodeAt(s: []const u8, pos: usize) Char {
    const b = s[pos];
    if (b < 0x80) return .{ .cp = b, .len = 1 };
    const raw = Char{ .cp = 0x110000 + @as(u21, b), .len = 1 };
    const n = std.unicode.utf8ByteSequenceLength(b) catch return raw;
    if (pos + n > s.len) return raw;
    const cp = std.unicode.utf8Decode(s[pos..][0..n]) catch return raw;
    return .{ .cp = cp, .len = n };
}

// --- parsing -----------------------------------------------------------------

const Node = union(enum) {
    empty,
    char: u21,
    any,
    set: u32,
    assert: Assert,
    group: struct { index: u32, child: *const Node },
    concat: []const Node,
    alternate: []const Node,
    /// `loop` numbers the progress-check slots of a repeat whose body can
    /// match empty and that has optional iterations.
    repeat: struct { child: *const Node, min: u32, max: ?u32, loop: ?u32 },
};

/// Whether `node` can match the empty string.
fn nullable(node: Node) bool {
    return switch (node) {
        .empty, .assert => true,
        .char, .any, .set => false,
        .group => |g| nullable(g.child.*),
        .concat => |items| for (items) |item| {
            if (!nullable(item)) break false;
        } else true,
        .alternate => |branches| for (branches) |branch| {
            if (nullable(branch)) break true;
        } else false,
        .repeat => |r| r.min == 0 or nullable(r.child.*),
    };
}

const Parser = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    groups: u32 = 0,
    loops: u32 = 0,
    depth: u32 = 0,
    sets: std.ArrayList(Set) = .empty,

    fn parseAlternation(self: *Parser) Error!Node {
        var branches: std.ArrayList(Node) = .empty;
        try branches.append(self.arena, try self.parseBranch());
        while (self.pos < self.src.len and self.src[self.pos] == '|') {
            self.pos += 1;
            try branches.append(self.arena, try self.parseBranch());
        }
        if (branches.items.len == 1) return branches.items[0];
        return .{ .alternate = branches.items };
    }

    fn parseBranch(self: *Parser) Error!Node {
        var items: std.ArrayList(Node) = .empty;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '|' or (c == ')' and self.depth > 0)) break;
            const atom = try self.parseAtom();
            try items.append(self.arena, try self.parseQuantifiers(atom));
        }
        return switch (items.items.len) {
            0 => .empty,
            1 => items.items[0],
            else => .{ .concat = items.items },
        };
    }

    fn parseAtom(self: *Parser) Error!Node {
        const c = self.src[self.pos];
        switch (c) {
            '(' => {
                self.pos += 1;
                self.depth += 1;
                if (self.depth > max_nesting) return error.TooBig;
                self.groups += 1;
                const index = self.groups;
                const child = try self.parseAlternation();
                if (self.pos >= self.src.len or self.src[self.pos] != ')') return error.UnmatchedParen;
                self.pos += 1;
                self.depth -= 1;
                return .{ .group = .{ .index = index, .child = try self.box(child) } };
            },
            '.' => {
                self.pos += 1;
                return .any;
            },
            '^', '$' => {
                self.pos += 1;
                return .{ .assert = if (c == '^') .start else .end };
            },
            '[' => return .{ .set = try self.parseBracket() },
            '*', '+', '?', '{' => return error.BadRepetition,
            '\\' => return self.parseEscape(),
            else => {
                const ch = decodeAt(self.src, self.pos);
                self.pos += ch.len;
                return .{ .char = ch.cp };
            },
        }
    }

    fn parseEscape(self: *Parser) Error!Node {
        if (self.pos + 1 >= self.src.len) return error.TrailingBackslash;
        const c = self.src[self.pos + 1];
        self.pos += 2;
        return switch (c) {
            '1'...'9' => error.BackReference,
            'w', 'W' => .{ .set = try self.addSet(.{ .ranges = &.{}, .classes = .initOne(.word), .negated = c == 'W' }) },
            's', 'S' => .{ .set = try self.addSet(.{ .ranges = &.{}, .classes = .initOne(.space), .negated = c == 'S' }) },
            'b' => .{ .assert = .word_boundary },
            'B' => .{ .assert = .not_word_boundary },
            '<' => .{ .assert = .word_start },
            '>' => .{ .assert = .word_end },
            '`' => .{ .assert = .start },
            '\'' => .{ .assert = .end },
            else => blk: {
                const ch = decodeAt(self.src, self.pos - 1);
                self.pos += ch.len - 1;
                break :blk .{ .char = ch.cp };
            },
        };
    }

    fn parseQuantifiers(self: *Parser, atom: Node) Error!Node {
        var node = atom;
        var stacked: u32 = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            var min: u32 = 0;
            var max: ?u32 = null;
            switch (c) {
                '*' => self.pos += 1,
                '+' => {
                    self.pos += 1;
                    min = 1;
                },
                '?' => {
                    self.pos += 1;
                    max = 1;
                },
                '{' => {
                    self.pos += 1;
                    const bounds = try self.parseInterval();
                    min = bounds.min;
                    max = bounds.max;
                },
                else => break,
            }
            if (node == .assert) return error.BadRepetition;
            stacked += 1;
            if (self.depth + stacked > max_nesting) return error.TooBig;
            var loop: ?u32 = null;
            if ((max == null or max.? != min) and nullable(node)) {
                loop = self.loops;
                self.loops += 1;
            }
            // Boxed first: assigning in one expression would alias `node`.
            const child = try self.box(node);
            node = .{ .repeat = .{ .child = child, .min = min, .max = max, .loop = loop } };
        }
        return node;
    }

    const Fetched = struct { value: i32, stop: u8 };

    /// Reads digits up to `}` or `,` the way glibc does: -1 when there are
    /// none, -2 when something else is in the way or the pattern ends (`stop`
    /// is then 0).
    fn fetchNumber(self: *Parser) Fetched {
        var num: i32 = -1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '}' or c == ',') return .{ .value = num, .stop = c };
            if (c < '0' or c > '9' or num == -2) {
                num = -2;
            } else {
                num = if (num == -1) c - '0' else @min(dup_max + 1, num * 10 + (c - '0'));
            }
        }
        return .{ .value = -2, .stop = 0 };
    }

    fn parseInterval(self: *Parser) Error!struct { min: u32, max: ?u32 } {
        var first = self.fetchNumber();
        if (first.value == -1) {
            // `{,n}` means `{0,n}`; `{}` is invalid.
            if (first.stop != ',') return error.BadInterval;
            first.value = 0;
        }
        var stop = first.stop;
        var last: i32 = -2;
        if (first.value != -2) {
            if (first.stop == '}') {
                last = first.value;
            } else if (first.stop == ',') {
                const second = self.fetchNumber();
                last = second.value;
                stop = second.stop;
            }
        }
        if (first.value == -2 or last == -2) return if (stop == 0) error.UnmatchedBrace else error.BadInterval;
        if ((last != -1 and first.value > last) or stop != '}') return error.BadInterval;
        if ((if (last == -1) first.value else last) > dup_max) return error.TooBig;
        return .{ .min = @intCast(first.value), .max = if (last == -1) null else @intCast(last) };
    }

    fn parseBracket(self: *Parser) Error!u32 {
        const s = self.src;
        self.pos += 1;
        var set = Set{ .ranges = &.{} };
        if (self.pos < s.len and s[self.pos] == '^') {
            set.negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayList(Range) = .empty;
        var first = true;
        while (true) {
            if (self.pos >= s.len) return error.UnmatchedBracket;
            if (s[self.pos] == ']' and !first) {
                self.pos += 1;
                break;
            }
            first = false;
            const lo = switch (try self.bracketElement()) {
                .class => |class| {
                    set.classes.insert(class);
                    if (self.rangeFollows()) return error.BadRange;
                    continue;
                },
                .char => |c| c,
            };
            if (!self.rangeFollows()) {
                try ranges.append(self.arena, .{ .lo = lo, .hi = lo });
                continue;
            }
            self.pos += 1;
            const hi = switch (try self.bracketElement()) {
                .class => return error.BadRange,
                .char => |c| c,
            };
            if (hi < lo) return error.BadRange;
            try ranges.append(self.arena, .{ .lo = lo, .hi = hi });
            // `[a-c-e]`: a range cannot start where another ended.
            if (self.rangeFollows()) return error.BadRange;
        }
        set.ranges = ranges.items;
        return self.addSet(set);
    }

    /// True at a `-` that forms a range rather than ending the expression.
    fn rangeFollows(self: *const Parser) bool {
        return self.pos + 1 < self.src.len and self.src[self.pos] == '-' and self.src[self.pos + 1] != ']';
    }

    const Element = union(enum) { char: u21, class: Class };

    /// One bracket-expression item: a character, `[:class:]`, or a
    /// single-character `[.c.]` or `[=c=]`. Backslash is literal here.
    fn bracketElement(self: *Parser) Error!Element {
        const s = self.src;
        if (s[self.pos] == '[' and self.pos + 1 < s.len and std.mem.indexOfScalar(u8, ":.=", s[self.pos + 1]) != null) {
            const kind = s[self.pos + 1];
            const close = [2]u8{ kind, ']' };
            const end = std.mem.indexOfPos(u8, s, self.pos + 2, &close) orelse return error.UnmatchedBracket;
            const name = s[self.pos + 2 .. end];
            self.pos = end + 2;
            if (kind == ':') {
                for (class_names) |entry| {
                    if (std.mem.eql(u8, name, entry[0])) return .{ .class = entry[1] };
                }
                return error.BadClass;
            }
            if (name.len == 0) return error.BadCollation;
            const ch = decodeAt(name, 0);
            if (ch.len != name.len) return error.BadCollation;
            return .{ .char = ch.cp };
        }
        const ch = decodeAt(s, self.pos);
        self.pos += ch.len;
        return .{ .char = ch.cp };
    }

    fn addSet(self: *Parser, set: Set) Error!u32 {
        try self.sets.append(self.arena, set);
        return @intCast(self.sets.items.len - 1);
    }

    fn box(self: *Parser, node: Node) Error!*const Node {
        const ptr = try self.arena.create(Node);
        ptr.* = node;
        return ptr;
    }
};

// --- code generation -----------------------------------------------------------

const Inst = union(enum) {
    char: u21,
    any,
    set: u32,
    /// Try the first target before the second.
    split: [2]u32,
    jmp: u32,
    save: u32,
    assert: Assert,
    /// Sets a loop's "has iterated" slot to 1 (`on`) or unset.
    flag: struct { slot: u32, on: bool },
    /// Ends an iteration of a loop whose body can match empty. An iteration
    /// that consumed nothing leaves the loop at `exit` if it was the first one
    /// and fails otherwise, so empty iterations neither repeat forever nor
    /// replace the captures of a real one.
    progress: struct { start: u32, flag: u32, exit: u32 },
    match,
};

const Compiler = struct {
    arena: Allocator,
    insts: std.ArrayList(Inst) = .empty,
    /// First slot after the capture slots; loop `n` uses the two after
    /// `loop_base + 2n`.
    loop_base: u32,

    fn emit(self: *Compiler, inst: Inst) Error!u32 {
        if (self.insts.items.len >= max_insts) return error.TooBig;
        try self.insts.append(self.arena, inst);
        return @intCast(self.insts.items.len - 1);
    }

    fn here(self: *const Compiler) u32 {
        return @intCast(self.insts.items.len);
    }

    fn gen(self: *Compiler, node: Node) Error!void {
        switch (node) {
            .empty => {},
            .char => |c| _ = try self.emit(.{ .char = c }),
            .any => _ = try self.emit(.any),
            .set => |index| _ = try self.emit(.{ .set = index }),
            .assert => |a| _ = try self.emit(.{ .assert = a }),
            .group => |g| {
                _ = try self.emit(.{ .save = 2 * g.index });
                try self.gen(g.child.*);
                _ = try self.emit(.{ .save = 2 * g.index + 1 });
            },
            .concat => |items| for (items) |item| try self.gen(item),
            .alternate => |branches| {
                var jumps: std.ArrayList(u32) = .empty;
                for (branches[0 .. branches.len - 1]) |branch| {
                    const split = try self.emit(.{ .split = .{ 0, 0 } });
                    try self.gen(branch);
                    try jumps.append(self.arena, try self.emit(.{ .jmp = 0 }));
                    self.insts.items[split].split = .{ split + 1, self.here() };
                }
                try self.gen(branches[branches.len - 1]);
                for (jumps.items) |jump| self.insts.items[jump].jmp = self.here();
            },
            .repeat => |r| {
                var i: u32 = 0;
                while (i < r.min) : (i += 1) try self.gen(r.child.*);
                const start = self.loop_base + 2 * (r.loop orelse 0);
                const flag = start + 1;
                if (r.loop != null) _ = try self.emit(.{ .flag = .{ .slot = flag, .on = r.min > 0 } });
                // Every split and progress check below exits to the end.
                var exits: std.ArrayList(u32) = .empty;
                const count = r.max orelse r.min + 1;
                const first = self.here();
                while (i < count) : (i += 1) {
                    try exits.append(self.arena, try self.emit(.{ .split = .{ 0, 0 } }));
                    if (r.loop != null) _ = try self.emit(.{ .save = start });
                    try self.gen(r.child.*);
                    if (r.loop != null) try exits.append(self.arena, try self.emit(.{ .progress = .{ .start = start, .flag = flag, .exit = 0 } }));
                }
                if (r.max == null) _ = try self.emit(.{ .jmp = first });
                const end = self.here();
                for (exits.items) |at| switch (self.insts.items[at]) {
                    .split => self.insts.items[at].split = .{ at + 1, end },
                    .progress => self.insts.items[at].progress.exit = end,
                    else => unreachable,
                };
            },
        }
    }
};

// --- matching ------------------------------------------------------------------

const unset = std.math.maxInt(usize);

/// Threads waiting at consuming instructions, in priority order, each with
/// its capture slots.
const ThreadList = struct {
    pcs: std.ArrayList(u32) = .empty,
    caps: std.ArrayList(usize) = .empty,

    fn clear(self: *ThreadList) void {
        self.pcs.clearRetainingCapacity();
        self.caps.clearRetainingCapacity();
    }
};

const Frame = union(enum) {
    explore: u32,
    restore: struct { slot: u32, value: usize },
};

const Vm = struct {
    re: *const Regex,
    text: []const u8,
    nslots: usize,
    /// Generation in which each instruction was last reached, so a closure
    /// visits it at most once per position.
    mark: []u32,
    generation: u32 = 0,
    work: []usize,
    best: []usize,
    found: bool = false,
    stack: std.ArrayList(Frame) = .empty,
    clist: ThreadList = .{},
    nlist: ThreadList = .{},

    fn init(re: *const Regex, text: []const u8) Allocator.Error!Vm {
        const nslots = re.slots;
        const mark = try re.allocator.alloc(u32, re.insts.len);
        @memset(mark, 0);
        return .{
            .re = re,
            .text = text,
            .nslots = nslots,
            .mark = mark,
            .work = try re.allocator.alloc(usize, nslots),
            .best = try re.allocator.alloc(usize, nslots),
        };
    }

    fn deinit(self: *Vm) void {
        const gpa = self.re.allocator;
        self.nlist.caps.deinit(gpa);
        self.nlist.pcs.deinit(gpa);
        self.clist.caps.deinit(gpa);
        self.clist.pcs.deinit(gpa);
        self.stack.deinit(gpa);
        gpa.free(self.best);
        gpa.free(self.work);
        gpa.free(self.mark);
    }

    fn run(self: *Vm) Allocator.Error!?Match {
        const text = self.text;
        var pos: usize = 0;
        self.generation += 1;
        while (true) {
            // Later starts only matter until something has matched.
            if (!self.found) {
                @memset(self.work, unset);
                try self.addThread(&self.clist, 0, pos);
            }
            if (self.clist.pcs.items.len == 0 and (self.found or pos >= text.len)) break;

            const ch: ?Char = if (pos < text.len) decodeAt(text, pos) else null;
            self.generation += 1;
            self.nlist.clear();
            for (self.clist.pcs.items, 0..) |pc, index| {
                const caps = self.clist.caps.items[index * self.nslots ..][0..self.nslots];
                if (self.found and caps[0] > self.best[0]) continue;
                const advance = switch (self.re.insts[pc]) {
                    .match => {
                        if (!self.found or caps[0] < self.best[0] or (caps[0] == self.best[0] and caps[1] > self.best[1])) {
                            @memcpy(self.best, caps);
                            self.found = true;
                        }
                        continue;
                    },
                    .char => |want| if (ch) |got| self.charEquals(want, got.cp) else false,
                    .any => ch != null,
                    .set => |set| if (ch) |got| self.re.sets[set].matches(got.cp, self.re.icase) else false,
                    else => unreachable,
                };
                if (advance) {
                    @memcpy(self.work, caps);
                    try self.addThread(&self.nlist, pc + 1, pos + ch.?.len);
                }
            }
            const step = ch orelse break;
            pos += step.len;
            std.mem.swap(ThreadList, &self.clist, &self.nlist);
        }
        if (!self.found) return null;

        const groups = try self.re.allocator.alloc(?Span, self.re.groups + 1);
        for (groups, 0..) |*group, i| {
            const start = self.best[2 * i];
            const end = self.best[2 * i + 1];
            group.* = if (start == unset or end == unset) null else .{ .start = start, .end = end };
        }
        return .{ .groups = groups };
    }

    fn charEquals(self: *const Vm, want: u21, got: u21) bool {
        if (want == got) return true;
        return self.re.icase and foldLower(want) == foldLower(got);
    }

    /// Follows every non-consuming instruction reachable from `start` at
    /// `pos`, in priority order, adding the consuming ones to `list` with the
    /// slots in `work`. Slot writes are undone on the way back, so `work` ends
    /// as it began.
    fn addThread(self: *Vm, list: *ThreadList, start: u32, pos: usize) Allocator.Error!void {
        const gpa = self.re.allocator;
        try self.stack.append(gpa, .{ .explore = start });
        while (self.stack.pop()) |frame| {
            var pc = switch (frame) {
                .restore => |r| {
                    self.work[r.slot] = r.value;
                    continue;
                },
                .explore => |target| target,
            };
            while (true) {
                // A progress check's outcome depends on the thread's slots, so
                // a later path may pass where an earlier one failed. It cannot
                // loop: the iteration it ends began with a marked `save`.
                if (self.re.insts[pc] != .progress) {
                    if (self.mark[pc] == self.generation) break;
                    self.mark[pc] = self.generation;
                }
                switch (self.re.insts[pc]) {
                    .jmp => |target| pc = target,
                    .split => |targets| {
                        try self.stack.append(gpa, .{ .explore = targets[1] });
                        pc = targets[0];
                    },
                    .save => |slot| {
                        try self.setSlot(slot, pos);
                        pc += 1;
                    },
                    .flag => |f| {
                        try self.setSlot(f.slot, if (f.on) 1 else unset);
                        pc += 1;
                    },
                    .progress => |p| {
                        if (self.work[p.start] != pos) {
                            try self.setSlot(p.flag, 1);
                            pc += 1;
                        } else if (self.work[p.flag] == unset) {
                            pc = p.exit;
                        } else {
                            break;
                        }
                    },
                    .assert => |a| {
                        if (!assertHolds(a, self.text, pos)) break;
                        pc += 1;
                    },
                    .char, .any, .set, .match => {
                        try list.pcs.append(gpa, pc);
                        try list.caps.appendSlice(gpa, self.work);
                        break;
                    },
                }
            }
        }
    }

    fn setSlot(self: *Vm, slot: u32, value: usize) Allocator.Error!void {
        try self.stack.append(self.re.allocator, .{ .restore = .{ .slot = slot, .value = self.work[slot] } });
        self.work[slot] = value;
    }
};

fn isWordByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

fn assertHolds(a: Assert, text: []const u8, pos: usize) bool {
    const before = pos > 0 and isWordByte(text[pos - 1]);
    const after = pos < text.len and isWordByte(text[pos]);
    return switch (a) {
        .start => pos == 0,
        .end => pos == text.len,
        .word_boundary => before != after,
        .not_word_boundary => before == after,
        .word_start => !before and after,
        .word_end => before and !after,
    };
}

// --- tests -------------------------------------------------------------------

const testing = std.testing;

/// Matches `pattern` against `text` and renders the result like bash's
/// BASH_REMATCH: the groups joined by `|`, an unset group as `-`, or null for
/// no match.
fn render(arena: Allocator, pattern: []const u8, text: []const u8, options: Options) !?[]const u8 {
    const re = try compileOptions(arena, pattern, options);
    const m = (try re.match(text)) orelse return null;
    var out: std.ArrayList(u8) = .empty;
    for (m.groups, 0..) |group, i| {
        if (i != 0) try out.append(arena, '|');
        if (group) |span| {
            try out.appendSlice(arena, text[span.start..span.end]);
        } else {
            try out.append(arena, '-');
        }
    }
    return out.items;
}

fn expectMatch(pattern: []const u8, text: []const u8, want: ?[]const u8) !void {
    return expectMatchOptions(pattern, text, want, .{});
}

fn expectMatchOptions(pattern: []const u8, text: []const u8, want: ?[]const u8, options: Options) !void {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const got = try render(state.allocator(), pattern, text, options);
    if (want) |w| {
        if (got == null or !std.mem.eql(u8, got.?, w)) {
            std.debug.print("/{s}/ on \"{s}\": got {?s}, want {s}\n", .{ pattern, text, got, w });
            return error.TestUnexpectedResult;
        }
    } else if (got) |g| {
        std.debug.print("/{s}/ on \"{s}\": got {s}, want no match\n", .{ pattern, text, g });
        return error.TestUnexpectedResult;
    }
}

fn expectCompileError(pattern: []const u8, want: Error) !void {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    try testing.expectError(want, compile(state.allocator(), pattern));
}

test "literals, dot, anchors and alternation" {
    try expectMatch("abc", "xxabcxx", "abc");
    try expectMatch("abc", "ab", null);
    try expectMatch("a.c", "abc", "abc");
    try expectMatch("a.c", "a\nc", "a\nc");
    try expectMatch("^ab", "ab", "ab");
    try expectMatch("^ab", "cab", null);
    try expectMatch("ab$", "cab", "ab");
    try expectMatch("ab$", "abc", null);
    try expectMatch("^$", "", "");
    try expectMatch("a^b", "a^b", null);
    try expectMatch("a$b", "a$b", null);
    try expectMatch("(^a|b)", "ba", "b|b");
    try expectMatch("cat|dog", "hotdog", "dog");
    try expectMatch("a||b", "b", "b");
    try expectMatch("a|", "b", "");
    try expectMatch("(|a)b", "ab", "ab|a");
    try expectMatch("x*", "abc", "");
    try expectMatch("a)", "a)", "a)");
}

test "leftmost then longest" {
    try expectMatch("b*|abc", "abc", "abc");
    try expectMatch("a|ab|abc", "abcd", "abc");
    try expectMatch("abcd|c", "abcd", "abcd");
    try expectMatch("(a|ab)(c|bcd)(d*)", "abcd", "abcd|a|bcd|");
    try expectMatch("(a|ab)(bc|c)", "abc", "abc|a|bc");
    try expectMatch("(ab|a)(bc|c)?", "abc", "abc|ab|c");
    try expectMatch("(a*)(a*)", "aa", "aa|aa|");
    try expectMatch("(.*)-(.*)", "a-b-c", "a-b-c|a-b|c");
    try expectMatch("([0-9]+)\\.([0-9]+)", "v10.20.3", "10.20|10|20");
    try expectMatch("(a|(b))*", "ba", "ba|a|b");
    try expectMatch("(a){2,3}", "aaaa", "aaa|a");
    try expectMatch("(a)|b", "b", "b|-");
    try expectMatch("(a)(b)?", "a", "a|a|-");
    try expectMatch("()", "x", "|");
    try expectMatch("(^)*", "b", "|");
    try expectMatch("(a*)*", "b", "|");
    try expectMatch("(a*)*", "aa", "aa|aa");
    try expectMatch("(a|b)*c", "abac", "abac|a");
    try expectMatch("(a|)+", "aa", "aa|a");
    try expectMatch("(a?)*", "ab", "a|a");
    try expectMatch("(a*)*b", "aab", "aab|aa");
    try expectMatch("(a*){0,3}", "b", "|");
    try expectMatch("(b|a*)*", "ab", "ab|b");
    try expectMatch("((a)|b)*", "ab", "ab|b|a");
    try expectMatch("(a*)+", "aab", "aa|aa");
}

test "repetition" {
    try expectMatch("a*", "aaa", "aaa");
    try expectMatch("a+", "baaa", "aaa");
    try expectMatch("ba?c", "bc", "bc");
    try expectMatch("a**", "aaa", "aaa");
    try expectMatch("a+?", "aaa", "aaa");
    try expectMatch("a{3}", "aaaa", "aaa");
    try expectMatch("a{2,}", "aaaa", "aaaa");
    try expectMatch("a{1,2}", "aaa", "aa");
    try expectMatch("a{,2}", "aaa", "aa");
    try expectMatch("a{,}", "aaa", "aaa");
    try expectMatch("a{0}b", "ab", "b");
    try expectMatch("(a{0})b", "ab", "b|");
    try expectMatch("a{1,2}{2}", "aaaa", "aaaa");
    try expectMatch("a{1,2}?", "aaa", "aa");
    try expectMatch("a\\{2\\}", "a{2}", "a{2}");
}

test "bracket expressions" {
    try expectMatch("[abc]+", "xxbcay", "bca");
    try expectMatch("[^abc]+", "abxyc", "xy");
    try expectMatch("[a-c]+", "xabcd", "abc");
    try expectMatch("[]a]+", "x]a]", "]a]");
    try expectMatch("[^]a]+", "]xy", "xy");
    try expectMatch("[a-]+", "x-a-", "-a-");
    try expectMatch("[%--]", "+", "+");
    try expectMatch("[\\n]", "\\", "\\");
    try expectMatch("[a\\]]+", "a\\]", "\\]");
    try expectMatch("[[:alpha:][:digit:]]+", "--a1b2--", "a1b2");
    try expectMatch("[[:space:]]+", "a \t\nb", " \t\n");
    try expectMatch("[[:upper:][:punct:]]+", "aB!c", "B!");
    try expectMatch("[[:xdigit:]]+", "xyzBEEF", "BEEF");
    try expectMatch("[[.-.]]", "-", "-");
    try expectMatch("[[=a=]]", "a", "a");
    try expectMatch("[^a]", "\n", "\n");
    try expectMatch("[é]", "xé", "é");
    try expectMatch("^.$", "é", "é");
    try expectMatch("[^a]", "é", "é");
}

test "escapes" {
    try expectMatch("\\.", "a.b", ".");
    try expectMatch("\\n", "n", "n");
    try expectMatch("\\x", "x", "x");
    try expectMatch("a\\|b", "a|b", "a|b");
    try expectMatch("\\(a\\)", "(a)", "(a)");
    try expectMatch("\\w+", "  ab_1 ", "ab_1");
    try expectMatch("\\W+", "ab, cd", ", ");
    try expectMatch("\\s\\S", "a b", " b");
    try expectMatch("\\bb", "ab b", "b");
    try expectMatch("\\<b\\>", "ab b", "b");
    try expectMatch("\\B", "ab", "");
    try expectMatch("a\\'", "ba", "a");
    try expectMatch("\\`a", "ba", null);
    try expectMatch("\\>a", "a", null);
    try expectMatch("\\*", "a*", "*");
}

test "case-insensitive matching" {
    try expectMatchOptions("A", "xa", "a", .{ .icase = true });
    try expectMatchOptions("[B-D]+", "abcde", "bcd", .{ .icase = true });
    try expectMatchOptions("[[:upper:]]+", "abC", "abC", .{ .icase = true });
    try expectMatchOptions("[^a]", "A", null, .{ .icase = true });
    try expectMatch("A", "a", null);
}

test "invalid patterns" {
    try expectCompileError("*a", error.BadRepetition);
    try expectCompileError("+a", error.BadRepetition);
    try expectCompileError("a|*b", error.BadRepetition);
    try expectCompileError("(*b)", error.BadRepetition);
    try expectCompileError("^*b", error.BadRepetition);
    try expectCompileError("$*", error.BadRepetition);
    try expectCompileError("\\b*", error.BadRepetition);
    try expectCompileError("{a}", error.BadRepetition);
    try expectCompileError("a{", error.UnmatchedBrace);
    try expectCompileError("a{1", error.UnmatchedBrace);
    try expectCompileError("a{1x", error.UnmatchedBrace);
    try expectCompileError("a{x}", error.BadInterval);
    try expectCompileError("a{}", error.BadInterval);
    try expectCompileError("a{2,1}", error.BadInterval);
    try expectCompileError("a{1,2,3}", error.BadInterval);
    try expectCompileError("a{32768}", error.TooBig);
    try expectCompileError("(a", error.UnmatchedParen);
    try expectCompileError("[a", error.UnmatchedBracket);
    try expectCompileError("[]", error.UnmatchedBracket);
    try expectCompileError("[[:alpha:]", error.UnmatchedBracket);
    try expectCompileError("[[:alpha", error.UnmatchedBracket);
    try expectCompileError("[[:foo:]]", error.BadClass);
    try expectCompileError("[[.space.]]", error.BadCollation);
    try expectCompileError("[z-a]", error.BadRange);
    try expectCompileError("[a-c-e]", error.BadRange);
    try expectCompileError("[[:alpha:]-z]", error.BadRange);
    try expectCompileError("[a-[:alpha:]]", error.BadRange);
    try expectCompileError("\\", error.TrailingBackslash);
    try expectCompileError("(a)\\1", error.BackReference);
    try expectCompileError("(((a{100}){100}){100})", error.TooBig);
    try testing.expectEqualStrings("Unmatched ( or \\(", errorMessage(error.UnmatchedParen));
}

test "matching time is linear in the text" {
    var state = std.heap.ArenaAllocator.init(testing.allocator);
    defer state.deinit();
    const arena = state.allocator();

    // Exponential for a backtracking matcher.
    const text = try arena.alloc(u8, 5000);
    @memset(text, 'a');
    const re = try compile(arena, "(a*)*(a|aa)*b");
    try testing.expect((try re.match(text)) == null);
    const nested = try compile(arena, "^(a+)+$");
    const m = (try nested.match(text)).?;
    try testing.expectEqual(@as(usize, 5000), m.groups[0].?.end);
}

test "invalid UTF-8 bytes match only themselves" {
    try expectMatch("\xff", "a\xffb", "\xff");
    try expectMatch(".", "\xff", "\xff");
    try expectMatch("[^a]", "\xfe", "\xfe");
    try expectMatch("\xff", "\xfe", null);
}
