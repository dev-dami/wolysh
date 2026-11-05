#!/usr/bin/env bash
# set -euo pipefail with the usual ways to handle failures on purpose.
set -euo pipefail

trap 'echo "exit trap: status $?"' EXIT

log() { printf '[%s] %s\n' "$1" "${*:2}"; }

# A failing command guarded with || true does not stop the script.
missing_dir=$(mktemp -d)/nope
rm "$missing_dir" 2>/dev/null || true
log info "rm failure ignored"
cat "$missing_dir" 2>/dev/null || log warn "cannot read a missing file"

# Capture a status without tripping errexit.
rc=0
grep_like() { [[ $1 == *"$2"* ]]; }
grep_like "haystack" "needle" || rc=$?
log info "search status $rc"

# Conditions do not trigger errexit.
if ! grep_like "abc" "x"; then log info "no x in abc"; fi
while grep_like "${loop:-aaa}" "aa"; do loop=${loop:-aaa}; loop=${loop%a}; done
log info "loop ended with loop=$loop"

# nounset: defaults keep unset variables safe.
log info "optional=${OPTIONAL_SETTING:-default} first arg=${1-none} args=$#"
declare -a empty=()
log info "empty array size ${#empty[@]}"

# pipefail: the pipeline fails when any part fails.
set +e
false | true
log info "pipefail status $? PIPESTATUS=${PIPESTATUS[*]}"
true | (exit 3) | true
log info "middle failure status $?"
set -e

# Arithmetic that evaluates to 0 returns 1: guard it.
n=0
((n++)) || true
((n += 0)) || log warn "(( )) returned 1 for a zero result"
log info "n=$n"

# Failures inside a function stop it under errexit only when not in a condition.
step() { log step "$1"; [[ $1 != bad ]]; }
for s in one bad two; do
    if step "$s"; then log ok "$s"; else log fail "$s"; fi
done

# A subshell failure can be caught. Inside a condition errexit is off, even
# in the subshell, so the echo after false still runs.
if (set -e; false; echo "runs: errexit is ignored in a condition"); then log info "subshell ok"; fi
if (exit 6); then log info "subshell ok"; else log info "subshell failed with $?"; fi
out=$(echo partial; exit 2) || log info "command substitution failed with $?, output '$out'"

rm -rf "${missing_dir%/nope}"
log info "about to fail for real"
grep_like "abc" "zzz"
log info "never printed"
