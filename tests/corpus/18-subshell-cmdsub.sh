#!/usr/bin/env bash
# Subshells, command substitution, brace groups and pipelines into loops.

base=$(mktemp -d)
trap 'rm -rf "$base"' EXIT
cd "$base" || exit 1
mkdir -p one/two/three

count=10
(
    count=20
    cd one/two || exit
    echo "inside: count=$count dir=${PWD##*/}"
)
echo "outside: count=$count dir=$([[ $PWD == "$base" ]] && echo base || echo other)"

(exit 3)
echo "subshell status: $?"
(false || exit 5) || echo "chained status: $?"

# Command substitution strips trailing newlines only.
v=$(printf 'a\n\nb\n\n\n')
printf '[%s] len=%d\n' "${v//$'\n'/|}" "${#v}"
nested=$(echo "outer $(echo "middle $(echo inner)")")
echo "$nested"
old=`echo backticks \`echo nested\``
echo "$old"

printf 'line1\nline2\nline3\n' > "$base/data.txt"
content=$(< "$base/data.txt")
echo "file has ${#content} chars, last line: ${content##*$'\n'}"

# A pipeline into while runs in a subshell: the counter is lost.
n=0
printf '%s\n' a b c | while read -r _; do n=$((n + 1)); done
echo "after piped loop: n=$n"
# A brace group with a redirect keeps changes.
n=0
{ while read -r _; do n=$((n + 1)); done; } < "$base/data.txt"
echo "after redirected loop: n=$n"

# Output of a group is captured as one stream.
summary=$({
    echo "header"
    for i in 1 2 3; do echo "item $i"; done
    echo "footer"
} | wc -l)
echo "group printed $summary lines"

# Exit status of a command substitution in an assignment.
if out=$(grep_missing_cmd_zz 2>/dev/null); then echo "found"; else echo "assignment status $?"; fi
result=$(exit 9)
echo "status after assignment: $?"

# Functions that return values via stdout.
upper() { tr '[:lower:]' '[:upper:]' <<< "$1"; }
join_by() { local IFS=$1; shift; echo "$*"; }
echo "$(upper hello) $(join_by - a b c) $(join_by '' x y z)"

# Subshell inherits variables and functions but not changes back.
greet() { echo "hi from ${1:-nobody}"; }
who=parent
( who=child; greet "$who" )
greet "$who"
echo "depth: $(echo $(echo $(echo deep)))"
echo "BASH_SUBSHELL outside=$BASH_SUBSHELL inside=$(echo $BASH_SUBSHELL) nested=$( (echo $BASH_SUBSHELL) )"
