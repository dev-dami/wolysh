#!/usr/bin/env python3
"""End-to-end checks that wsh builtins behave like their bash counterparts."""
import os
import pathlib
import pty
import re
import select
import shlex
import signal
import subprocess
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"


def run_shell(command, **kwargs):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=10,
        check=False,
        **kwargs,
    )


def run_bash(command, **kwargs):
    return subprocess.run(
        ["bash", "--norc", "--noprofile", "-c", command],
        cwd=ROOT,
        capture_output=True,
        timeout=10,
        check=False,
        **kwargs,
    )


class Session:
    """A wsh instance on a pty, as in tests/pty_test.py."""

    def __init__(self):
        self.data_home = tempfile.TemporaryDirectory(prefix="wsh-builtins-pty-")
        env = dict(os.environ)
        env["TERM"] = "xterm-256color"
        env["XDG_CONFIG_HOME"] = os.path.join(self.data_home.name, "config")
        env["XDG_DATA_HOME"] = os.path.join(self.data_home.name, "data")
        os.makedirs(os.path.join(env["XDG_DATA_HOME"], "wsh"), exist_ok=True)
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            # Start outside any repository so the prompt does no git lookups.
            os.chdir("/")
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        self.buf = b""

    def read_until(self, needle, timeout=8.0):
        deadline = time.time() + timeout
        while time.time() < deadline:
            if needle in strip_ansi(self.buf):
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
        return needle in strip_ansi(self.buf)

    def send(self, data):
        os.write(self.fd, data if isinstance(data, bytes) else data.encode())

    def clear(self):
        self.buf = b""

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
    # Terminal integration adds OSC title and prompt marks around output.
    data = re.sub(rb"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)", b"", data)
    return re.sub(rb"\x1b\[[0-9;?]*[A-Za-z]", b"", data)


PRINTF_CASES = [
    ["%-6s|%5s|\\n", "ab", "cd"],
    ["%05d|%-5d|%+d|% d|\\n", "42", "-7", "5", "6"],
    ["%x %X %o %#x %#o %u\\n", "255", "255", "8", "255", "8", "-1"],
    ["%.3s|%10.2f|%-10.3e|\\n", "abcdef", "3.14159", "1234.5"],
    ["%g %g %g %g %G\\n", "0.0001", "1e10", "100000", "1234567", "0.00001"],
    ["%*d|%-*d|%.*f\\n", "5", "42", "4", "7", "2", "3.14159"],
    ["%.0d|%.3d|%08.3d|\\n", "0", "7", "7"],
    ["%d %d %d\\n", "'A", '"B', "0x1f"],
    ["%d\\n", "abc"],
    ["%d\\n", "12abc"],
    ["%d\\n", "99999999999999999999"],
    ["%x %o\\n", "08", "0x"],
    ["%s %s\\n", "a", "b", "c"],
    ["%s\\n"],
    ["%b|\\n", "a\\tb", "c\\0101d", "e\\x41f"],
    ["x%by\\n", "stop\\cnow", "more"],
    ["\\101\\0101\\x41\\u00e9\\n"],
    ["%q\\n", "a b", "it's", "", "~a", "a~", "#a", "a#", "a,b", "*?[]", "{x}", "a\tb", "\x01"],
    ["%e %E %f %F\\n", "1.5", "-2.25e-5", "1e300", "inf"],
    ["%a %A %.3a\\n", "1", "0.1", "1.999999"],
    ["%.0f %.0f %.0f %.2f\\n", "0.5", "1.5", "2.5", "2.675"],
    ["%#g %#.3g %g %g\\n", "1", "1", "1e-5", "123456789"],
    ["%.17g %.20g %08.3f|%-8.2e|\\n", "0.1", "0.1", "-1.5", "-2.5"],
    ["%f\\n", "3.5abc"],
    ["%c%c|%5c|\\n", "hello", "w", "x"],
    ["%5%"],
    ["%z"],
    ["abc%"],
    ["-%s\\n", "x"],
]


class PrintfTests(unittest.TestCase):
    def test_printf_matches_bash(self):
        for case in PRINTF_CASES:
            command = "printf " + " ".join(shlex.quote(arg) for arg in case)
            with self.subTest(command=command):
                ours = run_shell(command)
                theirs = run_bash(command)
                self.assertEqual(ours.stdout, theirs.stdout)
                self.assertEqual(ours.returncode, theirs.returncode)
                self.assertEqual(bool(ours.stderr), bool(theirs.stderr))

    def test_invalid_number_is_reported(self):
        result = run_shell("printf '%d\\n' abc")
        self.assertEqual(result.stdout, b"0\n")
        self.assertEqual(result.stderr, b"wsh: printf: abc: invalid number\n")
        self.assertEqual(result.returncode, 1)

    def test_time_conversion_matches_bash(self):
        command = ("printf '%(%F %T %a %b %e %j %z %Z)T|%(%s %U %W %V %G)T\\n' 0 0 1719835200 1719835200 "
                   "1705320000 1705320000 4102444800 4102444800; printf '[%20(%F)T][%-6(%y)T][%.4(%Y)T]\\n' 0 0 0")
        for tz in ("UTC", "Europe/London", "America/New_York", "AEST-10AEDT,M10.1.0,M4.1.0/3"):
            with self.subTest(tz=tz):
                env = dict(os.environ, TZ=tz, LC_ALL="C")
                self.assertEqual(run_shell(command, env=env).stdout, run_bash(command, env=env).stdout)
        now = run_shell("printf '%(%s)T'")
        self.assertLess(abs(int(now.stdout) - int(time.time())), 5)

    def test_printf_v_assigns(self):
        result = run_shell("printf -v out '%s-%03d' x 7; echo \"[$out]\"")
        self.assertEqual(result.stdout, b"[x-007]\n")
        self.assertEqual(result.returncode, 0)


class ReadTests(unittest.TestCase):
    def assert_same(self, ours, theirs):
        wsh = run_shell(ours)
        bash = run_bash(theirs)
        self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)
        self.assertEqual(wsh.returncode, bash.returncode)

    def test_eof_status_and_partial_line(self):
        script = 'printf "abc" | { read x; echo "rc=$? x=[$x]"; }; printf "" | { read y; echo "rc=$? y=[$y]"; }'
        self.assert_same(script, script)

    def test_while_read_terminates(self):
        ours = ('printf "a\\nb" | { while true { read -r "line"; let st = "$?"; if st != 0 { break }; '
                'echo "got $line"; }; echo "last=[$line]"; }')
        theirs = 'printf "a\\nb" | { while read -r line; do echo "got $line"; done; echo "last=[$line]"; }'
        self.assert_same(ours, theirs)

    def test_posix_while_read_once_supported(self):
        script = 'printf "1\\n2\\n" | { n=0; while read -r "v"; do n=$((n + v)); done; echo "sum=$n"; }'
        check = subprocess.run([str(SHELL), "--no-config", "-n", "-c", script], capture_output=True, timeout=10)
        if check.returncode != 0:
            self.skipTest("POSIX while/do loops are not parsed by this build")
        self.assert_same(script, script)

    def test_ifs_prefix_assignment_splits(self):
        script = 'IFS=: read -r a b <<< "x:y"; echo "[$a] [$b]"; IFS=: read -r c d e <<< "1::3:"; echo "[$c] [$d] [$e]"'
        self.assert_same(script, script)

    def test_ifs_prefix_shadows_shell_variable(self):
        script = 'IFS=,; IFS=: read -r a b <<< "x:y"; echo "[$a] [$b] [$IFS]"'
        self.assert_same(script, script)

    def test_field_splitting_rules(self):
        # Names are quoted because wsh expands a bare word that names a variable.
        script = (
            'read "a" "b" <<< "  one two  three  "; echo "[$a] [$b]"; '
            'read "a" "b" <<< "x\\ y z"; echo "[$a] [$b]"; '
            'read -r "a" "b" <<< "x\\ y z"; echo "[$a] [$b]"; '
            'IFS=: read "a" "b" <<< "x:y:"; echo "[$a] [$b]"; '
            'IFS=: read "a" "b" <<< "x:y::"; echo "[$a] [$b]"; '
            'printf "  keep  \\n" | { read; echo "[$REPLY]"; }'
        )
        self.assert_same(script, script)

    def test_character_counts_and_delimiters(self):
        script = (
            'printf "abcdef" | { read -n 3 x; echo "rc=$? [$x]"; }; '
            'printf "ab\\ncdef" | { read -n 3 x; echo "rc=$? [$x]"; }; '
            'printf "ab\\ncdef" | { read -N 4 x; echo "rc=$? [$x]"; }; '
            'printf "ab" | { read -n 3 x; echo "rc=$? [$x]"; }; '
            'printf "a:b:c" | { read -d : x; read -d : y; echo "[$x] [$y]"; }; '
            'printf "a\\0b\\0" | { read -r -d "" x; echo "rc=$? [$x]"; }'
        )
        self.assert_same(script, script)

    def test_array_option_stores_a_list(self):
        ours = 'read -a "arr" <<< "a b  c"; printf "<%s>" $arr; echo'
        theirs = 'read -a arr <<< "a b  c"; printf "<%s>" "${arr[@]}"; echo'
        self.assert_same(ours, theirs)

    def test_timeout_reports_status_above_128(self):
        script = 'sleep 1 | { read -t 0.2 x; echo "rc=$?"; }'
        self.assert_same(script, script)

    def test_invalid_options_and_names(self):
        for script in ("read -z x <<< a", "read 1x <<< a", "read -n abc x <<< a", "read -t abc x <<< a", "read -u 9 x"):
            with self.subTest(script=script):
                wsh = run_shell(script)
                bash = run_bash(script)
                self.assertEqual(wsh.returncode, bash.returncode)
                self.assertTrue(wsh.stderr.startswith(b"wsh: read: "))


class GetoptsTests(unittest.TestCase):
    def test_getopts_loop_matches_bash(self):
        body_wsh = ('fn parse() { OPTIND=1; while true { getopts ":ab:c" "o" "$@"; let st = "$?"; '
                    'if st != 0 { break }; echo "o=$o arg=${OPTARG:-} ind=$OPTIND"; }; echo "end ind=$OPTIND"; }; ')
        body_bash = ('parse() { OPTIND=1; while getopts ":ab:c" o "$@"; do '
                     'echo "o=$o arg=${OPTARG:-} ind=$OPTIND"; done; echo "end ind=$OPTIND"; }; ')
        calls = "parse -a -b val -c rest; parse -ac -bval x; parse -x -b; parse -- -a; parse -a - b"
        wsh = run_shell(body_wsh + calls)
        bash = run_bash(body_bash + calls)
        self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)

    def test_diagnostics_without_silent_mode(self):
        wsh = run_shell('getopts "a:" "o" -x; echo "o=$o"; OPTIND=1; getopts "a:" "o" -a; echo "o=$o"')
        self.assertEqual(wsh.stdout, b"o=?\no=?\n")
        self.assertIn(b"illegal option -- x", wsh.stderr)
        self.assertIn(b"option requires an argument -- a", wsh.stderr)

    def test_usage_errors(self):
        self.assertEqual(run_shell("getopts").returncode, 2)
        self.assertEqual(run_shell("getopts ab 1x -a").returncode, 1)


class MapfileTests(unittest.TestCase):
    def test_mapfile_options_match_bash(self):
        cases = [
            ('mapfile -t "arr" <<< "a\nb\nc"; printf "<%s>" $arr; echo',
             'mapfile -t arr <<< "a\nb\nc"; printf "<%s>" "${arr[@]}"; echo'),
            ('printf "l1\\nl2\\nl3\\nl4\\n" | { mapfile -t -s 1 -n 2 "arr"; printf "<%s>" $arr; echo; }',
             'printf "l1\\nl2\\nl3\\nl4\\n" | { mapfile -t -s 1 -n 2 arr; printf "<%s>" "${arr[@]}"; echo; }'),
            ('printf "a:b:c" | { readarray -t -d : "arr"; printf "<%s>" $arr; echo; }',
             'printf "a:b:c" | { readarray -t -d : arr; printf "<%s>" "${arr[@]}"; echo; }'),
            ('mapfile <<< "m"; printf "<%s>" "$MAPFILE"; echo',
             'mapfile <<< "m"; printf "<%s>" "${MAPFILE[@]}"; echo'),
        ]
        for ours, theirs in cases:
            with self.subTest(script=theirs):
                wsh = run_shell(ours)
                bash = run_bash(theirs)
                self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)
                self.assertEqual(wsh.returncode, bash.returncode)

    def test_callback_runs_per_quantum(self):
        wsh = run_shell('fn cb() { echo "cb $1 [$2]" }; mapfile -t -C cb -c 1 "arr" <<< "u\nv"')
        self.assertEqual(wsh.stdout, b"cb 0 [u]\ncb 1 [v]\n")

    def test_invalid_arguments(self):
        for script in ("mapfile -t 1x <<< a", "mapfile -u 9 arr", "mapfile -n x arr <<< a"):
            with self.subTest(script=script):
                self.assertEqual(run_shell(script).returncode, run_bash(script).returncode)


class UlimitTests(unittest.TestCase):
    def test_open_files_matches_bash(self):
        for script in ("ulimit -n", "ulimit -Hn", "ulimit -S -n 256; ulimit -n", "ulimit -c -n", "ulimit -p"):
            with self.subTest(script=script):
                self.assertEqual(run_shell(script).stdout, run_bash(script).stdout)

    def test_errors(self):
        self.assertEqual(run_shell("ulimit -n abc").returncode, 1)
        self.assertEqual(run_shell("ulimit -z").returncode, 2)
        result = run_shell("ulimit -a")
        self.assertIn(b"open files                          (-n) ", result.stdout)
        self.assertEqual(result.stdout.count(b"\n"), 17)


class TypeTests(unittest.TestCase):
    def test_type_t_matches_bash(self):
        names = "ll if then fi do done case '[[' '{' '!' time in echo cd ls definitely-missing-xyz"
        wsh = run_shell(f"alias ll='ls -l'; fn f() {{ echo hi }}; type -t f {names}; echo rc=$?")
        bash = run_bash(f"shopt -s expand_aliases; alias ll='ls -l'; f() {{ echo hi; }}; type -t f {names}; echo rc=$?")
        self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)

    def test_type_and_command_forms(self):
        for script in ("type -p ls echo; echo rc=$?", "type -P echo", "type ls if echo",
                       "command -v ls if echo missing-xyz; echo rc=$?", "command -V echo",
                       "PATH=/nonexistent command -pv sh", "type -x ls; echo rc=$?"):
            with self.subTest(script=script):
                wsh = run_shell(script)
                bash = run_bash(script)
                self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)

    def test_command_p_uses_the_standard_path(self):
        result = run_shell("PATH=/nonexistent command -p sh -c 'echo ran'")
        self.assertEqual(result.stdout, b"ran\n")


class MiscBuiltinTests(unittest.TestCase):
    def test_help(self):
        listing = run_shell("help")
        self.assertEqual(listing.returncode, 0)
        self.assertIn(b"read", listing.stdout)
        self.assertIn(b"language overview", listing.stdout)
        one = run_shell("help getopts")
        self.assertEqual(one.stdout.splitlines()[0], b"getopts: getopts optstring name [arg ...]")
        missing = run_shell("help definitely-missing")
        self.assertEqual(missing.returncode, 1)
        self.assertIn(b"no help topics match", missing.stderr)

    def test_hash_is_truthful(self):
        result = run_shell("hash; hash -r; hash sh; echo rc=$?; hash -t sh; hash missing-xyz; echo rc=$?")
        self.assertEqual(result.stdout.splitlines()[0], b"hash: hash table empty")
        self.assertIn(b"rc=0", result.stdout)
        self.assertIn(b"rc=1", result.stdout)
        self.assertNotEqual(run_shell("hash -p /bin/sh x").returncode, 0)

    def test_umask_forms_match_bash(self):
        script = ("umask 022; umask; umask -S; umask -p; umask -p -S; umask u=rwx,g=rx,o=; umask; "
                  "umask g+w; umask; umask o-x,a+r; umask; umask -S 077; umask 999; echo rc=$?")
        wsh = run_shell(script)
        bash = run_bash(script)
        self.assertEqual(wsh.stdout, bash.stdout)

    def test_times_and_logout(self):
        self.assertRegex(run_shell("times").stdout, rb"^\d+m\d+\.\d{3}s \d+m\d+\.\d{3}s\n\d+m\d+\.\d{3}s \d+m\d+\.\d{3}s\n$")
        result = run_shell("logout; echo rc=$?")
        self.assertEqual(result.stdout, b"rc=1\n")
        self.assertIn(b"not login shell", result.stderr)
        login = subprocess.run([str(SHELL), "--no-config", "-l", "-c", "logout 3; echo unreachable"],
                               capture_output=True, timeout=10)
        self.assertEqual(login.returncode, 3)
        self.assertEqual(login.stdout, b"")

    def test_export_readonly_alias_listings(self):
        # Names are quoted because wsh expands a bare word that names a variable.
        script = ("export WSH_COMPAT_X='a\"b$c'; export -p | grep 'WSH_COMPAT'; "
                  "export -n WSH_COMPAT_X; echo \"[$WSH_COMPAT_X]\"; export -p | grep -c 'WSH_COMPAT'; "
                  "readonly WSH_RO=1; readonly -p | grep 'WSH_RO'; "
                  "alias b1=ls a1=\"echo it's\"; alias -p; unalias -a; alias -p; unalias missing; echo rc=$?")
        wsh = run_shell(script)
        bash = run_bash(script)
        self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)

    def test_directory_stack_matches_bash(self):
        script = ("cd /tmp; pushd /usr; pushd /; dirs; dirs -v; dirs -p; dirs +1; dirs -0; "
                  "pushd +2; popd +1; popd; pwd; popd; echo rc=$?; pushd; echo rc=$?; dirs -c; dirs")
        wsh = run_shell(script)
        bash = run_bash(script)
        self.assertEqual(wsh.stdout, bash.stdout, wsh.stderr)

    def test_jobs_and_disown(self):
        result = run_shell("sleep 5 > /dev/null & sleep 6 > /dev/null & jobs -p | wc -l; jobs -r %1; disown %1; jobs; "
                           "disown -h %2; jobs -l %2 | wc -l; kill %2; disown -a; jobs; disown %9; echo rc=$?")
        lines = result.stdout.decode().splitlines()
        self.assertEqual(lines[0].strip(), "2")
        self.assertRegex(lines[1], r"^\[1\] - Running  sleep 5")
        self.assertRegex(lines[2], r"^\[2\] \+ Running  sleep 6")
        self.assertEqual(lines[3].strip(), "1")
        self.assertEqual(lines[4], "rc=1")
        self.assertIn(b"%9: no such job", result.stderr)


class InteractiveReadTests(unittest.TestCase):
    def setUp(self):
        self.session = Session()
        self.assertTrue(self.session.read_until(b"\xe2\x9d\xaf"), "the shell never drew a prompt")

    def tearDown(self):
        self.session.close()

    # The read prompt also appears in the echoed command line, so wait for it
    # at the start of a fresh line: typing earlier would race the editor.
    def test_silent_read_does_not_echo(self):
        s = self.session
        s.clear()
        s.send('read -s -p "pw: " "pw"; echo "got=$pw"\r')
        self.assertTrue(s.read_until(b"\npw: "), strip_ansi(s.buf))
        s.clear()
        s.send("hunter2\r")
        self.assertTrue(s.read_until(b"got=hunter2"), strip_ansi(s.buf))
        self.assertNotIn(b"hunter2", strip_ansi(s.buf).replace(b"got=hunter2", b""))

    def test_single_character_read_returns_without_enter(self):
        s = self.session
        s.clear()
        s.send('read -n 1 -p "key? " "key"; echo "|key=$key"\r')
        self.assertTrue(s.read_until(b"\nkey? "), strip_ansi(s.buf))
        s.send("x")
        self.assertTrue(s.read_until(b"|key=x"), strip_ansi(s.buf))

if __name__ == "__main__":
    unittest.main()
