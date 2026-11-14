"""End-to-end tests for the Tab completion menu, checked against the screen.

wsh runs in a pty, and its output goes through a small VT100 emulator so the
tests assert what the user would see: which rows hold the menu, which item is
drawn in reverse video, and that nothing is left behind after the menu
closes. Only the Python standard library is used.
"""

import fcntl
import os
import pty
import select
import signal
import struct
import tempfile
import termios
import time
import unicodedata
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WSH = os.path.join(ROOT, "zig-out", "bin", "wsh")

TAB = b"\t"
SHIFT_TAB = b"\x1b[Z"
ENTER = b"\r"
ESC = b"\x1b"
BS = b"\x7f"
CTRL_C = b"\x03"
CTRL_G = b"\x07"
UP = b"\x1b[A"
DOWN = b"\x1b[B"
LEFT = b"\x1b[D"
RIGHT = b"\x1b[C"


def cell_width(ch):
    if unicodedata.combining(ch):
        return 0
    return 2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1


class Screen:
    """A VT100 subset: text with deferred autowrap, CR/LF/BS, cursor moves,
    erase in line/display, scrolling, and SGR reverse video."""

    def __init__(self, cols, rows):
        self.cols, self.rows = cols, rows
        self.grid = [[" "] * cols for _ in range(rows)]
        self.attr = [[False] * cols for _ in range(rows)]
        self.x = self.y = 0
        self.wrap = False
        self.reverse = False
        self.state = "text"
        self.seq = ""
        self.utf8 = b""

    def resize(self, cols, rows):
        grid = [[" "] * cols for _ in range(rows)]
        attr = [[False] * cols for _ in range(rows)]
        for r in range(min(rows, self.rows)):
            for c in range(min(cols, self.cols)):
                grid[r][c] = self.grid[r][c]
                attr[r][c] = self.attr[r][c]
        self.grid, self.attr, self.cols, self.rows = grid, attr, cols, rows
        self.x, self.y = min(self.x, cols - 1), min(self.y, rows - 1)

    def lf(self):
        if self.y == self.rows - 1:
            self.grid.pop(0)
            self.attr.pop(0)
            self.grid.append([" "] * self.cols)
            self.attr.append([False] * self.cols)
        else:
            self.y += 1

    def put(self, ch):
        w = cell_width(ch)
        if w == 0:
            return
        if self.wrap or self.x + w > self.cols:
            self.x = 0
            self.lf()
            self.wrap = False
        self.grid[self.y][self.x] = ch
        self.attr[self.y][self.x] = self.reverse
        if w == 2 and self.x + 1 < self.cols:
            self.grid[self.y][self.x + 1] = ""
        self.x += w
        if self.x >= self.cols:
            self.x = self.cols - 1
            self.wrap = True

    def clear_cells(self, row, cols):
        for c in cols:
            self.grid[row][c] = " "
            self.attr[row][c] = False

    def csi(self, params, final):
        if params.startswith(("?", ">")):
            return
        nums = [int(p) if p.isdigit() else 0 for p in params.split(";")] if params else []
        n = nums[0] if nums and nums[0] else 1
        if final == "m":
            for p in nums or [0]:
                if p == 7:
                    self.reverse = True
                elif p in (0, 27):
                    self.reverse = False
            return
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
        elif final in "Hf":
            r = (nums[0] if nums and nums[0] else 1) - 1
            c = (nums[1] if len(nums) > 1 and nums[1] else 1) - 1
            self.y, self.x = min(r, self.rows - 1), min(c, self.cols - 1)
        elif final == "J":
            mode = nums[0] if nums else 0
            if mode == 0:
                self.clear_cells(self.y, range(self.x, self.cols))
                for r in range(self.y + 1, self.rows):
                    self.clear_cells(r, range(self.cols))
            elif mode in (2, 3):
                for r in range(self.rows):
                    self.clear_cells(r, range(self.cols))
        elif final == "K":
            mode = nums[0] if nums else 0
            cols = range(self.x, self.cols) if mode == 0 else range(0, self.x + 1) if mode == 1 else range(self.cols)
            self.clear_cells(self.y, cols)
        self.wrap = False

    def feed(self, data):
        for b in data:
            if self.state == "text":
                if b == 0x1B:
                    self.state = "esc"
                elif b == 0x0D:
                    self.x, self.wrap = 0, False
                elif b == 0x0A:
                    self.lf()
                    self.wrap = False
                elif b == 0x08:
                    if self.wrap:
                        self.wrap = False
                    elif self.x > 0:
                        self.x -= 1
                elif b < 0x20:
                    pass
                else:
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
                if b == ord("["):
                    self.state, self.seq = "csi", ""
                elif b == ord("]"):
                    self.state = "osc"
                else:
                    self.state = "text"
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

    def reversed_text(self):
        """The text drawn in reverse video, row by row (empty rows dropped)."""
        out = []
        for r in range(self.rows):
            text = "".join(ch for ch, rev in zip(self.grid[r], self.attr[r]) if rev).strip()
            if text:
                out.append(text)
        return out

    def dump(self):
        return "\n".join(f"{'>' if i == self.y else ' '}|{line}" for i, line in enumerate(self.lines()))


class Wsh:
    """An interactive wsh in a pty, with its own config, history and cwd."""

    def __init__(self, cwd, cols=40, rows=16, config=""):
        self.tmp = tempfile.TemporaryDirectory(prefix="wsh-menu-")
        env = {k: v for k, v in os.environ.items() if not k.startswith("WSH")}
        env.update(TERM="xterm-256color", HOME=self.tmp.name, PS1="$ ",
                   XDG_CONFIG_HOME=os.path.join(self.tmp.name, "config"),
                   XDG_DATA_HOME=os.path.join(self.tmp.name, "data"))
        os.makedirs(os.path.join(env["XDG_CONFIG_HOME"], "wsh"))
        os.makedirs(os.path.join(env["XDG_DATA_HOME"], "wsh"))
        with open(os.path.join(env["XDG_CONFIG_HOME"], "wsh", "config"), "w") as f:
            f.write("PS1='$ '\nlet highlight = false\nlet autosuggest = false\n" + config)
        self.screen = Screen(cols, rows)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            os.chdir(cwd)
            os.execve(WSH, ["wsh"], env)
            os._exit(127)
        self.winsize(cols, rows)
        self.settle(0.3, limit=5.0)

    def winsize(self, cols, rows):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def resize(self, cols, rows):
        self.screen.resize(cols, rows)
        self.winsize(cols, rows)
        os.kill(self.pid, signal.SIGWINCH)
        self.settle()

    def settle(self, quiet=0.15, limit=3.0):
        end = time.time() + limit
        last = time.time()
        while time.time() < end:
            ready, _, _ = select.select([self.fd], [], [], 0.03)
            if ready:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    return
                if not chunk:
                    return
                self.screen.feed(chunk)
                last = time.time()
            elif time.time() - last > quiet:
                return

    def send(self, data):
        os.write(self.fd, data)
        self.settle()

    def type(self, text):
        for ch in text.encode():
            os.write(self.fd, bytes([ch]))
            self.settle(0.02)
        self.settle()

    def lines(self):
        return self.screen.lines()

    def close(self):
        try:
            os.kill(self.pid, signal.SIGKILL)
            os.waitpid(self.pid, 0)
        except OSError:
            pass
        os.close(self.fd)
        self.tmp.cleanup()


def nonblank(lines):
    return [line for line in lines if line.strip()]


class MenuTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.dir = tempfile.TemporaryDirectory(prefix="wsh-menu-files-")
        for name in ("apple", "apricot", "avocado", "banana"):
            open(os.path.join(cls.dir.name, name), "w").close()
        many = os.path.join(cls.dir.name, "many")
        os.mkdir(many)
        for i in range(500):
            open(os.path.join(many, f"file{i:03d}.txt"), "w").close()
        odd = os.path.join(cls.dir.name, "odd")
        os.mkdir(odd)
        for name in ("my file", "my été", "my_long_" + "x" * 60):
            open(os.path.join(odd, name), "w").close()

    @classmethod
    def tearDownClass(cls):
        cls.dir.cleanup()

    def start(self, **kw):
        sh = Wsh(self.dir.name, **kw)
        self.addCleanup(sh.close)
        return sh

    def assertScreen(self, sh, ok, message):
        if not ok:
            self.fail(message + "\n" + sh.screen.dump())

    def menu_rows(self, sh):
        """Rows below the cursor row that hold text."""
        return nonblank(sh.lines()[sh.screen.y + 1:])

    def open_menu(self, sh, text="cat a"):
        sh.type(text)
        sh.send(TAB)

    def test_menu_appears_below_the_line(self):
        sh = self.start()
        self.open_menu(sh)
        lines = sh.lines()
        self.assertScreen(sh, lines[sh.screen.y] == "$ cat a", "the line is unchanged")
        below = " ".join(self.menu_rows(sh))
        for name in ("apple", "apricot", "avocado"):
            self.assertScreen(sh, name in below, f"{name} is listed below the line")
        self.assertScreen(sh, "banana" not in below, "non-matching names are not listed")
        self.assertScreen(sh, sh.screen.reversed_text() == [], "nothing is selected yet")

    def test_tab_moves_selection_and_updates_the_line(self):
        sh = self.start()
        self.open_menu(sh)
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat apple", "first Tab selects apple")
        self.assertScreen(sh, sh.screen.reversed_text() == ["apple"], "apple is highlighted")
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat apricot", "second Tab selects apricot")
        self.assertScreen(sh, sh.screen.reversed_text() == ["apricot"], "apricot is highlighted")
        sh.send(SHIFT_TAB)
        self.assertScreen(sh, sh.screen.reversed_text() == ["apple"], "Shift-Tab goes back")
        sh.send(UP)
        self.assertScreen(sh, sh.screen.reversed_text() == ["avocado"], "Up from the first item wraps to the last")
        sh.send(DOWN)
        self.assertScreen(sh, sh.screen.reversed_text() == ["apple"], "Down wraps to the first")

    def test_no_duplicate_lists(self):
        sh = self.start()
        self.open_menu(sh)
        for _ in range(5):
            sh.send(TAB)
        text = "\n".join(sh.lines())
        self.assertScreen(sh, text.count("avocado") == 1, "the list is drawn once")
        self.assertScreen(sh, text.count("$ cat") == 1, "the prompt is drawn once")

    def test_typing_closes_and_erases_the_menu(self):
        sh = self.start()
        self.open_menu(sh)
        sh.type("p")
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat ap", "the key is inserted")
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu rows are erased")
        self.assertScreen(sh, "avocado" not in "\n".join(sh.lines()), "nothing left in view")

    def test_backspace_closes_the_menu(self):
        sh = self.start()
        self.open_menu(sh)
        sh.send(TAB)
        sh.send(BS)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat apple", "Backspace edits the selected word")
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu rows are erased")

    def test_escape_restores_the_word(self):
        sh = self.start()
        self.open_menu(sh)
        sh.send(TAB)
        sh.send(TAB)
        sh.send(ESC)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat a", "Esc restores the typed word")
        self.assertScreen(sh, self.menu_rows(sh) == [], "Esc closes the menu")

    def test_ctrl_g_restores_the_word(self):
        sh = self.start()
        self.open_menu(sh)
        sh.send(TAB)
        sh.send(CTRL_G)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat a", "Ctrl-G restores the typed word")
        self.assertScreen(sh, self.menu_rows(sh) == [], "Ctrl-G closes the menu")

    def test_enter_accepts_without_running(self):
        sh = self.start()
        self.open_menu(sh, "echo a")
        sh.send(TAB)
        sh.send(TAB)
        sh.send(ENTER)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ echo apricot", "Enter keeps the selection")
        self.assertScreen(sh, self.menu_rows(sh) == [], "Enter closes the menu")
        sh.type("x")
        sh.send(ENTER)
        self.assertScreen(sh, "apricot x" in sh.lines(), "the command runs on the next Enter")

    def test_ctrl_c_leaves_no_menu(self):
        sh = self.start()
        self.open_menu(sh)
        sh.send(TAB)
        sh.send(CTRL_C)
        text = "\n".join(sh.lines())
        self.assertScreen(sh, "avocado" not in text, "the menu is erased")
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$", "a fresh prompt follows")

    def test_submitting_leaves_no_menu(self):
        sh = self.start()
        self.open_menu(sh, "echo a")
        sh.type("z")
        sh.send(ENTER)
        text = "\n".join(sh.lines())
        self.assertScreen(sh, "avocado" not in text, "no menu rows after running")
        self.assertScreen(sh, "az" in sh.lines(), "the command ran")

    def test_long_list_is_capped_and_scrolls(self):
        sh = self.start(cols=40, rows=15)
        self.open_menu(sh, "ls many/")
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ ls many/file", "the common prefix goes in first")
        sh.send(TAB)
        rows = self.menu_rows(sh)
        self.assertScreen(sh, 2 <= len(rows) <= 6, "the menu height is capped")
        self.assertScreen(sh, rows[-1].startswith("…and ") and rows[-1].endswith(" more"), "a final row counts the rest")
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ ls many/file", "the line stays")
        for _ in range(60):
            os.write(sh.fd, TAB)
        sh.settle(0.3)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ ls many/file059.txt", "selection follows Tab")
        self.assertScreen(sh, sh.screen.reversed_text() == ["file059.txt"], "the selection scrolls into view")
        self.assertScreen(sh, len(self.menu_rows(sh)) == len(rows), "the height stays the same")
        sh.send(ESC)
        self.assertScreen(sh, self.menu_rows(sh) == [], "Esc erases a scrolled menu")

    def test_menu_near_the_bottom_of_the_screen(self):
        sh = self.start(cols=40, rows=10)
        for _ in range(12):
            sh.send(ENTER)
        self.open_menu(sh)
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat apple", "the line moves up above the menu")
        self.assertScreen(sh, "avocado" in " ".join(self.menu_rows(sh)), "the menu fits below")
        sh.type("x")
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu rows are erased")
        self.assertScreen(sh, sh.lines().count("$ cat apple x") == 1, "the line is drawn once")

    def test_menu_in_a_multiline_buffer(self):
        sh = self.start()
        sh.type("if true {")
        sh.send(ENTER)
        self.open_menu(sh, "cat a")
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y].endswith("cat apple"), "the continuation line is updated")
        self.assertScreen(sh, sum(1 for l in sh.lines() if l.startswith("$ if true {")) == 1, "the first line is drawn once")
        sh.send(ESC)
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu closes")
        self.assertScreen(sh, sh.lines()[sh.screen.y].endswith("cat a"), "the word is restored")

    def test_narrow_terminal_truncates_items(self):
        sh = self.start(cols=30, rows=16)
        self.open_menu(sh, "ls odd/my")
        rows = self.menu_rows(sh)
        self.assertScreen(sh, all(len(r) <= 30 for r in sh.lines()), "nothing wider than the terminal")
        self.assertScreen(sh, any(r.endswith("…") for r in rows), "the long name is cut with an ellipsis")
        self.assertScreen(sh, any("my été" in r for r in rows), "unicode names are shown")
        sh.send(TAB)
        sh.send(TAB)
        sh.send(TAB)
        line = "\n".join(sh.lines())
        self.assertScreen(sh, "my_long_xxx" in line, "the long name goes into the line")
        sh.send(ESC)
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu closes")

    def test_resize_while_open(self):
        sh = self.start(cols=60, rows=16)
        self.open_menu(sh)
        sh.send(TAB)
        sh.resize(30, 16)
        sh.send(TAB)
        self.assertScreen(sh, sh.screen.reversed_text() == ["apricot"], "the menu redraws after a resize")
        sh.send(ESC)
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu closes after a resize")

    def test_menu_shows_when_the_command_fills_the_screen(self):
        sh = self.start(cols=40, rows=8)
        sh.type("if true {")
        for i in range(8):
            sh.send(ENTER)
            sh.type(f"echo {i}")
        sh.send(ENTER)
        self.open_menu(sh)
        self.assertScreen(sh, sh.lines()[sh.screen.y].endswith("cat a"), "the cursor's line stays in view")
        below = " ".join(self.menu_rows(sh))
        for name in ("apple", "apricot", "avocado"):
            self.assertScreen(sh, name in below, f"{name} is listed below the line")
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y].endswith("cat apple"), "Tab puts the first name in")
        self.assertScreen(sh, sh.screen.reversed_text() == ["apple"], "the selection is visible")
        sh.send(ESC)
        self.assertScreen(sh, self.menu_rows(sh) == [], "the menu closes")
        self.assertScreen(sh, sh.lines()[-1].endswith("cat a"), "the command fills the screen again")
        self.assertScreen(sh, sh.lines()[0].endswith("echo 1"), "the window shows the rows above again")

    def test_tiny_screen_rings_the_bell_instead_of_a_menu(self):
        sh = self.start(cols=40, rows=3)
        self.open_menu(sh)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat a", "the word is unchanged")
        self.assertScreen(sh, self.menu_rows(sh) == [], "no menu opens")
        sh.send(TAB)
        self.assertScreen(sh, sh.lines()[sh.screen.y] == "$ cat a", "Tab does not change the word unseen")


if __name__ == "__main__":
    unittest.main()
