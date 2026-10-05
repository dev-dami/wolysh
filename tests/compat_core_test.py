#!/usr/bin/env python3
"""End-to-end checks for core bash-parity semantics: words, assignments,
expansion limits, source, cd, aliases, kill, command errors and arithmetic."""
import os
import pathlib
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"


def run_shell(command, cwd=ROOT, env=None, timeout=10):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=cwd,
        env=env,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


class CoreCompatTests(unittest.TestCase):
    def assert_success(self, result):
        self.assertEqual(
            result.returncode,
            0,
            f"wsh exited {result.returncode}; stdout={result.stdout!r}, stderr={result.stderr!r}",
        )

    def assert_output(self, command, stdout, **kwargs):
        result = run_shell(command, **kwargs)
        self.assert_success(result)
        self.assertEqual(result.stdout.decode(), stdout)
        return result

    # --- 1. bare words ------------------------------------------------------

    def test_bare_words_stay_literal_for_commands(self):
        self.assert_output("status=dirty; echo git status", "git status\n")
        self.assert_output("for f in a b { }; echo rm f; /bin/echo f", "rm f\nf\n")

    def test_print_still_reads_bare_names(self):
        self.assert_output("for file in one two { print file }", "one\ntwo\n")
        self.assert_output('let name = "x"; print name "name"', "x name\n")

    # --- 2. assignments and the environment --------------------------------

    def test_bare_assignment_is_not_exported(self):
        self.assert_output("secret=x; /bin/sh -c 'echo \"[$secret]\"'; echo $secret", "[]\nx\n")

    def test_assignment_updates_exported_names(self):
        self.assert_output(
            "export WSH_CORE_EXPORTED=old; WSH_CORE_EXPORTED=new; /bin/sh -c 'echo $WSH_CORE_EXPORTED'",
            "new\n",
        )
        env = dict(os.environ, WSH_CORE_INHERITED="parent")
        self.assert_output(
            "WSH_CORE_INHERITED=changed; /bin/sh -c 'echo $WSH_CORE_INHERITED'", "changed\n", env=env
        )

    def test_unset_removes_variable_and_environment_entry(self):
        self.assert_output('x=1; unset x; echo "[$x]"', "[]\n")
        self.assert_output(
            "export WSH_CORE_GONE=1; unset WSH_CORE_GONE; /bin/sh -c 'echo \"[$WSH_CORE_GONE]\"'; echo \"[$WSH_CORE_GONE]\"",
            "[]\n[]\n",
        )

    def test_unset_functions_and_options(self):
        result = run_shell("fn greet() { echo hi }; unset -f greet; greet")
        self.assertEqual(result.returncode, 127)
        self.assertIn(b"command not found: greet", result.stderr)
        # Without an option a name with no variable falls back to the function.
        result = run_shell("fn greet() { echo hi }; unset greet; greet")
        self.assertEqual(result.returncode, 127)
        self.assert_output("fn greet() { echo hi }; unset -v greet; greet", "hi\n")
        result = run_shell("unset -v 1bad")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"not a valid identifier", result.stderr)
        result = run_shell("unset -z x")
        self.assertEqual(result.returncode, 2)

    def test_function_can_unset_itself_while_running(self):
        self.assert_output("fn once() { unset -f once; echo still running }; once; once || echo gone", "still running\ngone\n")

    def test_large_variable_does_not_break_external_commands(self):
        result = run_shell("big=$(head -c 300000 /dev/zero | tr '\\0' a); /bin/echo ok; echo ${#big}")
        self.assert_success(result)
        self.assertEqual(result.stdout, b"ok\n300000\n")
        result = run_shell("export big=$(head -c 300000 /dev/zero | tr '\\0' a); /bin/true")
        self.assertEqual(result.returncode, 126)
        self.assertIn(b"wsh: /bin/true: Argument list too long", result.stderr)

    # --- 3. assignment status -----------------------------------------------

    def test_assignment_status_comes_from_command_substitution(self):
        self.assert_output("out=$(false) || echo fallback", "fallback\n")
        self.assert_output("x=$(exit 3); echo $?", "3\n")
        self.assert_output("false; y=$?; echo $? $y", "0 1\n")
        self.assert_output("a=$(exit 2) b=$(true); echo $?", "0\n")
        self.assert_output("$(exit 4); echo $?", "4\n")

    # --- 4. list values -----------------------------------------------------

    def test_long_lists_expand_in_full(self):
        items = ",".join(f"item{i}" for i in range(1000))
        result = self.assert_output(
            f'let parts = split("{items}", ","); let n = 0; for p in $parts {{ let n = n + 1 }}; echo $n $p',
            "1000 item999\n",
        )
        self.assertEqual(result.stderr, b"")

    # --- 5. brace expansion -------------------------------------------------

    def test_large_brace_ranges_expand(self):
        self.assert_output("let n = 0; for i in {1..10001} { let n = n + 1 }; echo $n $i", "10001 10001\n")
        self.assert_output("for i in {1..1000000} { }; echo $i", "1000000\n", timeout=60)

    def test_brace_padding_and_steps_match_bash(self):
        for word in ("{01..10}", "{-05..5}", "{1..10..2}", "{10..1..3}", "{a..z..2}", "{1..010}", "{05..-3..2}", "x{1..3}y{a,b}"):
            with self.subTest(word=word):
                expected = subprocess.run(["bash", "-c", f"echo {word}"], capture_output=True, check=True).stdout
                result = run_shell(f"echo {word}")
                self.assert_success(result)
                self.assertEqual(result.stdout, expected)

    def test_oversized_brace_range_fails_loudly(self):
        result = run_shell("echo {1..99999999}; echo after")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"after\n")
        self.assertIn(b"brace expansion: too many words", result.stderr)

    # --- 6. source ----------------------------------------------------------

    def test_return_ends_only_the_sourced_file(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            script = pathlib.Path(temp_dir) / "s.sh"
            script.write_text("echo in\nreturn 3\necho skipped\n")
            self.assert_output(f". {shlex.quote(str(script))}; echo after $?", "in\nafter 3\n")
            self.assert_output(
                f"fn f() {{ source {shlex.quote(str(script))}; echo inside $?; return 5 }}; f; echo $?",
                "in\ninside 3\n5\n",
            )

    def test_sourced_file_sees_caller_positional_parameters(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            script = pathlib.Path(temp_dir) / "args.sh"
            script.write_text('echo "$# $1 $2"\n')
            quoted = shlex.quote(str(script))
            main = pathlib.Path(temp_dir) / "main.sh"
            main.write_text(f". {quoted}; . {quoted} x; echo $1\n")
            result = subprocess.run(
                [str(SHELL), "--no-config", str(main), "a", "b"],
                capture_output=True,
                timeout=10,
                check=False,
            )
            self.assert_success(result)
            self.assertEqual(result.stdout, b"2 a b\n1 x \na\n")

    def test_source_searches_path_then_current_directory(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir)
            (base / "bin").mkdir()
            (base / "bin" / "lib.sh").write_text("echo from-path\n")
            (base / "lib.sh").write_text("echo from-cwd\n")
            (base / "local.sh").write_text("echo local-only\n")
            env = dict(os.environ, PATH=f"{base / 'bin'}:{os.environ['PATH']}")
            self.assert_output(". lib.sh; source local.sh", "from-path\nlocal-only\n", cwd=base, env=env)
            result = run_shell(". missing-file.sh", cwd=base)
            self.assertEqual(result.returncode, 1)
            self.assertIn(b"missing-file.sh: No such file or directory", result.stderr)

    # --- 7. cd and pwd ------------------------------------------------------

    def make_tree(self, base):
        (base / "real" / "sub").mkdir(parents=True)
        (base / "sub" / "deep").mkdir(parents=True)
        (base / "file").write_text("")
        (base / "link").symlink_to(base / "real" / "sub")

    def test_cd_dash_returns_to_the_absolute_previous_directory(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            self.assert_output(
                "cd sub; cd deep; cd -; echo $PWD $OLDPWD",
                f"{base}/sub\n{base}/sub {base}/sub/deep\n",
                cwd=base,
            )

    def test_cd_is_logical_by_default(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            self.assert_output(
                "cd link; pwd; pwd -P; /bin/sh -c 'echo $PWD'; cd ..; pwd",
                f"{base}/link\n{base}/real/sub\n{base}/link\n{base}\n",
                cwd=base,
            )
            self.assert_output("cd -P link; pwd; cd ..; pwd", f"{base}/real/sub\n{base}/real\n", cwd=base)
            self.assert_output("cd -L link/..; pwd", f"{base}\n", cwd=base)

    def test_inherited_pwd_keeps_the_symlinked_path(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            env = dict(os.environ, PWD=str(base / "link"))
            self.assert_output("pwd; cd ..; pwd", f"{base}/link\n{base}\n", cwd=base / "link", env=env)
            # A stale PWD is ignored.
            env = dict(os.environ, PWD=str(base))
            self.assert_output("pwd", f"{base}/real/sub\n", cwd=base / "link", env=env)

    def test_cd_uses_cdpath_and_announces_the_directory(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            self.assert_output(f"CDPATH=:{base}/sub; cd deep; pwd", f"{base}/sub/deep\n{base}/sub/deep\n", cwd=base)
            # An empty entry is the current directory and is not announced.
            self.assert_output(f"CDPATH=:{base}/real; cd sub; pwd", f"{base}/sub\n", cwd=base)
            # `./name` bypasses CDPATH.
            result = run_shell(f"CDPATH={base}/sub; cd ./deep", cwd=base)
            self.assertEqual(result.returncode, 1)

    def test_cd_errors_match_bash(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            cases = {
                "cd missing": b"wsh: cd: missing: No such file or directory\n",
                "cd file": b"wsh: cd: file: Not a directory\n",
                "cd missing/..": b"wsh: cd: missing/..: No such file or directory\n",
                'cd ""': b"wsh: cd: null directory\n",
            }
            for command, message in cases.items():
                with self.subTest(command=command):
                    result = run_shell(command, cwd=base)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stderr, message)
            result = run_shell("cd a b", cwd=base)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stderr, b"wsh: cd: too many arguments\n")
            result = run_shell("unset OLDPWD; cd -", cwd=base)
            self.assertEqual(result.returncode, 1)
            self.assertEqual(result.stderr, b"wsh: cd: OLDPWD not set\n")
            if os.geteuid() != 0:
                locked = base / "locked"
                locked.mkdir(mode=0)
                try:
                    result = run_shell("cd locked", cwd=base)
                    self.assertEqual(result.returncode, 1)
                    self.assertEqual(result.stderr, b"wsh: cd: locked: Permission denied\n")
                finally:
                    locked.chmod(0o755)

    def test_pushd_and_popd_keep_logical_paths(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            self.make_tree(base)
            self.assert_output(
                "cd link; pushd .. > /dev/null; pwd; popd > /dev/null; pwd",
                f"{base}\n{base}/link\n",
                cwd=base,
            )

    # --- 8. aliases with operators -----------------------------------------

    def test_alias_with_a_pipeline_runs_whole(self):
        self.assert_output("alias up = echo abc | tr a-z A-Z\nup", "ABC\n")
        self.assert_output("alias psg='printf \"%s\\n\" alpha beta gamma | grep'\npsg -v beta", "alpha\ngamma\n")

    def test_operator_alias_redirection_and_pipeline_cover_the_whole_body(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            out = pathlib.Path(temp_dir) / "out"
            self.assert_output(f"alias two = echo one; echo two\ntwo > {out}; /bin/cat {out}", "one\ntwo\n")
            self.assert_output("alias two = echo one; echo two\ntwo | /usr/bin/wc -l", "2\n")
            self.assert_output("alias two = echo one; echo two\nWSH_CORE_X=1 two && echo ok", "one\ntwo\nok\n")

    def test_alias_arguments_are_passed_literally(self):
        self.assert_output("alias show = echo start | cat; echo\nshow 'a  b' '$HOME' \"it's\"", "start\na  b $HOME it's\n")
        # As in bash, arguments after a trailing `;` form a command of their own.
        self.assert_output("alias first = echo start;\nfirst /bin/echo next", "start\nnext\n")

    def test_self_referencing_aliases_do_not_recurse(self):
        result = run_shell("alias greet = echo hi; greet\ngreet", timeout=5)
        self.assertEqual(result.stdout, b"hi\n")
        self.assertIn(b"command not found: greet", result.stderr)
        result = run_shell("alias loop = echo x | loop\nloop | cat", timeout=5)
        self.assertIn(b"command not found: loop", result.stderr)
        self.assert_output("alias echo = echo prefixed\necho hi", "prefixed hi\n")

    # --- 9. kill ------------------------------------------------------------

    def test_kill_reports_failures(self):
        result = run_shell("kill 2147483646; echo $?")
        self.assertEqual(result.stdout, b"1\n")
        self.assertEqual(result.stderr, b"wsh: kill: (2147483646) - No such process\n")
        if os.geteuid() != 0:
            result = run_shell("kill -0 1; echo $?")
            self.assertEqual(result.stdout, b"1\n")
            self.assertEqual(result.stderr, b"wsh: kill: (1) - Operation not permitted\n")
        result = run_shell("/bin/sleep 5 & kill -9 $!; wait $!; echo $?")
        self.assertEqual(result.stdout, b"137\n")

    def test_kill_lists_signals_like_bash(self):
        bash = shutil.which("bash")
        if bash is None:
            self.skipTest("bash is not installed")
        for args in ("-l", "-L", "-l 9 137 KILL sigterm 0"):
            with self.subTest(args=args):
                expected = subprocess.run([bash, "-c", f"kill {args}"], capture_output=True, check=True).stdout
                self.assert_output(f"kill {args}", expected.decode())
        result = run_shell("kill -l 200")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"200: invalid signal specification", result.stderr)

    # --- 10. command execution errors ---------------------------------------

    def test_command_execution_errors_match_bash(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir)
            (base / "noexec").write_text("echo hi\n")
            (base / "adir").mkdir()
            bad = base / "badinterp"
            bad.write_text("#!/nonexistent/interp -x\necho hi\n")
            bad.chmod(0o755)
            (base / "pathdir").mkdir()
            (base / "pathdir" / "plainfile").write_text("echo hi\n")
            cases = [
                ("./noexec", 126, "wsh: ./noexec: Permission denied\n"),
                ("./adir", 126, "wsh: ./adir: Is a directory\n"),
                ("./missing", 127, "wsh: ./missing: No such file or directory\n"),
                ("./badinterp", 126, "wsh: ./badinterp: /nonexistent/interp: bad interpreter: No such file or directory\n"),
                ("./noexec/x", 126, "wsh: ./noexec/x: Not a directory\n"),
                ("./noexec | cat", 0, "wsh: ./noexec: Permission denied\n"),
            ]
            if os.geteuid() == 0:
                cases = [case for case in cases if "noexec" not in case[0]]
            for command, status, message in cases:
                with self.subTest(command=command):
                    result = run_shell(command, cwd=base)
                    self.assertEqual(result.returncode, status)
                    self.assertEqual(result.stderr.decode(), message)
            env = dict(os.environ, PATH=f"{base / 'pathdir'}:{os.environ['PATH']}")
            result = run_shell("plainfile", cwd=base, env=env)
            if os.geteuid() != 0:
                self.assertEqual(result.returncode, 126)
                self.assertEqual(result.stderr.decode(), f"wsh: {base}/pathdir/plainfile: Permission denied\n")
            result = run_shell("exec ./adir", cwd=base)
            self.assertEqual(result.returncode, 126)
            self.assertEqual(result.stderr, b"wsh: ./adir: Is a directory\n")
            result = run_shell("exec wsh-core-missing-command; echo unreachable", cwd=base)
            self.assertEqual(result.returncode, 127)
            self.assertEqual(result.stdout, b"")
            self.assertEqual(result.stderr, b"wsh: exec: wsh-core-missing-command: not found\n")
            result = run_shell("command ./adir", cwd=base)
            self.assertEqual(result.returncode, 126)
            self.assertEqual(result.stderr, b"wsh: ./adir: Is a directory\n")

    # --- 11. expression arithmetic -----------------------------------------

    def test_division_by_zero_is_an_error(self):
        for expr in ("10 / 0", "5 % 0", "1.5 / 0"):
            with self.subTest(expr=expr):
                result = run_shell(f'let x = {expr}; echo "[$x] $?"')
                self.assertEqual(result.stdout, b"[] 2\n")
                self.assertEqual(result.stderr, b"wsh: division by zero\n")

    def test_minimum_integer_wraps_like_bash(self):
        self.assert_output(
            "let m = -9223372036854775807 - 1; let a = m / -1; let b = m % -1; let c = -m; let d = abs(m); echo $a $b $c $d",
            "-9223372036854775808 0 -9223372036854775808 -9223372036854775808\n",
        )

    def test_only_canonical_numerals_are_numbers(self):
        cases = [
            ('"1.10" == "1.1"', "false"),
            ('"007" == "7"', "false"),
            ('"inf" == "infinity"', "false"),
            ('"nan" == "nan"', "true"),
            ('"-0" == "0"', "true"),
            ('1 == "1.0"', "true"),
            ('"9" < "10"', "true"),
            ('"09" < "1"', "true"),
            ('"1" + ".0"', "1.0"),
            ('"007" + "1"', "0071"),
            ('"2" + "3"', "5"),
            ('"1.5" * 2', "3"),
        ]
        for expr, expected in cases:
            with self.subTest(expr=expr):
                self.assert_output(f"let r = {expr}; echo $r", expected + "\n")

    def test_arithmetic_on_non_numbers_is_an_error(self):
        for expr, operand in (('"abc" - 1', "abc"), ('2 * "007"', "007"), ('-"x"', "x"), ("missing / 2", "")):
            with self.subTest(expr=expr):
                result = run_shell(f"let r = {expr}; echo $?")
                self.assertEqual(result.stdout, b"1\n")
                self.assertEqual(result.stderr.decode(), f"wsh: not a number: '{operand}'\n")
        self.assert_output("let total = 0; for n in 1 2 3 { let total = total + n }; echo $total", "6\n")


class Session:
    """A pty-driven interactive shell, as in tests/pty_test.py."""

    def __init__(self, cwd):
        self.data_home = tempfile.TemporaryDirectory(prefix="wsh-pty-")
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["XDG_CONFIG_HOME"] = os.path.join(self.data_home.name, "config")
        env["XDG_DATA_HOME"] = os.path.join(self.data_home.name, "data")
        env.pop("PWD", None)
        os.makedirs(os.path.join(env["XDG_DATA_HOME"], "wsh"), exist_ok=True)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        self.buf = b""

    def read_until(self, needle, timeout=8.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.buf:
                return True
            ready, _, _ = select.select([self.fd], [], [], 0.2)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                self.buf += chunk
        return needle in self.buf

    def send(self, data):
        os.write(self.fd, data.encode())

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass
        os.close(self.fd)
        self.data_home.cleanup()


def strip_ansi(data):
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", data)


class InteractiveCdTests(unittest.TestCase):
    def test_prompt_follows_the_logical_directory(self):
        with tempfile.TemporaryDirectory(prefix="wsh-core-") as temp_dir:
            base = pathlib.Path(temp_dir).resolve()
            (base / "real" / "sub").mkdir(parents=True)
            (base / "shortcut").symlink_to(base / "real" / "sub")
            session = Session(base)
            try:
                self.assertTrue(session.read_until("❯".encode()), session.buf[-200:])
                session.buf = b""
                session.send("cd shortcut\r")
                self.assertTrue(session.read_until(b"shortcut"), strip_ansi(session.buf))
                session.buf = b""
                session.send("echo [$PWD]\r")
                self.assertTrue(session.read_until(f"[{base}/shortcut]".encode()), strip_ansi(session.buf))
                session.buf = b""
                session.send("cd ..; echo [$PWD]\r")
                self.assertTrue(session.read_until(f"[{base}]".encode()), strip_ansi(session.buf))
            finally:
                session.close()


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
