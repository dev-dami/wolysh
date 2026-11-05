#!/usr/bin/env bash
# A version comparator: split on dots, compare numerically, sort a release list.
set -u

# vercmp A B prints <, = or > and returns 0, 1 or 2 accordingly.
vercmp() {
    local IFS=.
    local -a a=($1) b=($2)
    local i n=${#a[@]}
    ((${#b[@]} > n)) && n=${#b[@]}
    for ((i = 0; i < n; i++)); do
        local x=${a[i]:-0} y=${b[i]:-0}
        if ((10#$x > 10#$y)); then echo ">"; return 2; fi
        if ((10#$x < 10#$y)); then echo "<"; return 1; fi
    done
    echo "="
    return 0
}

version_ge() {
    vercmp "$1" "$2" > /dev/null
    (($? != 1))
}

strip() {
    local v=${1#v}
    v=${v%%[-+]*}
    printf '%s' "$v"
}

pairs=(
    "1.0 1.0.0"
    "1.2 1.10"
    "2.0.1 2.0"
    "0.9.9 1.0"
    "1.08 1.8"
    "10.4.2 9.99.99"
    "v3.1.4-beta 3.1.4"
)
for p in "${pairs[@]}"; do
    read -r l r <<< "$p"
    printf '%-12s %s %s\n' "$l" "$(vercmp "$(strip "$l")" "$(strip "$r")")" "$r"
done

# Insertion sort with the comparator.
releases=(1.10.0 1.2.3 1.2.10 0.9 2.0.0 1.2 1.2.3.1 10.0 1.9.9)
sorted=()
for v in "${releases[@]}"; do
    inserted=0
    new=()
    for s in "${sorted[@]+"${sorted[@]}"}"; do
        if ((!inserted)) && ! version_ge "$v" "$s"; then
            new+=("$v")
            inserted=1
        fi
        new+=("$s")
    done
    ((inserted)) || new+=("$v")
    sorted=("${new[@]}")
done
echo "sorted: ${sorted[*]}"
echo "oldest: ${sorted[0]} newest: ${sorted[-1]}"

required=1.2.5
for have in 1.2.4 1.2.5 1.3 0.99; do
    if version_ge "$have" "$required"; then
        echo "$have satisfies >= $required"
    else
        echo "$have is too old (need $required)"
    fi
done
