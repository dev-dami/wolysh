#!/usr/bin/env python3
"""What the line editor draws, checked on an emulated terminal screen.

wsh runs in a pty of a fixed size; a small VT100 emulator (below) applies
its output to a character grid, and the tests compare the grid and the
cursor with what the user should see. The emulator does only what the
editor emits: text with deferred autowrap (wide characters wrap whole),
CR, LF, BS and the CSI cursor, erase and SGR sequences. A resize either
cuts rows as xterm does or re-wraps the text the way reflowing terminals
(VTE, kitty, iTerm2, Windows Terminal) do."""
import fcntl
import os
import pty
import select
import struct
import sys
import tempfile
import termios
import time
import unicodedata
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHELL = os.path.abspath(os.environ.get("WSH", os.path.join(ROOT, "zig-out/bin/wsh")))
TIMEOUT = 5.0

if not os.path.exists(SHELL):
    print(f"error: {SHELL} does not exist - run `zig build -Doptimize=ReleaseFast` first")
    sys.exit(2)

UP, DOWN, LEFT, RIGHT = b"\x1b[A", b"\x1b[B", b"\x1b[D", b"\x1b[C"
HOME, END, ENTER, ESC = b"\x1b[H", b"\x1b[F", b"\r", b"\x1b"
CTRL_A, CTRL_C, CTRL_E, CTRL_K, CTRL_U = b"\x01", b"\x03", b"\x05", b"\x0b", b"\x15"
ALT_ENTER = b"\x1b\r"


def cell_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    def __init__(self, cols, rows, reflow=False):
        self.cols, self.rows = cols, rows
        self.reflow = reflow
        self.grid = [[" "] * cols for _ in range(rows)]
        # wrapped[r]: row r continues on row r + 1 (the text wrapped there).
        self.wrapped = [False] * rows
        self.x = self.y = 0
        self.pending_wrap = False
        self.state = "text"
        self.seq = ""
        self.utf8 = b""

    def resize(self, cols, rows):
        if self.reflow:
            self.reflow_to(cols, rows)
            return
        # Like xterm: no reflow; rows are cut or padded.
        self.grid = [(r + [" "] * cols)[:cols] for r in self.grid]
        while len(self.grid) > rows and self.y >= rows:
            self.grid.pop(0)
            self.wrapped.pop(0)
            self.y -= 1
        self.grid = self.grid[:rows] + [[" "] * cols for _ in range(rows - len(self.grid))]
        self.wrapped = [False] * rows
        self.cols, self.rows = cols, rows
        self.x = min(self.x, cols - 1)
        self.pending_wrap = False

    def reflow_to(self, cols, rows):
        """Re-wraps each logical line (rows joined by autowrap) at the new
        width, keeping the cursor on its character, as VTE and kitty do.
        Blank rows below the cursor are dropped and the top scrolls away
        when the text no longer fits."""
        lines, cursor = [], None
        current = []
        for r in range(self.rows):
            if r == self.y:
                cursor = (len(lines), len([c for c in current if c != ""]) + sum(
                    1 for c in self.grid[r][:self.x] if c != ""))
            current += self.grid[r]
            if not self.wrapped[r]:
                lines.append(current)
                current = []
        if current:
            lines.append(current)
        lines = [[c for c in line if c != ""] for line in lines]
        lines = [line[:len("".join(line).rstrip())] for line in lines]
        # The cursor may sit on blanks past the end of its line.
        lines[cursor[0]] += [" "] * (cursor[1] - len(lines[cursor[0]]))
        while len(lines) > cursor[0] + 1 and not lines[-1]:
            lines.pop()
        grid, wrapped, y, x = [], [], 0, 0
        for index, line in enumerate(lines):
            row, col = [], 0
            for i, ch in enumerate(line + [None]):
                if index == cursor[0] and i == cursor[1]:
                    if col >= cols:
                        grid.append(row + [" "] * (cols - len(row)))
                        wrapped.append(True)
                        row, col = [], 0
                    y, x = len(grid), col
                if ch is None:
                    break
                w = cell_width(ch)
                if col + w > cols:
                    grid.append(row + [" "] * (cols - len(row)))
                    wrapped.append(True)
                    row, col = [], 0
                row.append(ch)
                if w == 2:
                    row.append("")
                col += w
            grid.append(row + [" "] * (cols - len(row)))
            wrapped.append(False)
        drop = max(0, min(len(grid) - rows, y))
        grid, wrapped, y = grid[drop:][:rows], wrapped[drop:][:rows], y - drop
        grid += [[" "] * cols for _ in range(rows - len(grid))]
        wrapped += [False] * (rows - len(wrapped))
        self.grid, self.wrapped, self.cols, self.rows = grid, wrapped, cols, rows
        self.y, self.x = y, min(x, cols - 1)
        self.pending_wrap = False

    def line_feed(self):
        if self.y == self.rows - 1:
            self.grid.pop(0)
            self.grid.append([" "] * self.cols)
            self.wrapped.pop(0)
            self.wrapped.append(False)
        else:
            self.y += 1

    def put(self, ch):
        w = cell_width(ch)
        if w == 0:
            return
        if self.pending_wrap or self.x + w > self.cols:
            self.wrapped[self.y] = True
            self.x = 0
            self.line_feed()
            self.wrapped[self.y] = False
        self.pending_wrap = False
        self.grid[self.y][self.x] = ch
        if w == 2:
            self.grid[self.y][self.x + 1] = ""
        self.x += w
        if self.x >= self.cols:
            self.x = self.cols - 1
            self.pending_wrap = True

    def csi(self, params, final):
        if params.startswith("?"):
            return
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
        n = nums[0] if nums and nums[0] else 1
        if final == "A":
            self.y = max(0, self.y - n)
        elif final == "B":
            self.y = min(self.rows - 1, self.y + n)
        elif final == "C":
            self.x = min(self.cols - 1, self.x + n)
        elif final == "D":
            self.x = max(0, self.x - n)
        elif final == "G":
            self.x = min(self.cols - 1, n - 1)
        elif final == "H":
            self.y = min((nums[0] if nums and nums[0] else 1) - 1, self.rows - 1)
            self.x = min((nums[1] if len(nums) > 1 and nums[1] else 1) - 1, self.cols - 1)
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 0:
                self.grid[self.y][self.x:] = [" "] * (self.cols - self.x)
                for r in range(self.y + 1, self.rows):
                    self.grid[r] = [" "] * self.cols
                self.wrapped[self.y:] = [False] * (self.rows - self.y)
            else:
                self.grid = [[" "] * self.cols for _ in range(self.rows)]
                self.wrapped = [False] * self.rows
        elif final == "K":
            self.grid[self.y][self.x:] = [" "] * (self.cols - self.x)
        if final != "m":
            self.pending_wrap = False

    def feed(self, data):
        for b in data:
            if self.state == "text":
                if b == 0x1B:
                    self.state = "esc"
                elif b == 0x0D:
                    self.x = 0
                    self.pending_wrap = False
                elif b == 0x0A:
                    self.line_feed()
                    self.pending_wrap = False
                elif b == 0x08:
                    if self.pending_wrap:
                        self.pending_wrap = False
                    elif self.x > 0:
                        self.x -= 1
                elif b >= 0x20:
                    self.utf8 += bytes([b])
                    try:
                        ch = self.utf8.decode()
                    except UnicodeDecodeError:
                        if len(self.utf8) < 4:
                            continue
                        ch = "?"
                    self.utf8 = b""
                    self.put(ch)
            elif self.state == "esc":
                self.state = {ord("["): "csi", ord("]"): "osc"}.get(b, "text")
                self.seq = ""
            elif self.state == "csi":
                if 0x40 <= b <= 0x7E:
                    self.csi(self.seq, chr(b))
                    self.state = "text"
                else:
                    self.seq += chr(b)
            elif self.state == "osc":
                if b == 0x07:
                    self.state = "text"
                elif b == 0x1B:
                    self.state = "osc_esc"
            elif self.state == "osc_esc":
                self.state = "text"

    def lines(self):
        return ["".join(r).rstrip() for r in self.grid]

    def dump(self):
        rows = [(">" if i == self.y else " ") + "|" + line for i, line in enumerate(self.lines())]
        return f"cursor row {self.y} col {self.x}\n" + "\n".join(rows)


class Term:
    """wsh in a pty, with an empty config and the given history."""

    def __init__(self, cols=20, rows=8, config="", history=None, reflow=False, files=()):
        self.tmp = tempfile.TemporaryDirectory(prefix="wsh-render-")
        env = {k: v for k, v in os.environ.items() if not k.startswith("WSH")}
        env.update(TERM="xterm-256color", HOME=self.tmp.name, PS1="$ ",
                   XDG_CONFIG_HOME=os.path.join(self.tmp.name, "config"),
                   XDG_DATA_HOME=os.path.join(self.tmp.name, "data"))
        for sub in ("config", "data"):
            os.makedirs(os.path.join(self.tmp.name, sub, "wsh"))
        with open(os.path.join(self.tmp.name, "config", "wsh", "config"), "w") as f:
            f.write("PS1='$ '\n" + config)
        if history is not None:
            with open(os.path.join(self.tmp.name, "data", "wsh", "history"), "w") as f:
                f.write("#wsh-history v2\n")
                for entry in history:
                    f.write(entry.replace("\\", "\\\\").replace("\n", "\\n") + "\n")
        for name in files:
            open(os.path.join(self.tmp.name, name), "w").close()
        self.screen = Screen(cols, rows, reflow)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(self.tmp.name)
            os.execve(SHELL, ["wsh"], env)
            os._exit(127)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.wait(lambda s: s.lines()[s.y].startswith("$"))

    def pump(self, timeout):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if r:
            try:
                chunk = os.read(self.fd, 65536)
            except OSError:
                return
            self.screen.feed(chunk)

    def wait(self, predicate, timeout=TIMEOUT):
        """Reads output until `predicate(screen)` holds, then a little more
        so a frame is never checked half-drawn."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            if predicate(self.screen):
                self.settle(0.05)
                if predicate(self.screen):
                    return True
            self.pump(0.05)
        return predicate(self.screen)

    def settle(self, quiet=0.15):
        last = time.time()
        while time.time() - last < quiet:
            r, _, _ = select.select([self.fd], [], [], 0.02)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                self.screen.feed(chunk)
                last = time.time()

    def send(self, data, quiet=0.15):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())
        self.settle(quiet)

    def type(self, text):
        for ch in text:
            self.send(ch, quiet=0.01)
        self.settle()

    def resize(self, cols, rows):
        self.screen.resize(cols, rows)
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        self.settle(0.3)

    def close(self):
        try:
            os.kill(self.pid, 9)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        self.tmp.cleanup()


class EditorRenderTests(unittest.TestCase):
    def term(self, **kw):
        t = Term(**kw)
        self.addCleanup(t.close)
        return t

    def expect(self, t, lines, cursor=None):
        """The top of the screen reads `lines` (and the cursor is at `cursor`)."""
        def ok(s):
            return s.lines()[:len(lines)] == lines and (cursor is None or (s.y, s.x) == cursor)
        self.assertTrue(t.wait(ok, timeout=2.0), "\n" + t.screen.dump())

    def test_up_and_down_move_by_screen_row_in_a_wrapped_line(self):
        t = self.term()
        t.type("echo " + "a" * 30)
        self.expect(t, ["$ echo aaaaaaaaaaaaa", "a" * 17], (1, 17))
        t.send(UP)
        self.expect(t, ["$ echo aaaaaaaaaaaaa", "a" * 17], (0, 17))
        t.send(DOWN)
        self.expect(t, ["$ echo aaaaaaaaaaaaa", "a" * 17], (1, 17))
        t.send(UP)
        t.type("X")
        self.expect(t, ["$ echo aaaaaaaaaaXaa", "a" * 18], (0, 18))

    def test_up_on_the_first_row_still_browses_history(self):
        t = self.term(history=["echo old"])
        t.type("echo " + "b" * 20)
        t.send(UP)
        t.send(UP)
        self.expect(t, ["$ echo old", ""], (0, 10))

    def test_end_keys_accept_the_suggestion(self):
        t = self.term(history=["echo hello"])
        for key in (END, b"\x1b[4~", b"\x1bOF", CTRL_E):
            t.type("ec")
            self.expect(t, ["$ echo hello"], (0, 4))
            t.send(key)
            self.expect(t, ["$ echo hello"], (0, 12))
            t.send(CTRL_U)

    def test_a_wide_character_wraps_whole(self):
        t = self.term()
        t.type("echo " + "a" * 12 + "中文字")
        self.expect(t, ["$ echo aaaaaaaaaaaa", "中文字"], (1, 6))
        t.send(LEFT)
        self.expect(t, ["$ echo aaaaaaaaaaaa", "中文字"], (1, 4))
        t.send(LEFT * 2)
        self.expect(t, ["$ echo aaaaaaaaaaaa", "中文字"], (1, 0))

    def test_cursor_after_a_full_width_line_stays_off_the_next_line(self):
        t = self.term()
        t.type("if true {\recho " + "a" * 11 + "\r}")
        t.send(UP)
        t.send(CTRL_E)
        self.expect(t, ["$ if true {", "  … echo " + "a" * 11, "", "  … }"], (2, 0))

    def test_a_command_taller_than_the_screen_keeps_the_cursor_on_it(self):
        t = self.term(rows=6)
        t.type("if true {" + "".join(f"\recho {i}" for i in range(9)))
        self.expect(t, ["  … echo 3", "  … echo 4", "  … echo 5",
                        "  … echo 6", "  … echo 7", "  … echo 8"], (5, 10))
        t.send(UP * 7)
        t.type("X")
        self.expect(t, ["  … echo 1X", "  … echo 2", "  … echo 3",
                        "  … echo 4", "  … echo 5", "  … echo 6"], (0, 11))
        t.send(DOWN * 7)
        t.type("Y")
        self.expect(t, ["  … echo 3", "  … echo 4", "  … echo 5",
                        "  … echo 6", "  … echo 7", "  … echo 8Y"], (5, 11))

    def test_ctrl_c_on_an_earlier_line_keeps_the_later_ones(self):
        t = self.term()
        t.type("if true {\recho one\recho two")
        t.send(UP * 2)
        t.send(CTRL_C)
        self.expect(t, ["$ if true {", "  … echo one", "  … echo two^C", "$"], (3, 2))

    def test_line_keys_act_on_the_current_line(self):
        t = self.term()
        t.type("if true {\recho one")
        t.send(HOME)
        t.type("X")
        self.expect(t, ["$ if true {", "  … Xecho one"], (1, 5))
        t.send(CTRL_A)
        t.send(CTRL_K)
        self.expect(t, ["$ if true {", "  …"], (1, 4))
        t.type("echo two")
        t.send(LEFT * 3)
        t.send(CTRL_U)
        self.expect(t, ["$ if true {", "  … two"], (1, 4))
        # At the start of a line, Ctrl-U joins it to the line above.
        t.send(CTRL_U)
        self.expect(t, ["$ if true {two"], (0, 11))

    def test_up_keeps_browsing_history_past_a_recalled_multiline_entry(self):
        t = self.term(history=["echo old", "if true {\n  echo a\n}"])
        t.send(UP)
        self.expect(t, ["$ if true {", "  …   echo a", "  … }"], (2, 5))
        t.send(UP)
        self.expect(t, ["$ echo old", ""], (0, 10))
        t.send(DOWN)
        self.expect(t, ["$ if true {", "  …   echo a", "  … }"], (2, 5))

    def test_vi_j_and_k_move_between_lines(self):
        t = self.term(config="set -o vi\n", history=["echo old"])
        t.type("if true {\recho one\recho two")
        t.send(ESC)
        t.send(b"k")
        self.expect(t, ["$ if true {", "  … echo one", "  … echo two"], (1, 11))
        t.send(b"j")
        self.expect(t, ["$ if true {", "  … echo one", "  … echo two"], (2, 11))

    def test_alt_enter_inserts_a_new_line(self):
        t = self.term()
        t.type("echo one two")
        t.send(LEFT * 4)
        t.send(ALT_ENTER)
        self.expect(t, ["$ echo one", "  …  two"], (1, 4))

    def test_continuation_prompts_indent_by_nesting_not_line_number(self):
        t = self.term()
        t.type("if true {\recho 1\recho 2\rfor x in a; do\recho $x")
        self.expect(t, ["$ if true {", "  … echo 1", "  … echo 2",
                        "  … for x in a; do", "    … echo $x"])

    def test_a_full_width_command_has_no_blank_line_before_its_output(self):
        t = self.term()
        t.type("echo " + "a" * 13)
        t.send(ENTER)
        self.expect(t, ["$ echo " + "a" * 13, "a" * 13, "$"], (2, 2))

    def test_ctrl_l_redraws_every_line_of_the_prompt(self):
        t = self.term(config="PS1='top\\n> '\n")
        t.type("echo hi")
        t.send(b"\x0c")
        self.expect(t, ["top", "> echo hi"], (1, 9))

    def test_esc_and_arrows_end_a_history_search_on_the_match(self):
        t = self.term(history=["echo old", "if true {\n  echo a\n}"])
        t.send(b"\x12")
        t.type("old")
        t.send(LEFT)
        self.expect(t, ["$ echo old", ""], (0, 6))
        t.send(CTRL_U)
        t.send(b"\x12")
        t.type("a")
        t.send(ESC)
        self.expect(t, ["$ if true {", "  …   echo a", "  … }"], (1, 11))

    def test_vertical_moves_keep_the_column_through_a_short_line(self):
        t = self.term()
        t.type("if true {\recho abcdefghij\rx\recho abcdefghij")
        lines = ["$ if true {", "  … echo abcdefghij", "  … x", "  … echo abcdefghij"]
        self.expect(t, lines, (3, 19))
        t.send(UP)
        self.expect(t, lines, (2, 5))
        t.send(UP)
        self.expect(t, lines, (1, 19))
        t.send(DOWN)
        t.send(DOWN)
        self.expect(t, lines, (3, 19))
        # A horizontal move sets a new goal column.
        t.send(LEFT * 3)
        t.send(UP)
        t.send(UP)
        self.expect(t, lines, (1, 16))

    def test_vi_j_and_k_keep_the_column_through_a_short_line(self):
        t = self.term(config="set -o vi\n")
        t.type("if true {\recho abcdefghij\rx\recho abcdefghij")
        lines = ["$ if true {", "  … echo abcdefghij", "  … x", "  … echo abcdefghij"]
        t.send(ESC)
        self.expect(t, lines, (3, 18))
        t.send(b"k")
        self.expect(t, lines, (2, 4))
        t.send(b"k")
        self.expect(t, lines, (1, 18))
        t.send(b"j")
        t.send(b"j")
        self.expect(t, lines, (3, 18))
        # An edit sets a new goal column.
        t.send(b"0")
        t.send(b"x")
        t.send(b"k")
        t.send(b"k")
        self.expect(t, lines[:1] + ["  … echo abcdefghij", "  … x", "  … cho abcdefghij"], (1, 4))

    def test_a_bound_command_prints_right_below_a_full_width_line(self):
        t = self.term(config="bind -x '\"\\C-t\": echo hi'\n")
        t.type("echo " + "a" * 13)
        t.send(b"\x14")
        self.expect(t, ["$ echo " + "a" * 13, "hi", "$ echo " + "a" * 13, ""], (3, 0))

    def resized(self, reflow, cols, new_cols, keys, expected, files=()):
        """Types `keys` on a `cols` wide screen below some earlier output,
        resizes it to `new_cols` and checks the frame reads `expected` once,
        with no stale copy of the prompt or the command left anywhere.
        Neither kind of terminal can be told from the other, so the redraw
        starts as high as either needs: when the guess is wrong the row of
        output above the prompt is given up instead of leaving a stale one."""
        t = self.term(cols=cols, rows=12, reflow=reflow, files=files)
        t.type("echo marker")
        t.send(ENTER)
        for key in keys:
            t.type(key) if isinstance(key, str) else t.send(key)
        t.resize(new_cols, 12)
        t.settle(0.3)
        lines = t.screen.lines()
        mode = "reflow" if reflow else "xterm"
        where = f"{mode} {cols} -> {new_cols}\n" + t.screen.dump()
        self.assertEqual(sum(1 for line in lines if line.startswith("$ ")), 2, where)
        if reflow == (new_cols < cols):
            self.assertIn("marker", lines, where)
        expected = [line.rstrip() for line in expected]
        start = next(i for i, line in enumerate(lines) if line.startswith("$ ") and "marker" not in line)
        self.assertEqual(lines[start:start + len(expected)], expected, where)
        self.assertEqual([line for line in lines[start + len(expected):] if line], [], where)
        return t

    def test_resize_redraws_a_wrapped_command_once(self):
        text = "printf zzzzzzzzzz zzzzzzzzzz zzzzzzzzzz zzzzzzzzz"
        line = "$ " + text
        for reflow in (False, True):
            with self.subTest(reflow=reflow, to="narrower"):
                self.resized(reflow, 30, 20, [text], [line[i:i + 20] for i in range(0, len(line), 20)])
            with self.subTest(reflow=reflow, to="wider"):
                self.resized(reflow, 20, 30, [text], [line[i:i + 30] for i in range(0, len(line), 30)])

    def test_resize_redraws_a_multiline_command_once(self):
        keys = ["if true {", ENTER, "echo zzzzzzzzzzzzzzzzzzzz", ENTER, "echo z"]
        narrow = ["$ if true {", "  … echo zzzzzzzzzzz", "zzzzzzzzz", "  … echo z"]
        wide = ["$ if true {", "  … echo zzzzzzzzzzzzzzzzzzzz", "  … echo z"]
        for reflow in (False, True):
            with self.subTest(reflow=reflow, to="narrower"):
                self.resized(reflow, 30, 20, keys, narrow)
            with self.subTest(reflow=reflow, to="wider"):
                self.resized(reflow, 20, 30, keys, wide)

    def test_resize_redraws_an_open_menu_once(self):
        files = ("apple", "apricot", "avocado")
        keys = ["cat " + "z" * 20 + " a", b"\t", b"\t"]
        for reflow in (False, True):
            for cols, new_cols in ((40, 20), (20, 40)):
                with self.subTest(reflow=reflow, cols=cols, new_cols=new_cols):
                    line = "$ cat " + "z" * 20 + " apple"
                    rows = [line[i:i + new_cols] for i in range(0, len(line), new_cols)]
                    t = self.resized(reflow, cols, new_cols, keys, rows + ["apple    avocado", "apricot"]
                                     if new_cols == 20 else rows + ["apple  apricot  avocado"], files)
                    self.assertEqual("\n".join(t.screen.lines()).count("avocado"), 1, t.screen.dump())


if __name__ == "__main__":
    unittest.main()
