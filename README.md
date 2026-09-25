# wolysh (`wsh`)

**Familiar commands. Better scripts. One small Linux shell.**

wolysh is a Linux shell for developers who want everyday commands to stay
simple and scripts to be easier to read. Run tools and pipelines as commands;
use expressions, functions, and control flow in their own clear syntax.

```text
let workers = 4 * 2
if workers > 4 {
    print "Building with $workers workers"
    cargo build --jobs $workers
}
```

## Why wolysh

- **Work the way you already do:** external commands, pipes, redirection,
  variables, and globbing stay familiar.
- **Write clearer scripts:** use `let`, arithmetic, `if`, loops, and functions
  instead of squeezing logic into command arguments.
- **Stay in flow:** interactive completion, syntax highlighting, history
  suggestions, and reverse search are built in.
- **Control real jobs:** foreground and background processes use Linux process
  groups, with `Ctrl-Z`, `bg`, and `fg` support.

The core design keeps commands and language expressions in distinct positions,
so neither has to compromise:

| You type | What it is |
| --- | --- |
| `cargo build --profile $mode` | a command: words, globs, redirections, pipes |
| `let x = 4 * (10 + 2)` | an expression: real arithmetic and precedence |
| `if exists("Cargo.toml") { cargo build }` | both, composed |

At statement level, a leading keyword (`let`, `if`, `for`, `while`, `fn`,
`return`, `env`, `alias`, `break`, `continue`) starts a language construct;
anything else is a command. Inside expressions you get real precedence,
short-circuiting `and`/`or`, lists, and function calls — without a single
`[`, `]`, `-eq` or `$((...))` in sight.

wolysh is an early-stage project, not a drop-in Bash or POSIX shell. Linux
x86_64 is the currently tested and released target; known language gaps are
listed under [Deliberate limitations](#deliberate-limitations).

## Build and run

**Requirements:** Linux x86_64 and Zig 0.16.0 to build. The PTY test suite also
needs Python 3.

```sh
zig build -Doptimize=ReleaseFast     # -> zig-out/bin/wsh
zig build small                      # size-optimized, for the size budget
zig build test                       # unit tests
python3 tests/pty_test.py            # interactive tests through a real pty

./zig-out/bin/wsh                    # interactive shell
./zig-out/bin/wsh -c 'echo hi'       # run a string
./zig-out/bin/wsh script.wsh a b     # run a script with positional arguments
```

Install the built binary:

```sh
sudo install -m 0755 zig-out/bin/wsh /usr/local/bin/wsh
```

To use it as your login shell, first add `/usr/local/bin/wsh` to
`/etc/shells` if it is not already listed, then:

```sh
chsh -s /usr/local/bin/wsh
```

Only switch after testing it in a terminal; keep a working way to restore your
previous login shell.

## Releases

Push a `vX.Y.Z` tag to run the release workflow. It runs the unit and PTY tests,
then publishes a Linux x86_64 `ReleaseFast` archive containing the shell,
README, MIT license, and examples, plus a SHA-256 checksum.

## Performance snapshot

These local measurements are from one development machine, not a standardized
cross-machine benchmark. Startup used 500 `-c true` runs; the loop measurement
used 20,000 iterations. Results vary with hardware and workload.

| | wolysh | bash |
| --- | ---: | ---: |
| Empty startup (`-c true`, 500 runs) | **1.14 ms** | 2.16 ms |
| Idle RSS, interactive | **≈0.7 MB** | ≈4.2 MB |
| `while` loop, 20 000 iterations | **15 ms** | 120 ms |
| Binary (stripped) | **312 KB** (201 KB `ReleaseSmall`) | — |

In that specific loop workload, wolysh took 15 ms versus 120 ms for Bash. Treat
that as a workload-specific result, not a general speed guarantee.

## The language

### Variables and environment

```text
let name = "dami"
let count = 10 * 4
let parts = split("a:b:c", ":")          # lists work
let path = dir + "/main.rs"              # `+` concatenates strings

env PATH += "/opt/bin"                   # environment is explicit
env EDITOR = "hx"
```

`$name` and `${name}` interpolate in words, and a **bare identifier that names a
variable is also a reference to it**, so loops read cleanly:

```text
for file in *.rs {
    print file            # prints the value of `file`
    print "file"          # quoted: prints the literal word
}
```

### Control flow

```text
if count > 10 {
    print "big"
} else if count > 3 {
    print "medium"
} else {
    print "small"
}

for f in src/*.zig { print f }
while n < 10 { let n = n + 1 }
while true { if exists(".stop") { break } }
```

### Functions

Parameters may have defaults, and `return` sets the exit status.

```text
fn build(mode = "debug") {
    cargo build --profile $mode
}

fn is_big(n) {
    if n > 100 { return 0 }
    return 1
}

if is_big(500) { print "big" }      # a function called from an expression
```

### Expressions

Operators, in precedence order: `or`/`||`, `and`/`&&`, `==`/`!=`,
`<`/`<=`/`>`/`>=`, `+`/`-`, `*`/`/`/`%`, unary `-`/`not`/`!`, calls.

Comparisons are numeric when both sides look like numbers, so a parameter that
arrived as a command word still compares as a number (`check 5` binds `"5"`, and
`n > 10` is false — correctly).

Built-in expression functions:

```text
exists(path)  is_dir(p)  is_file(p)  is_link(p)
len(x)  empty(x)  int(x)  str(x)  abs(n)  min(..)  max(..)
upper(s)  lower(s)  trim(s)  basename(p)  dirname(p)
env("NAME", fallback)  contains(s, sub)  starts_with(s, p)  ends_with(s, s)
split(s, sep)  join(list, sep)
```

These live in **expressions**, not in command arguments — a command's words are
words. The shell catches the mistake rather than quietly printing text:

```text
❯ print len("abc")
wsh: 'len' is an expression function, not a command.
     try: let result = len(...)

❯ let n = len("abc")
❯ print $n
3
```

Read-only names: `status` (last exit code), `cwd`, `host`, `pid`, `argv`, `env`.

A call to anything else that names a function, builtin or executable *runs* it
and reports success, which is what makes predicates read naturally:

```text
if is_big(500) { print "big" }
let ok = has_network()
```

Expressions are predicates, so a command yields a bool; use `status` when you
need the numeric exit code.

## Expansions

```text
$var  ${var}  ${#var}  ${var:-fallback}  ${var:+alt}   variables
$?    $$      $!      $0 $1 $2 ... $#                   status, pid, arguments
$(cmd)  `cmd`                                           command substitution
"..."  '...'  \escape                                   quoting
~  ~/path                                               home
*  ?  [abc]                                             globbing
>  >>  <  2>  2>>                                       redirection
|  &&  ||  &  ;                                         pipelines and sequencing
# comment                                               to end of line
```

Field splitting and globbing happen only on unquoted expansion — `"$x"` never
splits, `$x` does, and a quoted `"*"` stays a literal star.

## Interactive editing

| Key | Action |
| --- | --- |
| Right / `End` | accept the inline suggestion, else move right |
| Up / `Down` | history |
| `Ctrl-R` | incremental reverse search |
| `Tab` | complete command names, paths, directories, `$variables` |
| `Ctrl-A` / `Ctrl-E` | start / end of line |
| `Ctrl-B` / `Ctrl-F` | back / forward one character |
| `Alt-B` / `Alt-F` | back / forward one word |
| `Ctrl-W`, `Ctrl-U`, `Ctrl-K` | delete word / to start / to end |
| `Ctrl-T` | transpose characters |
| `Ctrl-L` | clear the screen |
| `Ctrl-C` | abandon the line |
| `Ctrl-D` | end of input on an empty line |
| `Ctrl-Z` | suspend the foreground job |

Plus: syntax highlighting, an inline autosuggestion drawn from history, a
continuation prompt for open constructs, and a prompt that shows the working
directory and git branch.

## Job control

Real job control, not a toy: each job gets its own process group, the shell
passes the controlling terminal to the foreground job and takes it back
afterwards, and `Ctrl-C`/`Ctrl-Z` reach the right processes.

```text
❯ sleep 300 &
[1] 18371
❯ jobs
[1] + Running  sleep 300
❯ fg
```

`jobs`, `fg`, `bg` and `wait` all understand `%1`, `%+` and command prefixes.

## Builtins

`cd` `pwd` `echo` `print` `exit` `export` `unset` `set` `alias` `unalias`
`jobs` `fg` `bg` `wait` `history` `which` `read` `test` `true` `false` `clear`
`source` (`.`) `eval`

Everything else is an external program, resolved on `PATH`. A script file without
a shebang is run through `/bin/sh`, like a real shell.

## Configuration

`$XDG_CONFIG_HOME/wsh/config` (or `~/.config/wsh/config`) is wsh source, run
before the first prompt. See `examples/config`. History lives in
`$XDG_DATA_HOME/wsh/history`.

```text
alias ll = ls -lah

fn mkcd(dir) {
    mkdir -p $dir
    cd $dir
}

let autosuggest = true
let git_prompt = true
```

`prompt`, `git_prompt`, `autosuggest`, `highlight`, `completion` and
`history_limit` can all be set this way, and take effect immediately.

## Architecture

```text
src/
├── main.zig              entry point, REPL, argument parsing
├── shell.zig             state: variables, environment, jobs, terminal
├── lexer.zig             two-mode lexer (command words / expressions)
├── parser.zig            AST + recursive-descent parser
├── ast.zig               syntax tree
├── exec.zig              statements, pipelines, functions, expressions
├── expand.zig            quoting, $, globbing, field splitting, $()
├── glob.zig              wildcard matching and directory walking
├── proc.zig              fork/exec, pipes, process groups, waiting
├── jobs.zig              job table
├── builtins.zig          shell builtins
├── fs.zig  sys.zig       filesystem and syscall helpers
├── value.zig             runtime values
├── history.zig           persistent searchable history
└── interactive/
    ├── editor.zig        line editing, rendering, incremental search
    ├── highlight.zig     syntax highlighting
    ├── complete.zig      tab completion
    ├── prompt.zig        the prompt
    └── term.zig          raw mode
```

Two decisions explain most of the code:

**The shell talks to the kernel directly.** A shell *is* the process-group and
controlling-terminal manager, so `proc.zig` uses `fork`/`execve`/`pipe2`/`waitpid`
and `posix.tcsetpgrp` rather than delegating to an I/O abstraction. Startup is
allocation-light and there is nothing to initialise.

**Function bodies are stored as source.** Defining a function keeps its text, not
its AST, so the per-command arena can be released wholesale after every line
without the function table dangling.

## Deliberate limitations

Documented rather than silently surprising:

- **No subshells.** `( ... )` is not supported; use `$( ... )` or a script.
- **No heredocs.** `<<` is not implemented.
- **No `$((...))`.** The parser reports it and points you at `let`; arithmetic
  belongs in expressions, not inside a word.
- **No `2>&1`.** Use `2>` to a file; descriptor duplication is not implemented.
- **No brace expansion.** `{a,b}` is left alone; `{ ... }` opens a block only
  when it stands alone (`if x { ... }`), which keeps `find . -exec ls {} \;`
  working.
- **Aliases expand to words, not syntax.** `alias ll = ls -la` works; an alias
  body containing `|` or a redirect would be dropped. Use a function instead.
- **Every code point counts as one column.** The editor skips ANSI escapes and
  counts UTF-8 code points rather than bytes, which is right for the prompt and
  for command lines. Double-width CJK, combining marks and right-to-left text
  still measure one column each, so they render imperfectly.

## Tests

```sh
zig build test                          # 57 unit tests: lexer, parser, expansion,
                                        # globbing, forks, pipelines, functions,
                                        # jobs, config, the line editor
zig build test -Dtest-filter=glob       # a subset
python3 tests/pty_test.py               # 19 checks through a real pty: prompt
                                        # geometry, suggestions, completion,
                                        # history, Ctrl-C, Ctrl-Z/bg/fg, jobs
WSH=/path/to/wsh python3 tests/pty_test.py   # test a different binary
```

## License

wolysh is licensed under the MIT License. See [LICENSE](LICENSE).
