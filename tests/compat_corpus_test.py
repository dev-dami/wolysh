#!/usr/bin/env python3
"""Compatibility corpus: each script in tests/corpus/ runs under bash and
under wsh, and standard output and exit status must match. The scripts are
written like real-world Bash scripts (argument parsing, config and CSV
parsing, templates, traps, strict mode), so a difference here is a script
that cannot move over. Standard error is not compared, because messages start
with `bash:` or `wsh:`."""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
CORPUS = ROOT / "tests" / "corpus"
SCRIPTS = sorted(CORPUS.glob("[0-9][0-9]-*.sh"))


def run_script(command, script):
    """Runs one script in a fresh HOME/TMPDIR and returns (status, stdout)."""
    with tempfile.TemporaryDirectory() as home:
        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "LC_ALL": "C",
            "HOME": home,
            "TMPDIR": home,
        }
        done = subprocess.run(
            [*command, str(script)],
            cwd=home,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=20,
            check=False,
        )
    return done.returncode, done.stdout.decode(errors="replace"), done.stderr.decode(errors="replace")


class CorpusTests(unittest.TestCase):
    maxDiff = None

    def test_corpus_is_present(self):
        self.assertGreaterEqual(len(SCRIPTS), 20, f"expected the corpus scripts in {CORPUS}")

    def test_scripts_match_bash(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not installed")
        for script in SCRIPTS:
            with self.subTest(script=script.name):
                expected = run_script([bash], script)
                actual = run_script([str(SHELL), "--no-config"], script)
                self.assertEqual(
                    actual[:2],
                    expected[:2],
                    f"{script.name}: status/stdout differ (bash exit {expected[0]}, wsh exit {actual[0]})\n"
                    f"wsh stderr:\n{actual[2]}",
                )


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
