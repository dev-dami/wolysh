# Language guide

wolysh keeps command execution and language expressions in distinct positions.
At statement level, a leading keyword starts a language construct; otherwise,
the line is a command.

| Statement starts with | Meaning |
| --- | --- |
| `let`, `env` | Define a value or update an environment variable |
| `if`, `for`, `while` | Control flow |
| `fn`, `return` | Define a function or return its status |
| `alias`, `break`, `continue` | Aliases and loop control |
| `{`, `!` | Brace group in the current shell, or a negated pipeline |
| Anything else | Run a command or pipeline |

## Values and control flow

```text
let name = "wsh"
let count = 4 * (10 + 2)
let parts = split("a:b:c", ":")

env PATH += "/opt/bin"
env EDITOR = "hx"

if count > 10 {
    print "large"
} else {
    print "small"
}

for file in src/*.zig { print file }
while count > 0 { let count = count - 1 }
```

`$name` and `${name}` expand values in command words. In a language expression,
a bare identifier that names a variable refers to that value. Numeric-looking
values compare numerically; `+` adds numbers and concatenates strings.

## Functions and expressions

```text
fn build(mode = "debug") {
    cargo build --profile $mode
}

let mode = "release"
if exists("Cargo.toml") { build $mode }
```

Expressions support `or`/`||`, `and`/`&&`, comparisons, arithmetic, unary
operators, lists, and function calls. Built-in expression functions include:

```text
exists(p)  is_dir(p)  is_file(p)  is_link(p)
len(x)  empty(x)  int(x)  str(x)  abs(n)  min(..)  max(..)
upper(s)  lower(s)  trim(s)  basename(p)  dirname(p)
env(name, fallback)  contains(s, sub)  starts_with(s, prefix)
ends_with(s, suffix)  split(s, sep)  join(list, sep)
```

Expression functions belong in expressions, not as command arguments. For
example, use `let length = len("abc")`, not `print len("abc")`.

## Command words and expansions

```text
$var  ${var}  ${#var}  ${var:-fallback}  ${var:+alt}
$?  $$  $!  $0  $1  $2  $#  $@  $*  $-
$(command)  `command`  $((expr))  "quoted"  'literal'  ~  ~/path
*  ?  [abc]  >  >>  <  2>  2>>  2>&1  <&  >&  &>  <<WORD  <<-WORD  <<<word
|  &&  ||  &  ;  !  { ...; }
```

Field splitting and globbing apply to unquoted expansions, and `IFS` decides
where fields split (default: space, tab, newline). `"$value"` does not split,
and a quoted `"*"` remains literal. Comments start with `#`.

Arithmetic expansion evaluates an integer expression and substitutes the
result. `$10` follows the POSIX single-digit rule and means `$1` followed by a
literal `0`; write `${10}` for the tenth positional parameter.

```text
let n = 3
echo $((n * 2 + 1))     # 7
echo {a,b}/config       # a/config b/config
echo file{1..3}.log     # file1.log file2.log file3.log
```

Brace expansion covers comma lists and numeric ranges, and runs before
globbing. Arithmetic expansion covers the common integer operators; it is not
a complete POSIX arithmetic implementation.

Redirections apply from left to right, so `command 2>&1 >out.txt` sends stderr
to the original stdout and stdout to the file. File descriptors above 2 are
accepted (`3>log`), as are the duplication and shorthand forms `<&`, `>&`, and
`&>`. An unquoted here-document delimiter enables variable and command
substitution; quoting any part of the delimiter keeps the body literal, and a
`<<-` delimiter strips leading tabs from the body. `<<<word` feeds one word
plus a newline as standard input:

```text
cat <<EOF
Hello, $USER
EOF

cat <<'EOF'
The text $USER stays literal.
EOF

cat <<-EOF
	leading tabs are stripped
	EOF

tr a-z A-Z <<< "here string"
```

Parenthesized command groups run in a child shell process. Variable, directory,
and exit-state changes inside them do not affect the parent; groups can be
pipeline stages. Braced groups run in the current shell, so their changes
persist. Background braced groups (`{ ...; } &`) run in a child process and
register as jobs. `!` negates a pipeline's status, and a `NAME=value` prefix applies to
one command only:

```text
(cd /tmp; pwd)
(printf 'hello\n') | wc -l
{ cd /tmp; pwd; }
! grep -q pattern file
LC_ALL=C sort names.txt
```

Named function parameters are local to each call and restore enclosing bindings
on return, including during recursion. `$0` stays the script name inside a
function, and `source file arg...` gives
the sourced file its own positional parameters.

## Interactive shell

The line editor provides syntax highlighting, history suggestions, tab
completion for commands/paths/variables, typo suggestions for command names,
and a git-aware prompt. Fuzzy matching uses a Bloom-style character filter
before bounded edit-distance checks; regular command lookup does not run it.
The shell caches up to 64 recent failed command names per session and can show
their best correction inline; press Right to accept it.

| Key | Action |
| --- | --- |
| Up / Down | Browse history |
| `Ctrl-R` | Search history |
| Tab | Complete commands, paths, and variables |
| Right / End | Accept suggestion or move right |
| `Ctrl-A` / `Ctrl-E` | Start / end of line |
| `Ctrl-C` / `Ctrl-D` | Cancel line / exit on empty input |
| `Ctrl-Z` | Suspend the foreground job |

`jobs`, `fg`, `bg`, and `wait` support `%1`, `%+`, and command prefixes.
Foreground jobs receive the terminal and run in their own process groups.
`wait -n` blocks until a job completes; optional operands limit which jobs it
can return. `wait -n` returns 127 when no eligible running or completed job
remains. Already completed jobs retain their exit status until consumed.

Interactive shells define `la` as `ls -A` and `lh` as `ls -lh` by default;
configuration can override either alias.

Builtins include `cd`, `pwd`, `echo`, `print`, `printf`, `exit`, `export`,
`unset`, `alias`, `unalias`, `jobs`, `fg`, `bg`, `wait`, `parallel`, `history`, `read`,
`test`, `source`, `eval`, `shift`, `type`, `command`, `builtin`, `local`,
`readonly`, `trap`, `umask`, `kill`, `exec`, `pushd`, `popd`, `dirs`, and `:`.
`echo` accepts bundled flags such as `-ne` and interprets escapes; other
commands resolve through `PATH`.

## Parallel tasks and syntax checks

```text
parallel -j 2 'cargo check' 'cargo test'
parallel --jobs 4 --fail-fast --report checks.jsonl 'task one' 'task two'
```

Commands use Wolysh syntax and inherit the current environment, variables,
functions, and aliases. Each task has an isolated shell state; stdout, stderr,
and stdin are shared unless redirected. The default limit is the available
CPU count. `--fail-fast` stops queued tasks after observing a failure and waits
for tasks already started. `--report` writes completion and skipped-task records
as JSONL, separate from task output.

`wsh -n` / `--check` accepts the same script, `-c`, and standard-input modes as
normal execution, parses the source, and returns 0 for valid syntax or 2 for a
syntax error. It does not execute commands or substitutions. It cannot validate
commands stored in strings for later `eval`, function calls, or `parallel`.

See [agent workflows](agent-workflows.md) for report fields and exit semantics.

## Configuration

Configuration is loaded from `$XDG_CONFIG_HOME/wsh/config` or
`~/.config/wsh/config`; history is stored under `$XDG_DATA_HOME/wsh/history`.
See [`examples/config`](../examples/config) for a working example.

## Known limitations

- `$name` on an indexed array expands to every element, as it does for wsh
  lists; Bash gives element 0. Write `${name[0]}` in scripts meant for both
  shells, including for `$BASH_REMATCH`.
- `BASH_COMMAND` is not set, so a DEBUG trap cannot see the command about to
  run.
- `<` and `>` in `[[ ]]` compare bytes; Bash orders them by the current
  locale's collation.

See the [PTY tests](../tests/pty_test.py) and [contributor guide](../CONTRIBUTING.md)
for verification instructions.
