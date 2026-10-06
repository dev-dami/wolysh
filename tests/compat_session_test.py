#!/usr/bin/env python3
"""Interactive session behaviour driven through a real pty: Ctrl-C, signals,
history persistence, hooks, terminal integration and bash prompts."""
import os
import pathlib
import pty
import re
import select
import signal
import sys
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = pathlib.Path(os.environ.get("WSH", ROOT / "zig-out/bin/wsh")).resolve()
TIMEOUT = 8.0

PROMPT_END = b"\x1b]133;B\x1b\\"
OUTPUT_START = b"\x1b]133;C\x1b\\"
COMMAND_END = re.compile(rb"\x1b\]133;D;(\d+)\x1b\\")


def strip_ansi(data):
    data = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", data)
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", data)


class Session:
    def __init__(self, home, extra_env=None, cwd=None):
        env = {k: v for k, v in os.environ.items() if k not in ("PS1", "PS2", "PROMPT_COMMAND", "HISTCONTROL", "NO_COLOR")}
        env["HOME"] = str(home)
        env["TERM"] = "xterm-256color"
        env["XDG_CONFIG_HOME"] = str(home / "config")
        env["XDG_DATA_HOME"] = str(home / "data")
        env.update(extra_env or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd or home)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        self.buf = b""
        self.status = None

    def fill(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return True
        try:
            chunk = os.read(self.fd, 65536)
        except OSError:
            return False
        if not chunk:
            return False
        self.buf += chunk
        return True

    def read_until(self, pattern, start=0, timeout=TIMEOUT):
        """Waits for `pattern` (bytes or compiled regex) at or after `start`;
        returns the end offset of the match or None."""
        deadline = time.time() + timeout
        while True:
            if isinstance(pattern, bytes):
                at = self.buf.find(pattern, start)
                if at >= 0:
                    return at + len(pattern)
            else:
                match = pattern.search(self.buf, start)
                if match:
                    return match.end()
            if time.time() >= deadline or not self.fill(0.1):
                return None

    def wait_prompt(self, start=0, timeout=TIMEOUT):
        return self.read_until(PROMPT_END, start, timeout)

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def run(self, line, timeout=TIMEOUT):
        """Runs one command line and returns (status, output) using the
        OSC 133 marks, or (None, raw text) if the command never finished."""
        start = len(self.buf)
        self.send(line + "\r")
        begin = self.read_until(OUTPUT_START, start, timeout)
        if begin is None:
            return None, strip_ansi(self.buf[start:])
        match = None
        deadline = time.time() + timeout
        while match is None and time.time() < deadline:
            match = COMMAND_END.search(self.buf, begin)
            if match is None and not self.fill(0.1):
                break
        if match is None:
            return None, strip_ansi(self.buf[start:])
        self.wait_prompt(match.end(), timeout)
        output = self.buf[begin:match.start()].replace(b"\r\n", b"\n")
        return int(match.group(1)), strip_ansi(output)

    def last_prompt(self):
        """The most recent prompt, from its start mark to its end mark."""
        start = self.buf.rfind(b"\x1b]133;A")
        end = self.buf.find(PROMPT_END, start)
        return self.buf[start:end + len(PROMPT_END)]

    def wait_exit(self, timeout=TIMEOUT):
        deadline = time.time() + timeout
        while time.time() < deadline:
            pid, status = os.waitpid(self.pid, os.WNOHANG)
            if pid:
                self.status = os.waitstatus_to_exitcode(status)
                return self.status
            self.fill(0.05)
        return None

    def close(self):
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
                os.waitpid(self.pid, 0)
            except (ProcessLookupError, ChildProcessError):
                pass
        os.close(self.fd)


def process_gone(pid, timeout=4.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            with open(f"/proc/{pid}/stat") as f:
                if f.read().split(") ")[-1].startswith("Z"):
                    return True
        except FileNotFoundError:
            return True
        time.sleep(0.05)
    return False


class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="wsh-session-")
        self.home = pathlib.Path(self.temp.name)
        self.history_file = self.home / "data" / "wsh" / "history"
        self.sessions = []

    def tearDown(self):
        for session in self.sessions:
            session.close()
        self.temp.cleanup()

    def start(self, **kwargs):
        session = Session(self.home, **kwargs)
        self.sessions.append(session)
        self.assertIsNotNone(session.wait_prompt(), "the shell never drew a prompt: %r" % session.buf[-300:])
        return session

    def interrupt(self, session, line):
        """Starts `line`, presses Ctrl-C and returns what it printed."""
        start = len(session.buf)
        session.send(line + "\r")
        begin = session.read_until(OUTPUT_START, start)
        self.assertIsNotNone(begin)
        time.sleep(0.5)
        session.send(b"\x03")
        match_end = session.read_until(COMMAND_END, begin, timeout=4)
        self.assertIsNotNone(match_end, "Ctrl-C did not end %r: %r" % (line, strip_ansi(session.buf[start:])[-300:]))
        self.assertIn(b"\x1b]133;D;130", session.buf[begin:])
        self.assertIsNotNone(session.wait_prompt(match_end))
        return strip_ansi(session.buf[begin:match_end])

    # --- Ctrl-C ----------------------------------------------------------------

    def test_ctrl_c_stops_a_while_loop_of_external_commands(self):
        s = self.start()
        self.interrupt(s, "while true { sleep 1 }")
        self.assertEqual(s.run("echo st=$?"), (0, b"st=130\n"))

    def test_ctrl_c_stops_a_for_loop_instead_of_the_current_command(self):
        s = self.start()
        output = self.interrupt(s, "for i in 1 2 3 { sleep 2; echo iter-$i }")
        self.assertNotIn(b"iter-", output)
        time.sleep(2.5)
        status, output = s.run("echo after")
        self.assertEqual((status, output), (0, b"after\n"))
        self.assertNotRegex(strip_ansi(s.buf), rb"iter-\d")

    def test_ctrl_c_stops_a_builtin_only_loop(self):
        s = self.start()
        s.run("let n = 0")
        self.interrupt(s, "while true { let n = n + 1 }")
        status, output = s.run("echo st=$? $n")
        self.assertEqual(status, 0)
        self.assertRegex(output, rb"^st=130 [1-9][0-9]*\n$")

    def test_ctrl_c_skips_the_rest_of_an_and_or_list(self):
        s = self.start()
        output = self.interrupt(s, "sleep 5 || echo fallback-ran")
        self.assertNotIn(b"fallback-ran", output)

    # --- signals ---------------------------------------------------------------

    def test_sighup_saves_history_hangs_up_jobs_and_exits_129(self):
        s = self.start()
        s.run("sleep 300 &")
        status, output = s.run("echo BG=$!")
        self.assertEqual(status, 0)
        bg = int(re.search(rb"BG=(\d+)", output).group(1))
        s.run("echo before-hangup")
        os.kill(s.pid, signal.SIGHUP)
        self.assertEqual(s.wait_exit(), 129)
        self.assertTrue(process_gone(bg), "background job survived SIGHUP")
        self.assertIn("echo before-hangup", self.history_file.read_text())

    def test_sighup_with_a_partly_typed_line(self):
        s = self.start()
        s.send("echo never-run")
        time.sleep(0.3)
        os.kill(s.pid, signal.SIGHUP)
        self.assertEqual(s.wait_exit(), 129)

    def test_sigterm_is_ignored(self):
        s = self.start()
        os.kill(s.pid, signal.SIGTERM)
        time.sleep(0.3)
        self.assertEqual(s.run("echo alive"), (0, b"alive\n"))

    # --- history ---------------------------------------------------------------

    def test_multi_line_entries_round_trip_across_restarts(self):
        s = self.start()
        self.assertEqual(s.run("if true {\recho ml-one\r}"), (0, b"ml-one\n"))
        s.run("printf 'a\\\\nb\\n'")
        s.send("exit\r")
        self.assertEqual(s.wait_exit(), 0)

        raw = self.history_file.read_text()
        self.assertTrue(raw.startswith("#wsh-history v2\n"), raw)
        self.assertIn("if true {\\necho ml-one\\n}\n", raw)

        s2 = self.start()
        status, output = s2.run("history")
        self.assertEqual(status, 0)
        self.assertRegex(output, rb"\d+  if true \{\necho ml-one\n\}\n")
        self.assertIn(b"printf 'a\\\\nb\\n'\n", output)

    def test_plain_history_files_still_load(self):
        self.history_file.parent.mkdir(parents=True)
        self.history_file.write_text("echo old-one\nprintf 'x\\ny'\n")
        s = self.start()
        status, output = s.run("history")
        self.assertIn(b"echo old-one\n", output)
        self.assertIn(b"printf 'x\\ny'\n", output)

    def test_concurrent_sessions_keep_each_others_entries(self):
        a = self.start()
        b = self.start()
        a.run("echo from-a-1")
        b.run("echo from-b-1")
        a.run("echo from-a-2")
        a.send("exit\r")
        self.assertEqual(a.wait_exit(), 0)
        b.send("exit\r")
        self.assertEqual(b.wait_exit(), 0)

        c = self.start()
        _, output = c.run("history")
        for entry in (b"echo from-a-1", b"echo from-b-1", b"echo from-a-2"):
            self.assertIn(entry, output)

    def test_histcontrol_ignorespace_and_ignoredups(self):
        s = self.start()
        s.run("HISTCONTROL=ignoreboth")
        s.run(" echo secret-entry")
        s.run("echo twice")
        s.run("echo twice")
        raw = self.history_file.read_text()
        self.assertNotIn("secret-entry", raw)
        self.assertEqual(raw.count("echo twice"), 1)

    def test_history_builtin_options(self):
        s = self.start()
        for n in range(1, 5):
            s.run(f"echo entry-{n}")
        _, output = s.run("history 2")
        self.assertEqual(output.count(b"\n"), 2)
        self.assertIn(b"history 2", output)

        s.run("history -d 1")
        self.assertNotIn("echo entry-1", self.history_file.read_text())
        _, output = s.run("history -d 99")
        self.assertIn(b"out of range", output)

        backup = self.home / "backup"
        s.run(f"history -w {backup}")
        self.assertIn("echo entry-4", backup.read_text())

        s.run("history -c")
        _, output = s.run("history")
        self.assertNotIn(b"entry-4", output)
        s.run(f"history -r {backup}")
        _, output = s.run("history")
        self.assertIn(b"echo entry-4", output)

        status, output = s.run("history -z")
        self.assertEqual(status, 2)
        self.assertIn(b"invalid option", output)

    # --- hooks -----------------------------------------------------------------

    def test_hooks_run_and_leave_the_status_alone(self):
        s = self.start()
        s.run("fn precmd() { echo PRECMD-RAN; false }")
        s.run('fn preexec(line) { echo "PREEXEC[$1]" }')
        s.run('fn chpwd() { echo "CHPWD $PWD" }')
        s.run('PROMPT_COMMAND="echo PC-RAN"')
        start = len(s.buf)
        status, output = s.run("false")
        self.assertEqual(status, 1)
        self.assertIn(b"PREEXEC[false]", output)
        tail = strip_ansi(s.buf[start:])
        self.assertIn(b"PRECMD-RAN", tail)
        self.assertIn(b"PC-RAN", tail)
        self.assertEqual(s.run("echo st=$?")[1].splitlines()[-1], b"st=1")

        target = self.home / "dir with space"
        target.mkdir()
        status, output = s.run(f"cd '{target}' && echo after-cd")
        self.assertEqual(status, 0)
        lines = output.splitlines()
        self.assertLess(lines.index(b"CHPWD " + str(target).encode()), lines.index(b"after-cd"))
        self.assertIn(b"\x1b]7;file://", s.buf[start:])
        self.assertIn(b"/dir%20with%20space\x1b\\", s.buf[start:])

    def test_a_failing_hook_is_reported_once(self):
        s = self.start()
        s.run("fn precmd() { return 3 }")
        for _ in range(3):
            s.run("true")
        self.assertEqual(strip_ansi(s.buf).count(b"precmd hook failed with status 3"), 1)

    # --- terminal integration --------------------------------------------------

    def test_osc_marks_and_title(self):
        s = self.start()
        start = len(s.buf)
        s.run("false")
        raw = s.buf[start:]
        self.assertIn(b"\x1b]2;false\x07", raw)
        self.assertIn(b"\x1b]133;C\x1b\\", raw)
        self.assertIn(b"\x1b]133;D;1\x1b\\", raw)
        self.assertIn(b"\x1b]133;A\x1b\\", raw)
        self.assertIn(b"\x1b]7;file://", raw)

    def test_terminal_integration_switch_and_dumb_terminals(self):
        marker = "❯".encode()
        s = self.start()
        start = len(s.buf)
        s.send("let terminal_integration = false\r")
        start = s.read_until(COMMAND_END, start)
        self.assertIsNotNone(start)
        self.assertIsNotNone(s.read_until(marker, start))
        s.send("echo plain-mode\r")
        self.assertIsNotNone(s.read_until(marker, s.read_until(b"plain-mode\r\n", start) or start))
        self.assertNotIn(b"\x1b]", s.buf[start:])

        dumb = Session(self.home, extra_env={"TERM": "dumb"})
        self.sessions.append(dumb)
        self.assertIsNotNone(dumb.read_until("❯".encode()))
        self.assertNotIn(b"\x1b]", dumb.buf)

    # --- prompt ----------------------------------------------------------------

    def test_ps1_renders_bash_escapes(self):
        workdir = self.home / "proj$(boom)"
        workdir.mkdir()
        s = self.start(extra_env={"USER": "tester"}, cwd=workdir)
        start = len(s.buf)
        s.run(r"PS1='[\u \W]\$ '")
        self.assertIsNotNone(s.read_until(b"[tester proj$(boom)]$ ", start))

        s.run(r"PS1='\[\e[1m\]bold>\[\e[0m\] '")
        self.assertIn(b"\x1b[1mbold>\x1b[0m " + PROMPT_END, s.last_prompt())

    def test_ps1_and_ps2_from_the_environment(self):
        s = self.start(extra_env={"PS1": r"env-ps1 \$ ", "PS2": "cont> "})
        self.assertIn(b"env-ps1 $ ", s.buf)
        start = len(s.buf)
        s.send("if true {\r")
        self.assertIsNotNone(s.read_until(b"cont> ", start))
        s.send("}\r")
        self.assertIsNotNone(s.read_until(COMMAND_END, start))

    def test_multi_line_ps1_keeps_its_first_line(self):
        s = self.start()
        s.run(r"PS1='top-line\nbottom> '")
        self.assertRegex(strip_ansi(s.last_prompt()), rb"top-line\r?\n.*bottom> ")
        self.assertEqual(s.run("echo still-works"), (0, b"still-works\n"))

    def test_no_color_drops_prompt_colours(self):
        s = self.start(extra_env={"NO_COLOR": "1"})
        self.assertIn("\u276f".encode(), s.last_prompt())
        self.assertNotRegex(s.last_prompt(), rb"\x1b\[3\dm")


if __name__ == "__main__":
    if not SHELL.exists():
        print(f"error: {SHELL} does not exist - run `zig build -Doptimize=ReleaseFast` first")
        sys.exit(2)
    unittest.main(verbosity=2)
