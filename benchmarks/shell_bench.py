#!/usr/bin/env python3
"""Compare real shell workloads using warmups, interleaved runs, and medians."""

import argparse
import hashlib
import json
import os
import pathlib
import platform
import random
import shlex
import shutil
import statistics
import subprocess
import tempfile
import time


ROOT = pathlib.Path(__file__).resolve().parent.parent


def workloads(iterations, tasks, workers):
    wsh_loop = f"let n = 0; while n < {iterations} {{ let n = n + 1 }}"
    bash_loop = f"n=0; while (( n < {iterations} )); do (( n += 1 )); done"
    wsh_task = "let n = 0; while n < 2000 { let n = n + 1 }"
    bash_task = "n=0; while (( n < 2000 )); do (( n += 1 )); done"
    def native_parallel(task):
        return f"parallel -j {workers} " + " ".join([shlex.quote(task)] * tasks)

    def bash_parallel(task):
        return (
            f"task={shlex.quote(task)}; active=0; "
            f"for (( t=0; t<{tasks}; t++ )); do "
            '( eval "$task" ) & (( active += 1 )); '
            f"if (( active >= {workers} )); then wait -n; (( active -= 1 )); fi; "
            "done; wait"
        )
    return {
        "startup": (":", ":", True),
        "arithmetic_loop": (wsh_loop, bash_loop, True),
        "external_commands": ("/bin/true; " * 100, "/bin/true; " * 100, True),
        "pipelines": ("/bin/printf x | /bin/cat; " * 40, "/bin/printf x | /bin/cat; " * 40, True),
        "wait_next": ("/bin/true & wait -n; " * 100, "/bin/true & wait -n; " * 100, True),
        "parallel_arithmetic": (native_parallel(wsh_task), bash_parallel(bash_task), False),
        "parallel_external": (native_parallel("/bin/true"), bash_parallel("/bin/true"), False),
    }


# A synthetic `cargo test` log: passing tests, ANSI colour on some lines, a
# few failures and a panic message, so every `out` question has an answer.
def write_test_log(path, megabytes):
    rng = random.Random(1)
    target = megabytes * 1024 * 1024
    failures = {int(target * f / 100) for f in (17, 43, 71, 96)}
    written = 0
    index = 0
    with open(path, "w") as log:
        log.write("running many tests\n")
        while written < target:
            index += 1
            name = f"mod_{index % 997}::case_{index}"
            if any(written <= at < written + 64 for at in failures):
                line = f"test {name} ... FAILED\n"
            elif rng.random() < 0.1:
                line = f"test {name} ... \x1b[32mok\x1b[0m\n"
            else:
                line = f"test {name} ... ok\n"
            log.write(line)
            written += len(line)
        log.write("\nfailures:\n\n---- net::connect stdout ----\n")
        log.write("thread 'net::connect' panicked at src/net.rs:42:9:\nconnection refused (os error 111)\n\n")
        log.write(f"test result: FAILED. {index - 4} passed; 4 failed; 0 ignored; 0 measured; 0 filtered out\n")


class AgentFixture:
    """A private state directory holding a finished run of the test log and
    an open session, for the agent workloads."""

    def __init__(self, wsh, megabytes):
        self.wsh = str(wsh)
        self.dir = tempfile.mkdtemp(prefix="wsh-bench-")
        self.runtime = os.path.join(self.dir, "runtime")
        os.mkdir(self.runtime, 0o700)
        self.log = os.path.join(self.dir, "test.log")
        write_test_log(self.log, megabytes)
        self.env = {"XDG_RUNTIME_DIR": self.runtime, "BENCH_LOG": self.log, "BENCH_DIR": self.dir}
        environment = dict(os.environ, **self.env)
        subprocess.run([self.wsh, "run", "-d", "--name", "bench", "--", f"cat {shlex.quote(self.log)}"], env=environment, check=True, capture_output=True)
        subprocess.run([self.wsh, "run", "wait", "bench"], env=environment, check=True, capture_output=True)
        subprocess.run([self.wsh, "session", "new", "bench"], env=environment, check=True, capture_output=True)

    def close(self):
        environment = dict(os.environ, **self.env)
        subprocess.run([self.wsh, "session", "kill", "bench"], env=environment, capture_output=True, check=False)
        pid_file = os.path.join(self.runtime, "wsh", "daemon.pid")
        try:
            os.kill(int(open(pid_file).read().strip()), 15)
        except (OSError, ValueError):
            pass
        shutil.rmtree(self.dir, ignore_errors=True)


def agent_workloads():
    """Background runs, sessions and `out`, each next to the nearest thing a
    Bash user writes by hand. Lists are argv for the `wsh` binary (the fast
    path without shell start-up); strings run with `-c`."""
    log = '"$BENCH_LOG"'
    return {
        "run_start": {"wsh": ["run", "-d", "--", "/bin/true"], "bash": 'nohup /bin/true > "$BENCH_DIR/nohup.log" 2>&1 &'},
        "run_status": {"wsh": ["run", "status", "bench"], "bash": f'kill -0 1 2>/dev/null; wc -c < {log}'},
        "run_logs_tail": {"wsh": ["run", "logs", "bench", "--tail", "50"], "bash": f"tail -n 50 {log}"},
        "session_exec": {"wsh": ["session", "exec", "bench", "--", "true"], "bash": "true"},
        "out_failures": {"wsh": f"out failures --file {log}", "bash": f"grep -n -E 'FAILED|panicked|^test result' {log}", "status": (0, 1)},
        "out_budget": {
            "wsh": f"out budget 4k --file {log}",
            "bash": f"head -n 3 {log}; grep -n -E 'FAILED|error|panicked' {log} | head -n 50; tail -n 5 {log}",
        },
        "out_find": {"wsh": f"out find connection refused --limit 20 --file {log}", "bash": f"grep -n -i 'connection refused' {log} | head -n 20"},
        "run_logs_failures": {"wsh": ["run", "logs", "bench", "--failures"], "status": (0, 1)},
    }


def measure(binary, source, bash=False, extra_env=None, statuses=(0,)):
    args = [str(binary)]
    if isinstance(source, list):
        args += source
    else:
        args += ["--noprofile", "--norc"] if bash else ["--no-config"]
        args += ["-c", source]
    environment = {key: value for key, value in os.environ.items() if key not in ("BASH_ENV", "ENV")}
    environment.update(extra_env or {})
    start = time.perf_counter_ns()
    result = subprocess.run(args, env=environment, capture_output=True, timeout=60, check=False)
    elapsed = (time.perf_counter_ns() - start) / 1_000_000
    if result.returncode not in statuses:
        raise RuntimeError(f"{binary} failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return elapsed


def agent_names():
    return set(agent_workloads())


def run_workload(output, rng, shells, runs, name, work, extra_env):
    # A previous release has none of the agent commands; Bash only runs a
    # workload that has a Bash form.
    participants = [
        shell
        for shell in shells
        if (shell != "baseline" or work.get("baseline", False)) and (shell != "bash" or work.get("bash") is not None)
    ]
    statuses = work.get("status", (0,))

    def source_for(shell):
        return work["bash"] if shell == "bash" else work["wsh"]

    samples = {shell: [] for shell in participants}
    for shell in participants:
        measure(shells[shell], source_for(shell), shell == "bash", extra_env, statuses)
    for _ in range(runs):
        rng.shuffle(participants)
        for shell in participants:
            samples[shell].append(measure(shells[shell], source_for(shell), shell == "bash", extra_env, statuses))
    medians = {shell: round(statistics.median(values), 3) for shell, values in samples.items()}
    output["results"][name] = {
        "median_ms": medians,
        "samples_ms": samples,
        "bash_over_wsh": round(medians["bash"] / medians["wsh"], 3) if "bash" in medians else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wsh", type=pathlib.Path, default=ROOT / "zig-out/bin/wsh")
    parser.add_argument("--baseline", type=pathlib.Path, help="previous ReleaseFast wsh binary")
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--iterations", type=int, default=20000)
    parser.add_argument("--tasks", type=int, default=32)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--no-agent", action="store_true", help="skip the background run, session and out workloads")
    parser.add_argument("--log-mb", type=int, default=20, help="size of the synthetic test log for the out workloads")
    args = parser.parse_args()
    if min(args.runs, args.iterations, args.tasks, args.workers) < 1:
        parser.error("counts must be positive")
    bash = shutil.which("bash")
    if bash is None:
        parser.error("Bash is required for comparison")
    shells = {"wsh": args.wsh.resolve(), "bash": pathlib.Path(bash)}
    if args.baseline:
        shells["baseline"] = args.baseline.resolve()
    versions = {
        name: subprocess.check_output([str(binary), "--version"], text=True).splitlines()[0]
        for name, binary in shells.items()
    }
    output = {
        "platform": platform.platform(),
        "cpu_count": os.cpu_count(),
        "versions": versions,
        "sha256": {name: hashlib.sha256(binary.read_bytes()).hexdigest() for name, binary in shells.items()},
        "runs": args.runs,
        "iterations": args.iterations,
        "tasks": args.tasks,
        "workers": args.workers,
        "results": {},
    }
    rng = random.Random(0)
    table = {
        name: {"wsh": wsh_source, "bash": bash_source, "baseline": baseline_supported}
        for name, (wsh_source, bash_source, baseline_supported) in workloads(args.iterations, args.tasks, args.workers).items()
    }
    fixture = None
    if not args.no_agent:
        fixture = AgentFixture(shells["wsh"], args.log_mb)
        output["log_mb"] = args.log_mb
        table.update(agent_workloads())
    try:
        for name, work in table.items():
            run_workload(output, rng, shells, args.runs, name, work, fixture.env if fixture and name in agent_names() else None)
    finally:
        if fixture:
            fixture.close()
    if args.json:
        print(json.dumps(output, indent=2))
    else:
        print(f"{output['platform']}; {args.runs} interleaved samples; {args.workers} parallel workers")
        print("All times are medians in ms; includes process startup and captured output.")
        print(f"{'workload':<22} {'wsh':>10} {'bash':>10} {'baseline':>10} {'bash/wsh':>10}")
        for name, row in output["results"].items():
            medians = row["median_ms"]
            baseline = f"{medians['baseline']:.3f}" if "baseline" in medians else "-"
            bash_ms = f"{medians['bash']:.3f}" if "bash" in medians else "-"
            ratio = f"{row['bash_over_wsh']:.3f}" if row["bash_over_wsh"] is not None else "-"
            print(f"{name:<22} {medians['wsh']:>10.3f} {bash_ms:>10} {baseline:>10} {ratio:>10}")


if __name__ == "__main__":
    main()
