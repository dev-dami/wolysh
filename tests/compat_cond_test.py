#!/usr/bin/env python3
"""End-to-end checks for `[[ ]]`, `(( ))` and `for (( ))`.

Each row runs in wsh and, when it is installed, in bash; both must print the
recorded output and exit with the recorded status. Error messages are checked
against wsh's wording only.
"""
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
BASH = shutil.which("bash")
# `<` and `>` in `[[ ]]` collate by locale in bash; wsh compares bytes.
ENV = dict(os.environ, LC_ALL="C")

# (command, stdout, status)
CONDITIONALS = [
    ("[[ -f /etc/passwd ]] && echo file; [[ -d /etc && ! -f /etc ]] && echo dir", "file\ndir\n", 0),
    ("[[ abc == a* ]] && echo glob; [[ abc == \"a*\" ]] || echo quoted", "glob\nquoted\n", 0),
    ("p='a*'; [[ abc == $p ]] && echo var; [[ abc == \"$p\" ]] || echo literal", "var\nliteral\n", 0),
    ("[[ abc != b* ]] && echo ne; [[ abc = abc ]] && echo eq", "ne\neq\n", 0),
    ("[[ abc == @(abc|def) ]] && echo extglob; [[ abc == *\"b\"* ]] && echo mixed", "extglob\nmixed\n", 0),
    ("x=3; [[ $x == [0-9] ]] && echo digit; [[ $x == [!0-9] ]] || echo not-other", "digit\nnot-other\n", 0),
    ("[[ b < c ]] && echo lt; [[ c > b ]] && echo gt; [[ 10 < 9 ]] && echo bytes", "lt\ngt\nbytes\n", 0),
    ("[[ 1+1 -eq 2 ]] && echo arith; x=3; [[ x -gt 2 ]] && echo name; [[ $x -le 3 ]] && echo le", "arith\nname\nle\n", 0),
    ("[[ -n \"\" ]] || echo empty; [[ \"\" ]] || echo bare-empty; [[ x ]] && echo bare", "empty\nbare-empty\nbare\n", 0),
    ("v=\"a b\"; [[ $v == \"a b\" ]] && echo no-split; [[ * == \\* ]] && echo no-glob", "no-split\nno-glob\n", 0),
    ("[[ ( a == a || a == b ) && ! b == a ]] && echo grouped", "grouped\n", 0),
    ("[[ 5 -gt 3 && 2 -lt 1 || 1 -eq 1 ]] && echo precedence", "precedence\n", 0),
    ("[[ ! a == b && ! b == c ]] && echo negations", "negations\n", 0),
    ("[[ -e /nonexistent || -d / ]] && echo or", "or\n", 0),
    ("[[ a == b ]]; echo $?; ! [[ a == b ]] && echo inverted", "1\ninverted\n", 0),
    ("[[ a &&\nb ]] && echo multi-line", "multi-line\n", 0),
    ("[[ \"a\nb\" == *$'\\n'* ]] && echo newline; [[ a$'\\t'b == a?b ]] && echo ansi-c", "newline\nansi-c\n", 0),
    ("x=\" a \"; [[ $x == \" a \" ]] && echo spaces; [[ ~ == $HOME ]] && echo tilde", "spaces\ntilde\n", 0),
    ("if [[ $(echo hi) == hi ]]; then echo substitution; fi", "substitution\n", 0),
    ("s=$( [[ a < b ]] && echo inside ); echo $s", "inside\n", 0),
    ("case x in x) [[ 1 -eq 1 ]] && echo in-case;; esac", "in-case\n", 0),
    ("f() { [[ $1 == y* ]]; }; f yes && echo function", "function\n", 0),
    ("i=0; while [[ $i -lt 3 ]]; do i=$((i+1)); done; echo $i", "3\n", 0),
    ("v=hello; until [[ ${#v} -le 2 ]]; do v=${v%?}; done; echo $v", "he\n", 0),
    ("[[ -o errexit ]] || echo off", "off\n", 0),
    ("shopt -s nocasematch; [[ ABC == abc ]] && echo nocase; [[ ABC =~ ^abc$ ]] && echo nocase-re", "nocase\nnocase-re\n", 0),
    ("x=a; [[ $x == a ]] && [[ -n $x ]] | cat; echo \"${PIPESTATUS[@]}\"", "0 0\n", 0),
    # -v follows bash: a bare array name means element 0.
    ("x=; [[ -v x ]] && echo set; [[ -v never_set ]] || echo unset; set -- one; [[ -v 1 ]] && echo positional", "set\nunset\npositional\n", 0),
    ("a=(1 '' 3); [[ -v a[1] ]] && echo element; [[ -v a[5] ]] || echo no-element; b=(); [[ -v b ]] || echo empty-array", "element\nno-element\nempty-array\n", 0),
    ("c=([2]=v); [[ -v c ]] || echo no-zero; declare -A m=([k]=1); [[ -v m[k] ]] && echo key; [[ -v m[z] ]] || echo no-key", "no-zero\nkey\nno-key\n", 0),
]

REGEXES = [
    ("[[ abc =~ ^a(b)(c)$ ]] && echo \"${BASH_REMATCH[0]} ${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${#BASH_REMATCH[@]}\"", "abc b c 3\n", 0),
    ("[[ x.y =~ x.y ]] && echo dot; [[ xzy =~ \"x.y\" ]] || echo quoted-dot", "dot\nquoted-dot\n", 0),
    ("re='^(foo|bar)$'; [[ bar =~ $re ]] && echo variable; [[ foobar =~ ^(foo|bar)+$ ]] && echo unquoted-group", "variable\nunquoted-group\n", 0),
    ("[[ a =~ b ]]; echo \"$? ${#BASH_REMATCH[@]}\"", "1 0\n", 0),
    ("[[ ab =~ a\\.b ]]; echo $?; [[ aw =~ a\\w ]]; echo $?; [[ aw =~ \"a\\w\" ]]; echo $?", "1\n0\n1\n", 0),
    ("re='a\\.b'; [[ axb =~ $re ]]; echo $?; re='\\w'; [[ a =~ $re ]]; echo $?; [[ a =~ \"$re\" ]]; echo $?", "1\n0\n1\n", 0),
    ("x=a.b; [[ a.b =~ ^$x$ ]]; echo $?; [[ axb =~ ^\"$x\"$ ]]; echo $?", "0\n1\n", 0),
    ("[[ \"a b\" =~ a\\ b ]]; echo $?; [[ \"a b\" =~ (a b) ]]; echo $?", "0\n0\n", 0),
    ("[[ x =~ [[:alpha:]] ]]; echo $?; [[ \"a]\" =~ a] ]]; echo $?; [[ ab =~ a|b ]]; echo $?", "0\n0\n0\n", 0),
    ("[[ abc =~ (z)|(b) ]]; echo \"${#BASH_REMATCH[@]} [${BASH_REMATCH[1]}] [${BASH_REMATCH[2]}]\"", "3 [] [b]\n", 0),
    ("BASH_REMATCH=x; [[ abc =~ b ]]; echo \"${BASH_REMATCH[0]}\"", "b\n", 0),
]

ARITHMETIC = [
    ("(( 1 < 3 )) && echo lt; i=0; (( i++ )); echo \"$? $i\"; (( i++ )); echo \"$? $i\"", "lt\n1 1\n0 2\n", 0),
    ("x=5; (( x > 3 )) && echo gt; (( y = x * 2 )); echo $y; (( 0 )); echo $?", "gt\n10\n1\n", 0),
    ("n=2; (( n == 2 )) && (( $n + 1 == 3 )) && echo dollar; ((n += 5)); echo $n", "dollar\n7\n", 0),
    ("a=(1 2 3); (( a[1] == 2 )) && echo element; (( ${#a[@]} == 3 )) && echo count", "element\ncount\n", 0),
    ("(( x = 2 > 1 ? 10 : 20 )); echo $x; (( )); echo $?", "10\n1\n", 0),
    ("i=0; while (( i < 3 )); do ((i++)); done; echo $i; until (( i == 0 )); do (( i-- )); done; echo $i", "3\n0\n", 0),
    ("f() { local n=$1; (( n <= 1 )) && { echo 1; return; }; echo $(( n * $(f $((n-1))) )); }; f 5", "120\n", 0),
    # Parentheses that do not close as `))` are nested subshells.
    ("( (echo nested) ); ((echo inner) )", "nested\ninner\n", 0),
    ("for ((i=0; i<3; i++)); do echo $i; done", "0\n1\n2\n", 0),
    ("for ((i=0, j=10; i<j; i+=4, j--)) do echo \"$i,$j\"; done", "0,10\n4,9\n", 0),
    ("for (( ; ; )); do echo once; break; done; for ((k=3; k; k--)); { echo k$k; }", "once\nk3\nk2\nk1\n", 0),
    ("for ((i=0;i<2;i++))\ndo\n echo line$i\ndone", "line0\nline1\n", 0),
    ("for ((i=0; i<5; i++)); do (( i == 1 )) && continue; (( i == 3 )) && break; echo $i; done", "0\n2\n", 0),
    ("arr=(a b c); for ((i=${#arr[@]}-1; i>=0; i--)); do printf %s \"${arr[i]}\"; done; echo", "cba\n", 0),
]

STRICT = [
    ("set -e; (( 0 )) || echo guarded; [[ a == b ]] || echo guarded-test; echo still", "guarded\nguarded-test\nstill\n", 0),
    ("( set -e; (( 0 )); echo unreached ); echo $?", "1\n", 0),
    ("( set -e; [[ a == b ]]; echo unreached ); echo $?", "1\n", 0),
    ("set -e; f() { (( 0 )); echo unreached; }; f; echo unreached", "", 1),
    ("set -e; for ((i=0; i<2; i++)); do :; done; echo loop-ok", "loop-ok\n", 0),
    ("trap 'echo debug' DEBUG; [[ a == a ]]; (( 1 ))", "debug\ndebug\n", 0),
]

ERRORS = [
    ("(( 1/0 )); echo $?", "1\n", 'wsh: ((: 1/0 : division by 0 (error token is "0 ")\n'),
    ("((1 + )); echo $?", "1\n", 'wsh: ((: 1 + : arithmetic syntax error: operand expected (error token is "+ ")\n'),
    ("[[ 1.5 -eq 1 ]]; echo $?", "1\n", 'wsh: [[: 1.5: arithmetic syntax error: invalid arithmetic operator (error token is ".5")\n'),
    ("[[ 08 -eq 8 ]]; echo $?", "1\n", 'wsh: [[: 08: value too great for base (error token is "08")\n'),
    ("[[ a =~ a[ ]]; echo $?", "2\n", "wsh: [[: invalid regular expression `a[': Unmatched [, [^, [:, [., or [=\n"),
]

SYNTAX_ERRORS = ["[[ ]]", "[[ a == ]]", "[[ -f ]]", "[[ a\n== a ]]", "[[ a == b", "for ((i=0; i<3)); do :; done"]


def run(argv, command, cwd):
    return subprocess.run(argv + [command], cwd=cwd, env=ENV, capture_output=True, timeout=10, check=False)


def run_shell(command, cwd=ROOT):
    return run([str(SHELL), "--no-config", "-c"], command, cwd)


def run_bash(command, cwd=ROOT):
    return run([BASH, "-c"], command, cwd)


class ConditionalTests(unittest.TestCase):
    def check(self, rows):
        for command, stdout, status in rows:
            with self.subTest(command=command):
                result = run_shell(command)
                self.assertEqual(result.stdout.decode(), stdout, f"wsh stderr={result.stderr!r}")
                self.assertEqual(result.returncode, status, f"wsh stderr={result.stderr!r}")
                self.assertEqual(result.stderr, b"")
                if BASH:
                    expected = run_bash(command)
                    self.assertEqual(expected.stdout.decode(), stdout, "bash")
                    self.assertEqual(expected.returncode, status, "bash")

    def test_conditionals_match_bash(self):
        self.check(CONDITIONALS)

    def test_regular_expressions_match_bash(self):
        self.check(REGEXES)

    def test_arithmetic_commands_and_loops_match_bash(self):
        self.check(ARITHMETIC)

    def test_tests_count_as_commands_for_errexit_and_debug(self):
        self.check(STRICT)

    def test_errors_name_the_problem(self):
        for command, stdout, message in ERRORS:
            with self.subTest(command=command):
                result = run_shell(command)
                self.assertEqual(result.stdout.decode(), stdout)
                self.assertEqual(result.stderr.decode(), message)
                if BASH:
                    self.assertEqual(run_bash(command).stdout.decode(), stdout)

    def test_malformed_tests_are_syntax_errors(self):
        for command in SYNTAX_ERRORS:
            with self.subTest(command=command):
                result = run_shell(command)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertNotEqual(result.stderr, b"")
                if BASH:
                    self.assertEqual(run_bash(command).returncode, 2)

    def test_comparisons_never_redirect(self):
        # Before `(( ))` existed, `(( x > 3 ))` truncated a file named 3.
        with tempfile.TemporaryDirectory(prefix="wsh-cond-") as temp_dir:
            result = run_shell("x=5; (( x > 3 )); (( x < 9 )); [[ a < b ]]; [[ b > a ]]; echo done", cwd=temp_dir)
            self.assertEqual(result.stdout, b"done\n", result.stderr)
            self.assertEqual(os.listdir(temp_dir), [])

    def test_xtrace_shows_tests_like_bash(self):
        command = (
            "set -x; x=1; [[ $x == 1 && a < b ]]; (( x + $x )); for ((i=0;i<1;i++)); do :; done\n"
            "[[ x ]]; [[ ! a == b ]]"
        )
        want = (
            "+ x=1\n+ [[ 1 == 1 ]]\n+ [[ a < b ]]\n+ ((  x + 1  ))\n"
            "+ (( i=0 ))\n+ (( i<1 ))\n+ :\n+ (( i++ ))\n+ (( i<1 ))\n"
            "+ [[ -n x ]]\n+ [[ ! a == b ]]\n"
        )
        result = run_shell(command)
        self.assertEqual(result.stderr.decode(), want)
        if BASH:
            self.assertEqual(run_bash(command).stderr.decode(), want)
        # Recorded from bash 5.3, which escapes only the glob characters of a
        # quoted pattern; bash 5.2 escapes every quoted character.
        quoted = run_shell('set -x; [[ abc == "a*" ]]')
        self.assertEqual(quoted.stderr.decode(), "+ [[ abc == a\\* ]]\n")


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
