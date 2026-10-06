//! Abstract syntax tree for wolysh.
//!
//! wolysh keeps commands and language expressions in the same grammar but in
//! different positions: at statement level an unquoted word starts a *command*,
//! while keywords (`let`, `if`, `for`, `while`, `fn`, `return`, `env`, `alias`)
//! introduce language constructs whose operands are *expressions*. Control
//! flow (`if`, loops, `case`, `select`) is a compound *command*, so it can be
//! redirected, piped and backgrounded like any other command.

const std = @import("std");

/// A shell word: raw source text including any quotes. Quote handling,
/// variable expansion, command substitution and globbing all happen in the
/// expander, which is why the AST keeps the raw slice.
pub const Word = []const u8;

pub const RedirectKind = enum {
    out,
    out_append,
    in,
    here_doc,
    /// `<<<word`: the expanded word becomes standard input.
    here_string,
    err_out,
    err_append,
    out_dup,
    err_dup,
    in_dup,
    /// `>|`: truncate even when `noclobber` is set.
    clobber,
    /// `<>`: open read-write, creating but never truncating.
    read_write,

    pub fn fd(self: RedirectKind) i32 {
        return switch (self) {
            .in, .here_doc, .here_string, .in_dup, .read_write => 0,
            .err_out, .err_append, .err_dup => 2,
            else => 1,
        };
    }

    pub fn isInput(self: RedirectKind) bool {
        return self == .in or self == .here_doc or self == .here_string;
    }

    pub fn append(self: RedirectKind) bool {
        return self == .out_append or self == .err_append;
    }

    pub fn duplicates(self: RedirectKind) bool {
        return self == .out_dup or self == .err_dup or self == .in_dup;
    }
};

pub const Redirect = struct {
    kind: RedirectKind,
    target: Word,
    body: []const u8 = "",
    expand_body: bool = true,
    /// Explicit `N` written before the operator; negative when absent, in which
    /// case the kind's own descriptor is used.
    fd: i32 = -1,
    /// `<<-`: strip leading tabs from the body and the delimiter line.
    strip_tabs: bool = false,
    /// `{name}>file`: the shell picks a free descriptor (10 or above), stores
    /// its number in `name`, and leaves it open after the command.
    fd_var: []const u8 = "",

    pub fn targetFd(self: Redirect) i32 {
        return if (self.fd >= 0) self.fd else self.kind.fd();
    }
};

/// A `NAME=value` word in command-prefix position.
pub const PrefixAssign = struct {
    name: []const u8,
    value: Word,
    /// `NAME[subscript]=value`: the raw subscript text.
    index: ?[]const u8 = null,
    /// `NAME+=value`.
    append: bool = false,
    /// `NAME=(...)`: `value` is the raw text between the parentheses.
    compound: bool = false,
};

pub const Command = struct {
    words: []Word,
    redirects: []Redirect,
    subshell: ?[]Stmt = null,
    /// `{ ...; }`: like a subshell but executed in the current shell.
    group: ?[]Stmt = null,
    /// Temporary environment assignments written before the command word.
    assigns: []PrefixAssign = &.{},
    /// `if`, loops, `case` and `select`. Like a group, a compound command runs
    /// in the current shell unless it is piped or backgrounded.
    compound: ?*Compound = null,
};

pub const ChainOp = enum { and_, or_ };

pub const ChainLink = struct {
    op: ChainOp,
    pipeline: Pipeline,
};

/// A pipeline plus any `&&`/`||` continuation. `a && b || c` evaluates left to
/// right: `commands` runs first, then each link runs only when the running
/// status selects it (left-associative, like bash).
pub const Pipeline = struct {
    commands: []Command,
    background: bool = false,
    links: []ChainLink = &.{},
    /// A leading `!` inverts the status of the pipeline it precedes.
    negate: bool = false,
    /// Source line of the pipeline's first word, for `$LINENO`.
    line: u32 = 0,
    time: TimeMode = .none,
};

/// `time PIPELINE` reports elapsed and CPU time; `time -p` uses the POSIX
/// format.
pub const TimeMode = enum { none, default, posix };

pub const BinOp = enum { add, sub, mul, div, mod, eq, ne, lt, le, gt, ge };

pub const UnOp = enum { neg, not };

pub const Expr = union(enum) {
    null_lit,
    boolean: bool,
    int: i64,
    float: f64,
    /// A string literal; `Word` so `$` interpolation keeps working.
    string: Word,
    ident: []const u8,
    list: []*Expr,
    bin: struct { op: BinOp, lhs: *Expr, rhs: *Expr },
    un: struct { op: UnOp, operand: *Expr },
    /// Logical operators short-circuit and return a bool.
    logic: struct { op: ChainOp, lhs: *Expr, rhs: *Expr },
    call: struct { callee: []const u8, args: []*Expr },
    /// `list[i]` (negative counts from the end) and `map["key"]`.
    index: struct { target: *Expr, index: *Expr },
};

pub const VarDecl = struct {
    name: []const u8,
    value: *Expr,
    line: u32 = 0,
};

pub const EnvOp = enum { set, append };

pub const EnvAssign = struct {
    name: []const u8,
    op: EnvOp,
    value: *Expr,
    line: u32 = 0,
};

/// The test of an `if`, `while` or `until`: a native expression, a command
/// list whose status decides, or both. Both are kept when the condition is
/// nothing but bare names joined by `!`, `&&` and `||` (`if ! ready {`): it
/// is an expression when every name is a variable and commands otherwise.
pub const Condition = struct {
    expr: ?*Expr = null,
    list: ?[]Stmt = null,
};

pub const If = struct {
    cond: Condition,
    then: *Block,
    /// The `else` branch. `else if` and `elif` are desugared into a block
    /// holding one nested `if` command.
    else_: ?*Block,
};

pub const For = struct {
    name: []const u8,
    /// The `in` clause is a word list, so `for f in *.rs` globs naturally.
    /// Without `in` it is `"$@"`.
    items: []Word,
    body: *Block,
};

pub const While = struct {
    cond: Condition,
    body: *Block,
    /// `until`: loop while the condition fails.
    until: bool = false,
};

/// What follows a `case` item's body: `;;` stops, `;&` runs the next body
/// without testing it, `;;&` goes on testing the remaining patterns.
pub const CaseNext = enum { stop, fallthrough, test_next };

pub const CaseItem = struct {
    patterns: []Word,
    body: []Stmt,
    next: CaseNext,
};

pub const Case = struct {
    word: Word,
    items: []CaseItem,
};

/// The expression of `[[ ... ]]`. Operands stay words, expanded without
/// splitting or globbing when the test runs.
pub const Cond = union(enum) {
    /// `-f file`, `-v name`, ...; a lone word is `-n word`.
    unary: struct { op: []const u8, operand: Word },
    /// The right side of `==`, `=` and `!=` is a pattern, and of `=~` a regular
    /// expression.
    binary: struct { op: []const u8, lhs: Word, rhs: Word },
    not: *Cond,
    and_: struct { lhs: *Cond, rhs: *Cond },
    or_: struct { lhs: *Cond, rhs: *Cond },
};

/// `for (( init; test; step ))`: three arithmetic expressions, any of which
/// may be empty. An empty test is true.
pub const ArithFor = struct {
    init: []const u8,
    cond: []const u8,
    step: []const u8,
    body: *Block,
};

pub const Compound = struct {
    /// Source text of the whole command, shown by `jobs`.
    text: []const u8 = "",
    kind: Kind,

    pub const Kind = union(enum) {
        if_: If,
        for_: For,
        while_: While,
        case_: Case,
        select_: For,
        /// `return`, `break`, `continue` or a function definition where a
        /// command is expected, as in `[ -f x ] || return 1`.
        statement: Stmt,
        /// `[[ expression ]]`.
        cond: *Cond,
        /// `(( expression ))`: the text between the parentheses.
        arith: []const u8,
        arith_for: ArithFor,

        /// `[[ ]]` and `(( ))` are tests whose status counts for `set -e`,
        /// ERR and DEBUG like a simple command's, where a loop's or an `if`'s
        /// only reports the commands inside it.
        pub fn isTest(self: Kind) bool {
            return self == .cond or self == .arith;
        }
    };
};

pub const Param = struct {
    name: []const u8,
    default: ?*Expr,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []Param,
    /// A POSIX definition (`name() { ...; } > log`) has one statement here:
    /// the compound command together with its redirections.
    body: *Block,
    /// The declaration's own source text. Function bodies are stored as source
    /// and re-parsed on each call, so the AST of the defining line can be freed.
    source: []const u8 = "",
    line: u32 = 0,
};

pub const Stmt = union(enum) {
    pipeline: Pipeline,
    var_decl: VarDecl,
    env_assign: EnvAssign,
    fn_decl: FnDecl,
    return_: ?*Expr,
    /// `break N`: how many enclosing loops to leave (at least 1).
    break_: u32,
    continue_: u32,
    alias: struct { name: []const u8, value: Word },
};

pub const Block = struct {
    stmts: []Stmt,
};

pub const Program = struct {
    stmts: []Stmt,
};
