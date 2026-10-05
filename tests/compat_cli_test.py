#!/usr/bin/env python3
"""End-to-end checks for the command line, login shells, `import-env` and
scripts streamed through standard input."""
import os
import pathlib
import pty
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
PROFILE_TIMEOUT_WARNING = b"did not finish within 5 seconds"


def base_env(**overrides):
    env = dict(os.environ)
    for name in ("WSH_NO_PROFILE", "WSH_PROFILE_IMPORT"):
        env.pop(name, None)
    env.update(overrides)
    return env


def run_shell(args, input=None, env=None, cwd=ROOT, argv0=None, timeout=20):
    return subprocess.run(
        [argv0 or str(SHELL), *args],
        executable=str(SHELL),
        input=input,
        env=env if env is not None else base_env(),
        cwd=cwd,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def read_until(fd, needle, timeout):
    data = b""
    deadline = time.time() + timeout
    while needle not in data and time.time() < deadline:
        ready, _, _ = select.select([fd], [], [], 0.1)
        if not ready:
            continue
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    return data


class CommandLineTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-cli-")
        self.env = base_env(XDG_CONFIG_HOME=self.temp.name, WSH_NO_PROFILE="1")

    def tearDown(self):
        self.temp.cleanup()

    def test_bundled_short_options(self):
        for args in (["-lc", "echo ok"], ["-ec", "echo ok"], ["-ilc", "echo ok"], ["-xuc", "echo ok"],
                     ["-eo", "pipefail", "-c", "echo ok"], ["+o", "errexit", "-c", "echo ok"],
                     ["-c", "-e", "echo ok"], ["-fCa", "-c", "echo ok"], ["--norc", "--noprofile", "-c", "echo ok"]):
            with self.subTest(args=args):
                result = run_shell(args, env=self.env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"ok\n")

    def test_invalid_options_are_errors(self):
        cases = (
            (["-q"], b"wsh: unknown option: -q"),
            (["--bogus"], b"wsh: unknown option: --bogus"),
            (["+c", "true"], b"wsh: unknown option: +c"),
            (["-xv"], b"wsh: unknown option: -xv"),
            (["-c"], b"wsh: -c: option requires an argument"),
            (["-o"], b"wsh: -o: option requires an argument"),
            (["--rcfile"], b"wsh: --rcfile: option requires an argument"),
            (["-o", "bogus", "-c", "true"], b"wsh: bogus: invalid option name"),
        )
        for args, message in cases:
            with self.subTest(args=args):
                result = run_shell(args, env=self.env)
                self.assertEqual(result.returncode, 2)
                self.assertIn(message, result.stderr)
                self.assertEqual(result.stdout, b"")

    def test_version_help_and_check(self):
        self.assertTrue(run_shell(["-v"], env=self.env).stdout.startswith(b"wolysh "))
        self.assertTrue(run_shell(["--version"], env=self.env).stdout.startswith(b"wolysh "))
        self.assertIn(b"usage: wsh", run_shell(["-h"], env=self.env).stdout)
        result = run_shell(["-nc", "echo should-not-run"], env=self.env)
        self.assertEqual((result.returncode, result.stdout), (0, b""))

    def test_dollar_zero_and_positional_parameters(self):
        result = run_shell(["-c", 'echo "$0|$1|$#"', "name", "one"], env=self.env)
        self.assertEqual(result.stdout, b"name|one|1\n")
        result = run_shell(["-c", 'echo "$0|$#"'], env=self.env)
        self.assertEqual(result.stdout, str(SHELL).encode() + b"|0\n")
        # As in bash, the operand after the command is `$0` even when it is `--`.
        result = run_shell(["-c", 'echo "$0|$1"', "--", "x"], env=self.env)
        self.assertEqual(result.stdout, b"--|x\n")
        result = run_shell(["-c", 'echo "$0"'], env=self.env, argv0="custom-name")
        self.assertEqual(result.stdout, b"custom-name\n")

    def test_s_reads_commands_and_keeps_arguments_positional(self):
        result = run_shell(["-s", "a", "b c"], input=b'echo "$1|$2|$#"\n', env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"a|b c|2\n")

    def test_dash_ends_options(self):
        script = pathlib.Path(self.temp.name) / "-dash.wsh"
        script.write_text('echo "$0|$1"\n')
        for marker in ("-", "--"):
            with self.subTest(marker=marker):
                result = run_shell(["-e", marker, "-dash.wsh", "arg"], env=self.env, cwd=self.temp.name)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"-dash.wsh|arg\n")

    def test_interactive_command_reads_the_configuration(self):
        config = pathlib.Path(self.temp.name) / "wsh"
        config.mkdir()
        (config / "config").write_text('let from_config = "default"\n')
        rcfile = pathlib.Path(self.temp.name) / "other"
        rcfile.write_text('let from_config = "rcfile"\n')
        cases = (
            (["-ic", "echo [$from_config]"], b"[default]\n"),
            (["-c", "echo [$from_config]"], b"[]\n"),
            (["-i", "--norc", "-c", "echo [$from_config]"], b"[]\n"),
            (["-i", "--no-config", "-c", "echo [$from_config]"], b"[]\n"),
            (["-i", "--rcfile", str(rcfile), "-c", "echo [$from_config]"], b"[rcfile]\n"),
        )
        for args, expected in cases:
            with self.subTest(args=args):
                result = run_shell(args, input=b"", env=self.env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, expected)

    def test_shlvl_and_shell_are_exported(self):
        env = dict(self.env)
        env.pop("SHLVL", None)
        env.pop("SHELL", None)
        result = run_shell(["-c", 'echo "$SHELL"; printenv SHLVL'], env=env)
        self.assertEqual(result.stdout, os.path.realpath(SHELL).encode() + b"\n1\n")
        for start, expected in (("4", b"5\n"), ("abc", b"1\n"), ("", b"1\n"), ("-5", b"0\n")):
            with self.subTest(shlvl=start):
                result = run_shell(["-c", "printenv SHLVL"], env=dict(env, SHLVL=start))
                self.assertEqual(result.stdout, expected)
        result = run_shell(["-c", 'echo "$SHELL"'], env=dict(env, SHELL="/bin/custom"))
        self.assertEqual(result.stdout, b"/bin/custom\n")


class InteractiveDetectionTests(unittest.TestCase):
    def test_piped_stdout_keeps_the_shell_interactive(self):
        temp = tempfile.TemporaryDirectory(prefix="wsh-pty-")
        self.addCleanup(temp.cleanup)
        env = base_env(TERM="xterm-256color", XDG_CONFIG_HOME=temp.name, XDG_DATA_HOME=temp.name)
        read_end, write_end = os.pipe()
        pid, master = pty.fork()
        if pid == 0:
            os.dup2(write_end, 1)
            os.close(read_end)
            os.close(write_end)
            os.chdir(ROOT)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        os.close(write_end)

        def cleanup():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                os.waitpid(pid, 0)
            except ChildProcessError:
                pass
            os.close(master)
            os.close(read_end)

        self.addCleanup(cleanup)
        self.assertIn("❯".encode(), read_until(master, "❯".encode(), 8))
        os.write(master, b"echo piped-$((40 + 2))\r")
        self.assertIn(b"piped-42\n", read_until(read_end, b"piped-42\n", 8))


class StreamingStdinTests(unittest.TestCase):
    def setUp(self):
        self.env = base_env(WSH_NO_PROFILE="1")

    def test_each_statement_runs_before_the_next_arrives(self):
        proc = subprocess.Popen([str(SHELL), "--no-config"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=self.env, cwd=ROOT)
        try:
            start = time.time()
            proc.stdin.write(b"echo first\nif true {\n  echo second\n}\n")
            proc.stdin.flush()
            # The producer keeps the pipe open; output must not wait for EOF.
            seen = read_until(proc.stdout.fileno(), b"second\n", 5)
            self.assertEqual(seen, b"first\nsecond\n")
            self.assertLess(time.time() - start, 2.5)
            proc.stdin.write(b"echo third\n")
            proc.stdin.close()
            self.assertEqual(proc.stdout.read(), b"third\n")
            self.assertEqual(proc.wait(timeout=5), 0)
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.wait()
            proc.stdout.close()
            proc.stderr.close()

    def test_slow_producer_sees_first_output_early(self):
        script = "echo 'echo first'; sleep 2; echo 'echo second'"
        proc = subprocess.Popen(f"({script}) | {shlex.quote(str(SHELL))} --no-config", shell=True,
                                stdout=subprocess.PIPE, env=self.env, cwd=ROOT)
        try:
            start = time.time()
            first = read_until(proc.stdout.fileno(), b"first\n", 5)
            elapsed = time.time() - start
            self.assertEqual(first, b"first\n")
            self.assertLess(elapsed, 1.5)
            self.assertEqual(proc.stdout.read(), b"second\n")
        finally:
            proc.wait(timeout=10)
            proc.stdout.close()

    def test_commands_read_the_input_that_follows_them(self):
        # A pipe is read a byte at a time, so `read` gets the next line.
        source = b'read line\nthis line is data\necho "got $line"\ncat\ncat reads the rest\n'
        result = run_shell(["--no-config"], input=source, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"got this line is data\ncat reads the rest\n")
        # A regular file is read ahead and rewound, so even a block-reading
        # command such as `head` leaves the rest of the script in place.
        source = b'read line\nthis line is data\necho "got $line"\nhead -n 1\nhead data\necho after\n'
        with tempfile.TemporaryFile() as script:
            script.write(source)
            script.seek(0)
            result = subprocess.run([str(SHELL), "--no-config"], stdin=script, capture_output=True,
                                    env=self.env, cwd=ROOT, timeout=20, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"got this line is data\nhead data\nafter\n")

    def test_multi_line_statements_and_here_documents(self):
        source = (b"if false {\n  echo then\n}\n\n# comment\nelse {\n  echo else\n}\n"
                  b"cat <<'EOF'\n$HOME is literal\n}\nEOF\necho a \\\n  b\necho done\n")
        result = run_shell(["--no-config"], input=source, env=self.env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"else\n$HOME is literal\n}\na b\ndone\n")

    def test_status_exit_and_syntax_errors(self):
        result = run_shell(["--no-config"], input=b"echo a\nfalse\n", env=self.env)
        self.assertEqual((result.returncode, result.stdout), (1, b"a\n"))
        result = run_shell(["--no-config"], input=b"exit 3\necho no\n", env=self.env)
        self.assertEqual((result.returncode, result.stdout), (3, b""))
        # Earlier statements have already run, as in bash; the error stops the rest.
        result = run_shell(["--no-config"], input=b"echo a\necho b; )\necho c\n", env=self.env)
        self.assertEqual((result.returncode, result.stdout), (2, b"a\n"))
        self.assertIn(b"line 2", result.stderr)

    def test_script_files_and_check_mode_parse_everything_first(self):
        with tempfile.TemporaryDirectory(prefix="wsh-script-") as temp:
            script = pathlib.Path(temp) / "broken.wsh"
            script.write_text("echo before\n)\n")
            result = run_shell(["--no-config", str(script)], env=self.env)
            self.assertEqual((result.returncode, result.stdout), (2, b""))
        result = run_shell(["--no-config", "--check"], input=b"echo before\n)\n", env=self.env)
        self.assertEqual((result.returncode, result.stdout), (2, b""))


class LoginTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-login-")
        self.home = pathlib.Path(self.temp.name)
        config = self.home / "config" / "wsh"
        config.mkdir(parents=True)
        (config / "login").write_text('export WSH_TEST_LOGIN_FILE="after-$WSH_TEST_FROM_PROFILE"\n')
        self.env = base_env(HOME=str(self.home), XDG_CONFIG_HOME=str(self.home / "config"),
                            WSH_TEST_KEEP="kept", WSH_BIN=str(SHELL))

    def tearDown(self):
        self.temp.cleanup()

    def write_profile(self, text):
        (self.home / ".profile").write_text(text)

    def run_login(self, args, **kwargs):
        # The real /etc/profile runs too; under heavy load it can exceed the
        # 5 second budget, so a timed-out import is retried once.
        for _ in range(2):
            result = run_shell(args, env=kwargs.get("env", self.env), argv0=kwargs.get("argv0"), timeout=30)
            if PROFILE_TIMEOUT_WARNING not in result.stderr:
                break
        return result

    def test_login_imports_the_profile_environment(self):
        self.write_profile(
            'echo "profile output"\n'
            'export WSH_TEST_FROM_PROFILE="from profile"\n'
            'export PATH="$PATH:/wsh-test/bin"\n'
            'unset WSH_TEST_KEEP\n'
        )
        command = 'echo "$WSH_TEST_FROM_PROFILE|$WSH_TEST_LOGIN_FILE|$WSH_TEST_KEEP|${WSH_PROFILE_IMPORT:-none}"; echo "$PATH"'
        for args, argv0 in ((["-lc", command], None), (["--login", "-c", command], None), (["-c", command], "-wsh")):
            with self.subTest(args=args, argv0=argv0):
                result = self.run_login(args, argv0=argv0)
                self.assertEqual(result.returncode, 0, result.stderr)
                lines = result.stdout.decode().splitlines()
                self.assertIn("profile output", lines)
                self.assertEqual(lines[-2], "from profile|after-from profile|kept|none")
                self.assertTrue(lines[-1].endswith(":/wsh-test/bin"), lines[-1])

    def test_noprofile_skips_login_initialisation(self):
        self.write_profile('export WSH_TEST_FROM_PROFILE="from profile"\n')
        command = 'echo "[$WSH_TEST_FROM_PROFILE|$WSH_TEST_LOGIN_FILE]"'
        for args, env in ((["-l", "--noprofile", "-c", command], self.env),
                          (["-lc", command], dict(self.env, WSH_NO_PROFILE="1")),
                          (["-c", command], self.env)):
            with self.subTest(args=args):
                result = run_shell(args, env=env)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, b"[|]\n")

    def test_a_profile_starting_wsh_does_not_recurse(self):
        self.write_profile('"$WSH_BIN" -lc \'echo "nested $WSH_PROFILE_IMPORT"\'\nexport WSH_TEST_FROM_PROFILE=outer\n')
        start = time.time()
        result = self.run_login(["-lc", 'echo "$WSH_TEST_FROM_PROFILE"'])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines()[-2:], ["nested 1", "outer"])
        self.assertEqual(result.stdout.count(b"nested"), 1)
        self.assertLess(time.time() - start, 15)

    def test_a_hanging_profile_is_abandoned(self):
        self.write_profile("export WSH_TEST_FROM_PROFILE=late\nsleep 30\n")
        start = time.time()
        result = run_shell(["-lc", 'echo "ran [$WSH_TEST_FROM_PROFILE]"'], env=self.env, timeout=30)
        self.assertLess(time.time() - start, 20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(PROFILE_TIMEOUT_WARNING, result.stderr)
        # The login file still runs; the profile's variables are not imported.
        self.assertEqual(result.stdout, b"ran []\n")


class ImportEnvTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-import-")
        self.dir = pathlib.Path(os.path.realpath(self.temp.name))
        self.target = self.dir / "target dir"
        self.target.mkdir()
        self.env = base_env(WSH_NO_PROFILE="1", REMOVED="present", CHANGED="old")

    def tearDown(self):
        self.temp.cleanup()

    def script(self, name, text):
        path = self.dir / name
        path.write_text(text)
        return path

    def test_exports_unsets_and_directory_changes_are_imported(self):
        self.script("setup.sh",
                    'echo "script output $1"\n'
                    'export IMPORTED="hello world"\n'
                    "export CHANGED=new\n"
                    "unset REMOVED\n"
                    'cd "$2"\n'
                    "return 3\n")
        command = ('import-env setup.sh arg1 ' + shlex.quote(str(self.target)) + '; echo "status=$?"; '
                   'echo "$IMPORTED|$CHANGED|${REMOVED:-gone}"; pwd; echo "$PWD|$OLDPWD"; '
                   'printenv IMPORTED')
        result = run_shell(["-c", command], env=self.env, cwd=self.dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines(), [
            "script output arg1",
            "status=3",
            "hello world|new|gone",
            str(self.target),
            f"{self.target}|{self.dir}",
            "hello world",
        ])

    def test_activate_style_scripts_see_that_they_are_sourced(self):
        self.script("activate",
                    'if [ "${BASH_SOURCE-}" = "$0" ]; then echo "must be sourced" >&2; exit 33; fi\n'
                    'export VIRTUAL_ENV="$(dirname "${BASH_SOURCE[0]}")"\n'
                    'export PATH="$VIRTUAL_ENV/bin:$PATH"\n')
        result = run_shell(["-c", 'import-env ./activate; echo "$? $VIRTUAL_ENV"'], env=self.env, cwd=self.dir)
        self.assertEqual(result.stdout, b"0 .\n")
        self.assertEqual(result.stderr, b"")

    def test_posix_shell_and_redirected_output(self):
        self.script("env.sh", 'echo "from sh"\nexport FROM_SH=yes\n')
        result = run_shell(["-c", "import-env --shell /bin/sh env.sh > out.txt; echo \"$? $FROM_SH\"; cat out.txt"],
                           env=self.env, cwd=self.dir)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"0 yes\nfrom sh\n")

    def test_failures_import_nothing(self):
        self.script("exits.sh", "export LEAKED=1\nexit 4\n")
        result = run_shell(["-c", 'import-env exits.sh; echo "status=$? [$LEAKED]"'], env=self.env, cwd=self.dir)
        self.assertEqual(result.stdout, b"status=4 []\n")
        self.assertIn(b"exited before its environment could be read", result.stderr)

        result = run_shell(["-c", 'import-env missing.sh; echo "status=$?"'], env=self.env, cwd=self.dir)
        self.assertEqual(result.stdout, b"status=1\n")
        self.assertIn(b"missing.sh: cannot read file", result.stderr)

        result = run_shell(["-c", 'import-env --shell no-such-shell-xyz exits.sh; echo "status=$?"'],
                           env=self.env, cwd=self.dir)
        self.assertEqual(result.stdout, b"status=127\n")

        for args in ("", "--bogus x"):
            with self.subTest(args=args):
                result = run_shell(["-c", f'import-env {args}; echo "status=$?"'], env=self.env, cwd=self.dir)
                self.assertEqual(result.stdout, b"status=2\n")
                self.assertIn(b"usage: import-env", result.stderr)


if __name__ == "__main__":
    unittest.main()
