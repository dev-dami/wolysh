#!/usr/bin/env python3
"""`set`, strict mode (errexit, pipefail, xtrace), traps and `exit`, checked
against bash wherever both shells accept the same script."""
import os
import pathlib
import pty
import select
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = pathlib.Path(os.environ.get("WSH", ROOT / "zig-out" / "bin" / "wsh")).resolve()
BASH = shutil.which("bash")
TIMEOUT = 10


def run_shell(command):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=TIMEOUT,
        check=False,
    )


def run_bash(command):
    return subprocess.run(
        [BASH, "--norc", "--noprofile", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=TIMEOUT,
        check=False,
    )


@unittest.skipUnless(BASH, "bash is needed as the reference shell")
class BashComparison(unittest.TestCase):
    def assert_like_bash(self, script, bash_script=None, stderr=False):
        """Same exit status and stdout (and stderr, when asked) as bash."""
        ours = run_shell(script)
        theirs = run_bash(bash_script or script)
        context = f"\nwsh:  {script!r}\nbash: {(bash_script or script)!r}\nwsh stderr: {ours.stderr!r}"
        self.assertEqual(ours.stdout, theirs.stdout, context)
        self.assertEqual(ours.returncode, theirs.returncode, context)
        if stderr:
            self.assertEqual(ours.stderr, theirs.stderr, context)
        return ours


class SetBuiltinTests(BashComparison):
    def test_double_dash_replaces_positional_parameters(self):
        self.assert_like_bash('set -- a "b c" d; echo $# "$1" "$2"; set --; echo $#')

    def test_first_non_option_starts_the_positional_parameters(self):
        self.assert_like_bash("set x -y; echo $# $1 $2")
        self.assert_like_bash("set -e x -u; echo $# $1 $2")
        self.assert_like_bash("set -- -x --; echo $# $1 $2")
        self.assert_like_bash("set - a b; echo $# $1")

    def test_set_name_value_no_longer_assigns(self):
        result = self.assert_like_bash("set NAME value; echo $# $1 $2; echo \"[$NAME]\"")
        self.assertEqual(result.stdout, b"2 NAME value\n[]\n")

    def test_positional_parameters_survive_command_lines_and_loops(self):
        result = run_shell("set -- a b; for i in 1 2 { set -- $i x; echo $# $1 }; echo $# $1 $2")
        self.assertEqual(result.stdout, b"2 1\n2 2\n2 2 x\n")

    def test_set_inside_a_function_is_local_to_the_call(self):
        self.assert_like_bash(
            "fn f() { set -- x y z; echo $# }; set -- a; f; echo $# $1",
            "f() { set -- x y z; echo $#; }; set -- a; f; echo $# $1",
        )

    def test_combined_flags_and_option_names(self):
        self.assert_like_bash(
            "set -euo pipefail; set -o | grep -E '^(errexit|nounset|pipefail|xtrace) '"
        )
        self.assert_like_bash("set -o errexit -o noglob; set +o | grep -E 'errexit|noglob|xtrace'")
        self.assert_like_bash("set -eu; set +eu; set -o | grep -E '^(errexit|nounset) '")
        self.assert_like_bash("set -o pipefail rest; echo $# $1; set -o | grep pipefail")

    def test_option_listing_formats(self):
        result = run_shell("set -o")
        self.assertIn(b"errexit        \toff\n", result.stdout)
        self.assertIn(b"pipefail       \toff\n", result.stdout)
        result = run_shell("set -x; set +o")
        self.assertIn(b"set -o xtrace\n", result.stdout)
        self.assertIn(b"set +o errexit\n", result.stdout)

    def test_vi_and_emacs_are_opposites(self):
        result = run_shell("set -o vi; set -o | grep -E '^(vi|emacs) '; set -o emacs; set -o | grep -E '^(vi|emacs) '")
        self.assertEqual(
            result.stdout,
            b"emacs          \toff\nvi             \ton\nemacs          \ton\nvi             \toff\n",
        )

    def test_unknown_options_are_errors_with_status_two(self):
        for script in ("set -Q; echo rc=$?", "set +Q; echo rc=$?", "set -o nosuch; echo rc=$?"):
            result = self.assert_like_bash(script)
            self.assertTrue(result.stderr.startswith(b"wsh: set: "), result.stderr)

    def test_listing_quotes_values(self):
        self.assert_like_bash("x='a b'; y=\"it's\"; w=plain; e=; set | grep -E '^(x|y|w|e)='")

    def test_dollar_dash_reports_flags(self):
        result = run_shell("set -eux; echo $-; set +ex -fC; echo $-")
        self.assertEqual(result.stdout, b"eux\nfuC\n")


class ErrexitTests(BashComparison):
    def test_a_failing_command_stops_the_script(self):
        self.assert_like_bash("set -e; echo before; false; echo after")
        self.assert_like_bash("set -o errexit; /bin/sh -c 'exit 4'; echo after")
        self.assert_like_bash("set -e; nosuchcommand-wsh 2>/dev/null; echo after")

    def test_conditions_do_not_stop_the_script(self):
        self.assert_like_bash("set -e; false || true; echo after")
        self.assert_like_bash("set -e; false && true; echo after")
        self.assert_like_bash("set -e; ! true; echo after")
        self.assert_like_bash("set -e; ! false; echo after")
        self.assert_like_bash("set -e; true && false; echo after")
        self.assert_like_bash(
            "set -e; if false { echo no }; echo after",
            "set -e; if false; then echo no; fi; echo after",
        )
        self.assert_like_bash(
            "set -e; let n = 0; while n < 2 { let n = n + 1; false }; echo after",
            "set -e; n=0; while [ $n -lt 2 ]; do n=$((n + 1)); false; done; echo after",
        )

    def test_pipelines_use_the_last_status_unless_pipefail(self):
        self.assert_like_bash("set -e; false | true; echo after")
        self.assert_like_bash("set -eo pipefail; false | true; echo after")
        self.assert_like_bash("set -e; true | false; echo after")

    def test_subshells_inherit_errexit(self):
        self.assert_like_bash("set -e; (false; echo inside); echo after")
        self.assert_like_bash("set -e; (exit 3); echo after")
        self.assert_like_bash("set -e; (false; echo inside) || echo rescued; echo after")
        self.assert_like_bash("set -e; (false && true); echo after")

    def test_groups_and_functions(self):
        self.assert_like_bash("set -e; { false && true; }; echo after")
        self.assert_like_bash("set -e; { false; echo inside; }; echo after")
        self.assert_like_bash(
            "set -e; fn f() { false; echo inside }; f; echo after",
            "set -e; f() { false; echo inside; }; f; echo after",
        )
        self.assert_like_bash(
            "set -e; fn f() { false; echo inside }; f || echo failed; echo after",
            "set -e; f() { false; echo inside; }; f || echo failed; echo after",
        )
        self.assert_like_bash(
            "set -e; fn f() { false && true }; f; echo after",
            "set -e; f() { false && true; }; f; echo after",
        )
        self.assert_like_bash(
            "set -e; fn f() { return 3 }; f; echo after",
            "set -e; f() { return 3; }; f; echo after",
        )

    def test_command_substitution_does_not_inherit_errexit(self):
        self.assert_like_bash('set -e; x=$(false; echo in); echo "after $x"')
        self.assert_like_bash('set -e; x=$(set -e; false; echo in); echo "after $x"')
        self.assert_like_bash("set -e; echo $(false) visible; echo after")

    def test_assignment_takes_the_substitution_status(self):
        self.assert_like_bash("set -e; x=$(false); echo after")
        self.assert_like_bash("x=$(exit 3); echo $?")

    def test_failed_redirection_stops_the_script(self):
        self.assert_like_bash("set -e; cat < /nonexistent-wsh-file 2>/dev/null; echo after")

    def test_errexit_runs_the_exit_trap(self):
        self.assert_like_bash("set -e; trap 'echo cleanup $?' EXIT; false; echo after")
        self.assert_like_bash(
            "set -e; trap 'echo cleanup $?' EXIT; fn f() { false; echo no }; f; echo after",
            "set -e; trap 'echo cleanup $?' EXIT; f() { false; echo no; }; f; echo after",
        )

    def test_set_plus_e_turns_it_off(self):
        self.assert_like_bash("set -e; set +e; false; echo after")


class PipefailTests(BashComparison):
    def test_pipeline_status(self):
        self.assert_like_bash(
            "set -o pipefail; false | true; echo $?; true | false | true; echo $?; "
            "(exit 2) | (exit 3) | true; echo $?; true | true; echo $?"
        )
        self.assert_like_bash("false | true; echo $?")

    def test_pipestatus_holds_every_stage(self):
        self.assert_like_bash(
            "false | true | (exit 4); echo $PIPESTATUS; ! false | true; echo $PIPESTATUS $?",
            'false | true | (exit 4); echo "${PIPESTATUS[@]}"; ! false | true; echo "${PIPESTATUS[@]}" $?',
        )
        self.assert_like_bash(
            "false; echo $PIPESTATUS; (exit 3); echo $PIPESTATUS; x=$(exit 5); echo $PIPESTATUS",
            'false; echo "${PIPESTATUS[@]}"; (exit 3); echo "${PIPESTATUS[@]}"; x=$(exit 5); echo "${PIPESTATUS[@]}"',
        )
        self.assert_like_bash(
            "set -o pipefail; false | true; echo $PIPESTATUS; { false | true; }; echo $PIPESTATUS",
            'set -o pipefail; false | true; echo "${PIPESTATUS[@]}"; { false | true; }; echo "${PIPESTATUS[@]}"',
        )

    def test_jobs_and_wait_still_report_status(self):
        result = run_shell("set -o pipefail; /bin/sh -c 'exit 6' | true & wait $!; echo $?")
        self.assertEqual(result.stdout, b"0\n")
        result = run_shell("/bin/sh -c 'exit 6' & wait $!; echo $?")
        self.assertEqual(result.stdout, b"6\n")


class XtraceTests(BashComparison):
    def test_words_are_quoted_like_bash(self):
        self.assert_like_bash(
            "set -x; echo 'a b' c \"\" \"it's\" '$x' '~' 'a~' '#x' 'a#' 'x=y' 'é'", stderr=True
        )

    def test_assignments_and_prefixes(self):
        self.assert_like_bash('set -x; x=1; y="a b" z=; FOO=bar true; echo $x', stderr=True)

    def test_substitutions_nest_and_ps4_is_used(self):
        self.assert_like_bash("set -x; x=$(echo hi); echo $x", stderr=True)
        self.assert_like_bash("set -x; x=$(y=$(echo in); echo $y)", stderr=True)
        self.assert_like_bash("PS4='>> '; set -x; echo hi", stderr=True)
        self.assert_like_bash("set -x; eval 'echo hi'", stderr=True)

    def test_pipelines_lists_and_redirects(self):
        self.assert_like_bash("set -x; (echo sub)", stderr=True)
        # bash traces pipeline stages from the children, in no fixed order.
        ours = run_shell("set -x; echo a | cat")
        theirs = run_bash("set -x; echo a | cat")
        self.assertEqual(ours.stdout, theirs.stdout)
        self.assertEqual(sorted(ours.stderr.splitlines()), sorted(theirs.stderr.splitlines()))
        self.assert_like_bash("set -x; true && echo a; ! false", stderr=True)
        self.assert_like_bash("set -x; echo hi > /dev/null; set +x; echo quiet", stderr=True)

    def test_functions(self):
        self.assert_like_bash(
            "set -x; fn f() { echo in }; f a 'b c'",
            "set -x; f() { echo in; }; f a 'b c'",
            stderr=True,
        )


class TrapTests(BashComparison):
    def test_exit_trap_runs_once_at_the_end(self):
        self.assert_like_bash("trap 'echo bye $?' EXIT; echo body")
        self.assert_like_bash("trap 'echo bye $?' EXIT; false")
        self.assert_like_bash("trap 'echo first' EXIT; trap 'echo second' EXIT")
        self.assert_like_bash("trap 'echo bye' 0; echo body")

    def test_exit_trap_and_exit_status(self):
        self.assert_like_bash("trap 'echo $?' EXIT; exit 3")
        self.assert_like_bash("trap 'false' EXIT; exit 3")
        self.assert_like_bash("trap 'exit 5' EXIT; exit 3")
        self.assert_like_bash("trap 'false; exit' EXIT; exit 3")
        self.assert_like_bash("trap 'echo trapped; exit 4' EXIT; echo body")
        self.assert_like_bash(
            "trap 'echo bye' EXIT; fn f() { exit 7 }; f; echo after",
            "trap 'echo bye' EXIT; f() { exit 7; }; f; echo after",
        )

    def test_exit_trap_from_a_script_file(self):
        with tempfile.TemporaryDirectory(prefix="wsh-strict-") as temp_dir:
            script = pathlib.Path(temp_dir) / "script.sh"
            script.write_text("trap 'echo cleanup' EXIT\necho body\n")
            ours = subprocess.run([str(SHELL), "--no-config", str(script)], capture_output=True, timeout=TIMEOUT)
            self.assertEqual(ours.stdout, b"body\ncleanup\n")
            self.assertEqual(ours.returncode, 0)

    def test_children_do_not_run_the_parent_exit_trap(self):
        self.assert_like_bash("trap 'echo bye' EXIT; (echo sub); echo after")
        self.assert_like_bash("trap 'echo bye' EXIT; x=$(echo sub); echo $x")
        self.assert_like_bash("trap 'echo bye' EXIT; echo a | cat")
        self.assert_like_bash(
            "trap 'echo bye' EXIT; fn f() { echo f }; f | cat",
            "trap 'echo bye' EXIT; f() { echo f; }; f | cat",
        )

    def test_a_subshell_runs_its_own_exit_trap(self):
        self.assert_like_bash("trap 'echo bye' EXIT; (trap 'echo subbye' EXIT; echo sub); echo after")
        self.assert_like_bash('x=$(trap "echo inner" EXIT; echo val); echo "[$x]"')

    def test_ignored_exit_trap_and_reset(self):
        self.assert_like_bash("trap 'echo bye' EXIT; trap '' EXIT; echo body")
        self.assert_like_bash("trap 'echo bye' EXIT; trap - EXIT; echo body")
        self.assert_like_bash("trap 'echo bye' EXIT; trap EXIT; echo body")

    def signal_case(self, script, sig, group=False):
        """Sends `sig` once the script prints `ready`. The foreground child
        prints it, so the signal cannot land before the child is running."""
        results = []
        for runner in ([str(SHELL), "--no-config", "-c", script], [BASH, "--norc", "--noprofile", "-c", script]):
            process = subprocess.Popen(runner, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
            ready = process.stdout.readline()
            self.assertEqual(ready, b"ready\n")
            if group:
                os.killpg(process.pid, sig)
            else:
                os.kill(process.pid, sig)
            out, err = process.communicate(timeout=TIMEOUT)
            results.append((process.returncode, out))
        self.assertEqual(results[0], results[1], script)
        return results[0]

    def test_exit_trap_runs_when_a_signal_ends_the_shell(self):
        script = "trap 'echo bye' EXIT; sh -c 'echo ready; exec sleep 1'; echo after"
        self.assertEqual(self.signal_case(script, signal.SIGTERM), (-signal.SIGTERM, b"bye\n"))
        self.assertEqual(self.signal_case(script, signal.SIGHUP), (-signal.SIGHUP, b"bye\n"))
        self.assertEqual(self.signal_case(script, signal.SIGINT, group=True), (-signal.SIGINT, b"bye\n"))

    def test_signal_traps_and_ignored_signals(self):
        status, out = self.signal_case(
            "trap 'echo bye' EXIT; trap 'echo got-term' TERM; sh -c 'echo ready; exec sleep 1'; echo after",
            signal.SIGTERM,
        )
        self.assertEqual((status, out), (0, b"got-term\nafter\nbye\n"))
        status, out = self.signal_case("trap '' TERM; sh -c 'echo ready; exec sleep 1'; echo after", signal.SIGTERM)
        self.assertEqual((status, out), (0, b"after\n"))

    def test_ctrl_c_handled_by_the_foreground_command_does_not_end_the_shell(self):
        status, out = self.signal_case(
            "trap 'echo bye' EXIT; sh -c 'trap \"echo handled\" INT; echo ready; sleep 1'; echo next",
            signal.SIGINT,
            group=True,
        )
        self.assertEqual((status, out), (0, b"handled\nnext\nbye\n"))

    def test_signal_sent_to_itself(self):
        self.assert_like_bash("trap 'echo bye' EXIT; kill -TERM $$; echo after")
        self.assert_like_bash("trap 'echo usr1' USR1; kill -USR1 $$; echo after $?")
        self.assert_like_bash("trap 'echo hi' TERM; trap - TERM; kill -TERM $$; echo survived")
        self.assert_like_bash("trap '' INT; sh -c 'kill -INT $$; echo child-survived'")

    def test_err_trap(self):
        self.assert_like_bash("trap 'echo ERR $?' ERR; false; echo after; false || true; true && false; echo end")
        self.assert_like_bash("trap 'echo ERR' ERR; ! false; ! true; echo end")
        self.assert_like_bash("trap 'echo ERR' ERR; (false; echo in); echo after")
        self.assert_like_bash("trap 'echo ERR' ERR; x=$(false); echo after")
        self.assert_like_bash("set -e; trap 'echo ERR' ERR; false; echo after")
        self.assert_like_bash("trap 'echo ERR $?' ERR; false | true; set -o pipefail; false | true; echo end")

    def test_err_trap_and_functions(self):
        self.assert_like_bash(
            "trap 'echo ERR' ERR; fn f() { false }; f; echo after",
            "trap 'echo ERR' ERR; f() { false; }; f; echo after",
        )
        self.assert_like_bash(
            "trap 'echo ERR' ERR; fn f() { false; echo inside }; f; echo after",
            "trap 'echo ERR' ERR; f() { false; echo inside; }; f; echo after",
        )
        self.assert_like_bash(
            "set -E; trap 'echo ERR' ERR; fn f() { false }; f; echo after",
            "set -E; trap 'echo ERR' ERR; f() { false; }; f; echo after",
        )

    def test_debug_and_return_traps(self):
        self.assert_like_bash("trap 'echo D' DEBUG; echo a | cat | cat")
        self.assert_like_bash(
            "trap 'echo D' DEBUG; fn f() { echo in }; f",
            "trap 'echo D' DEBUG; f() { echo in; }; f",
        )
        self.assert_like_bash("trap 'echo R' RETURN; . /dev/null; echo after")
        self.assert_like_bash(
            "trap 'echo R' RETURN; fn f() { echo in }; f; echo after",
            "trap 'echo R' RETURN; f() { echo in; }; f; echo after",
        )
        self.assert_like_bash(
            "fn f() { trap 'echo R $1' RETURN; echo in }; f arg; fn g() { echo g }; g",
            "f() { trap 'echo R $1' RETURN; echo in; }; f arg; g() { echo g; }; g",
        )

    def test_listing_formats(self):
        self.assert_like_bash("trap -p; trap 'echo x' EXIT INT; trap -p; trap -p INT; trap")
        self.assert_like_bash("trap 'echo it'\"'\"'s' USR1; trap -p USR1")
        self.assert_like_bash("trap '' INT; trap -p")
        self.assert_like_bash("trap 'echo x' sigterm RTMIN+3 64; trap -p")
        self.assert_like_bash("trap 'echo hi' ERR DEBUG RETURN; trap -p")
        self.assert_like_bash("trap -l")

    def test_subshells_list_the_parent_traps_until_they_set_one(self):
        self.assert_like_bash("trap 'echo x' EXIT; trap 'echo i' INT; s=$(trap); echo \"[$s]\"; trap -p | cat")
        self.assert_like_bash("trap 'echo x' INT; (trap 'echo y' TERM; trap -p)")

    def test_errors(self):
        self.assert_like_bash("trap 'echo x' FOO; echo $?")
        self.assert_like_bash("trap echo; echo $?")
        self.assert_like_bash("trap -x; echo $?")
        result = run_shell("trap 'echo x' KILL; echo $?")
        self.assertEqual(result.stdout, b"1\n")
        self.assertIn(b"cannot be caught", result.stderr)


class ExitTests(BashComparison):
    def test_status_wraps_modulo_256(self):
        for script in ("exit 256", "exit -1", "exit 257", "exit ' 3'", "exit +4", "exit -- 5", "false; exit"):
            self.assert_like_bash(script)
        self.assert_like_bash("(exit 300); echo $?")
        self.assert_like_bash("echo hi | exit 3; echo $?")

    def test_non_numeric_argument_exits_with_two(self):
        for argument in ("abc", "99999999999999999999", "1x"):
            result = run_shell(f"exit {argument}; echo after")
            self.assertEqual(result.returncode, 2, argument)
            self.assertEqual(result.stdout, b"")
            self.assertIn(b"numeric argument required", result.stderr)

    def test_too_many_arguments(self):
        result = self.assert_like_bash("exit 1 2; echo after")
        self.assertIn(b"too many arguments", result.stderr)


# --- interactive ---------------------------------------------------------------


class Session:
    def __init__(self):
        self.data_home = tempfile.TemporaryDirectory(prefix="wsh-pty-")
        env = dict(os.environ)
        env["HOME"] = os.path.expanduser("~")
        env["TERM"] = "xterm-256color"
        env["XDG_CONFIG_HOME"] = os.path.join(self.data_home.name, "config")
        env["XDG_DATA_HOME"] = os.path.join(self.data_home.name, "data")
        os.makedirs(os.path.join(env["XDG_DATA_HOME"], "wsh"), exist_ok=True)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(ROOT)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        self.buf = b""
        self.status = None

    def read_until(self, needle, timeout=TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in self.buf:
                return True
            r, _, _ = select.select([self.fd], [], [], 0.2)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return needle in self.buf
                if not chunk:
                    return needle in self.buf
                self.buf += chunk
        return needle in self.buf

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def exited(self, timeout=TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.status is None:
                pid, status = os.waitpid(self.pid, os.WNOHANG)
                if pid:
                    self.status = status
            if self.status is not None:
                return True
            self.read_until(b"\0", timeout=0.1)
        return False

    def close(self):
        if self.status is None:
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


PROMPT = b"\xe2\x9d\xaf"


class InteractiveExitTests(unittest.TestCase):
    def start_with_stopped_job(self):
        session = Session()
        self.addCleanup(session.close)
        self.assertTrue(session.read_until(PROMPT), session.buf[-200:])
        session.send("/bin/sleep 30\r")
        time.sleep(0.3)
        session.send(b"\x1a")
        self.assertTrue(session.read_until(b"Stopped"), session.buf[-300:])
        # Input sent before the editor is back in raw mode can be lost.
        session.buf = session.buf[session.buf.index(b"Stopped"):]
        self.assertTrue(session.read_until(PROMPT), session.buf[-300:])
        return session

    def test_exit_with_stopped_jobs_needs_a_second_exit(self):
        session = self.start_with_stopped_job()
        session.buf = b""
        session.send("exit\r")
        self.assertTrue(session.read_until(b"There are stopped jobs."), session.buf[-300:])
        self.assertFalse(session.exited(timeout=0.5))
        session.send("exit\r")
        self.assertTrue(session.exited(), session.buf[-300:])

    def test_another_command_resets_the_warning(self):
        session = self.start_with_stopped_job()
        session.buf = b""
        session.send("exit\r")
        self.assertTrue(session.read_until(b"There are stopped jobs."), session.buf[-300:])
        session.send("echo still-here\r")
        self.assertTrue(session.read_until(b"still-here\r\n"), session.buf[-300:])
        session.buf = b""
        session.send("exit\r")
        self.assertTrue(session.read_until(b"There are stopped jobs."), session.buf[-300:])
        self.assertFalse(session.exited(timeout=0.5))
        session.send("exit\r")
        self.assertTrue(session.exited(), session.buf[-300:])

    def test_ctrl_d_with_stopped_jobs_needs_a_second_ctrl_d(self):
        session = self.start_with_stopped_job()
        session.buf = b""
        session.send(b"\x04")
        self.assertTrue(session.read_until(b"There are stopped jobs."), session.buf[-300:])
        self.assertFalse(session.exited(timeout=0.5))
        session.send(b"\x04")
        self.assertTrue(session.exited(), session.buf[-300:])

    def test_interactive_exit_runs_the_exit_trap(self):
        session = Session()
        self.addCleanup(session.close)
        self.assertTrue(session.read_until(PROMPT), session.buf[-200:])
        session.send("trap 'echo trap-ran' EXIT\r")
        time.sleep(0.2)
        session.send("exit 3\r")
        self.assertTrue(session.read_until(b"trap-ran"), session.buf[-300:])
        self.assertTrue(session.exited(), session.buf[-300:])
        self.assertTrue(os.WIFEXITED(session.status))
        self.assertEqual(os.WEXITSTATUS(session.status), 3)


if __name__ == "__main__":
    if not SHELL.exists():
        raise SystemExit(f"error: {SHELL} does not exist - run `zig build -Doptimize=ReleaseFast` first")
    unittest.main()
