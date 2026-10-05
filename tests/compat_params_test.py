#!/usr/bin/env python3
"""Parameter expansion, arrays, declare and special variables, checked
against bash where the two shells share syntax."""
import os
import pathlib
import platform
import pty
import re
import select
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = ROOT / "zig-out" / "bin" / "wsh"
BASH = shutil.which("bash")
# Character counts and case mapping follow the locale in bash.
ENV = dict(os.environ, LC_ALL="C.UTF-8")


def run_shell(command, *args):
    return subprocess.run(
        [str(SHELL), "--no-config", "-c", command, *args],
        cwd=ROOT,
        env=ENV,
        capture_output=True,
        timeout=10,
        check=False,
    )


def run_script(shell, script, *args):
    # Scripts rather than `-c`: `bash -c` exits 127 after an expansion error
    # where a bash script exits 1, and scripts are what wsh has to replace.
    with tempfile.NamedTemporaryFile("w", suffix=".sh") as handle:
        handle.write(script + "\n")
        handle.flush()
        command = [BASH] if shell == "bash" else [str(SHELL), "--no-config"]
        return subprocess.run(
            [*command, handle.name, *args],
            cwd=ROOT,
            env=ENV,
            capture_output=True,
            timeout=10,
            check=False,
        )


def normalize(stderr):
    return re.sub(rb"(?m)^[^\n]*?: line \d+: ", b"wsh: ", stderr)


# Each case runs under both shells; status, stdout and stderr must agree.
PARAMETER_CASES = [
    # defaults, alternates and assignment, unset versus empty
    'x=hello; e=; echo "${x-d}" "${x:-d}" "${u-d}" "${u:-d}" "[${e-d}]" "${e:-d}"',
    'x=hello; e=; echo "[${x+a}]" "[${x:+a}]" "[${u+a}]" "[${u:+a}]" "[${e+a}]" "[${e:+a}]"',
    'e=; echo "${u=new}" "$u" "${e:=filled}" "$e" "${e=keep}"',
    'echo ${u:-$HOME} ${u:-~} "${u:-~}" ${u:-$(echo sub)} ${u:-$((2+3))} ${u:-"$HOME"}',
    "printf '<%s>' ${u:-a b} \"${u:-a b}\" ${u:-'q r'} ${u:-\"a  b\"}; echo",
    "x=abc; echo \"${x:-'q'}\" \"${u:-'q'}\" \"${u:-\"q r\"}\" ${x:+\"q r\"} \"${x:+$x x}\"",
    "echo ${u:-${v:-nested}} ${u:-a\\}b}",
    # length
    "x=hello; e=; echo ${#x} ${#e} ${#u} ${#HOME}",
    # prefix and suffix removal
    "p=/usr/local/lib/file.tar.gz; echo ${p#*/} ${p##*/} ${p%/*} ${p%.*} ${p%%.*} ${p#/usr} ${p%.gz}",
    "p=/usr/local/lib/file.tar.gz; echo \"[${p%%/*}]\" ${p%\"/file.tar.gz\"} ${p##*[/]} ${p#\"*\"}",
    "x='a*b?c'; echo \"${x#a\\*}\" \"${x#\"a*\"}\" \"${x#'a*'}\" \"${x%\\?c}\" \"${x#a*}\"",
    "x=abc123; echo ${x%%[0-9]*} ${x##*[a-c]} ${x#[!b]} ${x#[a]} ${x#??} ${x%???}",
    "x=aaa; echo ${x#a*} ${x##a*} ${x%a*} \"[${x%%a*}]\"",
    "pat='*.c'; f=main.c; echo ${f%$pat} \"${f%\"$pat\"}\" ${f%\\*.c}",
    # replacement
    "x=aXbXc; echo ${x/X/-} ${x//X/-} ${x/#a/A} ${x/%c/C} ${x/#X/-} ${x//[ab]/.} ${x/X} ${x//X}",
    "x=aXbXc; echo ${x/X/<&>} \"${x//X/[&]}\" ${x/X/\\&} ${x//X/'&'} ${x//X/\\\\&}",
    "x=aXbXc; r='<&>'; echo ${x//X/$r} ${x//X/\"$r\"}",
    "x=abc; echo ${x/#/P} ${x/%/S} ${x//} ${x/} ${x//?/<&>}",
    "p=a/b/c; echo ${p//\\//_} ${p/\\//:} ${p//[\\/]/.}",
    "x=foo; echo ${x/#f/F} ${x/%o/O} \"${x/o/\"o o\"}\"",
    # substrings
    'x=hello; echo ${x:1} ${x:1:3} ${x: -3} ${x: -3:2} ${x:1:-1} ${x:(-2)} ${x::2} "[${x:10}]" "[${x:2:0}]"',
    "x=hello; i=1; echo ${x:i:i+1} ${x:$i} ${x: -10}",
    # case modification and transforms
    "x=hello; y=HELLO; echo ${x^} ${x^^} ${y,} ${y,,} ${x^^[lo]} ${y,,[LO]} ${x^[h]} ${x^[e]}",
    "x=hello; echo ${x@U} ${x@L} ${x@u} ${x@Q} ${x@K}",
    "y=\"it's\"; e=; echo ${y@Q} \"${y@Q}\" ${e@Q}; z='a\\tb'; echo \"${z@E}\"",
    # characters, not bytes
    "x=héllo; echo ${#x} ${x:1:2} ${x^^} ${x: -2}",
    # indirection and name listing
    "v=val; r=v; echo ${!r} ${!r:-d} ${!r/a/A} \"${!r}\"",
    "a=(x y); r='a[1]'; echo ${!r}",
    "ab1=1; ab2=2; echo ${!ab*}; printf '<%s>' \"${!ab@}\"; echo",
    # positional parameters
    'echo ${1:-d} ${4:-d} ${#1} ${1#x} "${@/x/X}" "${*^^}" ${#@} ${#*} ${##} ${!#}',
    'echo ${@:2} ${@: -1} "${@:1:2}" ${*:2:1} "${@:5}"',
    'x="$@"; echo "[$x]"; y=$*; echo "[$y]"; IFS=:; z="$*"; echo "[$z]"',
    # in here-documents and arithmetic
    "x=a/b; cat <<EOF\n${x%/*} ${#x} ${u:-def}\nEOF",
    "a=(5 6 7); echo $(( ${#a[@]} - 1 )) $(( ${a[1]} * 2 )) $(( ${a[-1]} + ${a[0]} ))",
    # the motivating case: never silently empty
    'dir=/tmp/one/two; echo "${dir%/*}/" "${dir##*/}"',
]

ERROR_CASES = [
    "echo ${x;y}; echo after",
    "echo ${}; echo after",
    "x=hello; echo ${x:}; echo after",
    'echo "${x!y}"; echo after',
    "echo ${x;y} ran",
    "echo ${u:?}; echo after",
    "echo ${u?}; echo after",
    '(echo ${u:?boom}); echo "after $?"; (echo ${x;y}); echo "after $?"',
    "e=; echo ${e:?is empty $HOME}; echo after",
    "x=hello; echo ${x:1:-10}; echo after",
    "echo ${1:=x}; echo after",
    "echo ${!u}; echo after",
    "a=(1 2); echo ${a[-5]}; echo rc=$?",
    "a=(1 2); a[-5]=3; echo after",
    "a=(1 2 3); echo ${a[@]:1:-1}; echo after",
    "declare -p nope; echo rc=$?",
    "declare -r R=1; declare R=2; echo rc=$? $R",
    "declare -a q; declare -A q; echo rc=$?",
    "declare -A q; declare -a q; echo rc=$?",
    "local x=1; echo rc=$?",
]

ARRAY_CASES = [
    "a=(one \"two three\" four); echo ${#a[@]}; printf '<%s>' \"${a[@]}\"; echo; "
    "printf '<%s>' ${a[@]}; echo; printf '<%s>' \"${a[*]}\"; echo",
    "a=(one \"two three\"\n  four # a comment\n  five); echo ${#a[@]}; printf '<%s>' \"${a[@]}\"; echo",
    'a=([0]=x [3]=y); echo ${#a[@]} ${!a[@]} "${a[@]}"; a+=(z); echo ${!a[@]}; '
    "unset 'a[3]'; echo ${!a[@]} ${#a[@]}; declare -p a",
    "a=([2]=x y z); declare -p a; b=([1]=p [0]=q); declare -p b",
    "a=(1 2); a[5]=x; a[1]+=y; echo ${a[@]} ${!a[@]}; i=1; a[i+1]=q; echo ${a[2]} ${a[i]} ${a[-1]} ${#a[1]}",
    "a=(1 2 3 4 5); echo ${a[@]:1:2} ${a[@]: -2} ${a[@]:1}; echo ${a[@]: -2:1} \"[${a[@]:7}]\" \"[${a[@]: -9}]\"",
    "a=(foo.c bar.c \"baz qux.c\"); printf '<%s>' \"${a[@]%.c}\"; echo; printf '<%s>' \"${a[@]/o/0}\"; echo; "
    "echo ${a[@]^^}; printf '<%s>' \"${a[@]#*a}\" \"${a[@]/#/pre-}\"; echo",
    'a=("a b" c); IFS=:; echo "${a[*]}" "${!a[*]}"; s="${a[*]}"; echo "$s"; t="${a[@]}"; echo "$t"',
    "a=(); echo \"[${a[@]}]\" ${#a[@]}; printf '<%s>' \"${a[@]}\"; echo; a+=(x); a+=(\"y z\"); printf '<%s>' \"${a[@]}\"; echo",
    'a=(1 2 3); echo ${a[@]:-def} ${b[@]:-def} ${b[@]-und}; c=(""); echo "${c[@]:-def}" "[${c[@]-und}]"',
    'a=(1 2 3); b=("${a[@]}" 4); echo "${b[@]}" ${#b[@]}',
    "x=abc; echo ${x[0]} ${x[@]} ${#x[@]} \"[${x[1]}]\" ${x[@]:1} ${!x[@]}",
    "a=(1 2 3); a=x; declare -p a; b=(1 2); b+=3; declare -p b; s=ab; s+=cd; echo $s",
    "a=(1 2 3); unset 'a[0]' 'a[2]'; declare -p a; unset 'a[@]'; declare -p a",
    "a=(x y z); unset 'a[-1]'; echo ${a[@]} ${#a[@]}",
    "cd src && f=(*.zig); [ ${#f[@]} -gt 3 ] && echo many",
    "a=(x y); cat <<EOF\n${a[1]} ${#a[@]} \"${a[@]}\"\nEOF",
    "(a=(x y); echo ${a[1]}); echo after",
    # associative arrays
    "declare -A m=([one]=1 [two]=2); echo ${m[one]} ${m[two]} \"[${m[nope]}]\" ${#m[@]}; m[three]=3; m[one]+=1; "
    "echo ${m[one]} ${#m[@]}; unset 'm[two]'; echo ${#m[@]} ${m[two]:-gone}",
    "declare -A m; m[\"a b\"]=1; k=\"a b\"; echo ${m[$k]} \"${m[\"a b\"]}\" ${#m[a b]}",
    "declare -A m=([k]=\"v w\"); declare -p m; m+=([j]=x); echo ${m[j]} ${#m[@]}",
    "declare -A m=(k1 v1 k2 v2); echo ${m[k1]} ${m[k2]}",
    "declare -A m=([b]=2 [a]=1 [c]=3); printf '%s\\n' \"${!m[@]}\" | sort | tr '\\n' ' '; "
    "printf '%s\\n' \"${m[@]}\" | sort | tr '\\n' ' '; echo",
    "declare -A m=([a]=1 [b]=2); unset 'm[a]'; declare -p m; echo ${#m[@]} ${m[b]}",
    "declare -A m=([\"a b\"]=1 [c]=2 [d]=3); k=c; unset 'm[$k]' \"m[a b]\"; declare -p m; i=1; a=(x y z); unset 'a[i]'; echo ${!a[@]}",
]

DECLARE_CASES = [
    "declare -a a=(1 \"x y\" '$z' 'q\"r' 'b\\s'); declare -p a; declare x='it'\"'\"'s'; declare -p x",
    "declare -rx v=1; declare -p v; declare -i n=3+4; declare -p n; declare -l lo=ABC; declare -u up=abc; declare -p lo up",
    "declare -i n; n=2*3; echo $n; n+=4; echo $n; n=abc; echo $n; n='1 + 1'; echo $n",
    "declare -u u; u=hello; u+=world; echo $u; declare -l l=MiXeD; echo $l",
    "typeset -a t=(1 2); typeset -p t",
    "x=abc; declare -a x; echo ${x[0]} ${#x[@]}",
    "declare -ia nums=(1+1 2*3); echo ${nums[@]}; nums[2]=4/2; echo ${nums[2]}",
    "declare x=1 y=2; echo $x $y",
    "declare -A m=([k]=v); echo ${m@a} ${m[k]@a}; declare -i i=1; echo ${i@a}; a=(1); echo ${a@a}",
]

SPECIAL_CASES = [
    "echo $OSTYPE $HOSTTYPE",
    '[ "$HOSTNAME" = "$(uname -n)" ] && echo host-ok',
    "HOSTNAME=elsewhere; echo $HOSTNAME",
    "r=$RANDOM; [ \"$r\" -ge 0 ] && [ \"$r\" -le 32767 ] && echo random-ok",
    'RANDOM=42; a=$RANDOM; b=$RANDOM; RANDOM=42; c=$RANDOM; d=$RANDOM; [ "$a $b" = "$c $d" ] && echo seeded-ok',
    "SECONDS=100; [ $SECONDS -ge 100 ] && [ $SECONDS -lt 105 ] && echo seconds-ok",
    "echo ${UID} ${EUID} | grep -Eq '^[0-9]+ [0-9]+$' && echo ids-ok",
]


class BashComparisonTests(unittest.TestCase):
    def setUp(self):
        if BASH is None:
            self.skipTest("bash is not installed")

    def compare(self, cases, *args):
        for script in cases:
            with self.subTest(script=script):
                expected = run_script("bash", script, *args)
                actual = run_script("wsh", script, *args)
                self.assertEqual(
                    (actual.returncode, actual.stdout, normalize(actual.stderr)),
                    (expected.returncode, expected.stdout, normalize(expected.stderr)),
                )

    def test_parameter_forms(self):
        self.compare(PARAMETER_CASES, "x", "y", "z")

    def test_errors_abort_the_command_and_the_script(self):
        self.compare(ERROR_CASES)

    def test_arrays(self):
        self.compare(ARRAY_CASES)

    def test_declare(self):
        self.compare(DECLARE_CASES)

    def test_special_variables(self):
        self.compare(SPECIAL_CASES)

    def test_set_u(self):
        probe = run_shell("set -u; echo ok")
        if probe.stdout != b"ok\n" or probe.stderr:
            self.skipTest("this build has no `set -u`")
        self.compare([
            "set -u; echo $nope; echo after",
            "set -u; echo ${nope-d} ${nope:-e} ${nope+f}x; echo \"$@\" \"$*\"; echo ${#nope}; echo after",
            "set -u; echo $1; echo after",
            "set -u; a=(1); echo ${a[0]} ${a[5]}; echo after",
            "set -u; declare -A m; echo ${m[k]}; echo after",
            "set -u; echo \"${a[@]}\"; a=(); echo \"${a[@]}\" ${#a[@]}; echo after",
            "set -u; echo ${nope#x}; echo after",
        ])


class WshBehaviourTests(unittest.TestCase):
    def check(self, script, stdout, *args, status=0):
        result = run_shell(script, *args)
        self.assertEqual((result.returncode, result.stdout, result.stderr), (status, stdout.encode(), b""))

    def test_a_list_without_a_subscript_is_every_element(self):
        # bash expands `$a` to the first element; wsh keeps its own rule.
        self.check("a=(x y z); echo $a ${#a[@]}", "x y z 3\n")
        self.check('let l = split("a b,c", ","); for i in $l { echo "<$i>" }; echo "$l" ${l[1]} ${#l[@]}',
                   "<a>\n<b>\n<c>\na b c c 2\n")

    def test_expression_indexing(self):
        self.check('let l = split("a,b,c", ","); let x = l[0]; let y = l[-1]; let z = l[5]; echo $x $y "[$z]"',
                   "a c []\n")
        self.check("declare -A m=([k]=v); let v = m[\"k\"]; let g = [[1, 2], [3, 4]]; let c = g[1][0]; "
                   "let s = \"héllo\"[1]; echo $v $c $s", "v 3 é\n")
        self.check('a=(x y z); let n = ${#a[@]} + 1; if ${u:-d} == "d" { echo $n }', "4\n")
        result = run_shell("let bad = 5[0]")
        self.assertEqual(result.returncode, 1)
        self.assertIn(b"cannot index", result.stderr)

    def test_expression_functions(self):
        self.check('let l = append([1, 2], 3); let s = slice(l, 1); let t = slice("héllo", 1, -1); echo $l $s $t',
                   "1 2 3 2 3 éll\n")
        self.check('let r = replace("a-b-c", "-", "+"); let i = index("héllo", "llo"); '
                   'let j = index("abc", "z"); let k = index([1, 2, 3], 3); echo $r $i $j $k', "a+b+c 2 -1 2\n")
        self.check("declare -A m=([k]=v [j]=w); let ks = keys(m); let vs = values(m); "
                   "a=([1]=x [4]=y); let ak = keys(a); echo $ks $vs $ak", "k j v w 1 4\n")
        self.check('let n = len("héllo"); declare -A m=([a]=1); let c = len(m); x=héllo; echo $n $c ${#x}',
                   "5 1 5\n")

    def test_declare_in_functions_is_local(self):
        self.check("fn f() { local -a arr=(1 2); local -A mm=([k]=v); declare x=1; declare -g g=2; "
                   "declare -p arr mm x; }; f; echo ${#arr[@]} \"[$x]\" $g",
                   'declare -a arr=([0]="1" [1]="2")\ndeclare -A mm=([k]="v" )\ndeclare -- x="1"\n0 [] 2\n')
        self.check("declare -i n=5; fn f() { local n; n=2*3; echo $n; }; f; n=1+1; echo $n", "2*3\n2\n")

    def test_declare_functions(self):
        self.check("fn greet() { echo hi }; declare -F; declare -F greet; declare -f greet",
                   "declare -f greet\ngreet\nfn greet() { echo hi }\n")
        self.assertEqual(run_shell("declare -f nope").returncode, 1)

    def test_unsupported_declare_options_are_errors(self):
        result = run_shell("declare -n ref=x")
        self.assertEqual(result.returncode, 2)
        self.assertIn(b"unsupported option", result.stderr)

    def test_array_prefix_assignment_is_an_error(self):
        result = run_shell("a=(1 2) /usr/bin/env; echo after")
        self.assertEqual((result.returncode, result.stdout), (1, b""))
        self.assertIn(b"cannot prefix a command", result.stderr)

    def test_bare_words_are_not_special_variables(self):
        self.check("echo UID RANDOM", "UID RANDOM\n")

    def test_special_variable_values(self):
        result = run_shell("echo $UID $EUID $PPID $HOSTNAME $HOSTTYPE $OSTYPE $WSH_VERSION $EPOCHSECONDS $EPOCHREALTIME")
        self.assertEqual(result.stderr, b"")
        fields = result.stdout.decode().split()
        self.assertEqual(fields[:6], [str(os.getuid()), str(os.geteuid()), str(os.getpid()),
                                      socket.gethostname(), platform.machine(), "linux-gnu"])
        version = subprocess.run([str(SHELL), "--version"], capture_output=True, check=False).stdout.decode().split()[-1]
        self.assertEqual(fields[6], version)
        self.assertLess(abs(int(fields[7]) - time.time()), 30)
        self.assertRegex(fields[8], r"^\d+\.\d{6}$")
        self.assertRegex(run_shell("echo $LINENO").stdout.decode(), r"^\d+\n$")

    def test_random_differs_between_subshells(self):
        result = run_shell("echo $(echo $RANDOM) $(echo $RANDOM) $(echo $RANDOM) $(echo $RANDOM) $RANDOM $RANDOM")
        self.assertGreater(len(set(result.stdout.split())), 1)


class InteractiveTests(unittest.TestCase):
    def test_parameter_error_does_not_end_an_interactive_shell(self):
        data_home = tempfile.TemporaryDirectory(prefix="wsh-params-pty-")
        env = dict(os.environ, TERM="xterm-256color",
                   XDG_CONFIG_HOME=os.path.join(data_home.name, "config"),
                   XDG_DATA_HOME=os.path.join(data_home.name, "data"))
        pid, fd = pty.fork()
        if pid == 0:
            os.chdir(ROOT)
            os.execve(str(SHELL), ["wsh"], env)
            os._exit(127)
        buf = b""

        def read_until(needle, timeout=8.0):
            nonlocal buf
            deadline = time.time() + timeout
            while needle not in buf and time.time() < deadline:
                ready, _, _ = select.select([fd], [], [], 0.2)
                if ready:
                    try:
                        chunk = os.read(fd, 65536)
                    except OSError:
                        break
                    if not chunk:
                        break
                    buf += chunk
            return needle in buf

        try:
            self.assertTrue(read_until("❯".encode()), buf[-200:])
            os.write(fd, b"echo ${nope:?went-wrong}\r")
            self.assertTrue(read_until(b"nope: went-wrong"), buf[-300:])
            os.write(fd, b"echo still-$((40 + 2))\r")
            self.assertTrue(read_until(b"still-42"), buf[-300:])
        finally:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
            os.close(fd)
            data_home.cleanup()


if __name__ == "__main__":
    if not SHELL.is_file():
        print(f"error: {SHELL} does not exist; run `zig build -Doptimize=ReleaseFast` first", file=sys.stderr)
        sys.exit(2)
    unittest.main(verbosity=2)
