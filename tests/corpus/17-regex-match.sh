#!/usr/bin/env bash
# [[ =~ ]] and BASH_REMATCH: log parsing, validation and semantic versions.

log_re='^([0-9]{4})-([0-9]{2})-([0-9]{2}) ([A-Z]+) +\[([a-z_]+)\] (.*)$'
declare -A level_count=()

while IFS= read -r line; do
    if [[ $line =~ $log_re ]]; then
        level=${BASH_REMATCH[4]}
        level_count[$level]=$(( ${level_count[$level]:-0} + 1 ))
        printf '%s/%s %-5s %-8s %s\n' "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" \
            "$level" "${BASH_REMATCH[5]}" "${BASH_REMATCH[6]}"
    else
        echo "unparsed: $line"
    fi
done <<'LOG'
2024-03-01 INFO  [server] listening on :8080
2024-03-01 WARN  [db_pool] pool nearly full (9/10)
garbage line
2024-03-02 ERROR [server] request failed: timeout after 30s
2024-03-02 INFO  [server] shutting down
LOG
for l in ERROR INFO WARN; do echo "$l=${level_count[$l]:-0}"; done

semver='^v?(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-([0-9A-Za-z.-]+))?(\+([0-9A-Za-z.-]+))?$'
for v in 1.2.3 v10.0.1-rc.1 2.0.0+build.5 1.2 01.2.3 3.4.5-beta+exp.sha.5114f85; do
    if [[ $v =~ $semver ]]; then
        echo "$v: major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]} pre=${BASH_REMATCH[5]:--} build=${BASH_REMATCH[7]:--} groups=${#BASH_REMATCH[@]}"
    else
        echo "$v: not a semantic version"
    fi
done

email_re='^[A-Za-z0-9._%+-]+@([A-Za-z0-9-]+\.)+[A-Za-z]{2,}$'
for e in user@example.com first.last+tag@sub.domain.org bad@ "no at sign" a@b.c; do
    [[ $e =~ $email_re ]] && echo "valid:   $e" || echo "invalid: $e"
done

# Extract every key=value pair from a line by consuming matches.
line='name=web port=8080 debug=true path=/srv/app empty= retries=3'
pair_re='([a-z]+)=([^ ]*)'
rest=$line
while [[ $rest =~ $pair_re ]]; do
    printf '%s -> [%s]\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    rest=${rest#*"${BASH_REMATCH[0]}"}
done

# Quoted parts of the pattern match literally.
file="report.v2.(final).txt"
[[ $file =~ \.\(final\)\.txt$ ]] && echo "literal parentheses matched"
[[ $file =~ "(final)" ]] && echo "quoted pattern matched"
[[ "a.c" =~ ^a.c$ && "abc" =~ ^a.c$ ]] && echo "dot matches any character"
[[ "a.c" =~ ^a"."c$ && ! "abc" =~ ^a"."c$ ]] && echo "quoted dot is literal"
if [[ "no digits here" =~ [0-9]+ ]]; then echo "digits"; else echo "no match, status $?"; fi
