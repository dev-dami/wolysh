#!/usr/bin/env bash
# EXIT traps for cleanup: in the main script, in subshells, and with exit codes.

workdir=$(mktemp -d)
cleanup() {
    local status=$?
    if [[ -d $workdir ]]; then
        rm -rf "$workdir"
        echo "cleanup: removed work dir (status $status)"
    fi
    exit "$status"
}
trap cleanup EXIT

mkdir -p "$workdir/build"
for name in alpha beta gamma; do
    printf '%s\n' "$name" > "$workdir/build/$name.o"
done
objects=("$workdir"/build/*.o)
echo "built ${#objects[@]} objects: $(cat "${objects[@]}" | tr '\n' ' ')"

# A subshell has its own EXIT trap; the parent trap does not run there.
(
    trap 'echo "subshell trap: status $?"' EXIT
    echo "in subshell"
    exit 7
)
echo "subshell returned $?"

# The trap command shows the current trap.
show=$(trap -p EXIT)
echo "current trap: ${show}"

# Temporary traps inside a function, restored afterwards.
with_lock() {
    local lock=$workdir/lock
    : > "$lock"
    trap 'rm -f "$lock"; echo "lock released"' RETURN
    echo "lock held: $([[ -e $lock ]] && echo yes || echo no)"
    "$@"
}
with_lock echo "working under the lock"
trap - RETURN
echo "lock exists after: $([[ -e $workdir/lock ]] && echo yes || echo no)"

# Nested subshells each run their own trap in order.
(
    trap 'echo "outer subshell done"' EXIT
    (
        trap 'echo "inner subshell done"' EXIT
        echo "deep inside"
    )
    echo "back in outer subshell"
)

# Replacing and clearing a trap.
trap 'echo replaced' USR1
trap - USR1
echo "USR1 trap: [$(trap -p USR1)]"

echo "finishing with status 4"
exit 4
