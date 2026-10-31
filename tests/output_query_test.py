#!/usr/bin/env python3
"""End-to-end checks for the `out` builtin: summaries within a byte budget,
fuzzy and exact search, failed-test extraction, line ranges and statistics,
read from stdin, files and background-run logs."""
import json
import os
import pathlib
import re
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"

CARGO_LOG = """\
   Compiling demo v0.1.0 (/work/demo)
    Finished `test` profile [unoptimized + debuginfo] target(s) in 0.89s
     Running unittests src/lib.rs (target/debug/deps/demo-597d8a4ee52794e1)

running 4 tests
test tests::slow ... ignored
test tests::it_works ... ok
test tests::it_fails ... \x1b[31mFAILED\x1b[0m
test tests::it_panics ... \x1b[31mFAILED\x1b[0m

failures:

---- tests::it_fails stdout ----

thread 'tests::it_fails' panicked at src/lib.rs:6:29:
assertion `left == right` failed
  left: 4
 right: 5

---- tests::it_panics stdout ----

thread 'tests::it_panics' panicked at src/lib.rs:7:30:
connection refused by server


failures:
    tests::it_fails
    tests::it_panics

test result: FAILED. 1 passed; 2 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.19s

error: test failed, to rerun pass `--lib`
"""

PASSING_LOG = """\
running 2 tests
test a ... ok
test b ... ok

test result: ok. 2 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; finished in 0.00s
"""


def big_log(tests):
    """A cargo-like log of `tests` passing tests with two failures."""
    lines = ["   Compiling big v0.1.0 (/work/big)", "", f"running {tests} tests"]
    for i in range(tests):
        if i in (tests // 3, tests - 5):
            lines.append(f"test suite::case_{i} ... FAILED")
        else:
            lines.append(f"test suite::case_{i} ... ok")
    lines += ["", "failures:", "", f"---- suite::case_{tests // 3} stdout ----",
              f"thread 'suite::case_{tests // 3}' panicked at src/big.rs:10:5:", "connection refused", "",
              f"test result: FAILED. {tests - 2} passed; 2 failed; 0 ignored; 0 measured; 0 filtered out", ""]
    return "\n".join(lines)


class OutTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-out-")
        self.dir = pathlib.Path(self.temp.name)
        self.env = dict(os.environ, WSH_NO_PROFILE="1", XDG_CONFIG_HOME=str(self.dir))
        self.env.pop("XDG_RUNTIME_DIR", None)
        self.cargo = self.dir / "cargo.log"
        self.cargo.write_text(CARGO_LOG)

    def tearDown(self):
        self.temp.cleanup()

    def wsh(self, source, input=None, env=None, timeout=60):
        return subprocess.run(
            [str(SHELL), "--no-config", "-c", source],
            input=input,
            env=env or self.env,
            cwd=self.dir,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def test_failures_from_a_file(self):
        result = self.wsh("out failures --file cargo.log")
        self.assertEqual(result.returncode, 1, result.stderr)
        out = result.stdout.decode()
        self.assertIn("FAILED tests::it_fails [cargo] line 8 at src/lib.rs:6:29: assertion `left == right` failed", out)
        self.assertIn("FAILED tests::it_panics [cargo] line 9 at src/lib.rs:7:30: connection refused by server", out)
        self.assertIn("2 failures; 1 passed, 2 failed, 1 skipped [cargo]", out)

    def test_failure_statuses(self):
        (self.dir / "pass.log").write_text(PASSING_LOG)
        (self.dir / "prose.log").write_text("nothing to see here\njust words\n")
        passing = self.wsh("out failures --file pass.log")
        self.assertEqual(passing.returncode, 0)
        self.assertEqual(passing.stdout, b"no failures; 2 passed, 0 failed, 0 skipped [cargo]\n")
        prose = self.wsh("out failures --file prose.log")
        self.assertEqual(prose.returncode, 2)
        self.assertEqual(prose.stdout, b"no recognizable test output\n")

    def test_failures_json(self):
        result = self.wsh("out failures --json --file cargo.log")
        self.assertEqual(result.returncode, 1)
        records = [json.loads(line) for line in result.stdout.decode().splitlines()]
        failures = [r for r in records if r["type"] == "failure"]
        self.assertEqual([f["name"] for f in failures], ["tests::it_fails", "tests::it_panics"])
        self.assertEqual(failures[1]["location"], "src/lib.rs:7:30")
        self.assertEqual(failures[1]["reason"], "connection refused by server")
        summary = records[-1]
        self.assertEqual(summary, {"type": "summary", "status": "failed", "frameworks": ["cargo"],
                                   "passed": 1, "failed": 2, "skipped": 1, "failures": 2, "omitted": 0})

    def test_reads_standard_input(self):
        piped = self.wsh("out failures", input=CARGO_LOG.encode())
        self.assertEqual(piped.returncode, 1)
        self.assertIn(b"tests::it_panics", piped.stdout)
        # A pipeline inside the shell, and a redirected regular file.
        inner = self.wsh("cat cargo.log | out stats")
        self.assertEqual(inner.returncode, 0, inner.stderr)
        self.assertIn(b"frameworks: cargo\n", inner.stdout)
        redirected = self.wsh("out stats < cargo.log")
        self.assertEqual(redirected.stdout, inner.stdout)

    def test_budget_keeps_the_important_lines_within_the_limit(self):
        (self.dir / "big.log").write_text(big_log(3000))
        for size, limit in (("700", 700), ("2k", 2048), ("4096", 4096)):
            with self.subTest(size=size):
                result = self.wsh(f"out budget {size} --file big.log")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertLessEqual(len(result.stdout), limit)
                out = result.stdout.decode()
                self.assertTrue(out.startswith("   Compiling big v0.1.0"))
                self.assertIn("test suite::case_1000 ... FAILED\n", out)
                self.assertIn("test result: FAILED. 2998 passed; 2 failed", out)
                self.assertRegex(out, r"\[… [\d,]+ lines \([\d,]+ bytes\) elided; lines \d+–\d+ …\]")

    def test_elision_markers_name_exact_ranges(self):
        text = big_log(2000)
        (self.dir / "big.log").write_text(text)
        out = self.wsh("out budget 1500 --file big.log").stdout.decode()
        lines = text.split("\n")
        markers = re.findall(r"\[… ([\d,]+) lines? \(([\d,]+) bytes?\) elided; lines? (\d+)(?:–(\d+))? …\]", out)
        self.assertTrue(markers)
        for count, size, first, last in markers:
            first, last = int(first), int(last or first)
            self.assertEqual(int(count.replace(",", "")), last - first + 1)
            elided = "".join(line + "\n" for line in lines[first - 1:last])
            self.assertEqual(int(size.replace(",", "")), len(elided.encode()))
            # The marker's range (en dash and all) can be passed back to `out lines`.
            follow = self.wsh(f"out lines {first}–{last} --file big.log")
            self.assertEqual(follow.returncode, 0, follow.stderr)
            self.assertEqual(follow.stdout.decode(), elided)

    def test_budget_json_is_within_the_limit(self):
        (self.dir / "big.log").write_text(big_log(3000))
        result = self.wsh("out budget 3000 --json --file big.log")
        self.assertLessEqual(len(result.stdout), 3000)
        records = [json.loads(line) for line in result.stdout.decode().splitlines()]
        self.assertEqual(records[0], {"type": "line", "line": 1, "text": "   Compiling big v0.1.0 (/work/big)"})
        self.assertTrue(any(r["type"] == "elided" and r["lines"] == r["to"] - r["from"] + 1 for r in records))
        self.assertIn({"type": "line", "line": 1004, "text": "test suite::case_1000 ... FAILED"}, records)

    def test_small_input_is_returned_whole(self):
        result = self.wsh("out budget", input=b"one\r\n\x1b[1mtwo\x1b[0m\nthree")
        self.assertEqual(result.stdout, b"one\ntwo\nthree\n")
        raw = self.wsh("out budget --raw", input=b"\x1b[1mtwo\x1b[0m\n")
        self.assertEqual(raw.stdout, b"\x1b[1mtwo\x1b[0m\n")

    def test_find_ranks_lines_and_reports_positions(self):
        result = self.wsh("out find connection refused --file cargo.log")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines()[0], "23:connection refused by server")
        js = self.wsh("out find 'conn refused' --json --limit 1 --file cargo.log")
        records = [json.loads(line) for line in js.stdout.decode().splitlines()]
        match, summary = records
        self.assertEqual(match["line"], 23)
        self.assertEqual(match["offset"], CARGO_LOG.encode().index(b"connection refused by server"))
        self.assertEqual("".join(match["text"][p] for p in match["positions"]), "connrefused")
        self.assertEqual(summary, {"type": "summary", "matches": summary["matches"], "shown": 1})
        self.assertGreaterEqual(summary["matches"], 1)
        missing = self.wsh("out find zebra quokka --file cargo.log")
        self.assertEqual(missing.returncode, 1)
        self.assertEqual(missing.stdout, b"")

    def test_raw_json_offsets_index_the_text_they_come_with(self):
        (self.dir / "ansi.log").write_bytes(b"plain FAILED here\n\x1b[31mred FAILED\x1b[0m\n")
        for source, key in (("out grep FAILED --json --raw --file ansi.log", "spans"),
                            ("out find FAILED --json --raw --file ansi.log", "positions")):
            records = [json.loads(line) for line in self.wsh(source).stdout.decode().splitlines()]
            plain, colored = records[0], records[1]
            # A plain line keeps offsets that slice its text; a coloured one
            # gets none, since cleaned-line offsets would not index it.
            if key == "spans":
                self.assertEqual([plain["text"][a:b] for a, b in plain[key]], ["FAILED"])
            else:
                self.assertEqual("".join(plain["text"][p] for p in plain[key]), "FAILED")
            self.assertIn("\x1b", colored["text"])
            self.assertEqual(colored[key], [])

    def test_find_is_smart_case_and_shows_context(self):
        (self.dir / "case.log").write_text("Error here\nerror there\nfine\n")
        upper = self.wsh("out find Error --file case.log")
        self.assertEqual(upper.stdout, b"1:Error here\n")
        lower = self.wsh("out find error --file case.log")
        self.assertEqual(sorted(lower.stdout.decode().splitlines()), ["1:Error here", "2:error there"])
        ctx = self.wsh("out find there -C 1 --file case.log")
        self.assertEqual(ctx.stdout, b"1-Error here\n2:error there\n3-fine\n--\n")

    def test_grep_substring_regex_and_limits(self):
        result = self.wsh("out grep FAILED --file cargo.log")
        self.assertEqual(result.stdout, b"8:test tests::it_fails ... FAILED\n9:test tests::it_panics ... FAILED\n"
                                        b"30:test result: FAILED. 1 passed; 2 failed; 1 ignored; 0 measured; 0 filtered out; finished in 0.19s\n")
        limited = self.wsh("out grep FAILED --limit 1 --file cargo.log")
        self.assertEqual(limited.stdout.decode(), "8:test tests::it_fails ... FAILED\n[… 2 more matching lines; raise --limit …]\n")
        regex = self.wsh("out grep --regex 'panicked at [a-z/]+\\.rs:7' --file cargo.log")
        self.assertEqual(regex.stdout, b"22:thread 'tests::it_panics' panicked at src/lib.rs:7:30:\n")
        folded = self.wsh("out grep -i 'CONNECTION refused' --json --file cargo.log")
        match = json.loads(folded.stdout.decode().splitlines()[0])
        self.assertEqual(match["spans"], [[0, 18]])
        self.assertEqual(self.wsh("out grep nothing-like-this --file cargo.log").returncode, 1)
        bad = self.wsh("out grep --regex '(' --file cargo.log")
        self.assertEqual(bad.returncode, 2)
        self.assertIn(b"wsh: out:", bad.stderr)

    def test_grep_context_merges_overlapping_windows(self):
        (self.dir / "ctx.log").write_text("a\nhit 1\nb\nhit 2\nc\nd\ne\nhit 3\n")
        result = self.wsh("out grep hit -C 1 --file ctx.log")
        self.assertEqual(result.stdout, b"1-a\n2:hit 1\n3-b\n4:hit 2\n5-c\n--\n7-e\n8:hit 3\n")

    def test_lines_and_stats(self):
        result = self.wsh("out lines 5-7 --file cargo.log")
        self.assertEqual(result.stdout, b"running 4 tests\ntest tests::slow ... ignored\ntest tests::it_works ... ok\n")
        tail = self.wsh("out lines 32- --file cargo.log")
        self.assertEqual(tail.stdout, b"error: test failed, to rerun pass `--lib`\n")
        js = self.wsh("out lines 8 --json --file cargo.log")
        self.assertEqual(json.loads(js.stdout), {"type": "line", "line": 8, "text": "test tests::it_fails ... FAILED"})
        raw = self.wsh("out lines 8 --raw --file cargo.log")
        self.assertEqual(raw.stdout, b"test tests::it_fails ... \x1b[31mFAILED\x1b[0m\n")
        past = self.wsh("out lines 900-901 --file cargo.log")
        self.assertEqual(past.returncode, 1)
        self.assertIn(b"past the end (32 lines)", past.stderr)

        stats = self.wsh("out stats --json --file cargo.log")
        self.assertEqual(stats.returncode, 0)
        record = json.loads(stats.stdout)
        self.assertEqual(record["lines"], 32)
        self.assertEqual(record["bytes"], len(CARGO_LOG.encode()))
        self.assertEqual(record["frameworks"], ["cargo"])
        self.assertEqual(record["first_failure"], 8)
        self.assertGreaterEqual(record["errors"], 1)

    def test_budget_option_caps_other_subcommands(self):
        (self.dir / "many.log").write_text("".join(f"test t{i} ... FAILED\n" for i in range(500)))
        result = self.wsh("out failures --budget 600 --file many.log")
        self.assertEqual(result.returncode, 1)
        self.assertLessEqual(len(result.stdout), 600)
        self.assertRegex(result.stdout.decode(), r"\[… \d+ more not shown; raise --budget …\]\n500 failures \[cargo\]\n$")
        found = self.wsh("out grep FAILED --limit 500 --budget 1k --json --file many.log")
        self.assertLessEqual(len(found.stdout), 1024)
        records = [json.loads(line) for line in found.stdout.decode().splitlines()]
        self.assertEqual(records[-2]["type"], "truncated")
        self.assertEqual(records[-1], {"type": "summary", "matches": 500, "shown": 500})

    def test_background_run_logs(self):
        runtime = self.dir / "runtime"
        run_dir = runtime / "wsh" / "runs" / "test"
        run_dir.mkdir(parents=True)
        (run_dir / "output.log").write_text(CARGO_LOG)
        env = dict(self.env, XDG_RUNTIME_DIR=str(runtime))
        result = self.wsh("out failures --run test", env=env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"tests::it_fails", result.stdout)
        budget = self.wsh("out budget 1k --run test", env=env)
        self.assertEqual(budget.returncode, 0)
        self.assertLessEqual(len(budget.stdout), 1024)

        missing = self.wsh("out failures --run nope", env=env)
        self.assertEqual(missing.returncode, 2)
        self.assertIn(f"no log at {runtime}/wsh/runs/nope/output.log".encode(), missing.stderr)
        # Without a usable runtime directory the state lives under /tmp.
        fallback = self.wsh("out stats --run nope", env=dict(self.env, XDG_RUNTIME_DIR=str(self.dir / "absent")))
        self.assertIn(f"no log at /tmp/wsh-{os.getuid()}/runs/nope/output.log".encode(), fallback.stderr)
        bad = self.wsh("out stats --run ../x", env=env)
        self.assertEqual(bad.returncode, 2)
        self.assertIn(b"invalid run name", bad.stderr)

    def test_usage_errors(self):
        cases = (
            ("out", b"expected a subcommand"),
            ("out frobnicate", b"frobnicate: unknown subcommand"),
            ("out budget lots --file cargo.log", b"lots: invalid size"),
            ("out find --file cargo.log", b"find: expected a query"),
            ("out lines 9-3 --file cargo.log", b"9-3: invalid range"),
            ("out stats --bogus --file cargo.log", b"--bogus: unknown option"),
            ("out stats --file cargo.log --run x", b"--file and --run are exclusive"),
        )
        for source, message in cases:
            with self.subTest(source=source):
                result = self.wsh(source)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
        missing = self.wsh("out stats --file no-such.log")
        self.assertEqual(missing.returncode, 2)
        self.assertEqual(missing.stderr, b"wsh: out: no-such.log: No such file or directory\n")

    def test_help(self):
        result = self.wsh("help out")
        self.assertEqual(result.returncode, 0)
        self.assertIn(b"out budget [N]", result.stdout)
        self.assertIn(b"--run NAME", result.stdout)
        self.assertEqual(self.wsh("out --help").returncode, 0)

    def test_large_input(self):
        path = self.dir / "large.log"
        tests = 400_000  # about 12 MB
        path.write_text(big_log(tests))
        start = time.monotonic()
        budget = self.wsh("out budget 4k --file large.log")
        failures = self.wsh("out failures --json --file large.log")
        piped = self.wsh("cat large.log | out grep -i 'CONNECTION REFUSED'")
        elapsed = time.monotonic() - start
        self.assertLessEqual(len(budget.stdout), 4096)
        self.assertIn(f"test suite::case_{tests // 3} ... FAILED".encode(), budget.stdout)
        names = [json.loads(line).get("name") for line in failures.stdout.decode().splitlines()]
        self.assertEqual(names[:2], [f"suite::case_{tests // 3}", f"suite::case_{tests - 5}"])
        self.assertEqual(piped.stdout.decode().split(":", 1)[1], "connection refused\n")
        # Generous: these take well under a second on a laptop.
        self.assertLess(elapsed, 20)


if __name__ == "__main__":
    unittest.main()
