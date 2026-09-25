#!/usr/bin/env python3
"""Drive wolysh through a real pty and check the interactive behaviour."""
import os
import pty
import re
import select
import signal
import sys
import tempfile
import time

# Defaults to the ReleaseFast build; override with WSH=/path/to/wsh.
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL = os.path.abspath(os.environ.get("WSH", os.path.join(ROOT, "zig-out/bin/wsh")))
TIMEOUT = 8.0


if not os.path.exists(SHELL):
    print(f"error: {SHELL} does not exist - run `zig build -Doptimize=ReleaseFast` first")
    sys.exit(2)


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
            os.execve(SHELL, ["wsh"], env)
            os._exit(127)
        self.buf = b""

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
                    return False
                if not chunk:
                    return False
                self.buf += chunk
        return needle in self.buf

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def clear(self):
        self.buf = b""

    def drain(self, duration=0.4):
        """Reads whatever the shell has written for a short while."""
        deadline = time.time() + duration
        while time.time() < deadline:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if not r:
                continue
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            if not chunk:
                return
            self.buf += chunk

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


results = []


def check(name, ok, detail=""):
    results.append((name, ok, detail))
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else f"  <- {detail}"))


def strip_ansi(b):
    out = bytearray()
    i = 0
    while i < len(b):
        if b[i] == 0x1B:
            j = i + 1
            if j < len(b) and b[j:j+1] == b"[":
                j += 1
                while j < len(b) and not (0x40 <= b[j] <= 0x7E):
                    j += 1
                j += 1
            else:
                j += 1
            i = j
            continue
        out.append(b[i])
        i += 1
    return bytes(out)


def main():
    s = Session()

    # 1. prompt appears - if this fails nothing else is meaningful
    ok = s.read_until(b"\xe2\x9d\xaf")
    check("prompt is drawn", ok, repr(s.buf[-200:]))
    if not ok:
        s.close()
        print("\ncannot continue: the shell never drew a prompt")
        return 1

    # 1b. the cursor must land at the *visible* prompt width. The prompt is ~50
    # bytes once colour codes are included but only ~18 columns wide; measuring
    # bytes parked the cursor far right and drifted the prompt off the output.
    cols = re.findall(rb'\x1b\[(\d+)C', s.buf)
    visible = strip_ansi(s.buf).replace(b"\r", b"").split(b"\n")[-1]
    visible = visible.decode("utf-8", "replace")
    if cols:
        check(
            "cursor column matches the visible prompt width",
            int(cols[-1]) == len(visible),
            f"sent {int(cols[-1])}, prompt is {len(visible)} columns",
        )
    else:
        check("cursor column matches the visible prompt width", False, "no cursor move seen")

    # 2. simple command
    s.clear()
    s.send("echo interactive-works\r")
    check("command runs", s.read_until(b"interactive-works"))

    # 3. autosuggestion from history
    s.clear()
    s.send("echo interact")
    s.drain()
    plain = strip_ansi(s.buf)
    check("inline autosuggestion shown", b"interactive-works" in plain, repr(plain[-200:]))

    # accepting it with Right arrow should complete the line
    s.send(b"\x1b[C")
    s.drain(0.2)
    s.send("\r")
    check("autosuggestion accepted and runs", s.read_until(b"interactive-works"))

    # 4. tab completion of a command name
    s.clear()
    s.send("ech\t")
    s.drain()
    plain = strip_ansi(s.buf)
    check("tab completes 'ech' to 'echo '", b"echo " in plain, repr(plain[-200:]))
    s.send(b"\x15")  # Ctrl-U to clear the line
    s.drain(0.2)

    # 5. file completion
    s.clear()
    s.send("cat src/lex\t")
    s.drain()
    plain = strip_ansi(s.buf)
    check("tab completes a path", b"src/lexer.zig" in plain, repr(plain[-300:]))
    s.send(b"\x15")
    s.drain(0.2)

    # 6. history via Up arrow
    s.clear()
    s.send(b"\x1b[A")
    s.drain()
    plain = strip_ansi(s.buf)
    check("up arrow recalls history", b"echo interact" in plain or b"cat src/lex" in plain, repr(plain[-200:]))
    s.send(b"\x15")
    s.drain(0.2)

    # 7. Ctrl-C abandons the line
    s.clear()
    s.send("this should not run")
    s.drain(0.2)
    s.send(b"\x03")
    s.drain()
    plain = strip_ansi(s.buf)
    check("ctrl-c cancels the line", b"^C" in plain, repr(plain[-200:]))
    s.clear()
    s.send("echo after-cancel\r")
    check("prompt recovers after ctrl-c", s.read_until(b"after-cancel"))

    # 8. multi-line continuation with an unclosed brace
    s.clear()
    s.send("if true {\r")
    s.drain()
    plain = strip_ansi(s.buf)
    check("continuation prompt appears", b"\xe2\x80\xa6" in plain, repr(plain[-200:]))
    s.send("echo inside-block\r")
    s.drain(0.2)
    s.send("}\r")
    check("block executes after closing brace", s.read_until(b"inside-block"))

    # 9. job control: background job + jobs builtin
    s.clear()
    s.send("sleep 5 &\r")
    s.drain(0.5)
    s.clear()
    s.send("jobs\r")
    check("jobs lists the background job", s.read_until(b"Running"))

    # 10. Ctrl-Z suspends the foreground job, then bg/fg move it around
    s.clear()
    s.send("sleep 30\r")
    s.drain(0.4)
    s.send(b"\x1a")  # Ctrl-Z
    check("ctrl-z stops the foreground job", s.read_until(b"Stopped"))

    s.clear()
    s.send("bg\r")
    s.drain(0.4)
    s.clear()
    s.send("jobs\r")
    check("bg resumes the stopped job", s.read_until(b"Running"))

    s.clear()
    s.send("fg\r")
    s.drain(0.4)
    s.clear()
    s.send(b"\x03")  # Ctrl-C kills the foreground job
    check("fg returns the job to the foreground", s.read_until(b"\xe2\x9d\xaf", timeout=4))

    # 11. rendering geometry: a wrapped line must keep the cursor inside the
    # terminal, and the prompt must land on the line right after the output.
    s.clear()
    s.send("for i in 1 2 3 4 5 6 {\n    echo marker\n}\r")
    s.drain(1.2)
    after = strip_ansi(s.buf).replace(b"\r", b"").split(b"}")[-1]
    nonempty = [l for l in after.split(b"\n") if l.strip()]
    check("block output renders six lines", after.count(b"marker\n") == 6,
          f"got {after.count(b'marker' + bytes([10]))}")
    check("prompt directly follows the block output",
          bool(nonempty) and b"\xe2\x9d\xaf" in nonempty[-1],
          repr(nonempty[-3:]))

    long_send = "echo " + "x" * 90
    s.clear()
    s.send(long_send)
    s.drain(0.6)
    moves = [int(m) for m in re.findall(rb"\x1b\[(\d+)C", s.buf)]
    check("wrapped input keeps cursor columns inside the terminal",
          bool(moves) and all(m < 80 for m in moves), f"columns sent: {moves[-4:]}")
    s.send(b"\x15")
    s.drain(0.2)

    # 12. exit
    s.clear()
    s.send("exit\r")
    s.drain(0.5)
    try:
        os.waitpid(s.pid, os.WNOHANG)
    except ChildProcessError:
        pass
    s.close()

    failed = [r for r in results if not r[1]]
    print(f"\n{len(results) - len(failed)}/{len(results)} interactive checks passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
