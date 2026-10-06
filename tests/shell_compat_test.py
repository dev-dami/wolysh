#!/usr/bin/env python3
"""End-to-end checks for shell-script compatibility features."""
import json
import pathlib
import shlex
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"


def run_shell(command):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=10,
        check=False,
    )


class ShellCompatibilityTests(unittest.TestCase):
    def test_parallel_inherits_functions_and_isolates_state(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            child = pathlib.Path(temp_dir) / "child"
            inherited = pathlib.Path(temp_dir) / "inherited"
            commands = [f'let value = "child"; show > {child}', f"show > {inherited}"]
            result = run_shell(
                'let value = "parent"; fn show() { echo $value }; parallel -j 2 '
                + " ".join(shlex.quote(command) for command in commands) + "; echo $value"
            )
            self.assert_success(result)
            self.assertEqual(child.read_text(), "child\n")
            self.assertEqual(inherited.read_text(), "parent\n")
            self.assertEqual(result.stdout, b"parent\n")
            self.assertEqual(result.stderr, b"")

    def test_parallel_supports_pipelines_and_outer_redirects(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            output = pathlib.Path(temp_dir) / "output"
            result = run_shell(
                "parallel -j 2 'printf hello | /bin/cat' 'printf world' > "
                + shlex.quote(str(output))
            )
            self.assert_success(result)
            self.assertEqual(sorted(output.read_text()[i:i+5] for i in (0, 5)), ["hello", "world"])
            self.assertEqual(result.stdout, b"")

    def test_parallel_report_is_jsonl_and_failures_keep_input_order(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            report = pathlib.Path(temp_dir) / "results.jsonl"
            commands = ["/bin/sleep 0.04; exit 7", "exit 3", 'echo "quoted text"']
            result = run_shell(
                "parallel -j 3 --report " + shlex.quote(str(report)) + " "
                + " ".join(shlex.quote(command) for command in commands)
            )
            self.assertEqual(result.returncode, 7)
            rows = sorted(map(json.loads, report.read_text().splitlines()), key=lambda row: row["index"])
            self.assertEqual([row["status"] for row in rows], [7, 3, 0])
            self.assertEqual([row["command"] for row in rows], commands)
            self.assertTrue(all(row["pid"] > 0 and row["elapsed_ms"] >= 0 for row in rows))
            self.assertEqual(result.stdout, b"quoted text\n")
            self.assertEqual(result.stderr, b"")

    def test_parallel_fail_fast_skips_queued_tasks_and_drains_started_tasks(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            report = pathlib.Path(temp_dir) / "results.jsonl"
            started = pathlib.Path(temp_dir) / "started"
            skipped = pathlib.Path(temp_dir) / "skipped"
            commands = ["exit 9", f"/bin/sleep 0.04; echo finished > {started}", f"echo wrong > {skipped}"]
            result = run_shell(
                "parallel -j 2 --fail-fast --report " + shlex.quote(str(report)) + " "
                + " ".join(shlex.quote(command) for command in commands)
            )
            self.assertEqual(result.returncode, 9)
            self.assertEqual(started.read_text(), "finished\n")
            self.assertFalse(skipped.exists())
            rows = sorted(map(json.loads, report.read_text().splitlines()), key=lambda row: row["index"])
            self.assertEqual([row["event"] for row in rows], ["completed", "completed", "skipped"])
            self.assertIsNone(rows[-1]["status"])
            self.assertIsNone(rows[-1]["pid"])

    def test_parallel_limits_concurrency_and_refills_slots(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            helper = pathlib.Path(temp_dir) / "worker.py"
            events = pathlib.Path(temp_dir) / "events"
            helper.write_text(
                "import fcntl, os, sys, time\n"
                "def event(kind):\n"
                "    with open(sys.argv[1], 'a') as out:\n"
                "        fcntl.flock(out, fcntl.LOCK_EX)\n"
                "        out.write(f'{kind} {os.getpid()}\\n')\n"
                "event('start')\n"
                "time.sleep(0.06)\n"
                "event('end')\n"
            )
            task = f"{shlex.quote(sys.executable)} {shlex.quote(str(helper))} {shlex.quote(str(events))}"
            result = run_shell("parallel -j 2 " + " ".join([shlex.quote(task)] * 6))
            self.assert_success(result)
            active = 0
            peak = 0
            for event in events.read_text().splitlines():
                active += 1 if event.startswith("start ") else -1
                peak = max(peak, active)
                self.assertGreaterEqual(active, 0)
                self.assertLessEqual(active, 2)
            self.assertEqual(peak, 2)
            self.assertEqual(active, 0)
            self.assertEqual(len(events.read_text().splitlines()), 12)

    def test_parallel_validates_all_commands_before_any_side_effects(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            marker = pathlib.Path(temp_dir) / "marker"
            result = run_shell(f"parallel 'echo wrong > {marker}' 'if true {{'")
            self.assertEqual(result.returncode, 2)
            self.assertFalse(marker.exists())

    def test_parallel_rejects_invalid_options_and_report_paths(self):
        for options in ("-j 0", "-j -1", "-j nope", "--unknown", "--report"):
            with self.subTest(options=options):
                result = run_shell(f"parallel {options} 'echo wrong'")
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, b"")
        result = run_shell("parallel --report /wsh-missing-directory/results 'echo wrong'")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"")

    def test_parallel_is_available_via_builtin_and_command(self):
        for prefix in ("builtin", "command"):
            with self.subTest(prefix=prefix):
                result = run_shell(f"{prefix} parallel -j 1 'echo ready'")
                self.assert_success(result)
                self.assertEqual(result.stdout, b"ready\n")

    def test_parallel_preserves_other_background_jobs(self):
        result = run_shell("/bin/sh -c 'exit 6' & parallel -j 1 'echo ready'; wait $!")
        self.assertEqual(result.returncode, 6)
        self.assertEqual(result.stdout, b"ready\n")

    def test_parallel_reports_missing_commands_and_signals(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            report = pathlib.Path(temp_dir) / "results.jsonl"
            killed = "exec /bin/sh -c 'kill -TERM $$'"
            result = run_shell(
                "parallel -j 1 --report " + shlex.quote(str(report))
                + " 'wsh-definitely-missing-parallel-command' " + shlex.quote(killed)
            )
            self.assertEqual(result.returncode, 127)
            rows = list(map(json.loads, report.read_text().splitlines()))
            self.assertEqual([row["status"] for row in rows], [127, 143])

    def test_parallel_report_failure_is_visible_and_stops_queueing(self):
        result = run_shell("parallel -j 1 --report /dev/full 'echo first' 'echo wrong'")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, b"first\n")
        self.assertIn(b"cannot write task result", result.stderr)

    def test_parallel_defaults_to_available_cpus(self):
        result = run_shell("parallel 'printf a' 'printf b'")
        self.assert_success(result)
        self.assertEqual(sorted(result.stdout), sorted(b"ab"))

    def test_parallel_isolates_directories_and_environment(self):
        with tempfile.TemporaryDirectory(prefix="wsh-parallel-") as temp_dir:
            child = pathlib.Path(temp_dir) / "child"
            task = f'cd /tmp; env WSH_PARALLEL_VALUE = "child"; /bin/pwd > {child}'
            result = run_shell(
                'env WSH_PARALLEL_VALUE = "parent"; parallel -j 1 '
                + shlex.quote(task) + '; echo $WSH_PARALLEL_VALUE; /bin/pwd'
            )
            self.assert_success(result)
            self.assertEqual(child.read_text(), "/tmp\n")
            self.assertEqual(result.stdout, f"parent\n{ROOT}\n".encode())

    def test_wait_next_honors_selected_jobs_and_preserves_other_statuses(self):
        result = run_shell(
            "/bin/sh -c 'sleep 0.02; exit 5' & /bin/sh -c 'exit 7' & "
            "wait -n %1; echo $?; wait %2; echo $?; wait -n; echo $?"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"5\n7\n127\n")

    def test_wait_next_returns_the_first_completed_job(self):
        result = run_shell(
            "/bin/sh -c 'sleep 0.03; exit 5' & /bin/sh -c 'exit 7' & "
            "wait -n; echo $?; wait %1; echo $?"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"7\n5\n")

    def test_wait_preserves_status_of_partially_reaped_pipeline(self):
        result = run_shell("/bin/sleep 0.08 | /bin/sh -c 'exit 7' & /bin/sleep 0.02; wait %1")
        self.assertEqual(result.returncode, 7)

    def test_wait_next_rejects_invalid_selected_jobs(self):
        result = run_shell("/bin/sleep 0.01 & wait -n %99")
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"no such job", result.stderr)

    def test_wait_preserves_stopped_jobs_for_resumption(self):
        result = run_shell(
            "/bin/sh -c 'kill -STOP $$; exit 7' & wait %1; echo $?; "
            "bg %1; wait %1; echo $?"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout.splitlines()[0], b"147")
        self.assertEqual(result.stdout.splitlines()[-1], b"7")

    def test_check_syntax_has_no_effects_for_command_script_or_stdin(self):
        with tempfile.TemporaryDirectory(prefix="wsh-check-") as temp_dir:
            marker = pathlib.Path(temp_dir) / "marker"
            source = f"echo wrong > {marker}; echo $(/usr/bin/touch {marker})"
            script = pathlib.Path(temp_dir) / "script.wsh"
            script.write_text(source)
            for args, data in ((["--check", "-c", source], None), (["-n", str(script)], None), (["--check"], source.encode())):
                with self.subTest(args=args):
                    result = subprocess.run([str(SHELL), *args], input=data, capture_output=True, timeout=10, check=False)
                    self.assert_success(result)
                    self.assertEqual(result.stdout, b"")
                    self.assertFalse(marker.exists())
            result = subprocess.run([str(SHELL), "--check", "-c", "if true {"], capture_output=True, timeout=10, check=False)
            self.assertEqual(result.returncode, 2)

    def test_numbered_redirects_do_not_collide_with_temporary_descriptors(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            paths = [pathlib.Path(temp_dir) / f"fd{fd}" for fd in range(3, 7)]
            redirects = " ".join(
                f"{fd}>{shlex.quote(str(path))}"
                for fd, path in enumerate(paths, 3)
            )
            result = run_shell(
                "/bin/sh -c 'echo three >&3; echo four >&4; "
                "echo five >&5; echo six >&6' " + redirects
            )
            self.assert_success(result)
            self.assertEqual(
                [path.read_bytes() for path in paths],
                [b"three\n", b"four\n", b"five\n", b"six\n"],
            )

    def test_recursive_function_parameters_restore_enclosing_bindings(self):
        result = run_shell(
            'let n = "outer"; fn f(n) { if n > 0 { f 0; echo $n } }; '
            'f 1; echo $n'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"1\nouter\n")

    def test_function_defaults_and_missing_parameters_are_local(self):
        result = run_shell(
            'let n = "outer"; let m = "kept"; '
            'fn f(n = "default", m) { echo "$n:$m" }; '
            'f; echo "$n:$m"'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"default:\nouter:kept\n")

    def test_pipeline_prefix_assignments_are_isolated_for_external_commands(self):
        result = run_shell(
            'env WSH_STAGE_VALUE = "original"; '
            "WSH_STAGE_VALUE=left /bin/sh -c 'echo $WSH_STAGE_VALUE' | "
            "/bin/sh -c 'cat; echo $WSH_STAGE_VALUE'; echo $WSH_STAGE_VALUE"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"left\noriginal\noriginal\n")

    def test_pipeline_prefix_assignments_are_isolated_for_builtins_and_groups(self):
        stages = (
            "eval 'cat; echo $WSH_STAGE_VALUE'",
            "{ cat; echo $WSH_STAGE_VALUE; }",
        )
        for stage in stages:
            with self.subTest(stage=stage):
                result = run_shell(
                    'env WSH_STAGE_VALUE = "original"; '
                    "WSH_STAGE_VALUE=left eval 'echo $WSH_STAGE_VALUE' | "
                    f"{stage}; echo $WSH_STAGE_VALUE"
                )
                self.assert_success(result)
                self.assertEqual(result.stdout, b"left\noriginal\noriginal\n")

    def test_each_builtin_pipeline_stage_keeps_its_own_prefix_assignments(self):
        result = run_shell(
            'env WSH_STAGE_VALUE = "original"; '
            "WSH_STAGE_VALUE=left eval 'echo $WSH_STAGE_VALUE' | "
            "WSH_STAGE_VALUE=right eval 'cat; echo $WSH_STAGE_VALUE'; "
            "echo $WSH_STAGE_VALUE"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"left\nright\noriginal\n")

    def test_repeated_prefix_assignments_restore_original_value(self):
        result = run_shell(
            'env WSH_STAGE_VALUE = "original"; '
            "WSH_STAGE_VALUE=first WSH_STAGE_VALUE=last "
            "eval 'echo $WSH_STAGE_VALUE'; echo $WSH_STAGE_VALUE"
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"last\noriginal\n")

    def test_background_brace_group_is_registered_and_isolates_state(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            marker = shlex.quote(str(pathlib.Path(temp_dir) / "parent-ran"))
            result = run_shell(
                'let value = "parent"; '
                '{ let value = "child"; '
                "/bin/sh -c 'for i in $(seq 1 100); do "
                f"if test -f {marker}; then exit 0; fi; sleep 0.01; "
                "done; exit 1' && echo ready; } & "
                f"echo after; /usr/bin/touch {marker}; wait; echo $value"
            )
            self.assert_success(result)
            self.assertEqual(result.stdout, b"after\nready\nparent\n")
            # A non-interactive shell does not announce the job, as in bash.
            self.assertEqual(result.stderr, b"")

    def assert_success(self, result):
        self.assertEqual(
            result.returncode,
            0,
            f"wsh exited {result.returncode}; stdout={result.stdout!r}, stderr={result.stderr!r}",
        )

    def test_fd_duplication_before_stdout_redirect_preserves_original_stdout(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            output_path = pathlib.Path(temp_dir) / "redirected.txt"
            result = run_shell(
                "/bin/sh -c 'printf out; printf err >&2' 2>&1 > "
                f"{shlex.quote(str(output_path))}"
            )

            self.assert_success(result)
            self.assertEqual(result.stdout, b"err")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(output_path.read_bytes(), b"out")

    def test_fd_duplication_after_stdout_redirect_uses_redirected_stdout(self):
        with tempfile.TemporaryDirectory(prefix="wsh-compat-") as temp_dir:
            output_path = pathlib.Path(temp_dir) / "redirected.txt"
            result = run_shell(
                "/bin/sh -c 'printf out; printf err >&2' > "
                f"{shlex.quote(str(output_path))} 2>&1"
            )

            self.assert_success(result)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"")
            self.assertEqual(output_path.read_bytes(), b"outerr")

    def test_fd_duplication_routes_stderr_through_pipeline(self):
        result = run_shell(
            "/bin/sh -c 'printf out; printf err >&2' 2>&1 | /bin/cat"
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"outerr")
        self.assertEqual(result.stderr, b"")

    def test_command_not_found_diagnostic_obeys_fd_redirection(self):
        result = run_shell("wsh-missing-compat-command 2>&1")

        self.assertEqual(result.returncode, 127)
        self.assertIn(b"command not found: wsh-missing-compat-command", result.stdout)
        self.assertEqual(result.stderr, b"")

    def test_unquoted_heredoc_delimiter_expands_variables(self):
        result = run_shell(
            'let name = "wolysh"\ncat <<EOF\nhello $name $(printf expanded)\nEOF\n'
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"hello wolysh expanded\n")
        self.assertEqual(result.stderr, b"")

    def test_quoted_heredoc_delimiter_disables_expansion(self):
        result = run_shell("cat <<'EOF'\n$HOME $(printf expanded)\nEOF\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"$HOME $(printf expanded)\n")
        self.assertEqual(result.stderr, b"")

    def test_double_quoted_heredoc_delimiter_preserves_ordinary_backslash(self):
        result = run_shell('cat <<"\\EOF"\nbody\n\\EOF\n')

        self.assert_success(result)
        self.assertEqual(result.stdout, b"body\n")
        self.assertEqual(result.stderr, b"")

    def test_empty_quoted_heredoc_delimiter(self):
        result = run_shell("cat <<''\nbody\n\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"body\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_variable_changes_do_not_escape(self):
        result = run_shell(
            'let marker = "parent"\n'
            '(\n'
            '  let marker = "child"\n'
            '  print $marker\n'
            ')\n'
            'print $marker\n'
        )

        self.assert_success(result)
        self.assertEqual(result.stdout, b"child\nparent\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_runs_as_pipeline_stage(self):
        result = run_shell("(print outer; (print inner)) | /bin/cat\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"outer\ninner\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_word_may_contain_parentheses(self):
        result = run_shell("(print foo(bar))\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, b"foo(bar)\n")
        self.assertEqual(result.stderr, b"")

    def test_subshell_directory_change_does_not_escape(self):
        result = run_shell("(cd /tmp; /bin/pwd)\n/bin/pwd\n")

        self.assert_success(result)
        self.assertEqual(result.stdout, f"/tmp\n{ROOT}\n".encode())
        self.assertEqual(result.stderr, b"")

    def test_unterminated_heredoc_fails_with_a_syntax_error(self):
        result = run_shell("cat <<EOF\nbody without delimiter\n")

        self.assertEqual(result.returncode, 2)
        self.assertIn(b"here-document", result.stderr)


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
