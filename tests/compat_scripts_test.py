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

# --- arrays and the call stack -----------------------------------------------
case("array_without_subscript_is_element_zero", 'a=(x y z); echo $a "$a" ${#a[@]} ${#a}')
case("assoc_without_subscript_is_key_zero", 'declare -A m=([0]=zero [k]=v); echo $m')
case("bash_rematch_without_subscript", '[[ abc =~ b(c) ]]; echo $BASH_REMATCH ${BASH_REMATCH[1]}')
case("bash_source_is_the_script", 'echo "${BASH_SOURCE[0]##*/} ${#BASH_SOURCE[@]} $0" | sed "s|/[^ ]*/||"')
case("script_dir_idiom", 'd=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd); [[ -f $d/case.sh ]] && echo found')
case("is_sourced_idiom", '[[ "${BASH_SOURCE[0]}" == "$0" ]] && echo main || echo sourced')
case("funcname_stack", 'a() { b; }; b() { echo "${FUNCNAME[@]} $FUNCNAME ${FUNCNAME[1]} ${#FUNCNAME[@]}"; }; a; echo "[${FUNCNAME-unset}]"')
case("bash_lineno", 'f() { echo "${BASH_LINENO[0]}"; }\nf\n\nf')
case(
    "source_sets_bash_source_and_funcname",
    'printf "lib() { echo \\"in lib: \\${FUNCNAME[0]} \\${BASH_SOURCE[0]##*/}\\"; }\n'
    'echo \\"top of lib: \\${FUNCNAME[0]} \\${BASH_SOURCE[0]##*/} \\${BASH_SOURCE[1]##*/}\\"\n" > lib.sh\n'
    'source ./lib.sh; lib; echo "after: [${FUNCNAME-unset}]"',
)
case("caller_in_function", 'f() { caller; caller 0; }; f')

# --- shell options --------------------------------------------------------------
case("lastpipe_read", 'shopt -s lastpipe; echo "a b c" | read x y z; echo "$x|$y|$z"')
case("lastpipe_while_loop", "shopt -s lastpipe; printf '1\\n2\\n3\\n' | while read -r n; do s=$((s+n)); done; echo sum=$s")
case("lastpipe_mapfile_and_status", 'shopt -s lastpipe; printf "x\\ny\\n" | mapfile -t arr; echo ${#arr[@]}; false | true | cat; echo "${PIPESTATUS[@]}"')
case("lastpipe_pipefail", "shopt -s lastpipe; set -o pipefail; false | read w; echo $?")
case("lastpipe_off_by_default", 'echo z | read zz; echo "zz=${zz-unset}"')
case("inherit_errexit", 'shopt -s inherit_errexit; set -e; x=$(false; echo no); echo "x=$x"')
case("no_inherit_errexit", 'set -e; x=$(false; echo yes); echo "x=$x"')
case("braceexpand_off", "set +B; echo {a,b}; set -B; echo {a,b}; set +o braceexpand; echo {1..3}")
case("noexec", "echo before; set -n; echo never")
case("physical_cd", "mkdir -p real; ln -sfn real link; set -P; cd link; pwd | sed 's|.*/||'")
case("shellopts_lists_set_options", 'set -o pipefail -u; echo $SHELLOPTS')
case("set_o_names_accepted", "set -o posix -o verbose -o monitor -o keyword -o notify +o posix +o verbose +o monitor +o keyword +o notify; echo ok")
case("shopt_q_known_names", "for o in lastpipe inherit_errexit huponexit checkwinsize histappend; do shopt -q $o; echo $o=$?; done")
case("shopt_p_default", "shopt -p lastpipe sourcepath")
case("aliases_are_off_in_scripts", "alias say='echo aliased'\nsay hi")
case("expand_aliases_turns_them_on", "shopt -s expand_aliases\nalias say='echo aliased'\nsay hi; shopt expand_aliases")
case("command_v_ignores_aliases_that_do_not_expand", "alias ls='ls -l'\ncommand -v ls; type -t ls")
case(
    "export_updates_the_variable",
    'X=1; export X=2; echo $X; env | grep ^X=; declare -i n=1; export n=2+3; echo $n; export X+=z; echo $X',
)
case("exported_local_is_restored", 'f(){ local L=1; export L=2; env | grep ^L=; }; f; echo "[${L-unset}]"; env | grep -c ^L=')
case("local_shadows_an_exported_variable", 'export G=g; g(){ local G=inner; env | grep ^G=; }; g; env | grep ^G=')
case("local_path_changes_lookup", 'h(){ local PATH=/nope; ls >/dev/null 2>&1; echo $?; }; h; ls / >/dev/null && echo ok')
case("assignment_updates_an_exported_variable", 'export N=1; N=$((N+1)); env | grep ^N=')
case("which_is_the_program_in_scripts", "which sh | grep -c /; type -t which")
case("script_without_shebang_runs_in_a_shell", "printf 'echo ran \"$@\"\\n' > nosb; chmod +x nosb; ./nosb a; command ./nosb b; (exec ./nosb c)")
case("substitution_ending_in_a_continuation", 'x="$(echo a \\\n   )"; echo "[$x]"; y=`echo b \\\n`; echo "[$y]"')

# --- builtins ------------------------------------------------------------------
case("printf_v_array_element", 'printf -v "arr[2]" %s q; echo "${arr[2]}"; declare -A m; printf -v "m[k]" "%d" 42; echo ${m[k]}')
case("echo_hex_escapes_and_double_dash", 'echo -e "\\x41\\x4a|\\101|\\0101|\\xZ"; echo -- -n')
case("prompt_transform", 'x="a b"; echo ${x@P}; p="\\u \\$((1+1))"; USER=me; echo "${p@P}"; shopt -u promptvars; echo "${p@P}"')
case(
    "wait_p_and_remembered_status",
    'sleep 0.3 & a=$!; (sleep 0.05; exit 4) & b=$!; wait -n -p who; echo "rc=$? $(( who == b ))"; '
    'wait -f $a; echo $?; wait -p w2 $a; echo "rc=$? $(( w2 == a ))"; wait $b; echo "b=$?"; '
    'wait -n -p none; echo "rc=$? [${none-unset}]"',
)
case("readonly_assignment_stops_the_script", "readonly RO=1; RO=2; echo not-reached")
case("readonly_in_subshell_continues", "readonly RO=1; (RO=3); echo after:$?")
case(
    "coproc_variables_go_when_it_exits",
    'coproc FOO { echo hi; }; read -u ${FOO[0]} l; echo "$l"; wait $FOO_PID; echo "[${FOO[0]-gone}] [${FOO_PID-gone}]"',
)

# --- more Bash variables -------------------------------------------------------
case("bash_command", 'f() { echo "BC=[$BASH_COMMAND]"; }; f; trap \'echo "err: $BASH_COMMAND"\' ERR; false')
case("bash_subshell", 'echo "$BASH_SUBSHELL $(echo $BASH_SUBSHELL) $( (echo $BASH_SUBSHELL) )"; (echo $BASH_SUBSHELL)')
case("dirstack", 'pushd /tmp >/dev/null; echo "${#DIRSTACK[@]} ${DIRSTACK[0]}"; popd >/dev/null; echo ${#DIRSTACK[@]}')
case("groups", 'echo $(( ${#GROUPS[@]} > 0 )) $(( GROUPS[0] == $(id -g) ))')
case("bash_aliases", "alias ll='ls -l'\necho ${BASH_aliases-x} ${BASH_ALIASES[ll]}")
case("optind_opterr_defaults", "echo $OPTIND $OPTERR")

# --- errors -------------------------------------------------------------------------
case("command_not_found_message", "nonexistent_command_xyz; echo $?")
case("arithmetic_expansion_error_stops_the_script", "echo before; x=$((1/0)); echo after", stderr=False)
case("arithmetic_command_error_continues", "((1/0)); echo after:$?; let 1/0; echo after:$?", stderr=False)
case("arithmetic_error_in_a_pipeline_stage", "echo $(( 1/0 )) | cat; echo after", stderr=False)
case("arithmetic_error_in_a_subshell", "( echo $((1/0)) ); echo after:$?", stderr=False)
case("unterminated_double_quote", 'echo "abc', stderr=False)
case("unterminated_single_quote", "echo 'abc", stderr=False)
case("unterminated_backquote", "echo `x", stderr=False)
case("heredoc_ended_by_end_of_file", "cat <<EOF\nbody", stderr=False)
case("shift_past_the_end_is_quiet", "shift 2; echo $?; shopt -s shift_verbose; shift 2 2>/dev/null; echo $?")
case("function_named_fn", 'fn() { echo "args: $#"; }; fn a b c')
case("xtrace_for_and_case", 'set -x; for i in "a b" c; do :; done; case "x y" in x*) echo m;; esac')

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
