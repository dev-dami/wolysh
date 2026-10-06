#!/usr/bin/env python3
"""End-to-end checks for POSIX control flow, functions and the time keyword."""
import os
import pathlib
import pty
import re
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
BASH = shutil.which("bash")


def run_shell(command, *args, cwd=ROOT, input=None):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command, *args],
        cwd=cwd,
        input=input,
        capture_output=True,
        timeout=10,
        check=False,
    )


def run_script(path, *args, cwd=ROOT, input=None, shell=None):
    command = [shell, str(path), *args] if shell else [str(SHELL), "--no-config", str(path), *args]
    return subprocess.run(command, cwd=cwd, input=input, capture_output=True, timeout=10, check=False)


class ControlFlowTests(unittest.TestCase):
    def assert_success(self, result):
        self.assertEqual(
            result.returncode,
            0,
            f"wsh exited {result.returncode}; stdout={result.stdout!r}, stderr={result.stderr!r}",
        )

    def test_while_read_loop_over_a_file(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            data = pathlib.Path(temp_dir) / "hosts.txt"
            data.write_text("alpha 10.0.0.1\nbeta 10.0.0.2\n\ngamma 10.0.0.3\nunterminated")
            result = run_shell(
                'n=0\n'
                'while read -r name addr; do\n'
                '  n=$((n+1))\n'
                '  [ -z "$name" ] && continue\n'
                '  echo "$n: $name -> $addr"\n'
                'done < ' + str(data) + '\n'
                # Like bash, a last line without a newline ends the loop but
                # is still read.
                'echo "lines=$n last=$name"'
            )
            self.assert_success(result)
            self.assertEqual(
                result.stdout,
                b"1: alpha -> 10.0.0.1\n2: beta -> 10.0.0.2\n4: gamma -> 10.0.0.3\nlines=4 last=unterminated\n",
            )

    def test_case_dispatches_on_the_first_argument(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            script = pathlib.Path(temp_dir) / "service.sh"
            script.write_text(
                'case "$1" in\n'
                '  start|run) echo "starting $2" ;;\n'
                '  stop) echo stopping ;;\n'
                '  -h|--help) echo usage; exit 0 ;;\n'
                '  *.conf) echo "config $1" ;;\n'
                '  *) echo "unknown: $1" >&2; exit 1 ;;\n'
                'esac\n'
            )
            expectations = [
                (("start", "web"), 0, b"starting web\n"),
                (("run",), 0, b"starting \n"),
                (("stop",), 0, b"stopping\n"),
                (("--help",), 0, b"usage\n"),
                (("site.conf",), 0, b"config site.conf\n"),
                (("bogus",), 1, b""),
            ]
            for args, code, stdout in expectations:
                with self.subTest(args=args):
                    result = run_script(script, *args)
                    self.assertEqual(result.returncode, code, result.stderr)
                    self.assertEqual(result.stdout, stdout)
            self.assertEqual(run_script(script, "bogus").stderr, b"unknown: bogus\n")

    def test_case_fallthrough_operators_and_quoted_patterns(self):
        result = run_shell(
            'case abc in a*) echo one;& z*) echo two;; *) echo three;; esac\n'
            'case abc in a*) echo first;;& *c) echo second;;& z*) echo third;; esac\n'
            'pat="a*"; case abc in "$pat") echo literal;; $pat) echo glob;; esac\n'
            'case /usr/local/bin in */bin) echo path;; esac\n'
            'case x in (x|y) echo paren;; esac\n'
            'case nothing in a) echo no;; esac; echo "status $?"'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"one\ntwo\nfirst\nsecond\nglob\npath\nparen\nstatus 0\n")

    def test_case_and_loops_inside_substitutions(self):
        result = run_shell(
            'kind=$(case "$1" in *.tar.gz|*.tgz) echo tarball;; *.zip) echo zip;; *) echo other;; esac)\n'
            'echo "$kind"\n'
            'for word in `echo alpha beta`; do echo "[$word]"; done\n'
            'case `echo x` in x) echo backquoted;; esac\n'
            'if (test -n "$kind") then echo subshell-then; fi\n'
            'while { false; } do :; done; echo group-do',
            # As with `bash -c`, the first argument is $0.
            "wsh",
            "release.tar.gz",
        )
        self.assert_success(result)
        self.assertEqual(
            result.stdout,
            b"tarball\n[alpha]\n[beta]\nbackquoted\nsubshell-then\ngroup-do\n",
        )

    def test_function_with_local_and_return(self):
        result = run_shell(
            'total=outside\n'
            'sum() {\n'
            '  local total=0 n\n'
            '  for n in "$@"; do total=$((total + n)); done\n'
            '  echo "$FUNCNAME: $# numbers, total $total"\n'
            '  [ "$total" -gt 10 ] && return 3\n'
            '  return 0\n'
            '}\n'
            'sum 1 2 3; echo "status $?"\n'
            'sum 5 6 7; echo "status $?"\n'
            'echo "total=$total funcname=[$FUNCNAME]"\n'
            'function greet { echo "hello ${1:-world}"; }\n'
            'greet; greet ada\n'
            'usage(){ echo "usage: $0"; }\n'
            'usage',
            "wsh",
        )
        self.assert_success(result)
        self.assertEqual(
            result.stdout,
            b"sum: 3 numbers, total 6\nstatus 0\nsum: 3 numbers, total 18\nstatus 3\n"
            b"total=outside funcname=[]\nhello world\nhello ada\nusage: wsh\n",
        )

    def test_functions_override_builtins_and_reach_them_with_builtin(self):
        result = run_shell('echo() { builtin echo "wrapped:" "$@"; }; echo hi; command echo plain')
        self.assert_success(result)
        self.assertEqual(result.stdout, b"wrapped: hi\nplain\n")

    def test_function_definition_redirection_applies_on_every_call(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            log = pathlib.Path(temp_dir) / "log.txt"
            result = run_shell(
                'log() { echo "$*"; } >> ' + str(log) + '\n'
                'log first; log second\n'
                'quiet() { echo out; echo err >&2; } 2>/dev/null\n'
                'quiet'
            )
            self.assert_success(result)
            self.assertEqual(log.read_text(), "first\nsecond\n")
            self.assertEqual(result.stdout, b"out\n")
            self.assertEqual(result.stderr, b"")

    def test_for_over_a_glob_redirected_to_a_file(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            for name in ("b.txt", "a.txt", "notes.md"):
                (pathlib.Path(temp_dir) / name).write_text(name)
            result = run_shell(
                'for f in *.txt; do echo "file $f"; done > out\n'
                'for f in *.md { echo "native $f" } >> out\n'
                'cat out',
                cwd=temp_dir,
            )
            self.assert_success(result)
            self.assertEqual(result.stdout, b"file a.txt\nfile b.txt\nnative notes.md\n")

    def test_native_compound_redirections_are_not_dropped(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            result = run_shell(
                'for i in a b { echo $i } > loop.txt\n'
                'if true { echo branch } > if.txt\n'
                'let n = 0\n'
                'while n < 2 { let n = n + 1; echo $n } > while.txt\n'
                'while read -r line { echo "read $line" } < loop.txt',
                cwd=temp_dir,
            )
            self.assert_success(result)
            self.assertEqual(result.stdout, b"read a\nread b\n")
            directory = pathlib.Path(temp_dir)
            self.assertEqual((directory / "loop.txt").read_text(), "a\nb\n")
            self.assertEqual((directory / "if.txt").read_text(), "branch\n")
            self.assertEqual((directory / "while.txt").read_text(), "1\n2\n")

    def test_compound_commands_in_pipelines(self):
        result = run_shell(
            'printf "b\\na\\nc\\n" | while read -r l; do echo "item $l"; done | sort\n'
            'for i in 3 1 2; do echo $i; done | sort | tr "\\n" " "; echo\n'
            'if true; then echo out; echo problem >&2; fi 2>&1 | grep -c o\n'
            'case x in x) echo cased;; esac | tr a-z A-Z'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"item a\nitem b\nitem c\n1 2 3 \n2\nCASED\n")

    def test_compound_commands_in_lists_and_background(self):
        result = run_shell(
            'true && if true; then echo and-if; fi\n'
            'false || while true; do echo or-while; break; done\n'
            'for i in 1 2; do echo bg$i; done > /dev/null &\n'
            'wait\n'
            'until true; do :; done && echo until-ok'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"and-if\nor-while\nuntil-ok\n")

    def test_if_elif_else_and_until(self):
        result = run_shell(
            'for n in 1 5 12; do\n'
            '  if [ $n -lt 3 ]; then echo "$n small"\n'
            '  elif [ $n -lt 10 ]; then echo "$n medium"\n'
            '  else echo "$n large"\n'
            '  fi\n'
            'done\n'
            'i=0; until [ $i -ge 3 ]; do i=$((i+1)); done; echo "until $i"'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"1 small\n5 medium\n12 large\nuntil 3\n")

    def test_break_and_continue_counts_in_posix_loops(self):
        result = run_shell(
            'for i in 1 2 3; do\n'
            '  for j in a b c; do\n'
            '    [ $j = b ] && continue 2\n'
            '    [ $i = 3 ] && break 2\n'
            '    echo $i$j\n'
            '  done\n'
            'done\n'
            'echo done'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"1a\n2a\ndone\n")

    def test_for_without_in_iterates_positional_parameters(self):
        result = run_shell('show() { for arg; do echo "<$arg>"; done; }; show "a b" c')
        self.assert_success(result)
        self.assertEqual(result.stdout, b"<a b>\n<c>\n")

    def test_reserved_words_are_ordinary_arguments(self):
        result = run_shell("echo if then fi do done case esac in time; echo done")
        self.assert_success(result)
        self.assertEqual(result.stdout, b"if then fi do done case esac in time\ndone\n")

    def test_here_documents_inside_compound_commands(self):
        result = run_shell(
            'while read -r a b; do\n'
            '  cat <<EOF\n'
            'pair $a/$b\n'
            'EOF\n'
            'done <<INPUT\n'
            '1 2\n'
            '3 4\n'
            'INPUT\n'
            'if cat <<EOF; then\n'
            'from the condition\n'
            'EOF\n'
            '  echo after\n'
            'fi'
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"pair 1/2\npair 3/4\nfrom the condition\nafter\n")

    def test_native_conditions_accept_commands_and_special_parameters(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            (pathlib.Path(temp_dir) / "notes.txt").write_text("todo: ship\n")
            result = run_shell(
                'if grep -q todo notes.txt { echo has-todo }\n'
                'if ! grep -q done notes.txt { echo not-done }\n'
                'if grep -q todo notes.txt && test -f notes.txt { echo both }\n'
                'false\n'
                'if $? == 1 { echo status-one }\n'
                'show() { if $# == 2 { echo "two: $1 ${2}" }; if $1 == "abc" { echo first-is-abc } }\n'
                'show abc def\n'
                'let word = "abc"\n'
                'if ${#word} == 3 { echo len-3 }\n'
                'let ready = true\n'
                'if ready { echo var-ready }\n'
                'until ready { echo never }\n'
                'if no_such_command_xyz { echo never } else { echo missing }',
                cwd=temp_dir,
            )
            self.assert_success(result)
            self.assertEqual(
                result.stdout,
                b"has-todo\nnot-done\nboth\nstatus-one\ntwo: abc def\nfirst-is-abc\nlen-3\nvar-ready\nmissing\n",
            )
            self.assertIn(b"no_such_command_xyz", result.stderr)

    def test_select_reads_choices_from_standard_input(self):
        result = run_shell(
            'PS3="pick> "\n'
            'select fruit in apple banana; do\n'
            '  echo "chose [$fruit] reply $REPLY"\n'
            '  [ -n "$fruit" ] && break\n'
            'done\n'
            'echo "status $?"',
            input=b"7\n\n2\n",
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, b"chose [] reply 7\nchose [banana] reply 2\nstatus 0\n")
        self.assertEqual(result.stderr, b"1) apple\n2) banana\npick> pick> 1) apple\n2) banana\npick> ")

        at_eof = run_shell('select x in a; do echo never; done; echo "eof $?"', input=b"")
        self.assertEqual(at_eof.stdout, b"eof 1\n")

    def test_time_reports_in_bash_formats(self):
        result = run_shell('time sleep 0.2; time -p true; f() { :; }; time f | cat; time { false; }; echo "status $?"')
        self.assert_success(result)
        self.assertEqual(result.stdout, b"status 1\n")
        reports = result.stderr.decode()
        self.assertEqual(len(re.findall(r"\nreal\t\d+m\d+\.\d{3}s\nuser\t\d+m\d+\.\d{3}s\nsys\t\d+m\d+\.\d{3}s\n", reports)), 3)
        self.assertIn("real 0.00\nuser 0.00\nsys 0.00\n", reports)
        first_real = re.search(r"real\t0m(\d+\.\d{3})s", reports)
        self.assertGreaterEqual(float(first_real.group(1)), 0.19)

        custom = run_shell('TIMEFORMAT="took %1R"; time true; TIMEFORMAT=; time true; echo quiet')
        self.assertEqual(custom.stderr, b"took 0.0\n")
        self.assertEqual(custom.stdout, b"quiet\n")

    def test_check_accepts_new_syntax_without_running_it(self):
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            marker = pathlib.Path(temp_dir) / "marker"
            source = (
                f'if true; then touch {marker}; elif false; then :; else :; fi\n'
                f'while false; do :; done; until true; do :; done\n'
                f'for x in a; do touch {marker}; done; for y; do :; done\n'
                f'case x in x|y) touch {marker};; (z) :;& *) :;;& esac\n'
                f'f() {{ touch {marker}; }} > /dev/null; function g {{ :; }}\n'
                f'select s in a; do break; done\n'
                f'time touch {marker} | cat\n'
                f'if touch {marker} {{ :; }}\n'
            )
            result = subprocess.run([str(SHELL), "--check", "-c", source], capture_output=True, timeout=10, check=False)
            self.assert_success(result)
            self.assertFalse(marker.exists())

        for bad in ("if true; then echo", "for i in 1; do echo", "case x in a) echo",
                    "fi", "echo a;; echo b", "f() echo", "while true; done"):
            with self.subTest(source=bad):
                result = subprocess.run([str(SHELL), "--check", "-c", bad], capture_output=True, timeout=10, check=False)
                self.assertEqual(result.returncode, 2)
                self.assertTrue(result.stderr.startswith(b"wsh: "), result.stderr)

    @unittest.skipUnless(BASH, "bash is not installed")
    def test_scripts_match_bash(self):
        script_text = (
            'count() { local n=0; for _ in "$@"; do n=$((n+1)); done; echo "$n"; return $n; }\n'
            'count a b c; echo "rc=$?"\n'
            'for i in 1 2 3 4 5 6; do\n'
            '  case $i in\n'
            '    2|4) continue ;;\n'
            '    6) break ;;\n'
            '  esac\n'
            '  if [ $i -eq 1 ]; then echo first; elif [ $i -eq 3 ]; then echo third; else echo "other $i"; fi\n'
            'done\n'
            'n=0; while :; do n=$((n+1)); [ $n -ge 3 ] && break; done; echo "n=$n"\n'
            'printf "x y\\nz w\\n" | while read -r a b; do echo "$b-$a"; done\n'
            'r=$(for w in one two; do printf "%s." "$w"; done); echo "r=$r"\n'
            'outer() { inner "$@"; echo "outer sees $?"; }\n'
            'inner() { [ "$1" = fail ] && return 9; return 0; }\n'
            'outer fail; outer ok\n'
            'if ! false; then echo negated; fi\n'
            'false; if true; then :; fi; echo "after-if $?"\n'
            'until false; do echo once; break; done\n'
        )
        with tempfile.TemporaryDirectory(prefix="wsh-control-") as temp_dir:
            script = pathlib.Path(temp_dir) / "script.sh"
            script.write_text(script_text)
            ours = run_script(script)
            theirs = run_script(script, shell=BASH)
            self.assert_success(ours)
            self.assertEqual(ours.stdout, theirs.stdout)
            self.assertEqual(ours.stderr, theirs.stderr)


class Session:
    """A wsh REPL on a pty, as in tests/pty_test.py."""

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

    def read_until(self, needle, timeout=8.0):
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


PROMPT = b"\xe2\x9d\xaf"
CONTINUATION = b"\xe2\x80\xa6"


class InteractiveTests(unittest.TestCase):
    def setUp(self):
        self.session = Session()
        self.assertTrue(self.session.read_until(PROMPT), "the shell never drew a prompt")

    def tearDown(self):
        self.session.close()

    def enter_block(self, lines, expected):
        """Sends all but the last line, expecting a continuation prompt after
        each, then the last line, expecting `expected` in the output."""
        s = self.session
        for line in lines[:-1]:
            s.clear()
            s.send(line + "\r")
            self.assertTrue(s.read_until(CONTINUATION), f"no continuation prompt after {line!r}: {s.buf[-200:]!r}")
        s.clear()
        s.send(lines[-1] + "\r")
        self.assertTrue(s.read_until(expected), f"{expected!r} not printed: {s.buf[-300:]!r}")
        self.assertTrue(s.read_until(PROMPT))

    def test_posix_blocks_continue_until_closed(self):
        self.enter_block(["if true; then", "echo posix-if-ran", "fi"], b"posix-if-ran")
        self.enter_block(["for i in 1 2; do", "echo loop-$i", "done"], b"loop-2")
        self.enter_block(["case abc in", "a*) echo case-ran;;", "esac"], b"case-ran")
        self.enter_block(["greet() {", "echo hi-$1", "}; greet repl"], b"hi-repl")


if __name__ == "__main__":
    if not SHELL.is_file():
        print(
            f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first",
            file=sys.stderr,
        )
        sys.exit(2)
    unittest.main(verbosity=2)
