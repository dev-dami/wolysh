# Agent workflows

Use the native ReleaseFast binary for commands, scripts, and independent tasks.
Wolysh is its own scripting language; existing Bash scripts should continue to
run through Bash. Non-interactive execution does not load configuration,
history, completion, or the prompt.

## Install and invoke

Requires Linux x86_64 and Zig 0.16.0 for a source build:

```sh
zig build -Doptimize=ReleaseFast --prefix "$HOME/.local"
"$HOME/.local/bin/wsh" --no-config -c 'pwd'
```

For an agent integration, pass arguments directly to the process API:
`["/absolute/path/to/wsh", "--no-config", "-c", command]`. Read stdout,
stderr, and the process exit status separately. `-c` and script execution have
no interactive banners or background notifications except the existing job
registration message when using `&` explicitly.

## Validate generated scripts

```sh
wsh --check script.wsh
wsh -n -c 'parallel -j 2 "cargo check" "cargo test"'
printf 'echo ready\n' | wsh --check
```

Syntax checks return 0 for valid source and 2 for invalid source. They do not
execute commands, substitutions, or configuration. They check the source grammar,
not whether a program exists or whether code stored inside strings will parse
when evaluated. `parallel` additionally parses every task before starting any
task, so a malformed task prevents the whole batch from starting.

## Run independent tasks

```sh
wsh -c "parallel -j 2 --fail-fast --report checks.jsonl 'zig build check' 'zig build -Doptimize=ReleaseFast'"
```

Each quoted argument is a Wolysh command string. `parallel` uses native fork
and wait syscalls, without an external queue tool or relaunching Wolysh for
each task. Tasks inherit environment entries, variables, functions, aliases,
and the current directory. Their changes stay inside their own child process.

Options precede commands:

| Option | Behavior |
| --- | --- |
| `-j N`, `--jobs N` | Run at most N tasks at a time; N must be positive |
| No job limit | Use the available CPU count, capped by task count |
| `--fail-fast` | Stop launching queued tasks after observing a failure; drain started tasks |
| `--report path` | Create or truncate a JSONL report; fail before launching if it cannot open |
| `--` | End option parsing |
| `--help` | Print usage |

The next task starts as soon as any worker exits. All tasks run by default,
including after failures. The aggregate exit status is 0 when all tasks succeed;
otherwise it is the status of the failed task with the lowest input index among
started tasks. Invalid options or task syntax return 2. Scheduler and report
errors return 1. Missing commands return 127, and signal termination follows
the shell's `128 + signal` convention.

Tasks share their inherited stdin, stdout, and stderr. Output can interleave,
even between parts of a line, and tasks that read stdin can compete for input.
Give tasks their own redirects when the agent needs separate logs or inputs:

```text
parallel -j 2 --report checks.jsonl \
    'cargo check > check.log 2>&1 < /dev/null' \
    'cargo test > test.log 2>&1 < /dev/null'
```

Interactive `parallel` jobs support Ctrl-Z, `jobs`, `bg`, `fg`, and Ctrl-C
through the scheduler's shared process group. A task that explicitly launches
background work with `&` creates a separate job; wait for that work inside the
task to keep completion status meaningful.

## Consume results

Reports contain one JSON object per line, in completion order for started
tasks. Skipped tasks follow after the active tasks have drained. Fields are:

| Field | Meaning |
| --- | --- |
| `event` | `completed` or `skipped` |
| `index` | One-based position in the input command list |
| `command` | Expanded task command string |
| `pid` | Worker PID; null for skipped tasks |
| `status` | Exit status; null for skipped tasks |
| `elapsed_ms` | Monotonic elapsed milliseconds from launch; 0 for skipped tasks |

The scheduler writes the report itself; task stdout and stderr never become
report records. A write failure is reported on stderr, stops further queueing,
drains active tasks, and returns 1. A process killed before completion may
leave an incomplete report; the caller must also inspect the shell's exit
status. Quoted command strings defer their `$variables` and substitutions to
the task; double quotes can expand them in the parent before scheduling.

## Background runs

A command that an agent starts with `wsh -c` ends when the call ends, and the
agent must read all of its output. `wsh run` keeps the process alive after the
call returns and keeps every byte of its output on disk:

```sh
wsh run -d --name test -- cargo test        # prints "test" and returns at once
wsh run wait test --match 'test result' --timeout 10m
wsh run logs test --tail 20
wsh run status test --json
```

| Command | Behavior |
| --- | --- |
| `run -d [--name NAME] [--tty] [--] command...` | Start in the background. Print the name. Without `--name`, the name is `run-N` |
| `run status [NAME] [--json]` | One run, or a table of all runs. `--json` writes one object per line |
| `run wait NAME [--match TEXT] [--regex] [--timeout DURATION]` | Block until the run ends or a line matches |
| `run logs NAME [--tail N \| --head N \| --since OFFSET] [--json]` | Read the output |
| `run kill NAME [--signal SIG]` | Send a signal (default `TERM`) to every process of the run |
| `run rm NAME...` | Delete a finished run |

The command words are joined with spaces and run as one Wolysh command line,
as `ssh` does. Thus `run -d -- cargo test` and `run -d -- 'make 2>&1 | tee
log'` both work. The run starts in the caller's directory with the caller's
environment and gets `WSH_RUN=NAME`. As a builtin, `run -d` also gives the
run the shell's functions and variables, as `parallel` does. Its standard
input is `/dev/null`. Its stdout and stderr go to one append-only log, in the
order that they were written. `--tty` gives the run a pseudo-terminal
instead, for programs that change their output when they do not write to a
terminal. A name that is already in use is an error (status 1): remove the old
run with `run rm` first.

`run wait` returns the run's exit status, or 128 + the signal number when a
signal stopped it. With `--match TEXT`, it returns 0 and prints the first
output line that contains TEXT, from the start of the log. `--regex` makes
TEXT a regular expression. A run that ends without a matching line returns
its own nonzero status, or 1. `--timeout` takes `500ms`, `30s`, `5m`, `1h` or
plain seconds, and returns 124 when the time limit passes first. A run whose
supervisor died without a record of the status is `lost`. `run wait` returns
125 for it.

To poll output incrementally, read from a byte offset. `--since OFFSET` writes
the bytes from OFFSET to the current end and writes `next_offset=N` on
stderr. Give N to the next call:

```sh
wsh run logs test --since 0      # stderr: next_offset=1834
wsh run logs test --since 1834
wsh run logs test --since 1834 --json
```

`--json` writes one object:
`{"name","state","offset","next_offset","data"}`. Invalid UTF-8 in `data` is
replaced with U+FFFD. Use the plain form when the exact bytes matter.

`run status --json` objects have the fields `name`, `state` (`running`,
`exited`, `killed` or `lost`), `status`, `signal`, `pid`, `pgid`,
`started_ms`, `ended_ms`, `elapsed_ms`, `bytes`, `command`, `cwd`, `session`
and `tty`. The times are milliseconds since the Unix epoch.

## Persistent sessions

A session is a named Wolysh shell that keeps its directory, variables,
functions and job table between calls:

```sh
wsh session new work
wsh session exec work -- 'cd src && x=1'
wsh session exec work -- 'pwd; echo $x'     # prints .../src and 1
wsh session attach work                     # interactive; Ctrl-\ then d detaches
wsh session kill work
```

| Command | Behavior |
| --- | --- |
| `session new NAME` | Start a shell in the caller's directory with the caller's environment |
| `session ls [--json]` | List the sessions, their host process ids, current directories, and whether they are busy |
| `session exec NAME [--] command...` | Run a command line in the session and return its exit status |
| `session attach NAME` | Use the session interactively on its pseudo-terminal |
| `session kill NAME` | Hang up the session and everything that it started |

`session exec` gives the session the caller's own stdin, stdout and stderr, so
output streams directly to the caller and stdout and stderr stay separate.
Ctrl-C (SIGINT) on the client goes to the command, and the session stays. One
session runs one request at a time, and other requests wait. `exit` in a
command ends the session after it replies. Commands see `WSH_SESSION=NAME`,
and a run started inside a session records the session name. A background
job (`cmd &`) that keeps the caller's stdout open also keeps the caller
waiting for end of output, as with `wsh -c`. Redirect its output, or use
`run -d`.

`session attach` runs the line editor on a pseudo-terminal in the session. The
first attach creates the terminal, and it stays for the life of the session.
Type Ctrl-\ and then `d` to detach. Type Ctrl-\ twice to send one Ctrl-\.
`exit` ends the session. Ctrl-D on an empty line does not end the session.
A command in the foreground continues after you detach, as in tmux. The
session keeps the newest 64 KiB of terminal output, and the next attach shows
it first. A new attach replaces a client that is still attached. When the
client's terminal changes size, the session's terminal and its foreground
program get the new size. The session never waits for a client: when a client
falls more than about 1 MiB behind the output, the session drops it. Attach
again to get the replay buffer.

`session exec` requests interrupt the attached prompt and run between
commands. A line that is partly typed stays, with its cursor, and you can
continue to type it after the request. While a foreground command runs on the
terminal, requests wait. `session
ls` shows the directory of each session after its last command, from
`session exec` or from the attached prompt.

## Daemon and state directory

The first `session new` starts one daemon (`wsh --daemon`) for each user. It
listens on a Unix socket with mode 0600 and refuses a peer whose uid is not
the same. The daemon does not wait for a session: a request for a busy
session, however large, waits in a queue, and other clients get answers. A session is a child process of the daemon, as a tmux session is of
the tmux server, and ends with the daemon. Runs do not need the daemon: each
run has its own small supervisor process that records its exit status.
`run status`, `run logs` and `run wait` read the files directly.

The state directory is `$XDG_RUNTIME_DIR/wsh` when `XDG_RUNTIME_DIR` names a
directory, else `/tmp/wsh-<uid>`. Its mode is 0700, and it must belong to the
user:

| Path | Content |
| --- | --- |
| `runs/NAME/meta.json` | `name`, `command`, `cwd`, `pid`, `pgid`, `supervisor`, `sid`, `started_ms`, `ended_ms`, `status`, `signal`, `state`, `session`, `tty` |
| `runs/NAME/output.log` | Every byte the run wrote, append-only |
| `sessions/NAME/meta.json` | `name`, `pid`, `cwd`, `created_ms` |
| `daemon.sock`, `daemon.pid`, `daemon.lock` | The daemon's socket, process id and single-instance lock |

`meta.json` is replaced atomically. While a run is active, its supervisor
holds an exclusive `flock` on the run directory. If the supervisor dies, the
run shows as `lost`, and the daemon writes `"state":"lost"` on its next pass.
Finished runs are deleted after `WSH_RUN_TTL` seconds (default 24 hours).
Idle sessions end after `WSH_SESSION_TTL` seconds (default 12 hours). The
daemon stops after `WSH_DAEMON_IDLE` seconds (default 10 minutes) with no
session, no active run and no client. The client protocol is one request per
connection: a 4-byte little-endian length and a JSON object, answered in the
same way.

To run a script file named `run` or `session`, give a path: `wsh ./run`.

## Asking questions about output

A build or test run can print thousands of lines when the question is only
"what failed?". The `out` builtin answers that kind of question within a byte
budget, so the agent reads a few kilobytes instead of the whole log:

```sh
cargo test 2>&1 | wsh --no-config -c 'out budget 4k'
wsh --no-config -c 'out failures --json --file test.log'
wsh --no-config -c 'out find connection refused --file test.log'
wsh --no-config -c 'out lines 41-60 --file test.log'
```

A background run's log answers the same questions directly:
`run logs NAME --failures`, `--budget N`, `--find QUERY`, `--grep TEXT` or
`--stats` (with `--limit`, `--context` and `--json`) hand the whole log to
`out`.

Input is stdin, `--file FILE`, or `--run NAME` for the log of background run
`NAME` (`$XDG_RUNTIME_DIR/wsh/runs/NAME/output.log`, or
`/tmp/wsh-<uid>/runs/NAME/output.log` without a runtime directory). Files are
memory-mapped and scanned once; a 100 MB log takes well under a second.

| Command | Answer |
| --- | --- |
| `out budget [N]` | A summary of at most N bytes (default 4096; `2k`, `64K`, `1M` work) |
| `out find QUERY...` | The best fuzzy matches (fzf-style), best first; default 20 |
| `out grep PATTERN` | Lines containing PATTERN, in order; `--regex`, `-i`; default 100 |
| `out failures` | Failed tests and checks, with the runner's pass/fail/skip counts |
| `out lines A-B` | Lines A to B exactly (also `A`, `A-`, `A..B`) |
| `out stats` | Lines, bytes, error/failure/warning lines, test frameworks seen |

`out budget` returns small output unchanged. Otherwise it keeps, in original
order, the first and last lines, error and failure lines (the first and last of
them before the ones in between), summary lines such as `test result:`, a few
lines of context around errors, then warnings. Lines longer than 512 bytes
(or a quarter of a smaller budget) are cut and marked with the bytes dropped.
Each run of omitted lines becomes one marker with its exact range:

```text
[… 9,812 lines (1,203,331 bytes) elided; lines 41–9852 …]
```

Pass the range back as `out lines 41–9852` (an en dash or `-` both work) to
read it, or narrow it with `out grep` and `out find`.

`out find` splits the query on spaces; every word must match as a
subsequence, and consecutive characters and word starts score higher. The
search ignores case unless the query has an uppercase letter. `--context C`
(or `-C C`) adds surrounding lines to `find` and `grep`.

`out failures` recognises cargo test, pytest, `go test`, Jest, Vitest, Zig's
test runner and `zig build test`, unittest, Maven Surefire and Gradle (JUnit),
Mocha and RSpec. Each failure has the framework, the test name, the line it was
reported on, and when the output says, a `file:line` location and one line of
reason. Compiler-style errors that name a location (`file:line: error: ...`,
rustc's `error[E…]` followed by `--> file:line:col`, TypeScript's
`file(line,col): error`) and Python tracebacks count as generic failures. The
exit status is 1 when anything failed, 0 when test output was recognised and
nothing failed, and 2 when no test output was recognised.

Matching ignores ANSI colour and CRLF line endings, and a line redrawn with
carriage returns counts as its final text. Output is cleaned the same way;
`--raw` shows lines as they were written. `--budget N` caps the output of any
subcommand, dropping whole records and saying how many.

With `--json`, every subcommand prints one JSON object per line, each with a
`type`:

| `type` | Fields |
| --- | --- |
| `line` | `line`, `text` (budget, lines) |
| `elided` | `from`, `to`, `lines`, `bytes` (budget) |
| `match` | `line`, `offset`, `text`, and `score` and `positions` (find) or `spans` (grep) |
| `context` | `line`, `text` (find and grep with `--context`) |
| `failure` | `framework`, `name`, `line`, `location`, `reason` (null when unknown) |
| `summary` | find, grep: `matches`, `shown`; failures: `status`, `frameworks`, `passed`, `failed`, `skipped`, `failures`, `omitted` |
| `stats` | `lines`, `bytes`, `errors`, `failures`, `warnings`, `first_error`, `first_failure`, `first_warning`, `longest_line`, `frameworks` |
| `truncated` | `omitted`: records dropped by `--budget` |

`offset` is the byte offset of the line in the input. `positions` and `spans`
index `text`, which is the cleaned line (with `--raw`, `text` is the line as
written but the indexes still count in the cleaned line); an excerpt of a line
longer than 1 KiB also has `excerpt_start`. Usage and input errors exit with status 2; `find`
and `grep` exit 1 when nothing matched.

## Measure speed

```sh
zig build -Doptimize=ReleaseFast
python3 benchmarks/shell_bench.py --runs 15
```

See [the benchmark methodology](../benchmarks/README.md). Shell arithmetic and
queue overhead can improve considerably. External programs still determine
most of the elapsed time for builds, tests, and network requests; the shell
does not make the same external program execute faster.
