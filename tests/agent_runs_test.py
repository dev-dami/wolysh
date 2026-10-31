#!/usr/bin/env python3
"""End-to-end checks for background runs (`wsh run`), persistent sessions
(`wsh session`) and the per-user daemon. Each test uses its own
`XDG_RUNTIME_DIR`, so tests share no state, and stops its daemon and runs."""
import fcntl
import json
import os
import pathlib
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = pathlib.Path(os.environ.get("WSH", ROOT / "zig-out" / "bin" / "wsh"))


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A zombie is gone for every purpose here.
    try:
        with open(f"/proc/{pid}/stat") as stat:
            return stat.read().rsplit(")", 1)[1].split()[0] != "Z"
    except OSError:
        return False


def session_members(sid):
    """Live processes in session `sid`: a run or a session host and
    everything it started, background jobs included."""
    members = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit():
            continue
        try:
            with open(f"/proc/{entry}/stat") as stat:
                fields = stat.read().rsplit(")", 1)[1].split()
        except OSError:
            continue
        if fields[0] != "Z" and int(fields[3]) == sid:
            members.append(int(entry))
    return members


def kill_session(sid):
    for pid in session_members(sid):
        try:
            os.kill(pid, signal.SIGKILL)
        except OSError:
            pass


def wait_until(predicate, timeout=5.0, interval=0.02):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if predicate():
            return True
        time.sleep(interval)
    return predicate()


class AgentTestCase(unittest.TestCase):
    def setUp(self):
        self.runtime = tempfile.mkdtemp(prefix="wsh-agent-")
        self.state = pathlib.Path(self.runtime) / "wsh"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith("WSH_")}
        self.env["XDG_RUNTIME_DIR"] = self.runtime

    def tearDown(self):
        self.stop_daemon()
        runs = self.state / "runs"
        if runs.is_dir():
            for meta_path in runs.glob("*/meta.json"):
                try:
                    meta = json.loads(meta_path.read_text())
                except (OSError, ValueError):
                    continue
                if meta.get("sid"):
                    kill_session(meta["sid"])
                if meta.get("supervisor"):
                    try:
                        os.kill(meta["supervisor"], signal.SIGKILL)
                    except OSError:
                        pass
        shutil.rmtree(self.runtime, ignore_errors=True)

    def daemon_pid(self):
        try:
            return int((self.state / "daemon.pid").read_text())
        except (OSError, ValueError):
            return None

    def stop_daemon(self):
        hosts = []
        for meta_path in (self.state / "sessions").glob("*/meta.json"):
            try:
                hosts.append(json.loads(meta_path.read_text())["pid"])
            except (OSError, ValueError, KeyError):
                pass
        pid = self.daemon_pid()
        if pid and pid_alive(pid):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            wait_until(lambda: not pid_alive(pid), timeout=3)
        # A host leads its own session; kill it and anything it started.
        for host in hosts:
            kill_session(host)

    def wsh(self, *args, input=None, env=None, timeout=20, cwd=None):
        return subprocess.run(
            [str(SHELL), *args],
            input=input,
            env=env or self.env,
            cwd=cwd or self.runtime,
            capture_output=True,
            timeout=timeout,
            check=False,
        )

    def ok(self, *args, **kwargs):
        result = self.wsh(*args, **kwargs)
        self.assertEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        return result

    def status(self, name):
        result = self.ok("run", "status", name, "--json")
        return json.loads(result.stdout)

    def meta(self, name):
        return json.loads((self.state / "runs" / name / "meta.json").read_text())


class RunTests(AgentTestCase):
    def test_start_status_wait_logs(self):
        started = self.ok("run", "-d", "--name", "test", "--", "echo out; echo err >&2; sleep 0.2; exit 3")
        self.assertEqual(started.stdout, b"test\n")
        self.assertEqual(self.status("test")["state"], "running")
        waited = self.wsh("run", "wait", "test")
        self.assertEqual(waited.returncode, 3, waited.stderr)
        self.assertEqual(self.ok("run", "logs", "test").stdout, b"out\nerr\n")

        info = self.status("test")
        self.assertEqual(info["state"], "exited")
        self.assertEqual(info["status"], 3)
        self.assertIsNone(info["signal"])
        self.assertEqual(info["bytes"], 8)
        self.assertEqual(info["command"], "echo out; echo err >&2; sleep 0.2; exit 3")
        self.assertEqual(info["cwd"], self.runtime)
        self.assertGreaterEqual(info["elapsed_ms"], 200)

        listing = self.ok("run", "status").stdout.decode()
        self.assertIn("NAME", listing.splitlines()[0])
        self.assertRegex(listing, r"\ntest +exited +3 ")
        lines = self.ok("run", "status", "--json").stdout.splitlines()
        self.assertEqual([json.loads(line)["name"] for line in lines], ["test"])

        # The state directory and its files are private to the user.
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)
        meta = self.meta("test")
        for key in ("name", "command", "cwd", "pid", "pgid", "started_ms", "ended_ms", "status", "signal", "session"):
            self.assertIn(key, meta)
        self.assertIsNone(meta["session"])
        self.assertEqual((self.state / "runs" / "test" / "output.log").stat().st_mode & 0o777, 0o600)

    def test_returns_at_once_and_outlives_the_caller(self):
        begin = time.monotonic()
        self.ok("run", "-d", "--name", "slow", "--", "sleep 0.5; echo finished")
        self.assertLess(time.monotonic() - begin, 0.4)
        self.assertEqual(self.wsh("run", "wait", "slow").returncode, 0)
        self.assertEqual(self.ok("run", "logs", "slow").stdout, b"finished\n")

    def test_auto_names_and_collisions(self):
        self.assertEqual(self.ok("run", "-d", "true").stdout, b"run-1\n")
        self.assertEqual(self.ok("run", "-d", "true").stdout, b"run-2\n")
        self.ok("run", "-d", "--name", "dup", "true")
        clash = self.wsh("run", "-d", "--name", "dup", "true")
        self.assertEqual(clash.returncode, 1)
        self.assertIn(b"wsh: run: dup: already exists", clash.stderr)
        bad = self.wsh("run", "-d", "--name", "../x", "true")
        self.assertEqual(bad.returncode, 2)
        self.assertIn(b"invalid run name", bad.stderr)
        missing = self.wsh("run", "status", "nope")
        self.assertEqual(missing.returncode, 1)
        self.assertIn(b"wsh: run: nope: no such run", missing.stderr)

    def test_stdout_and_stderr_keep_their_order(self):
        script = "for i in 1 2 3 4 5; do echo out$i; echo err$i >&2; done; printf tail"
        self.ok("run", "-d", "--name", "mixed", "--", script)
        self.assertEqual(self.wsh("run", "wait", "mixed").returncode, 0)
        expected = b"".join(b"out%d\nerr%d\n" % (i, i) for i in range(1, 6)) + b"tail"
        self.assertEqual(self.ok("run", "logs", "mixed").stdout, expected)

    def test_wait_match_and_timeout(self):
        self.ok("run", "-d", "--name", "server", "--", "echo booting; sleep 0.3; echo 'READY on 8080'; sleep 30")
        matched = self.wsh("run", "wait", "server", "--match", "READY", "--timeout", "10s")
        self.assertEqual(matched.returncode, 0, matched.stderr)
        self.assertEqual(matched.stdout, b"READY on 8080\n")
        by_regex = self.wsh("run", "wait", "server", "--match", "^READY on [0-9]+$", "--regex")
        self.assertEqual(by_regex.returncode, 0, by_regex.stderr)

        begin = time.monotonic()
        timed_out = self.wsh("run", "wait", "server", "--timeout", "300ms")
        self.assertEqual(timed_out.returncode, 124)
        self.assertIn(b"timed out", timed_out.stderr)
        self.assertGreaterEqual(time.monotonic() - begin, 0.3)
        self.assertLess(time.monotonic() - begin, 5)
        missing = self.wsh("run", "wait", "server", "--match", "never", "--timeout", "0.2")
        self.assertEqual(missing.returncode, 124)

        self.ok("run", "kill", "server")
        self.assertEqual(self.wsh("run", "wait", "server").returncode, 143)
        info = self.status("server")
        self.assertEqual((info["state"], info["status"], info["signal"]), ("killed", 143, "TERM"))

        # A run that ends without the line is not a match.
        self.ok("run", "-d", "--name", "quiet", "--", "echo nothing")
        unmatched = self.wsh("run", "wait", "quiet", "--match", "READY")
        self.assertEqual(unmatched.returncode, 1)
        self.assertIn(b"before a line matched", unmatched.stderr)

    def test_kill_reaches_background_jobs_and_rm(self):
        self.ok("run", "-d", "--name", "group", "--", "sleep 30 & sleep 30 & wait")
        sid = self.meta("group")["sid"]
        # Supervisor, shell and both sleeps.
        self.assertTrue(wait_until(lambda: len(session_members(sid)) >= 4), session_members(sid))
        busy = self.wsh("run", "rm", "group")
        self.assertEqual(busy.returncode, 1)
        self.assertIn(b"still running", busy.stderr)

        self.ok("run", "kill", "group", "--signal", "KILL")
        self.assertEqual(self.wsh("run", "wait", "group").returncode, 137)
        self.assertTrue(wait_until(lambda: session_members(sid) == []), session_members(sid))
        self.assertEqual(self.status("group")["signal"], "KILL")
        again = self.wsh("run", "kill", "group")
        self.assertEqual(again.returncode, 1)
        self.assertIn(b"not running", again.stderr)

        self.ok("run", "rm", "group")
        self.assertFalse((self.state / "runs" / "group").exists())
        self.assertEqual(self.wsh("run", "status", "group").returncode, 1)

    def test_logs_answer_questions_within_a_budget(self):
        script = (
            "echo 'running 300 tests'; "
            "for i in $(seq 1 300); do echo \"test mod_$i::case ... ok\"; done; "
            "echo 'test net::refused ... FAILED'; echo; echo 'failures:'; echo '    net::refused'; echo; "
            "echo 'test result: FAILED. 300 passed; 1 failed; 0 ignored; 0 measured; 0 filtered out'; exit 101"
        )
        self.ok("run", "-d", "--name", "ct", "--", script)
        self.assertEqual(self.wsh("run", "wait", "ct").returncode, 101)

        failed = self.wsh("run", "logs", "ct", "--failures")
        self.assertEqual(failed.returncode, 1)
        self.assertIn(b"FAILED net::refused [cargo]", failed.stdout)
        self.assertIn(b"300 passed, 1 failed", failed.stdout)
        records = [json.loads(line) for line in self.wsh("run", "logs", "ct", "--failures", "--json").stdout.splitlines()]
        self.assertEqual([r["name"] for r in records if r["type"] == "failure"], ["net::refused"])

        summary = self.ok("run", "logs", "ct", "--budget", "400")
        self.assertLessEqual(len(summary.stdout), 400)
        self.assertIn(b"test net::refused ... FAILED", summary.stdout)
        self.assertIn(b"elided", summary.stdout)

        found = self.ok("run", "logs", "ct", "--find", "net refused", "--limit", "1")
        self.assertIn(b"net::refused", found.stdout.splitlines()[0])
        grep = self.ok("run", "logs", "ct", "--grep", "FAILED", "--budget", "80")
        self.assertLessEqual(len(grep.stdout), 80)
        self.assertIn(b"lines: 307", self.ok("run", "logs", "ct", "--stats").stdout)

        # The builtin form works too, and a byte range cannot be combined with a question.
        self.assertIn(b"net::refused", self.ok("-c", "run logs ct --failures --json || true").stdout)
        self.assertEqual(self.wsh("run", "logs", "ct", "--tail", "2", "--failures").returncode, 2)
        self.assertEqual(self.wsh("run", "logs", "ct", "--find", "a", "--grep", "b").returncode, 2)

    def test_logs_since_offsets_head_and_tail(self):
        self.ok("run", "-d", "--name", "poll", "--", "echo one; sleep 0.4; echo two; echo three")
        self.assertEqual(self.wsh("run", "wait", "poll", "--match", "one").returncode, 0)
        first = self.ok("run", "logs", "poll", "--since", "0")
        self.assertEqual(first.stdout, b"one\n")
        self.assertEqual(first.stderr, b"next_offset=4\n")
        self.assertEqual(self.wsh("run", "wait", "poll").returncode, 0)
        second = self.ok("run", "logs", "poll", "--since", "4")
        self.assertEqual(second.stdout, b"two\nthree\n")
        self.assertEqual(second.stderr, b"next_offset=14\n")
        final = json.loads(self.ok("run", "logs", "poll", "--since", "14", "--json").stdout)
        self.assertEqual((final["data"], final["offset"], final["next_offset"], final["state"]), ("", 14, 14, "exited"))
        middle = json.loads(self.ok("run", "logs", "poll", "--since", "4", "--json").stdout)
        self.assertEqual((middle["data"], middle["next_offset"]), ("two\nthree\n", 14))

        self.assertEqual(self.ok("run", "logs", "poll", "--head", "1").stdout, b"one\n")
        self.assertEqual(self.ok("run", "logs", "poll", "--tail", "2").stdout, b"two\nthree\n")
        self.assertEqual(self.ok("run", "logs", "poll", "--tail", "9").stdout, b"one\ntwo\nthree\n")
        self.assertEqual(self.wsh("run", "logs", "poll", "--tail", "1", "--head", "1").returncode, 2)

    def test_tty_runs_on_a_terminal(self):
        self.ok("run", "-d", "--tty", "--name", "term", "--", "test -t 0 && test -t 1 && echo terminal")
        self.assertEqual(self.wsh("run", "wait", "term").returncode, 0)
        self.assertEqual(self.ok("run", "logs", "term").stdout, b"terminal\n")
        self.assertTrue(self.status("term")["tty"])

    def test_builtin_inherits_functions_and_variables(self):
        script = "fn greet(who) { echo \"hello $who from $WSH_RUN\"; }; let n = 3; run -d --name b -- greet world; run wait b; run logs b; echo $n"
        result = self.ok("-c", script)
        self.assertEqual(result.stdout, b"b\nhello world from b\n3\n")

    def test_finished_runs_expire(self):
        self.ok("run", "-d", "--name", "old", "true")
        self.assertEqual(self.wsh("run", "wait", "old").returncode, 0)
        self.ok("run", "-d", "--name", "live", "sleep 30")
        env = dict(self.env, WSH_RUN_TTL="0")
        listing = self.ok("run", "status", env=env).stdout.decode()
        self.assertNotIn("old", listing)
        self.assertIn("live", listing)
        self.assertFalse((self.state / "runs" / "old").exists())

    def test_daemon_restart_keeps_runs(self):
        self.ok("session", "new", "w")
        daemon = self.daemon_pid()
        self.assertTrue(daemon and pid_alive(daemon))
        self.ok("run", "-d", "--name", "done", "exit 4")
        self.assertEqual(self.wsh("run", "wait", "done").returncode, 4)
        self.ok("run", "-d", "--name", "slow", "--", "sleep 0.5; exit 5")

        os.kill(daemon, signal.SIGKILL)
        self.assertTrue(wait_until(lambda: not pid_alive(daemon)))
        info = self.status("done")
        self.assertEqual((info["state"], info["status"]), ("exited", 4))
        # The run's own supervisor records its status without the daemon.
        self.assertEqual(self.wsh("run", "wait", "slow").returncode, 5)
        self.assertEqual(self.status("slow")["status"], 5)

        # Sessions lived in the daemon, as in a tmux server; a new daemon
        # starts on demand and knows none of them.
        self.assertEqual(self.wsh("session", "exec", "w", "--", "true").returncode, 1)
        self.ok("session", "new", "w2")
        self.assertNotEqual(self.daemon_pid(), daemon)
        names = [json.loads(line)["name"] for line in self.ok("session", "ls", "--json").stdout.splitlines()]
        self.assertEqual(names, ["w2"])

    def test_lost_run_is_marked(self):
        self.ok("run", "-d", "--name", "orphan", "sleep 30")
        meta = self.meta("orphan")
        os.kill(meta["supervisor"], signal.SIGKILL)
        self.assertTrue(wait_until(lambda: self.status("orphan")["state"] == "lost"))
        lost = self.wsh("run", "wait", "orphan")
        self.assertEqual(lost.returncode, 125)
        self.assertIn(b"lost", lost.stderr)
        os.killpg(meta["pgid"], signal.SIGKILL)
        # A starting daemon rescans the runs and records the loss on disk.
        self.ok("session", "new", "s")
        self.assertTrue(wait_until(lambda: self.meta("orphan")["state"] == "lost"))
        self.assertIsNotNone(self.meta("orphan")["ended_ms"])


class SessionTests(AgentTestCase):
    def test_state_persists_between_calls(self):
        self.ok("session", "new", "w")
        self.ok("session", "exec", "w", "--", "cd /tmp; x=1; fn twice(v) { echo $v$v; }")
        result = self.ok("session", "exec", "w", "--", "pwd; echo $x; twice ab; echo $WSH_SESSION")
        self.assertEqual(result.stdout, b"/tmp\n1\nabab\nw\n")
        status = self.wsh("session", "exec", "w", "--", "echo to-err >&2; false")
        self.assertEqual((status.returncode, status.stdout, status.stderr), (1, b"", b"to-err\n"))
        piped = self.ok("session", "exec", "w", "cat", input=b"from stdin\n")
        self.assertEqual(piped.stdout, b"from stdin\n")
        jobs = self.ok("session", "exec", "w", "--", "sleep 30 > /dev/null 2>&1 & echo started")
        self.assertEqual(jobs.stdout, b"started\n")
        self.assertIn(b"sleep 30", self.ok("session", "exec", "w", "jobs").stdout)

        dup = self.wsh("session", "new", "w")
        self.assertEqual(dup.returncode, 1)
        self.assertIn(b"wsh: session: w: already exists", dup.stderr)
        listing = self.ok("session", "ls").stdout.decode()
        self.assertRegex(listing, r"\nw +\d+ +idle ")

    def test_exit_ends_the_session(self):
        self.ok("session", "new", "e")
        self.assertEqual(self.wsh("session", "exec", "e", "--", "exit 7").returncode, 7)
        self.assertTrue(wait_until(lambda: self.ok("session", "ls").stdout == b""))

    def test_kill_and_unknown_sessions(self):
        self.ok("session", "new", "k")
        self.ok("session", "exec", "k", "--", "sleep 30 > /dev/null 2>&1 &")
        pid = json.loads(self.ok("session", "ls", "--json").stdout)["pid"]
        self.ok("session", "kill", "k")
        self.assertTrue(wait_until(lambda: session_members(pid) == []), session_members(pid))
        self.assertEqual(self.ok("session", "ls").stdout, b"")
        gone = self.wsh("session", "exec", "k", "--", "true")
        self.assertEqual(gone.returncode, 1)
        self.assertIn(b"wsh: session: k: no such session", gone.stderr)
        self.assertEqual(self.wsh("session", "kill", "k").returncode, 1)
        self.assertFalse((self.state / "sessions" / "k").exists())

    def test_without_a_daemon(self):
        self.assertEqual(self.ok("session", "ls").stdout, b"")
        missing = self.wsh("session", "exec", "none", "--", "true")
        self.assertEqual(missing.returncode, 1)
        self.assertIn(b"no such session", missing.stderr)
        self.assertIsNone(self.daemon_pid())

    def test_interrupt_is_forwarded(self):
        self.ok("session", "new", "i")
        client = subprocess.Popen([str(SHELL), "session", "exec", "i", "--", "sleep 30; echo after"],
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.3)
        client.send_signal(signal.SIGINT)
        out, _ = client.communicate(timeout=10)
        self.assertEqual(client.returncode, 130)
        self.assertEqual(out, b"")
        # The session itself survives the interrupt.
        self.assertEqual(self.ok("session", "exec", "i", "echo alive").stdout, b"alive\n")

    def test_idle_session_and_daemon_expire(self):
        env = dict(self.env, WSH_SESSION_TTL="1", WSH_DAEMON_IDLE="1")
        self.ok("session", "new", "idle", env=env)
        daemon = self.daemon_pid()
        self.assertTrue(wait_until(lambda: self.ok("session", "ls").stdout == b"", timeout=8))
        self.assertTrue(wait_until(lambda: not pid_alive(daemon), timeout=8))
        self.assertFalse((self.state / "daemon.sock").exists())

    def attach_client(self, name, rows=24, cols=80):
        pid, fd = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
            os.execve(str(SHELL), [str(SHELL), "session", "attach", name], self.env)
        return pid, fd

    def read_until(self, fd, needle, timeout=10):
        data = b""
        deadline = time.time() + timeout
        while needle not in data and time.time() < deadline:
            ready, _, _ = select.select([fd], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                data += chunk
        return data

    def detach_client(self, pid, fd):
        os.write(fd, b"\x1cd")
        self.assertIn(b"detached from session", self.read_until(fd, b"detached"))
        _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0)
        os.close(fd)

    def session_info(self, name):
        for line in self.ok("session", "ls", "--json").stdout.splitlines():
            info = json.loads(line)
            if info["name"] == name:
                return info
        return None

    def test_attach_and_detach(self):
        self.ok("session", "new", "a")
        pid, fd = self.attach_client("a")
        self.assertIn(b"[a]", self.read_until(fd, b"[a]"))
        os.write(fd, b"cd /tmp; y=5; echo value=$y\r")
        self.assertIn(b"value=5", self.read_until(fd, b"value=5"))
        self.detach_client(pid, fd)
        # A directory change at the prompt reaches `session ls` too.
        self.assertTrue(wait_until(lambda: self.session_info("a")["cwd"] == "/tmp"))

        self.assertEqual(self.ok("session", "exec", "a", "pwd; echo $y").stdout, b"/tmp\n5\n")

        # A second attach reaches the same terminal; `exit` there ends the session.
        pid, fd = self.attach_client("a")
        self.assertIn(b"[a]", self.read_until(fd, b"[a]"))
        os.write(fd, b"exit\r")
        self.read_until(fd, b"left session")
        os.waitpid(pid, 0)
        os.close(fd)
        self.assertTrue(wait_until(lambda: self.ok("session", "ls").stdout == b""))

        no_tty = self.wsh("session", "attach", "a")
        self.assertEqual(no_tty.returncode, 1)

    def test_attach_forwards_resizes(self):
        self.ok("session", "new", "r")
        pid, fd = self.attach_client("r", rows=24, cols=80)
        self.read_until(fd, b"[r]")
        os.write(fd, b"stty size\r")
        self.assertIn(b"24 80", self.read_until(fd, b"24 80"))
        # Resizing the client's terminal sends it SIGWINCH; the size must
        # reach the session's terminal and its foreground program.
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 40, 132, 0, 0))
        time.sleep(0.3)
        os.write(fd, b"stty size\r")
        self.assertIn(b"40 132", self.read_until(fd, b"40 132"))
        self.detach_client(pid, fd)

    def test_detach_keeps_the_foreground_command(self):
        self.ok("session", "new", "f")
        pid, fd = self.attach_client("f")
        self.read_until(fd, b"[f]")
        os.write(fd, b"for i in 1 2 3 4 5; do echo tick $i; sleep 0.3; done; echo DONE\r")
        self.detach_client(pid, fd)
        time.sleep(2.2)

        # The loop was not hung up: its output, written while nobody was
        # attached, comes back on the next attach.
        pid, fd = self.attach_client("f")
        replay = self.read_until(fd, b"\nDONE")
        self.assertIn(b"\nDONE", replay)
        for i in range(1, 6):
            self.assertIn(b"tick %d" % i, replay)
        os.write(fd, b"echo $((40+2))\r")
        self.assertIn(b"42", self.read_until(fd, b"\n42"))
        self.detach_client(pid, fd)
        # The session still answers requests between attaches.
        self.assertEqual(self.ok("session", "exec", "f", "echo ok").stdout, b"ok\n")

    def test_daemon_does_not_wait_for_a_busy_session(self):
        self.ok("session", "new", "A")
        self.ok("session", "new", "B")
        busy = subprocess.Popen([str(SHELL), "session", "exec", "A", "--", "sleep 4; echo slept"],
                                env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        script = pathlib.Path(self.runtime) / "big.wsh"
        script.write_text(("# " + "x" * 1000 + "\n") * 1000 + "echo big-ok\n")
        time.sleep(0.3)
        # About 1 MB: far more than a socket buffer, for a host that is busy.
        big = subprocess.Popen([str(SHELL), "-c", f's=$(cat {script}); session exec A -- "$s"'],
                               env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        time.sleep(0.8)
        begin = time.monotonic()
        self.assertIn(b"A", self.ok("session", "ls").stdout)
        self.assertEqual(self.ok("session", "exec", "B", "echo from-b").stdout, b"from-b\n")
        self.assertLess(time.monotonic() - begin, 1.0)
        self.assertIsNone(busy.poll())
        self.assertIsNone(big.poll())
        out, err = big.communicate(timeout=30)
        self.assertEqual((big.returncode, out), (0, b"big-ok\n"), err)
        self.assertEqual(busy.communicate(timeout=10)[0], b"slept\n")

    def test_ls_shows_the_current_directory(self):
        self.ok("session", "new", "w")
        self.assertEqual(self.session_info("w")["cwd"], self.runtime)
        self.ok("session", "exec", "w", "--", "cd /tmp")
        self.assertEqual(self.session_info("w")["cwd"], "/tmp")
        self.assertRegex(self.ok("session", "ls").stdout.decode(), r"\nw +\d+ +idle +\S+ +/tmp\n")
        meta = json.loads((self.state / "sessions" / "w" / "meta.json").read_text())
        self.assertEqual(meta["cwd"], "/tmp")


@unittest.skipUnless(os.geteuid() == 0, "needs root to act as another user")
class OtherUserTests(AgentTestCase):
    def test_other_users_are_refused(self):
        self.ok("session", "new", "mine")
        # Loosen the permissions so only the peer check stands in the way.
        os.chmod(self.runtime, 0o755)
        os.chmod(self.state, 0o755)
        os.chmod(self.state / "daemon.sock", 0o666)
        client = (
            "import socket, struct, json, sys\n"
            "s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)\n"
            "s.connect(sys.argv[1])\n"
            "body = json.dumps({'op': 'ls'}).encode()\n"
            "s.sendall(struct.pack('<I', len(body)) + body)\n"
            "head = s.recv(4)\n"
            "n = struct.unpack('<I', head)[0]\n"
            "data = b''\n"
            "while len(data) < n:\n"
            "    chunk = s.recv(n - len(data))\n"
            "    if not chunk: break\n"
            "    data += chunk\n"
            "print(data.decode())\n"
        )
        result = subprocess.run(["python3", "-I", "-c", client, str(self.state / "daemon.sock")],
                                capture_output=True, timeout=10, preexec_fn=lambda: os.setuid(65534))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"ok": False, "error": "permission denied", "status": None, "sessions": None})
        # The owner still gets through, and the next start tightens the mode.
        self.assertIn(b"mine", self.ok("session", "ls").stdout)
        self.ok("run", "-d", "true")
        self.assertEqual(self.state.stat().st_mode & 0o777, 0o700)

    def test_state_dir_of_another_user_is_refused(self):
        self.state.mkdir(mode=0o700)
        os.chown(self.state, 65534, 65534)
        result = self.wsh("run", "-d", "true")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"state directory is not private to this user", result.stderr)


class FramingTests(AgentTestCase):
    def test_raw_protocol(self):
        self.ok("session", "new", "p")
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.connect(str(self.state / "daemon.sock"))
        body = json.dumps({"op": "ls"}).encode()
        conn.sendall(struct.pack("<I", len(body)) + body)
        length = struct.unpack("<I", conn.recv(4))[0]
        data = b""
        while len(data) < length:
            data += conn.recv(length - len(data))
        conn.close()
        reply = json.loads(data)
        self.assertTrue(reply["ok"])
        self.assertEqual([s["name"] for s in reply["sessions"]], ["p"])
        self.assertEqual((self.state / "daemon.sock").stat().st_mode & 0o777, 0o600)


class HelpTests(unittest.TestCase):
    def test_help_mentions_the_commands(self):
        text = subprocess.run([str(SHELL), "--help"], capture_output=True, check=True).stdout
        self.assertIn(b"wsh run -d", text)
        self.assertIn(b"wsh session new", text)
        for topic in (b"run", b"session"):
            result = subprocess.run([str(SHELL), "-c", b"help " + topic], capture_output=True, check=True)
            self.assertTrue(result.stdout.startswith(topic + b": " + topic), result.stdout)
        usage = subprocess.run([str(SHELL), "run", "--help"], capture_output=True, check=True).stdout
        self.assertIn(b"run wait NAME", usage)


if __name__ == "__main__":
    unittest.main()
