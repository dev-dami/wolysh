#!/usr/bin/env bash
# Runs inputs that once caused memory errors, overflows, hangs or crashes.
# Use it with a Debug build made with -Dmem-guard=true:
#
#     zig build -Doptimize=Debug -Dmem-guard=true
#     tests/guard_cases.sh zig-out/bin/wsh
#
# A case fails when wsh takes more than 20 seconds, ends on a signal, or
# prints a panic, a double free or a mem-guard leak report. A case can exit
# with an error status: only the crash or the report counts.
set -u

wsh=${1:-zig-out/bin/wsh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failed=0
count=0

check() {
    local script=$1 status
    count=$((count + 1))
    timeout 20 "$wsh" --no-config -c "$script" > /dev/null 2> "$work/err" < /dev/null
    status=$?
    if [ "$status" -eq 124 ] || [ "$status" -ge 128 ] ||
        grep -q -e 'panic' -e 'Double free' -e 'mem-guard' "$work/err"; then
        failed=$((failed + 1))
        printf 'FAIL (status %d): %s\n' "$status" "$script"
        sed 's/^/    /' "$work/err" | head -40
    fi
}

# Everyday scripts.
check 'for i in 1 2 3; do x="$x$i"; done; echo "$x"'
check 'f() { local a=$1; echo "${a^^}"; }; f hello'
check 'arr=(a b c); arr+=(d); echo "${arr[@]:1:2}" "${#arr[@]}"'
check 'declare -A m; m[k]=v; unset "m[k]"; echo "${!m[@]}"'
check 'echo $(( 2**62 + 2**62 )) $(( -9223372036854775807 - 1 ))'
check 'x=$(printf "%s-" a b c); echo "${x%-}"'
check 'set -- one two three; shift; echo "$@"'

# An assignment inside a subscript or operand frees the stored value.
check 'a=(x y); a[a=0]=z; echo "${a[@]}"'
check 'declare -ia a=(1 2); a[0]="a=5"; echo "${a[@]}"'
check 'declare -A m=([k]=v); m[$((m=0))]=x; echo ok'
check 'declare -A m=([k]=v); unset "m[$((m=0))]"; echo ok'
check 'a=(x y); echo "${a[(a=5)-4]}"'
check 'a=(x y); echo "${a[a[50]=1,1]}"'
check 'declare -A m=([k]=v); echo "${m[$((m=0))k]}"'
check 'x=hello; echo "${x:(x=0)}"'
check 'x=hello; echo "${x#$((x=0))}"'
check 'export x=hello; echo "${x:(x=0)}"'
check 'a=(xx yy); echo "${a[@]/x/$((a=1))}"'
check 'a=(x y); a+=( $((a=1)) ); echo "${a[@]}"'
check 's=foo; s+=( $((s=1)) ); echo "${s[@]}"'
check 'declare -A m=([k]=v); m+=([j]=$((m=0))); echo ok'

# Builtins that kept a pointer across script code.
check 'IFS=": "; read IFS rest <<< "a:b c"; echo "$rest"'
check 'arr=(a b); mapfile -O 1 -c 1 -C "unset arr;:" arr <<< x; echo "${arr[@]}"'
check 'prompt="> "; unset prompt; echo ok'

# Bytes and numbers from data.
check 'x=$(printf "a\342\202"); echo "${x^^}" "${x,,}" "${x@U}"'
check 'printf -v x "\0a=b"; declare "$x"; echo ok'
check 'printf -v x "\0a="; declare "$x"; echo ok'
check 'TZ=JST-9 printf "%(%F)T\n" 9223372036854775807'
check 'TZ=EST5 printf "%(%F)T\n" -9223372036854775808'
check 'TZ=ABC600000 printf "%(%T)T\n" 0'
check 'COPROC_PID=1; COPROC=(99999999999); coproc true; echo ok'

# Test output that `out failures` once sliced out of bounds.
printf 'test ... FAILED\nAll tests passed.\nrspec # x\n== 18446744073709551615 passed, 1 passed in 0.1s ==\n' > "$work/log"
check "out failures --file $work/log"
check "out budget 1k --file $work/log"

# Limits: these must stop with an error, not hang or overflow the stack.
check '[[ x =~ a{0}{32767}{32767}{32767} ]]; echo $?'
check 'eval "$(printf "{ %.0s" $(seq 100000))"; echo $?'
check 'eval "[[ $(printf "( %.0s" $(seq 100000)) x ]]"; echo $?'

printf '%d of %d guard cases failed\n' "$failed" "$count"
[ "$failed" -eq 0 ]
