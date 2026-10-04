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


def measure(binary, source, bash=False):
    args = [str(binary)]
    args += ["--noprofile", "--norc"] if bash else ["--no-config"]
    environment = {key: value for key, value in os.environ.items() if key not in ("BASH_ENV", "ENV")}
    start = time.perf_counter_ns()
    result = subprocess.run(args + ["-c", source], env=environment, capture_output=True, timeout=60, check=False)
    elapsed = (time.perf_counter_ns() - start) / 1_000_000
    if result.returncode:
        raise RuntimeError(f"{binary} failed ({result.returncode}): {result.stderr.decode(errors='replace')}")
    return elapsed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wsh", type=pathlib.Path, default=ROOT / "zig-out/bin/wsh")
    parser.add_argument("--baseline", type=pathlib.Path, help="previous ReleaseFast wsh binary")
    parser.add_argument("--runs", type=int, default=9)
    parser.add_argument("--iterations", type=int, default=20000)
    parser.add_argument("--tasks", type=int, default=32)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--json", action="store_true")
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
    for name, (wsh_source, bash_source, baseline_supported) in workloads(args.iterations, args.tasks, args.workers).items():
        participants = [shell for shell in shells if shell != "baseline" or baseline_supported]
        samples = {shell: [] for shell in participants}
        for shell in participants:
            measure(shells[shell], bash_source if shell == "bash" else wsh_source, shell == "bash")
        for _ in range(args.runs):
            rng.shuffle(participants)
            for shell in participants:
                samples[shell].append(measure(shells[shell], bash_source if shell == "bash" else wsh_source, shell == "bash"))
        medians = {shell: round(statistics.median(values), 3) for shell, values in samples.items()}
        output["results"][name] = {
            "median_ms": medians,
            "samples_ms": samples,
            "bash_over_wsh": round(medians["bash"] / medians["wsh"], 3),
        }
    if args.json:
        print(json.dumps(output, indent=2))
    else:
        print(f"{output['platform']}; {args.runs} interleaved samples; {args.workers} parallel workers")
        print("All times are medians in ms; includes process startup and captured output.")
        print(f"{'workload':<22} {'wsh':>10} {'bash':>10} {'baseline':>10} {'bash/wsh':>10}")
        for name, row in output["results"].items():
            medians = row["median_ms"]
            baseline = f"{medians['baseline']:.3f}" if "baseline" in medians else "-"
            print(f"{name:<22} {medians['wsh']:>10.3f} {medians['bash']:>10.3f} {baseline:>10} {row['bash_over_wsh']:>10.3f}")


if __name__ == "__main__":
    main()
