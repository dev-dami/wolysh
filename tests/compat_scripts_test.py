#!/usr/bin/env python3
"""Whole-script differential tests: each case runs as a script under bash and
under wsh, and status and standard output must match (and standard error too,
unless the case says only the status matters). These are the idioms real
bash scripts are made of, so a failure here is a script that cannot move
over."""
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHELL = pathlib.Path(os.environ.get("WSH", ROOT / "zig-out/bin/wsh")).resolve()
BASH = shutil.which("bash")
ENV = dict(os.environ, LC_ALL="C.UTF-8")


def normalize(stderr):
    stderr = re.sub(rb"(?m)^[^\n]*?: line \d+: ", b"sh: ", stderr)
    return re.sub(rb"(?m)^(bash|wsh): ", b"sh: ", stderr)


def run(shell, script, workdir):
    path = pathlib.Path(workdir) / "case.sh"
    path.write_text(script + "\n")
    command = [BASH] if shell == "bash" else [str(SHELL), "--no-config"]
    done = subprocess.run(
        [*command, str(path)],
        cwd=workdir,
        env=ENV,
        capture_output=True,
        stdin=subprocess.DEVNULL,
        timeout=20,
        check=False,
    )
    return done.returncode, done.stdout, normalize(done.stderr).replace(str(path).encode(), b"SCRIPT")


# (name, script, compare standard error too)
CASES = []


def case(name, script, stderr=True):
    CASES.append((name, script, stderr))


# --- namerefs ---------------------------------------------------------------
case("nameref_scalar", "v=1; declare -n r=v; echo $r; r=2; echo $v")
case("nameref_local_param", 'f() { local -n ref=$1; ref=changed; }; x=orig; f x; echo $x')
case("nameref_array_append", 'add() { local -n a=$1; a+=("$2"); }; arr=(a b); add arr c; add arr d; echo "${arr[@]}" ${#arr[@]}')
case(
    "nameref_array_element",
    'arr=(a b c d); g() { local -n a=$1; a[1]=X; echo "${a[@]}" "${#a[@]}" "${!a[@]}"; '
    'for e in "${a[@]}"; do printf "<%s>" "$e"; done; echo; }; g arr',
)
case("nameref_assoc", 'declare -A m; h() { local -n mm=$1; mm[k]=val; mm[j]=2; }; h m; echo "${m[k]} ${#m[@]}"')
case("nameref_unset_element", 'arr=(a b c); declare -n p=arr; unset "p[0]"; echo "${arr[@]}"')
case("nameref_indirect_name", 'v=1; declare -n r=v; echo "${!r}"; unset -n r; echo "[${r-unset}] v=$v"')
case("nameref_creates_target", "declare -n q=newvar; q=hello; echo $newvar")
case("nameref_command_substitution", 'w() { local -n o=$1; o=$(echo computed); }; w res; echo $res')
case(
    "nameref_repointed_in_loop",
    "item1=A; item2=B; for n in 1 2; do declare -n cur=item$n; echo $cur; done",
)
case("nameref_chain", "chain1=end; declare -n c2=chain1; declare -n c3=c2; echo $c3; c3=changed; echo $chain1")
case("nameref_declare_p", "x=1; declare -n p=x; declare -p p")
case("nameref_read_target", 'read_into() { local -n out=$1; read -r out <<< "line"; }; read_into got; echo $got')
case("nameref_arithmetic", "inc() { local -n n=$1; (( n++ )); }; cnt=5; inc cnt; inc cnt; echo $cnt")
case("nameref_scope_restored", "r=outer; f() { local -n r=other; r=set; }; other=0; f; echo $r $other")

# --- let --------------------------------------------------------------------
case("let_assignment", 'let x=5+5; echo $x; let "y = x * 2" z=3; echo $y $z; let x++; echo $x')
case("let_status", "let 0; echo $?; let 1; echo $?; let 'a=0'; echo $?")
case("let_division_by_zero", "let 1/0; echo $?", stderr=False)

# --- special variables --------------------------------------------------------
case("ifs_save_and_restore", 'v="a  b c"; OLD=$IFS; IFS=,; w="x,y z"; printf "[%s]" $w; IFS=$OLD; printf "[%s]" $v; echo')
case("ifs_default_value", 'printf "%s" "$IFS" | od -An -c')
case("ifs_unset_restores_splitting", 'IFS=,; unset IFS; v="a b"; printf "[%s]" $v; echo')
case("ifs_default_keeps_carriage_return", r'printf "[%s]" $(printf "a\r\nb") | od -An -c')
case("bash_version_is_set", 'echo "${BASH_VERSINFO[0]}"; [[ -n $BASH_VERSION ]] && echo set; echo ${#BASH_VERSINFO[@]}')
case("bash_path_runs", '"$BASH" -c "echo ok" 2>/dev/null || echo "$BASH" | grep -c /')
case("bashpid", 'echo $(( BASHPID == $$ )); (echo $(( BASHPID != $$ )))')
case("shellopts_follow_set", 'set -e; set -u; case $SHELLOPTS in *errexit*nounset*) echo both;; esac')

# --- hash --------------------------------------------------------------------
case("hash_r_is_silent", "hash -r; echo ok")

# --- coprocesses ----------------------------------------------------------------
case("coproc_default_name", 'coproc cat; echo hi >&${COPROC[1]}; read -u ${COPROC[0]} l; echo $l')
case(
    "coproc_named_group",
    'coproc FOO { sort; }; printf "b\\na\\n" >&${FOO[1]}; eval "exec ${FOO[1]}>&-"; cat <&${FOO[0]}; wait; echo done',
)


class ScriptTests(unittest.TestCase):
    pass


def make(name, script, stderr):
    def test(self):
        with tempfile.TemporaryDirectory() as workdir:
            expected = run("bash", script, workdir)
            actual = run("wsh", script, workdir)
        self.assertEqual(actual[:2], expected[:2], f"status/stdout differ for:\n{script}")
        if stderr:
            self.assertEqual(actual[2], expected[2], f"stderr differs for:\n{script}")

    return test


class NativeSyntaxTests(unittest.TestCase):
    """wsh's own statements keep working next to their Bash namesakes."""

    def test_let_binding_with_spaces_is_the_native_statement(self):
        with tempfile.TemporaryDirectory() as workdir:
            status, out, _ = run("wsh", 'let x = 4; let y = x * 2; echo $x $y', workdir)
        self.assertEqual((status, out), (0, b"4 8\n"))


for _name, _script, _stderr in CASES:
    setattr(ScriptTests, f"test_{_name}", make(_name, _script, _stderr))

if __name__ == "__main__":
    unittest.main()
