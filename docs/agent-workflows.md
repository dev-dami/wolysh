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

## Measure speed

```sh
zig build -Doptimize=ReleaseFast
python3 benchmarks/shell_bench.py --runs 15
```

See [the benchmark methodology](../benchmarks/README.md). Shell arithmetic and
queue overhead can improve considerably. External programs still determine
most of the elapsed time for builds, tests, and network requests; the shell
does not make the same external program execute faster.
