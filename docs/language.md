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
$?  $$  $!  $0  $1  $2  $#
$(command)  `command`  "quoted"  'literal'  ~  ~/path
*  ?  [abc]  >  >>  <  2>  2>>  |  &&  ||  &  ;
```

Field splitting and globbing apply to unquoted expansions. `"$value"` does not
split, and a quoted `"*"` remains literal. Comments start with `#`.

## Interactive shell

The line editor provides syntax highlighting, history suggestions, tab
completion for commands/paths/variables, and a git-aware prompt.

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

Builtins include `cd`, `pwd`, `echo`, `print`, `exit`, `export`, `unset`,
`alias`, `unalias`, `jobs`, `fg`, `bg`, `wait`, `history`, `read`, `test`,
`source`, and `eval`. Other commands resolve through `PATH`.

## Configuration

Configuration is loaded from `$XDG_CONFIG_HOME/wsh/config` or
`~/.config/wsh/config`; history is stored under `$XDG_DATA_HOME/wsh/history`.
See [`examples/config`](../examples/config) for a working example.

## Known limitations

- No subshells, heredocs, `$((...))`, `2>&1`, or brace expansion.
- Aliases expand words only; use a function for pipelines or redirects.
- The editor counts each Unicode code point as one column, so wide or combining
  characters may render imperfectly.

See the [PTY tests](../tests/pty_test.py) and [contributor guide](../CONTRIBUTING.md)
for verification instructions.
