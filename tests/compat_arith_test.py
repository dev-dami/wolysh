#!/usr/bin/env python3
"""End-to-end checks for arithmetic expansion and the `test` builtin.

Most rows run in both wsh and bash and must agree with each other and with the
expected value. Rows whose bash behaviour changed between releases, and error
messages, are checked against the bash 5.3 results recorded here.
"""
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
BASH = shutil.which("bash")

MIN = "-9223372036854775808"

# (expression, value) pairs; each runs as `echo $(( expression ))`.
EXPRESSIONS = [
    # precedence and associativity
    ("1 + 2 * 3", "7"),
    ("(1 + 2) * 3", "9"),
    ("10 - 4 - 3", "3"),
    ("100 / 10 / 5", "2"),
    ("2 ** 3 ** 2", "512"),
    ("-2 ** 2", "4"),
    ("2 ** 0", "1"),
    ("7 % -3", "1"),
    ("-7 / 2", "-3"),
    ("-7 % 3", "-1"),
    ("1 + 2 << 1", "6"),
    ("-8 >> 1", "-4"),
    ("1 << 62", "4611686018427387904"),
    ("1 < 2 == 1", "1"),
    ("3 <= 3", "1"),
    ("3 >= 4", "0"),
    ("3 != 4", "1"),
    ("5 > 3 > 0", "1"),
    ("5 & 3 | 8 ^ 2", "11"),
    ("6 ^ 3", "5"),
    ("!0 + ~0", "0"),
    ("~5", "-6"),
    ("!!7", "1"),
    ("- -5", "5"),
    ("1 || 0 && 0", "1"),
    ("2 && 3", "1"),
    ("0 || 0", "0"),
    ("1, 2, 3", "3"),
    ("1 ? 2 : 3 ? 4 : 5", "2"),
    ("0 ? 2 : 0 ? 4 : 5", "5"),
    ("(5 > 3) ? 10 : 20", "10"),
    ("\t1\t+\t2 ", "3"),
    ("", "0"),
    # 64-bit wrapping, including the cases that used to trap
    ("(-9223372036854775807-1) / -1", MIN),
    ("(-9223372036854775807-1) % -1", "0"),
    ("-(-9223372036854775807-1)", MIN),
    ("9223372036854775807 + 1", MIN),
    ("-9223372036854775807 - 3", "9223372036854775806"),
    ("9223372036854775807 * 2", "-2"),
    ("2 ** 63", MIN),
    ("3 ** 40", "-6289078614652622815"),
    ("9223372036854775808", MIN),
    # literals
    ("0xff", "255"),
    ("0X1F", "31"),
    ("017", "15"),
    ("0", "0"),
    ("16#ff", "255"),
    ("2#1010", "10"),
    ("8#17", "15"),
    ("10#09", "9"),
    ("36#z", "35"),
    ("36#Z", "35"),
    ("37#z", "35"),
    ("37#A", "36"),
    ("64#@", "62"),
    ("64#_", "63"),
    # skipped operands are not evaluated
    ("0 && 1 / 0", "0"),
    ("1 || 1 / 0", "1"),
    ("0 ? 1 / 0 : 2", "2"),
]

# `test` rows recorded from bash 5.3; bash 5.2 returns 1 for `-t abc`.
TEST_CASES_BASH_5_3 = [
    ("-t abc", 2),
]

# Rows recorded from bash 5.3, whose handling differs in some older releases.
EXPRESSIONS_BASH_5_3 = [
    ("0 && 2 ** -1", "0"),
    ("++5", "5"),
    ("--5", "5"),
    ("1 << 64", "1"),
    ("1 << 65", "2"),
    ("1 << -1", MIN),
    ("99999999999999999999", "7766279631452241919"),
    ("0x", "0"),
]

# (script, stdout) pairs that exercise variables and assignment.
SCRIPTS = [
    ("i=5; echo $(( i++ )) $i $(( ++i )) $i $(( i-- )) $(( --i )) $i", "5 6 7 7 7 5 5\n"),
    ("x=3; echo $(( x+++1 )) $x $(( x---1 )) $x", "4 4 3 3\n"),
    ("x=3; echo $(( x ++ )) $x $(( - --x )) $x", "3 4 -3 3\n"),
    ("i=0; echo $(( i++ + i++ )) $i", "1 2\n"),
    ("c=0; echo $(( c++ )) $(( c++ )) $(( c++ )); echo $c", "0 1 2\n3\n"),
    (
        "a=7; echo $(( a /= 2 )) $(( a %= 2 )) $(( a <<= 4 )) $(( a >>= 1 )) $(( a &= 12 ))"
        " $(( a ^= 5 )) $(( a |= 16 )) $(( a += 1 )) $(( a -= 2 )) $(( a *= 2 )) $a",
        "3 1 16 8 8 13 29 30 28 56 56\n",
    ),
    ("echo $(( a = b = 5 )) $a $b", "5 5 5\n"),
    ("echo $(( c = 1, c += 2, c *= 3, c )) $c", "9 9\n"),
    ("echo $((x=1)) $((y = x ? 10 : 20)) $y", "1 10 10\n"),
    ("echo $(( 1 ? a = 2 : 3 )) $a", "2 2\n"),
    ('x="1+2"; echo $(( $x * 3 )) $(( x * 3 ))', "7 9\n"),
    ('x="2+3"; y=x; echo $(( y * 2 ))', "10\n"),
    ("x=010; echo $(( x + 0 ))", "8\n"),
    ('x=" 7 "; echo $(( x + 1 ))', "8\n"),
    ("x=; echo $(( x + 1 )) $(( never_set + 1 ))", "1 1\n"),
    ("x=5; echo $(( ${x} * 2 )) $(( ${x:-3} )) $(( ${never_set:-3} ))", "10 5 3\n"),
    ("echo $(( $(echo 6) * 7 )) $(( `echo 6` * 7 ))", "42 42\n"),
    ('echo $(( "1" + 2 ))', "3\n"),
    ('x=3; echo "$(( x * 2 ))" "$((x++))" $x', "6 3 4\n"),
    ('export E=1; echo $(( E += 5 )); printenv "E"', "6\n6\n"),
    (
        "echo $(( 0 && (y = 5) )) $(( 1 || (z = 5) )) $(( 1 ? 2 : (w = 9) )) $(( 0 ? (v = 1) : 3 ));"
        " echo y=$y z=$z w=$w v=$v",
        "0 1 2 3\ny= z= w= v=\n",
    ),
    ("bad=1/0; echo $(( 0 && bad ))", "0\n"),
    ("x=x; echo $(( 0 && x ))", "0\n"),
    # `$(( ))` inside the expression expands before evaluation, as in bash.
    ("echo $(( 0 && $(( q = 5 )) )); echo q=$q", "0\nq=5\n"),
]

# (expression, wsh's message) for failing expansions; bash exits 1 too.
ERRORS = [
    ("1 / 0", 'wsh: 1 / 0 : division by 0 (error token is "0 ")'),
    ("1 +", 'wsh: 1 + : arithmetic syntax error: operand expected (error token is "+ ")'),
    ("1 2", 'wsh: 1 2 : arithmetic syntax error in expression (error token is "2 ")'),
    ("2 ** -1", 'wsh: 2 ** -1 : exponent less than 0 (error token is "1 ")'),
    ("08", 'wsh: 08 : value too great for base (error token is "08 ")'),
    ("65#1", 'wsh: 65#1 : invalid arithmetic base (error token is "65#1 ")'),
    ("1 ? 2", "wsh: 1 ? 2 : `:' expected for conditional expression (error token is \"2 \")"),
    ("5 = 3", 'wsh: 5 = 3 : attempted assignment to non-variable (error token is "= 3 ")'),
    ("1 @ 2", 'wsh: 1 @ 2 : arithmetic syntax error: invalid arithmetic operator (error token is "@ 2 ")'),
    ("a /= 0", 'wsh: a /= 0 : division by 0 (error token is "0 ")'),
]


def run(argv, command, cwd):
    return subprocess.run(argv + [command], cwd=cwd, capture_output=True, timeout=10, check=False)


def run_shell(command, cwd=ROOT):
    return run([str(SHELL), "--no-config", "-c"], command, cwd)


def run_bash(command, cwd=ROOT):
    return run([BASH, "-c"], command, cwd)


class ArithmeticTests(unittest.TestCase):
    def assert_output(self, command, stdout, compare_bash=True):
        result = run_shell(command)
        self.assertEqual(result.stdout.decode(), stdout, f"wsh: {command!r} stderr={result.stderr!r}")
        self.assertEqual(result.returncode, 0, f"wsh: {command!r} stderr={result.stderr!r}")
        if compare_bash and BASH:
            expected = run_bash(command)
            self.assertEqual(expected.stdout.decode(), stdout, f"bash: {command!r}")

    def test_expressions_match_bash(self):
        for expression, value in EXPRESSIONS:
            with self.subTest(expression=expression):
                self.assert_output(f"echo $(( {expression} ))", value + "\n")

    def test_expressions_match_bash_5_3(self):
        for expression, value in EXPRESSIONS_BASH_5_3:
            with self.subTest(expression=expression):
                self.assert_output(f"echo $(( {expression} ))", value + "\n", compare_bash=False)

    def test_variables_and_assignments_match_bash(self):
        for command, stdout in SCRIPTS:
            with self.subTest(command=command):
                self.assert_output(command, stdout)

    def test_errors_name_the_problem(self):
        for expression, message in ERRORS:
            with self.subTest(expression=expression):
                result = run_shell(f"echo $(( {expression} ))")
                self.assertEqual(result.returncode, 1)
                self.assertEqual(result.stdout, b"")
                self.assertEqual(result.stderr.decode(), message + "\n")
                if BASH:
                    self.assertEqual(run_bash(f"echo $(( {expression} ))").returncode, 1)

    def test_recursive_variable_is_an_error(self):
        result = run_shell("x=x; echo $(( x ))")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stderr.decode(), 'wsh: x: expression recursion level exceeded (error token is "x")\n'
        )

    def test_readonly_variable_is_not_assigned(self):
        result = run_shell("readonly r=1; echo $(( r = 2 )); echo r=$r")
        self.assertEqual(result.stderr.decode(), "wsh: r: readonly variable\n")
        self.assertEqual(result.stdout, b"r=1\n")

    def test_minimum_integer_division_does_not_crash(self):
        result = run_shell("echo $(( (-9223372036854775807-1) / -1 )) $(( (-9223372036854775807-1) % -1 ))")
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stdout.decode(), MIN + " 0\n")


# Argument strings for `test`, with the expected status.
TEST_CASES = [
    ("", 1),
    ("''", 1),
    ("x", 0),
    ("-n", 0),
    ("!", 0),
    ("-z", 0),
    ("! x", 1),
    ("! ''", 0),
    ("x y", 2),
    ("-q y", 2),
    ("-n ''", 1),
    ("-z ''", 0),
    ("! = x", 1),
    ("! = !", 0),
    ("-n = -n", 0),
    ("'(' = '('", 0),
    ("-f -a -f", 0),
    ("'' -o b", 0),
    ("'' -a b", 1),
    ("'(' '' ')'", 1),
    ("'(' x ')'", 0),
    ("a b c", 2),
    ("! -n ''", 0),
    ("x -a '('", 0),
    ("! a = b", 0),
    ("! a = a", 1),
    ("'(' -n x ')'", 0),
    ("'(' ! x ')'", 1),
    ("! ! x", 0),
    ("a b c d", 2),
    ("1 -eq 1 -a 2 -eq 2 -o 3 -eq 4", 0),
    ("1 -lt 2 -lt 3", 2),
    ("x -a '(' y -o '' ')'", 0),
    ("'' -o '' -o x", 0),
    ("-n x -a -z '' -o -e /nonexistent", 0),
    ("a = b -o '(' c = c ')'", 0),
    ("! ! ! x", 1),
    ("' 5 ' -eq 5", 0),
    ("+5 -eq 5", 0),
    ("-5 -lt 0", 0),
    ("08 -eq 8", 0),
    ("-9223372036854775808 -lt 9223372036854775807", 0),
    ("3 -ge 3", 0),
    ("3 -ne 3", 1),
    ("2 -le 1", 1),
    ("2 -gt 1", 0),
    ("abc -eq 1", 2),
    ("'' -eq 0", 2),
    ("0x10 -eq 16", 2),
    ("'5 5' -eq 5", 2),
    ("99999999999999999999 -eq 1", 2),
    ("a '<' b", 0),
    ("b '<' a", 1),
    ("B '<' a", 0),
    ("a '>' b", 1),
    ("a '<' a", 1),
    ("a == a", 0),
    ("a != a", 1),
    ("-t 99", 1),
    ("-v never_set_name", 1),
    ("-v HOME", 0),
    ("-o errexit", 1),
    ("-o no_such_option", 1),
    ("-c /dev/null", 0),
    ("-b /dev/null", 1),
    ("-e ''", 1),
    ("-a /", 0),
    ("/ -ef /", 0),
    ("/ -ef /dev", 1),
    ("/nonexistent -ef /nonexistent", 1),
    ("/ -nt /nonexistent", 0),
    ("/nonexistent -nt /", 1),
    ("/nonexistent -ot /", 0),
    ("/ -ot /nonexistent", 1),
]

# Argument strings checked in a directory of prepared files.
FILE_CASES = [
    "-f file", "-f dir", "-d dir", "-e missing", "-a file", "-s file", "-s empty",
    "-h link", "-L link", "-L file", "-h dangling", "-e dangling", "-f link",
    "-p fifo", "-p file", "-S sock", "-S file", "-u setuid", "-u file", "-g setgid",
    "-g file", "-k sticky", "-k dir", "-O file", "-G file", "-r file", "-w file",
    "-x file", "-x exec", "-N modified", "-N read", "new -nt old", "old -nt new",
    "old -ot new", "new -ot old", "file -nt missing", "missing -ot file",
    "file -ef hardlink", "file -ef link", "file -ef empty",
]


class TestBuiltinTests(unittest.TestCase):
    def check(self, args, want, cwd=ROOT, compare_bash=True):
        for name, command in (("test", f"test {args}"), ("[", f"[ {args} ]")):
            with self.subTest(command=command):
                result = run_shell(command, cwd)
                self.assertEqual(result.returncode, want, f"{command!r}: stderr={result.stderr!r}")
                self.assertEqual(result.stdout, b"")
                if want == 2:
                    self.assertTrue(result.stderr.startswith(f"wsh: {name}: ".encode()), result.stderr)
                if compare_bash and BASH:
                    self.assertEqual(run_bash(command, cwd).returncode, want, f"bash: {command!r}")

    def test_argument_rules_and_operators_match_bash(self):
        for args, want in TEST_CASES:
            self.check(args, want)

    def test_argument_rules_match_bash_5_3(self):
        for args, want in TEST_CASES_BASH_5_3:
            self.check(args, want, compare_bash=False)

    def test_file_operators_match_bash(self):
        if not BASH:
            self.skipTest("bash is not installed")
        with tempfile.TemporaryDirectory(prefix="wsh-test-") as temp_dir:
            d = pathlib.Path(temp_dir)
            (d / "file").write_text("data")
            (d / "empty").write_text("")
            (d / "dir").mkdir()
            (d / "link").symlink_to("file")
            (d / "dangling").symlink_to("missing")
            os.link(d / "file", d / "hardlink")
            os.mkfifo(d / "fifo")
            server = socket.socket(socket.AF_UNIX)
            server.bind(str(d / "sock"))
            for name, mode in (("setuid", 0o4644), ("setgid", 0o2644), ("exec", 0o755)):
                (d / name).write_text("")
                os.chmod(d / name, mode)
            (d / "sticky").mkdir()
            os.chmod(d / "sticky", 0o1777)
            for name, atime, mtime in (("modified", 1_000, 2_000), ("read", 2_000, 1_000), ("old", 1_000, 1_000), ("new", 5_000, 5_000)):
                (d / name).write_text("x")
                os.utime(d / name, (atime, mtime))
            try:
                for args in FILE_CASES:
                    expected = run_bash(f"test {args}", d).returncode
                    self.assertIn(expected, (0, 1), args)
                    self.check(args, expected, d)
            finally:
                server.close()

    def test_bracket_requires_closing_bracket(self):
        result = run_shell("[ a = a")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b"wsh: [: missing `]'\n")
        result = run_shell("[ a = a ] ]")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stderr, b"wsh: [: too many arguments\n")

    def test_messages_name_the_problem(self):
        cases = [
            ("test abc -eq 1", "wsh: test: abc: integer expression expected"),
            ("test 1 -eq ''", "wsh: test: : integer expression expected"),
            ("test -t abc", "wsh: test: abc: integer expression expected"),
            ("test x y", "wsh: test: x: unary operator expected"),
            ("test a b c", "wsh: test: b: binary operator expected"),
            ("test a b c d", "wsh: test: too many arguments"),
            ("test '(' a = a", "wsh: test: `)' expected"),
            ("test 1 -lt 2 -lt 3", "wsh: test: syntax error: `-lt' unexpected"),
        ]
        for command, message in cases:
            with self.subTest(command=command):
                result = run_shell(command)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stderr.decode(), message + "\n")

    def test_variables_set_in_the_shell(self):
        result = run_shell('x=1; y=; test -v "x" && test -v "y" && ! test -v "never_set_name" && echo ok')
        self.assertEqual(result.stdout, b"ok\n")


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
