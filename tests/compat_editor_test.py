#!/usr/bin/env python3
"""Interactive line-editor checks: UTF-8 editing, bracketed paste, the kill
ring, history expansion, completion, TERM=dumb and NO_COLOR, driven through a
real pty."""
import fcntl
import os
import pathlib
import pty
import re
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = pathlib.Path(os.environ.get("WSH", ROOT / "zig-out" / "bin" / "wsh")).resolve()
TIMEOUT = 8.0
PROMPT = b"wsh>"


def strip_ansi(data):
    data = re.sub(rb"\x1b\][^\x07\x1b]*(\x07|\x1b\\)", b"", data)
    return re.sub(rb"\x1b\[[0-9;?]*[ -/]*[@-~]", b"", data)


class Session:
    """A wsh process on a pty with its own config, history and directory."""

    def __init__(self, cwd=None, env=None, config='let prompt = "wsh>"\n'):
        self.home = tempfile.TemporaryDirectory(prefix="wsh-editor-")
        config_home = os.path.join(self.home.name, "config")
        data_home = os.path.join(self.home.name, "data")
        os.makedirs(os.path.join(config_home, "wsh"))
        os.makedirs(os.path.join(data_home, "wsh"))
        with open(os.path.join(config_home, "wsh", "config"), "w") as handle:
            handle.write(config)
        full_env = dict(os.environ)
        full_env.pop("NO_COLOR", None)
        full_env.update({
            "TERM": "xterm-256color",
            "XDG_CONFIG_HOME": config_home,
            "XDG_DATA_HOME": data_home,
        })
        full_env.update(env or {})
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd or ROOT)
            os.execve(str(SHELL), ["wsh"], full_env)
            os._exit(127)
        self.buf = b""
        if not self.read_until(PROMPT):
            raise AssertionError(f"no prompt: {self.buf!r}")

    def read_until(self, needle, timeout=TIMEOUT, plain=False):
        deadline = time.time() + timeout
        while True:
            haystack = strip_ansi(self.buf).replace(b"\r", b"") if plain else self.buf
            if needle in haystack:
                return True
            remaining = deadline - time.time()
            if remaining <= 0:
                return False
            ready, _, _ = select.select([self.fd], [], [], min(remaining, 0.2))
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return False
                if not chunk:
                    return False
                self.buf += chunk

    def drain(self, duration=0.4):
        deadline = time.time() + duration
        while time.time() < deadline:
            ready, _, _ = select.select([self.fd], [], [], 0.05)
            if not ready:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def run(self, line, expect):
        """Types `line`, presses Enter and waits for `expect` in the output."""
        self.buf = b""
        self.send(line + "\r")
        return self.read_until(expect, plain=True)

    def plain(self):
        return strip_ansi(self.buf).replace(b"\r", b"")

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
        self.home.cleanup()


class EditorTests(unittest.TestCase):
    def session(self, **kwargs):
        session = Session(**kwargs)
        self.addCleanup(session.close)
        return session

    def temp_dir(self):
        directory = tempfile.TemporaryDirectory(prefix="wsh-editor-dir-")
        self.addCleanup(directory.cleanup)
        return pathlib.Path(directory.name)

    def test_backspace_removes_a_whole_utf8_character(self):
        s = self.session()
        s.buf = b""
        s.send("echo [xé".encode() + b"\x7f" + b"y]\r")
        self.assertTrue(s.read_until(b"[xy]\n", plain=True), s.plain()[-300:])
        self.assertNotIn(b"\xc3y", s.buf)

        # Left steps over the whole character, so typing lands before it.
        s.buf = b""
        s.send("echo [aé]".encode() + b"\x1b[D\x1b[D" + b"b\r")
        self.assertTrue(s.read_until("[abé]\n".encode(), plain=True), s.plain()[-300:])

    def test_bracketed_paste_is_inserted_without_running(self):
        s = self.session()
        s.buf = b""
        s.send(b"\x1b[200~echo $((40+2))\recho pasted-second\r\x1b[201~")
        s.drain(0.8)
        self.assertNotIn(b"42", s.plain())
        self.assertIn(b"echo pasted-second", s.plain())
        s.send(b"\r")
        self.assertTrue(s.read_until(b"\npasted-second\n", plain=True), s.plain()[-300:])
        self.assertIn(b"\n42\n", s.plain())
        # Bracketed paste is on while editing and off while a command runs.
        self.assertIn(b"\x1b[?2004l", s.buf)
        self.assertIn(b"\x1b[?2004h", s.buf)
        self.assertLess(s.buf.index(b"\x1b[?2004l"), s.buf.index(b"42"))

    def test_kill_ring_alt_d_and_yank(self):
        s = self.session()
        # Ctrl-A, Alt-F past "echo", Alt-D kills " alpha" forward, Ctrl-E,
        # Ctrl-Y yanks it back at the end.
        s.buf = b""
        s.send(b"echo alpha beta\x01\x1bf\x1bd\x05\x19\r")
        self.assertTrue(s.read_until(b"beta alpha\n", plain=True), s.plain()[-300:])

        # Alt-D at the start of the line kills forward, not backward.
        s.buf = b""
        s.send(b"Xecho kept\x01\x1bdecho\r")
        self.assertTrue(s.read_until(b"\nkept\n", plain=True), s.plain()[-300:])

        # Ctrl-W twice builds one kill ("one two"); Ctrl-Y yanks it and Alt-Y
        # rotates to the older kill "Xecho".
        s.buf = b""
        s.send(b"echo one two\x17\x17\x19\x1by\r")
        self.assertTrue(s.read_until(b"\nXecho\n", plain=True), s.plain()[-300:])

    def test_yank_last_argument_walks_history(self):
        s = self.session()
        self.assertTrue(s.run("true first-arg", PROMPT))
        self.assertTrue(s.run("true second-arg", PROMPT))
        s.buf = b""
        s.send(b"echo \x1b.\x1b.\r")
        self.assertTrue(s.read_until(b"\nfirst-arg\n", plain=True), s.plain()[-300:])

    def test_undo(self):
        s = self.session()
        s.buf = b""
        s.send(b"echo undone\x17\x1f\r")
        self.assertTrue(s.read_until(b"\nundone\n", plain=True), s.plain()[-300:])

    def test_history_expansion(self):
        s = self.session()
        self.assertTrue(s.run("echo history-one two", b"history-one two\n"))
        # The expansion is echoed, then run.
        self.assertTrue(s.run("echo !!", b"echo echo history-one two\n"))
        self.assertTrue(s.read_until(b"\necho history-one two\n", plain=True), s.plain()[-300:])
        self.assertTrue(s.run("echo !$", b"\ntwo\n"))
        self.assertTrue(s.run("^two^three^", b"\nthree\n"))
        self.assertTrue(s.run("echo !nosuchevent", b"wsh: !nosuchevent: event not found"))
        s.drain(0.3)
        self.assertNotIn(b"\n!nosuchevent", s.plain())
        # Single quotes and a backslash keep the bang literal.
        self.assertTrue(s.run("echo '!!' \\!x", b"\n!! !x\n"))

    def test_cd_completes_directories_only(self):
        directory = self.temp_dir()
        (directory / "alpha_dir").mkdir()
        (directory / "alpha_file").write_text("")
        s = self.session(cwd=directory)
        s.buf = b""
        s.send(b"cd alp\t")
        self.assertTrue(s.read_until(b"cd alpha_dir/", plain=True), s.plain()[-300:])

    def test_complete_word_list(self):
        s = self.session()
        self.assertTrue(s.run("complete -W 'zebra zulu' mycmd", PROMPT))
        s.buf = b""
        s.send(b"mycmd zeb\t")
        self.assertTrue(s.read_until(b"mycmd zebra ", plain=True), s.plain()[-300:])
        s.send(b"\x15")
        self.assertTrue(s.run("complete -p mycmd", b"complete -W 'zebra zulu' mycmd\n"))

    def test_complete_function(self):
        s = self.session()
        self.assertTrue(s.run('fn _pick() { let COMPREPLY = ["$2-picked"] }', PROMPT))
        self.assertTrue(s.run("complete -F _pick pick", PROMPT))
        s.buf = b""
        s.send(b"pick abc\t")
        self.assertTrue(s.read_until(b"pick abc-picked ", plain=True), s.plain()[-300:])

    def test_make_targets(self):
        directory = self.temp_dir()
        (directory / "Makefile").write_text("all: build\nbuild:\n\techo b\ndeploy-prod: build\n\techo d\n")
        s = self.session(cwd=directory)
        s.buf = b""
        s.send(b"make dep\t")
        self.assertTrue(s.read_until(b"make deploy-prod ", plain=True), s.plain()[-300:])

    @unittest.skipUnless(shutil.which("git"), "git is not installed")
    def test_git_subcommands_and_branches(self):
        directory = self.temp_dir()
        git = ["git", "-c", "user.email=wsh@example.invalid", "-c", "user.name=wsh"]
        subprocess.run(git + ["init", "-q", str(directory)], check=True)
        subprocess.run(git + ["-C", str(directory), "commit", "-q", "--allow-empty", "-m", "init"], check=True)
        subprocess.run(git + ["-C", str(directory), "branch", "feature-xyz"], check=True)
        s = self.session(cwd=directory)
        s.buf = b""
        s.send(b"git stas\t")
        self.assertTrue(s.read_until(b"git stash ", plain=True), s.plain()[-300:])
        s.send(b"\x15")
        s.buf = b""
        s.send(b"git checkout fea\t")
        self.assertTrue(s.read_until(b"git checkout feature-xyz ", plain=True), s.plain()[-300:])

    def test_long_options_from_help(self):
        s = self.session()
        s.buf = b""
        s.send(b"ls --almost-a\t")
        self.assertTrue(s.read_until(b"ls --almost-all ", plain=True), s.plain()[-300:])

    def test_edit_and_execute_in_editor(self):
        s = self.session(env={"VISUAL": "sed -i s/before-edit/after-edit/"})
        s.buf = b""
        s.send(b"echo before-edit\x18\x05")
        self.assertTrue(s.read_until(b"\nafter-edit\n", plain=True), s.plain()[-300:])

    def test_resize_redraws_without_a_key(self):
        s = self.session()
        s.send(b"echo resized")
        s.drain(0.3)
        s.buf = b""
        fcntl.ioctl(s.fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 60, 0, 0))
        self.assertTrue(s.read_until(b"echo resized", plain=True, timeout=3), s.buf[-300:])

    def test_term_dumb_has_no_cursor_movement(self):
        s = self.session(env={"TERM": "dumb"})
        self.assertTrue(s.run("echo dumb-ok", b"dumb-ok\n"))
        self.assertTrue(s.run("if true {", b"\xe2\x80\xa6"))
        self.assertTrue(s.run("echo inside", b"\xe2\x80\xa6"))
        self.assertTrue(s.run("}", b"\ninside\n"))
        self.assertIsNone(re.search(rb"\x1b\[[0-9;]*[ABCDGHJK]", s.buf), s.buf[-300:])
        self.assertNotIn(b"\x1b[?2004h", s.buf)

    def test_no_color_disables_highlighting(self):
        s = self.session(env={"NO_COLOR": "1"})
        s.buf = b""
        s.send(b"echo plain | cat")
        s.drain(0.4)
        self.assertIsNone(re.search(rb"\x1b\[[0-9;]*3[0-9]m", s.buf), s.buf[-300:])
        s.send(b"\x15")


if __name__ == "__main__":
    unittest.main()
