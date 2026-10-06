//! Abstract syntax tree for wolysh.
//!
//! wolysh keeps commands and language expressions in the same grammar but in
//! different positions: at statement level an unquoted word starts a *command*,
//! while keywords (`let`, `if`, `for`, `while`, `fn`, `return`, `env`, `alias`)
//! introduce language constructs whose operands are *expressions*.

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
};

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
};

pub const EnvOp = enum { set, append };

pub const EnvAssign = struct {
    name: []const u8,
    op: EnvOp,
    value: *Expr,
};

pub const If = struct {
    cond: *Expr,
    then: *Block,
    /// The `else` branch. `else if` is desugared into a block holding one
    /// nested `if_` statement.
    else_: ?*Block,
};

pub const For = struct {
    name: []const u8,
    /// The `in` clause is a word list, so `for f in *.rs` globs naturally.
    items: []Word,
    body: *Block,
};

pub const While = struct {
    cond: *Expr,
    body: *Block,
};

pub const Param = struct {
    name: []const u8,
    default: ?*Expr,
};

pub const FnDecl = struct {
    name: []const u8,
    params: []Param,
    body: *Block,
    /// The declaration's own source text. Function bodies are stored as source
    /// and re-parsed on each call, so the AST of the defining line can be freed.
    source: []const u8 = "",
};

pub const Stmt = union(enum) {
    pipeline: Pipeline,
    var_decl: VarDecl,
    env_assign: EnvAssign,
    if_: If,
    for_: For,
    while_: While,
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
