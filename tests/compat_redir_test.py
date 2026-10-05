#!/usr/bin/env python3
"""Redirections, process substitution, quoting, tilde and globbing, checked
against bash wherever both shells accept the same script."""
import os
import pathlib
import pty
import re
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
BASH = shutil.which("bash")
# wsh enables these by default; bash needs them switched on first, on a line
# of their own so the extended patterns parse.
BASH_PRELUDE = "shopt -s globstar extglob\n"


def run_shell(command, cwd=ROOT, env=None):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=cwd,
        env=env,
        capture_output=True,
        timeout=10,
        check=False,
    )


def run_bash(command, cwd, env=None):
    return subprocess.run(
        [BASH, "--norc", "--noprofile", "-c", BASH_PRELUDE + command],
        cwd=cwd,
        env=env,
        capture_output=True,
        timeout=10,
        check=False,
    )


def normalize_errors(stderr):
    """bash prefixes errors with `bash: line N:`; wsh says `wsh:`."""
    return re.sub(rb"(?m)^(?:/\S*/)?bash: line \d+: ", b"wsh: ", stderr)


def shell_env(**extra):
    env = dict(os.environ)
    env["LC_ALL"] = "C"
    env.update(extra)
    return env


def wsh_supports(command):
    return run_shell(command).returncode == 0


class Tree:
    """A scratch directory with a small file tree for glob checks."""

    def __init__(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-redir-")
        self.path = pathlib.Path(self.temp.name)
        for directory in ["a/b/c", "a-b", "d", ".hid/x"]:
            (self.path / directory).mkdir(parents=True)
        for name in ["a/x.zig", "a/b/y.zig", "a/b/c/z.zig", "a-b/q.zig", "top.zig",
                     ".hid/x/h.zig", ".dot.zig", "B.zig"]:
            (self.path / name).write_text("")
        (self.path / "link").symlink_to("a")

    def cleanup(self):
        self.temp.cleanup()


@unittest.skipIf(BASH is None, "bash is required for the comparisons")
class RedirectCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.tree = Tree()
        self.env = shell_env(HOME="/home/wsh-test", OLDPWD="/var")

    def tearDown(self):
        self.tree.cleanup()

    def same_as_bash(self, script, check_stderr=True):
        """Runs `script` in fresh copies of the tree under both shells."""
        results = []
        for runner in (run_bash, lambda c, cwd, env: run_shell(c, cwd=cwd, env=env)):
            tree = Tree()
            try:
                results.append(runner(script, tree.path, self.env))
            finally:
                tree.cleanup()
        bash, wsh = results
        self.assertEqual(wsh.stdout.decode(), bash.stdout.decode(), f"stdout differs for: {script}")
        if check_stderr:
            self.assertEqual(wsh.stderr.decode(), normalize_errors(bash.stderr).decode(), f"stderr differs for: {script}")
        self.assertEqual(wsh.returncode, bash.returncode, f"status differs for: {script}")
        return wsh

    # --- exec ----------------------------------------------------------------

    def test_exec_keeps_a_numbered_descriptor_open(self):
        self.same_as_bash(
            "exec 3>out; echo builtin >&3; /bin/sh -c 'echo child >&3'; exec 3>&-\n"
            "cat out\necho gone >&3\necho status=$?\n"
        )

    def test_exec_redirects_the_shells_own_output(self):
        result = run_shell("exec >log 2>&1; echo one; ls /nonexistent-wsh-path; echo two >&2", cwd=self.tree.path)
        self.assertEqual(result.stdout, b"")
        self.assertEqual(result.stderr, b"")
        log = (self.tree.path / "log").read_text()
        self.assertTrue(log.startswith("one\nls: cannot access"), log)
        self.assertTrue(log.endswith("two\n"), log)

    def test_exec_replaces_standard_input(self):
        self.same_as_bash("printf 'a\\nb\\n' > in\nexec <in\nread x\necho got $x\ncat\n")

    def test_exec_read_write_descriptor(self):
        self.same_as_bash("echo data > f\nexec 4<>f\ncat <&4\nexec 4>&-\necho more >> f\ncat f\n")

    def test_exec_with_a_command_applies_redirects_first(self):
        result = run_shell("exec /bin/echo replaced > out; echo never", cwd=self.tree.path)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"")
        self.assertEqual((self.tree.path / "out").read_text(), "replaced\n")

    def test_exec_rejects_unsupported_options(self):
        result = run_shell("exec -a name /bin/true")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b"wsh: exec: -a: unsupported option\n")

    def test_named_descriptor(self):
        self.same_as_bash("exec {fd}>f\necho $fd\necho via >&$fd\nexec {fd}>&-\ncat f\n")
        # bash names the unexpanded word; wsh names the descriptor.
        result = run_shell("exec {fd}>f; exec {fd}>&-; echo again >&$fd; echo status=$?", cwd=self.tree.path)
        self.assertEqual(result.stdout, b"status=1\n")
        self.assertEqual(result.stderr, b"wsh: 10: Bad file descriptor\n")

    # --- operators -------------------------------------------------------------

    def test_wide_descriptor_numbers(self):
        self.same_as_bash("echo x 10>f >&10\ncat f\n{ echo ten >&12; } 12>g\ncat g\necho y 33>h 1>&33\ncat h\n")

    def test_pipe_amp_carries_stderr(self):
        self.same_as_bash("ls /nonexistent-wsh-path |& cat\necho out |& cat\n{ echo a; echo b >&2; } |& cat\n")

    def test_clobber_and_read_write_operators(self):
        self.same_as_bash("echo one > f\necho two >| f\ncat f\necho abc > g\ncat 0<> g\necho hi 1<> h\ncat h\n")

    def test_group_redirects_the_named_descriptor(self):
        self.same_as_bash("{ echo out; echo err >&2; } 2>/dev/null\n{ echo out; echo err >&2; } >/dev/null 2>e\ncat e\n")

    def test_duplication_and_move(self):
        self.same_as_bash("echo moved 3>&1 >&3-\necho both >&f\ncat f\necho hi >&7\necho status=$?\n")

    def test_open_errors_report_the_reason(self):
        self.same_as_bash("cat < /nonexistent-wsh\necho status=$?\necho x > /nonexistent-wsh/f\necho status=$?\n")

    @unittest.skipUnless(wsh_supports("set -C"), "set -C is not available in this build")
    def test_noclobber(self):
        self.same_as_bash(
            "echo one > f\nset -C\necho two > f\necho status=$?\necho three &> f\n"
            "echo four >| f\ncat f\necho x > /dev/null\necho null=$?\necho new > g\ncat g\n"
        )

    # --- process substitution --------------------------------------------------

    def test_process_substitution_as_arguments(self):
        self.same_as_bash(
            "cat <(echo a) <(echo b)\ndiff <(printf 'a\\n') <(printf 'b\\n')\necho status=$?\n"
            "paste <(printf '1\\n2\\n') <(printf 'x\\ny\\n')\ncat <(echo {a,b})\n"
        )

    def test_process_substitution_as_redirect_target(self):
        self.same_as_bash("cat < <(printf 'p\\nq\\n')\nread x < <(echo first)\necho $x\n")

    def test_output_process_substitution(self):
        result = run_shell("echo hi > >(tr a-z A-Z)", cwd=self.tree.path)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout, b"HI\n")

    def test_process_substitution_paths(self):
        result = run_shell("echo <(true) --file=<(true)")
        self.assertRegex(result.stdout.decode(), r"^/dev/fd/\d+ --file=/dev/fd/\d+\n$")

    def test_process_substitution_descriptors_are_closed_and_reaped(self):
        result = run_shell(
            "/bin/ls /proc/self/fd > before; cat <(echo a) >/dev/null; /bin/ls /proc/self/fd > after\n"
            "diff before after && echo same\n/bin/sleep 0.2\nps -o stat= --ppid $$\n",
            cwd=self.tree.path,
        )
        self.assertEqual(result.stderr, b"")
        self.assertEqual(result.stdout.decode().split("\n")[0], "same")
        self.assertNotIn("Z", result.stdout.decode())

    # --- $(< file) ------------------------------------------------------------

    def test_file_substitution(self):
        self.same_as_bash(
            "printf 'line1\\nline2\\n\\n' > f\necho \"$(< f)\"\nx=$(<f)\necho \"$x\"\n"
            "echo \"[$(< /nonexistent-wsh)]\"\n"
        )

    def test_file_substitution_starts_no_process(self):
        result = run_shell("echo $$ > f; echo \"$(< f)\" $$", cwd=self.tree.path)
        first, second = result.stdout.decode().split()
        self.assertEqual(first, second)

    # --- ANSI-C quoting ---------------------------------------------------------

    def test_ansi_c_quoting(self):
        self.same_as_bash(
            "printf '%s|' $'a\\tb' $'it\\'s' $'\\x41\\101' $'\\e[0m' $'\\cA' $'q\\\\' $'\\xZ' | od -c\n"
            "echo $\"plain\" \"$'x'\"\ncat <<< $'x\\ny'\nv=$'q\\nr'\necho \"$v\"\n"
        )

    # --- tilde ------------------------------------------------------------------

    def test_tilde_prefixes(self):
        self.same_as_bash(
            "echo ~ ~/x ~root ~nosuchuser-wsh/x ~- a=~/x b=~:~ c=x:~ x:~ ~:x ~root: --opt=~\n"
            "echo \"~\" ~\"/x\" ~/\"x\"\n"
            "export P=~/bin:~/lib\necho $P\nx=~:~/a\necho $x\nreadonly R=~/r\necho $R\n"
        )

    def test_tilde_plus_is_the_working_directory(self):
        result = run_shell("cd /tmp; echo ~+/x", env=shell_env())
        self.assertEqual(result.stdout, b"/tmp/x\n")

    # --- globbing ---------------------------------------------------------------

    def test_globstar(self):
        self.same_as_bash(
            "echo **\necho **/\necho **/*.zig\necho */*\necho a/**\necho a/**/\necho **/b\necho link/**\n"
            "echo */ a/*/ /bin/sh*\n"
        )

    def test_bracket_classes(self):
        self.same_as_bash("echo [[:upper:]]* [![:lower:]]* [^a-z]* [[:bogus:]]* [ab [! a]\n")

    def test_extended_globs(self):
        self.same_as_bash("echo !(*.zig)\necho @(a|d)\necho +(a)*\necho *(a|-|b)\necho ?(a)-b\n")

    def test_glob_options(self):
        self.same_as_bash(
            "shopt -s dotglob\necho *\nshopt -u dotglob\nshopt -s nocaseglob\necho b*\nshopt -u nocaseglob\n"
            "shopt -s nullglob\necho x nomatch* y\nshopt -u nullglob\necho x nomatch* y\n"
        )

    def test_failglob_stops_the_command(self):
        result = run_shell("shopt -s failglob; echo nomatch*; echo status=$?", cwd=self.tree.path)
        self.assertEqual(result.stdout, b"status=1\n")
        self.assertEqual(result.stderr, b"wsh: no match: nomatch*\n")

    def test_globstar_and_extglob_can_be_switched_off(self):
        result = run_shell("shopt -u globstar extglob; echo **/b.zig; echo @(a)", cwd=self.tree.path)
        self.assertEqual(result.stdout, b"**/b.zig\n@(a)\n")

    @unittest.skipUnless(wsh_supports("set -f"), "set -f is not available in this build")
    def test_noglob(self):
        self.same_as_bash("set -f\necho *\nset +f\necho *.zig\n")

    # --- shopt ------------------------------------------------------------------

    def test_shopt(self):
        result = run_shell(
            "shopt nullglob; shopt -p extglob failglob; shopt -s bogus; echo status=$?\n"
            "shopt -q nullglob; echo q=$?; shopt -s nullglob; shopt -q nullglob; echo q=$?\n"
            "shopt -su nullglob; echo both=$?; shopt -x; echo bad=$?"
        )
        self.assertEqual(
            result.stdout,
            b"nullglob            \toff\nshopt -s extglob\nshopt -u failglob\nstatus=1\nq=1\nq=0\nboth=1\nbad=2\n",
        )
        self.assertEqual(
            result.stderr,
            b"wsh: shopt: bogus: invalid shell option name\n"
            b"wsh: shopt: cannot set and unset shell options simultaneously\n"
            b"wsh: shopt: -x: invalid option\nshopt: usage: shopt [-pqsu] [optname ...]\n",
        )

    def test_shopt_lists_every_option(self):
        result = run_shell("shopt")
        names = [line.split()[0] for line in result.stdout.decode().splitlines()]
        self.assertEqual(names, ["dotglob", "extglob", "failglob", "globstar", "nocaseglob", "nocasematch", "nullglob"])


class Session:
    """A wsh running on a pty (the helper from tests/pty_test.py)."""

    def __init__(self):
        self.data_home = tempfile.TemporaryDirectory(prefix="wsh-redir-pty-")
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["XDG_CONFIG_HOME"] = os.path.join(self.data_home.name, "config")
        env["XDG_DATA_HOME"] = os.path.join(self.data_home.name, "data")
        os.makedirs(os.path.join(env["XDG_DATA_HOME"], "wsh"), exist_ok=True)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.data_home.name)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        self.buf = b""

    def read_until(self, needle, timeout=8.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.buf:
                return True
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if r:
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


class InteractiveExecTests(unittest.TestCase):
    PROMPT = b"\xe2\x9d\xaf"

    def test_editor_still_draws_after_exec_moves_stderr_and_stdin(self):
        s = Session()
        try:
            self.assertTrue(s.read_until(self.PROMPT), s.buf[-200:])
            s.send("exec 2>/dev/null 4>side\r")
            s.buf = b""
            self.assertTrue(s.read_until(self.PROMPT), s.buf[-200:])
            s.send("echo shown; echo hidden >&2; echo aside >&4\r")
            self.assertTrue(s.read_until(b"shown"), s.buf[-200:])
            s.buf = b""
            self.assertTrue(s.read_until(self.PROMPT), s.buf[-200:])
            s.send("exec </dev/null; cat side\r")
            self.assertTrue(s.read_until(b"aside"), s.buf[-200:])
            s.buf = b""
            self.assertTrue(s.read_until(self.PROMPT), s.buf[-200:])
            s.send("echo still-here\r")
            self.assertTrue(s.read_until(b"\nstill-here"), s.buf[-200:])
            # Only the typed command line may mention it, never the output.
            self.assertNotIn(b"\nhidden", s.buf)
        finally:
            s.close()

    def test_ansi_c_string_with_escaped_quote_is_complete(self):
        s = Session()
        try:
            self.assertTrue(s.read_until(self.PROMPT), s.buf[-200:])
            s.send("echo $'it\\'s done'\r")
            self.assertTrue(s.read_until(b"it's done"), s.buf[-200:])
        finally:
            s.close()


if __name__ == "__main__":
    unittest.main(verbosity=2)
