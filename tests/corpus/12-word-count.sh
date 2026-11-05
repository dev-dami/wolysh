#!/usr/bin/env bash
# A word counter in the style of wc plus a frequency table.
set -euo pipefail
export LC_ALL=C

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/a.txt" <<'TXT'
The shell reads the script. The shell runs the script!
Words, words, words: the shell counts them all.
TXT
printf 'one\ntwo two\nthree three three\n' > "$tmp/b.txt"
: > "$tmp/empty.txt"

count_file() {
    local file=$1 lines=0 words=0 chars=0 line
    local -a w
    while IFS= read -r line || [[ -n $line ]]; do
        lines=$((lines + 1))
        read -ra w <<< "$line"
        words=$((words + ${#w[@]}))
        chars=$((chars + ${#line} + 1))
    done < "$file"
    printf '%5d %5d %5d %s\n' "$lines" "$words" "$chars" "${file##*/}"
    tot_l=$((tot_l + lines)); tot_w=$((tot_w + words)); tot_c=$((tot_c + chars))
}

tot_l=0 tot_w=0 tot_c=0
for f in "$tmp"/*.txt; do
    count_file "$f"
done
printf '%5d %5d %5d %s\n' "$tot_l" "$tot_w" "$tot_c" total

# Cross-check against wc.
for f in "$tmp"/a.txt "$tmp"/b.txt; do
    read -r l w c _ < <(wc "$f")
    echo "wc agrees for ${f##*/}: $l $w $c"
done

declare -A freq=()
while read -r word; do
    [[ -z $word ]] && continue
    freq[$word]=$(( ${freq[$word]:-0} + 1 ))
done < <(cat "$tmp"/*.txt | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z' '\n')

echo "distinct words: ${#freq[@]}"
echo "top words:"
for w in "${!freq[@]}"; do
    printf '%d %s\n' "${freq[$w]}" "$w"
done | sort -k1,1nr -k2,2 | {
    rank=0
    while read -r n w && ((rank < 5)); do
        rank=$((rank + 1))
        printf '  %d. %-6s %2d %s\n' "$rank" "$w" "$n" "$(printf '%*s' "$n" '' | tr ' ' '#')"
    done
}

longest=$(for w in "${!freq[@]}"; do printf '%d %s\n' "${#w}" "$w"; done | sort -k1,1nr -k2,2 | cut -d' ' -f2 | { read -r first; echo "$first"; })
echo "longest word: $longest (${#longest} letters)"
