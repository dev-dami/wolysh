#!/usr/bin/env bash
# Indexed arrays: append, slice, sparse indices, unset, sort and reverse.

fruits=(banana apple "dragon fruit" cherry)
fruits+=(elderberry)
fruits[10]=fig

echo "count: ${#fruits[@]}"
echo "indices: ${!fruits[*]}"
echo "first: ${fruits[0]} last: ${fruits[-1]}"
echo "slice 1-2: ${fruits[*]:1:2}"
echo "length of element 2: ${#fruits[2]}"

unset 'fruits[1]'
echo "after unset: ${#fruits[@]} -> ${!fruits[*]}"

i=0
for f in "${fruits[@]}"; do
    printf '%2d: %s\n' "$i" "$f"
    i=$((i + 1))
done

# Re-pack the sparse array and sort it.
packed=("${fruits[@]}")
echo "packed indices: ${!packed[*]}"
sorted=()
while IFS= read -r line; do
    sorted+=("$line")
done < <(printf '%s\n' "${packed[@]}" | sort)
echo "sorted: ${sorted[*]}"

reversed=()
for ((i = ${#sorted[@]} - 1; i >= 0; i--)); do
    reversed+=("${sorted[i]}")
done
(IFS=,; echo "reversed: ${reversed[*]}")

# Arrays of numbers: min, max, sum.
nums=(42 7 19 88 3 56)
min=${nums[0]} max=${nums[0]} sum=0
for n in "${nums[@]}"; do
    ((n < min)) && min=$n
    ((n > max)) && max=$n
    sum=$((sum + n))
done
echo "min=$min max=$max sum=$sum avg=$((sum / ${#nums[@]}))"

# Remove matching elements in place.
words=(alpha beta gamma beta delta beta)
for i in "${!words[@]}"; do
    [[ ${words[i]} == beta ]] && unset 'words[i]'
done
echo "without beta: ${words[*]} (${#words[@]} left)"
echo "uppercased: ${words[*]^^}"
echo "first letter dropped: ${words[*]#?}"
