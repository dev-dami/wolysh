# Changelog

All notable changes to wolysh are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://github.com/dev-dami/wolysh/compare/v0.3.5...HEAD
[0.3.5]: https://github.com/dev-dami/wolysh/compare/v0.3.4...v0.3.5
[0.3.4]: https://github.com/dev-dami/wolysh/compare/v0.3.3...v0.3.4
[0.3.0]: https://github.com/dev-dami/wolysh/releases/tag/v0.3.0
