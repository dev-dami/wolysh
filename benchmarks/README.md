# Shell benchmarks

Build with `zig build -Doptimize=ReleaseFast`, then run:

```sh
python3 benchmarks/shell_bench.py --runs 15
python3 benchmarks/shell_bench.py --runs 15 --baseline /path/to/previous/wsh --json
```

From an extracted release archive, pass `--wsh ./wsh`.

Python 3 and Bash are the only benchmark dependencies. The harness warms each
workload once, interleaves shell order using a fixed shuffle seed, and reports
medians. JSON output includes all samples, versions, parameters, and binary
SHA-256 checksums. A failed shell command stops the benchmark.

Both shells inherit the same environment with `BASH_ENV` and `ENV` removed.
Wolysh uses `--no-config`; Bash uses `--noprofile --norc`. Timings include process
startup and captured stdout/stderr. Run separately from compilation, tests,
and other heavy workloads. These are local warm-cache measurements, not
universal claims or CI performance thresholds.

| Workload | Work |
| --- | --- |
| `startup` | Start a shell, execute `:`, and exit |
| `arithmetic_loop` | Increment an integer 20,000 times in each shell's native while syntax |
| `external_commands` | Run the same `/bin/true` 100 times serially |
| `pipelines` | Run the same `/bin/printf x \| /bin/cat` 40 times |
| `wait_next` | Launch `/bin/true &` and `wait -n`, repeated 100 times |
| `parallel_arithmetic` | 32 independent 2,000-increment tasks, at most 4 workers |
| `parallel_external` | 32 independent `/bin/true` tasks, at most 4 workers |

The agent workloads run against a private `XDG_RUNTIME_DIR` holding a finished
run of a synthetic `cargo test` log (`--log-mb`, default 20 MB: passing tests,
some ANSI colour, four failures and a panic) and an open session. Each one sits
next to the nearest thing a Bash user writes by hand; `-` means Bash has no
counterpart. Commands written as `wsh run ...` use the fast path that skips
shell start-up. `--no-agent` leaves them out.

| Workload | Wolysh | Bash counterpart |
| --- | --- | --- |
| `run_start` | `wsh run -d -- /bin/true` | `nohup /bin/true > log 2>&1 &` |
| `run_status` | `wsh run status bench` | `kill -0` and `wc -c < log` |
| `run_logs_tail` | `wsh run logs bench --tail 50` | `tail -n 50 log` |
| `session_exec` | `wsh session exec bench -- true` | a fresh `bash -c true` |
| `out_failures` | `out failures --file log` | `grep -n -E 'FAILED\|panicked\|^test result' log` |
| `out_budget` | `out budget 4k --file log` | `head`, `grep \| head` and `tail` of the log |
| `out_find` | `out find connection refused --limit 20` | `grep -n -i 'connection refused' \| head -n 20` |
| `run_logs_failures` | `wsh run logs bench --failures` | - |

The Bash counterparts are cheaper questions: `grep` only finds lines, while
`out failures` names the failed tests, their locations and the summary counts,
and `out budget` stays within its byte limit. The comparison shows the cost of
asking, not equal work.

The parallel comparisons use Wolysh's native `parallel` and a Bash queue using
subshells, `eval`, and `wait -n`. They include the work inside the task, not just
scheduler latency. The arithmetic comparison measures language execution;
`parallel_external` isolates a small shared external workload. The previous
release does not have `parallel`, so its parallel results are omitted.

Use `--iterations`, `--tasks`, and `--workers` to change the workload sizes.
Inspect the source before extending claims to another workload, architecture,
or machine. In particular, CPU-bound external tools, disk, and network delays
can dominate shell overhead.

## Recorded local run

Measured on 2026-10-04 on Linux x86_64 with glibc 2.44, Bash 5.3.15,
15 interleaved samples, and the default workloads above. `wsh` is the v0.4.0
ReleaseFast binary; `baseline` is the unmodified v0.3.5 ReleaseFast binary.
These numbers describe this machine and workload only.

| Workload | Wolysh ms | Bash ms | v0.3.5 ms | Bash / Wolysh |
| --- | ---: | ---: | ---: | ---: |
| Startup | 0.756 | 1.552 | 0.706 | 2.05x |
| Arithmetic loop | 5.172 | 31.869 | 5.346 | 6.16x |
| External commands | 54.513 | 65.988 | 56.086 | 1.21x |
| Pipelines | 38.759 | 46.707 | 39.303 | 1.21x |
| Wait next | 55.937 | 81.419 | 126.707 | 1.46x |
| Parallel arithmetic | 10.327 | 60.555 | unavailable | 5.86x |
| Parallel external | 10.293 | 17.445 | unavailable | 1.70x |

Removing wait polling reduced the wait workload's median by about 56% against
v0.3.5. Startup, external-command, and pipeline measurements are close to the
previous release. The large arithmetic ratios
include Wolysh's existing interpreter advantage and do not imply the same
speedup for external build tools.

[Raw samples and binary checksums](results-linux-x86_64.json) accompany this
table so the measurements can be inspected and rerun.

## Recorded agent-feature run

Measured on 2026-10-31 on Linux x86_64 with glibc 2.39, Bash 5.2.21, 15
interleaved samples, the default workloads and a 20 MB synthetic test log.
`wsh` is the ReleaseFast build with background runs, sessions and `out`;
`baseline` is the ReleaseFast build of the commit before them (`b5b8232`),
which has none of the agent commands. These numbers describe this machine and
workload only.

| Workload | Wolysh ms | Bash ms | Baseline ms | Bash / Wolysh |
| --- | ---: | ---: | ---: | ---: |
| Startup | 1.097 | 2.193 | 1.082 | 2.00x |
| Arithmetic loop | 6.873 | 30.562 | 6.680 | 4.45x |
| External commands | 155.171 | 164.671 | 153.183 | 1.06x |
| Pipelines | 61.936 | 68.122 | 64.281 | 1.10x |
| Wait next | 136.248 | 168.261 | 136.447 | 1.24x |
| Parallel arithmetic | 9.536 | 45.916 | unavailable | 4.82x |
| Parallel external | 15.041 | 39.291 | unavailable | 2.61x |
| `run -d` | 1.643 | 2.344 | unavailable | 1.43x |
| `run status` | 0.762 | 3.719 | unavailable | 4.88x |
| `run logs --tail 50` | 0.861 | 3.257 | unavailable | 3.78x |
| `session exec` | 1.096 | 1.965 | unavailable | 1.79x |
| `out failures` | 19.244 | 29.318 | unavailable | 1.52x |
| `out budget 4k` | 17.586 | 31.860 | unavailable | 1.81x |
| `out find` | 18.905 | 33.677 | unavailable | 1.78x |
| `run logs --failures` | 15.800 | - | unavailable | - |

The shared workloads are within noise of the baseline, so the new features
cost nothing when unused. The read-only `run` commands answer in under a
millisecond on the fast path, about 4x quicker than the hand-written Bash
equivalent, which starts a shell and then `wc` or `tail`. The `out` questions
over 20 MB finish in about 16–19 ms. That is 1.5–1.8x quicker than the
`grep`-based counterparts while answering more: names, locations, counts or a
budgeted summary instead of matching lines.

[Raw samples and binary checksums](results-agent-linux-x86_64.json) for this run.
