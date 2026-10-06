# Changelog

All notable changes to wolysh are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.5.0] - 2026-10-06

Most of Bash's scripting language now works in wsh. Each area below is
compared against Bash 5.3 in the test suite; `docs/language.md` lists the known
differences.

### Added

- POSIX and Bash control flow: `if`/`elif`/`fi`, `case` with `;&` and `;;&`,
  `until`, `select`, POSIX function definitions, `local`, and the `time`
  keyword.
- `[[ ]]` with pattern, regular-expression (`=~`, `BASH_REMATCH`), integer and
  file tests; `(( ))`; and C-style `for (( init; test; step ))` loops. Regular
  expressions use a new linear-time POSIX ERE engine.
- Bash parameter expansion (`${var:=}`, `${var:?}`, `${var#pat}`,
  `${var/pat/rep}`, `${var:off:len}`, case modification, `${!name}`,
  `${!prefix*}`), indexed and associative arrays, `declare`/`typeset`
  attributes, and special variables such as `RANDOM`, `SECONDS` and `LINENO`.
- Bash integer arithmetic in `$(( ))`: every operator, bases (`16#ff`),
  assignment, comma and the conditional operator.
- `test` and `[` follow POSIX argument rules and support Bash's operators.
- Redirections: `exec` redirections, `{fd}>file`, `<>`, `>|`, process
  substitution `<( )` and `>( )`, ANSI-C quoting `$'...'`, Bash tilde rules,
  extended globbing and the glob `shopt` options.
- `set` with POSIX options, `set -euo pipefail`, `PIPESTATUS`, `set -x` with
  `PS4`, and `trap` for signals, `EXIT`, `ERR`, `DEBUG` and `RETURN`.
- Builtins: Bash `read`, `mapfile`/`readarray`, `getopts`, `printf` (including
  `%(fmt)T`), `help`, `type`, `command -v`, `hash`, `ulimit`, `times`,
  `logout`, `umask -S`, `pushd`/`popd`/`dirs`, and the Bash forms of `export`,
  `readonly` and `alias`.
- Command line: `-c` with `$0`, `-s`, `-i`, `-l`/`--login`, `-o`/`+o` and the
  set option letters; scripts streamed on standard input; `import-env` for the
  exported environment of a POSIX script.
- Interactive shell: UTF-8 line editing with a kill ring, undo, bracketed
  paste and vi mode; history expansion; programmable completion (`complete`,
  `compgen`); keyword highlighting that honours `NO_COLOR`; `PS1` escapes,
  `PROMPT_COMMAND`, and `precmd`, `preexec` and `chpwd` hooks.

### Changed

- A bare word in a command argument stays literal: `status=x; git status` runs
  `git status`. Bare names still refer to variables inside language
  expressions (`if count > 10 {`, `print name`).
- `name=value` sets a shell variable without exporting it, so `unset` removes
  it and child processes do not see it unless it is exported.
- `wsh -c 'cmd' a b` sets `$0` to `a` and `$1` to `b`, as `bash -c` does.
- `read` returns 1 at end of input, which ends `while read` loops.
- An expansion error such as `${x:?message}` stops a non-interactive shell with
  status 1.
- Functions take precedence over builtins of the same name; `builtin` reaches
  the builtin.
- Native expression arithmetic is exact for integers and rejects non-numeric
  operands instead of treating them as 0.
- Background jobs print `[1] pid` only in interactive shells.

### Fixed

- `cd -` returns to the previous directory.
- `return` in a sourced file returns to the caller instead of ending it.
- `for`, `while` and `if` blocks honour redirections such as `> file`.
- `$((minInt / -1))` no longer crashes the shell.
- Ctrl-C stops `while` loops and `wait -n`; SIGHUP keeps history and is noticed
  while the prompt is being drawn.
- Multi-line history entries survive a reload.
- The first stage of a pipeline joins its process group before running.
- Brace ranges and word lists are no longer cut off at fixed sizes.

## [0.4.1] - 2026-10-04

### Fixed

- Linux x86_64 release archives now target the baseline CPU instead of the
  GitHub runner's native CPU. This prevents `SIGILL` on CPUs without the
  runner's instruction extensions.
- CI and release tests use the same baseline x86_64 target as the archive.

## [0.4.0] - 2026-10-04

### Added

- Native `parallel` builtin with bounded concurrency (`-j` / `--jobs`),
  CPU-count defaults, fail-fast queueing, and optional JSONL task reports.
- `wsh -n` / `--check` validates command strings, scripts, and standard input
  without executing commands or substitutions.
- Reproducible shell benchmarks covering startup, arithmetic, external
  commands, pipelines, waits, and bounded parallel workloads against Bash.
- Agent workflow documentation and user-local ReleaseFast installation.

### Changed

- `wait -n` blocks on kernel child events instead of polling every millisecond,
  and honors explicit job or PID operands.
- Process launches avoid temporary duplicates of standard descriptors when
  the mappings cannot overwrite one another.
- Child environment entries are formatted directly into null-terminated
  buffers, removing an allocation and copy per entry.

### Fixed

- Waiting for a partially reaped pipeline retains the last stage's exit status.
- `wait $!` can consume a background job whose last process was already reaped.
- Waiting for a stopped job preserves it for later resumption.

## [0.3.5]

### Fixed

- `wait` consumes jobs that finished before it was called, preserving their
  exit status and removing them from the job table.

## [0.3.4]

### Fixed

- Multiple numbered redirects no longer collide with temporary file descriptors
  and send output to the wrong file.
- Function parameters are local to each call and restore enclosing bindings,
  including during recursion.
- Command-prefix assignments stay within their pipeline stage, including
  builtins and command groups; repeated assignments restore the original value.
- Background brace groups run in a child process and register as jobs.

## [0.3.0]

Compatibility and correctness work across expansion, grammar, execution, and
the builtin set. wolysh is still early-stage software and is not a Bash or
POSIX drop-in; [docs/language.md](docs/language.md) lists what remains missing.

### Added

- Expansion: `$((...))` arithmetic expansion; brace expansion, both lists
  (`{a,b}`) and numeric ranges (`{1..3}`).
- Grammar and execution: optional counts for `break` and `continue`
  (`break 2`); in-process brace groups (`{ ...; }`); pipeline negation with
  `!`; temporary environment assignments (`NAME=value cmd`); redirections on
  file descriptors above 2 together with the `<&`, `>&`, and `&>` forms;
  `<<-` tab-stripping here-documents and `<<<` here-strings.
- Builtins: `:` `printf` `type` `command` `builtin` `shift` `umask` `kill`
  `exec` `local` `readonly` `trap` `pushd` `popd` `dirs`.

### Changed

- `$@`, `$*`, and `$-` now expand in command words.
- `$10` follows the POSIX single-digit rule: it expands `$1` followed by a
  literal `0`.
- `$0` keeps the script name inside functions, and `source` accepts positional
  arguments for the sourced file.
- `IFS` is honored when splitting unquoted expansions into fields.
- `echo` accepts bundled flags and interprets escape sequences, including
  `\0nnn`, which `printf` also accepts.
- The version string is single-sourced: `build.zig` defines it, and the binary
  and tests read it from the generated `build_options` module. No output format
  change: `wsh --version` still prints `wolysh <version>`.

### Fixed

- Braced positional and special parameters (`${1}`, `${10}`, `${@}`, `${*}`,
  `${?}`, `${!}`, `${-}`, `${#}`) now expand instead of producing an empty
  string.
- Escaped backticks inside command substitution are no longer treated as the
  start of a nested substitution.
- Redirect descriptors above 2: a later `N>&M` is no longer clobbered by the
  close of an earlier redirect's temporary descriptor, and duplicating a
  descriptor the shell never opened is an error rather than a silent no-op.
- Command-prefix assignments are rolled back when a later assignment on the
  same command line fails to expand, so nothing leaks into the shell.
- `readonly` is enforced for bare `NAME=value` assignments (in addition to
  `let`, `env`, `set`, `export`, and `unset`).
- `wait`: named job and pid operands are honored, `wait -n` returns whichever
  job finishes first, and `wait` with no operands returns `0`.
- `test` / `[`: an operand that looks like a unary flag is compared when a
  binary operator follows (`test -n = -n`).
- `trap`: a first argument naming a signal is treated as the handler rather
  than silently resetting the listed signals.
- `kill -0` / `kill -s 0` test whether the target exists.
- A failed `exec` exits a non-interactive shell with status 127.
- Redirects on a brace group (`{ ...; } 2>file`) are accepted.

### Infrastructure

- `build.zig.zon` added with the package name, version, minimum Zig version,
  and the paths shipped in a source archive.
- `zig build fmt` (included in `zig build check`) runs `zig fmt --check` over
  `src`, `build.zig`, and `build.zig.zon`, and CI enforces it.
- Unit tests in `src/main.zig` and `src/interactive/prompt.zig` are wired into
  the `zig build test` aggregator and now run.
- `CHANGELOG.md` and `.editorconfig` added.

[Unreleased]: https://github.com/dev-dami/wolysh/compare/v0.5.0...HEAD
[0.5.0]: https://github.com/dev-dami/wolysh/compare/v0.4.1...v0.5.0
[0.4.1]: https://github.com/dev-dami/wolysh/compare/v0.4.0...v0.4.1
[0.4.0]: https://github.com/dev-dami/wolysh/compare/v0.3.5...v0.4.0
[0.3.5]: https://github.com/dev-dami/wolysh/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/dev-dami/wolysh/compare/v0.3.3...v0.3.4
[0.3.0]: https://github.com/dev-dami/wolysh/releases/tag/v0.3.0
