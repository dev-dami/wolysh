#!/usr/bin/env bash
# mapfile and process substitution: load lines, skip, limit, compare streams.
set -euo pipefail

mapfile -t squares < <(for i in $(seq 1 8); do echo $((i * i)); done)
echo "squares (${#squares[@]}): ${squares[*]}"

mapfile -t -s 2 -n 3 middle < <(seq 10 10 100)
echo "skip 2, take 3: ${middle[*]}"

mapfile -t lines <<'EOF'
first line
  indented line

last line
EOF
echo "lines read: ${#lines[@]}"
for i in "${!lines[@]}"; do
    printf '%d:[%s]\n' "$i" "${lines[i]}"
done

# Keep the trailing newlines without -t.
mapfile raw < <(printf 'a\nb\n')
printf 'raw[0] has %d chars\n' "${#raw[0]}"

# Append to an existing array with -O.
nums=(zero)
mapfile -t -O 1 nums < <(seq 1 3)
echo "nums: ${nums[*]} (indices ${!nums[*]})"

# Read two streams side by side.
exec 3< <(printf '%s\n' apple banana cherry)
exec 4< <(printf '%s\n' red yellow)
while true; do
    IFS= read -r -u 3 fruit || break
    IFS= read -r -u 4 color || color=unknown
    echo "$fruit is $color"
done
exec 3<&- 4<&-

# Set operations on two sorted lists.
left=(pear apple fig kiwi)
right=(kiwi plum apple)
mapfile -t both < <(sort <(printf '%s\n' "${left[@]}" | sort -u) <(printf '%s\n' "${right[@]}" | sort -u) | {
    prev=""
    while read -r x; do [[ $x == "$prev" ]] && echo "$x"; prev=$x; done
})
echo "in both: ${both[*]}"

count=0
while read -r n; do
    ((n % 3 == 0)) && count=$((count + 1))
done < <(seq 1 30)
echo "multiples of 3 up to 30: $count (variable survives the loop)"

echo "line count via wc: $(wc -l < <(seq 1 42))"

# Callback mode.
report() { printf 'callback at index %d: %s\n' "$1" "$2"; }
mapfile -t -C report -c 2 cb < <(printf '%s\n' a b c d e)
echo "callback array: ${cb[*]}"
