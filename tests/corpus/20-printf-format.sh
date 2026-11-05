#!/usr/bin/env bash
# printf: tables, padding, number bases, escapes, reuse of the format, -v.

items=("Disk usage:87" "Memory:42" "Swap:3" "CPU load:100")

bar() {
    local pct=$1 width=20 filled
    filled=$((pct * width / 100))
    printf -v full '%*s' "$filled" ''
    printf -v empty '%*s' $((width - filled)) ''
    printf '[%s%s]' "${full// /#}" "${empty// /.}"
}

printf '%-12s %5s %s\n' METRIC VALUE GRAPH
printf '%.0s=' {1..40}; printf '\n'
for it in "${items[@]}"; do
    name=${it%%:*} value=${it##*:}
    printf '%-12s %4d%% %s\n' "$name" "$value" "$(bar "$value")"
done

echo "--- numbers"
printf '%d|%5d|%-5d|%05d|%+d\n' 42 42 42 42 42
printf '%x|%X|%#x|%o|%#o\n' 255 255 255 8 8
printf '%.2f|%8.3f|%-8.1f|%e\n' 3.14159 2.5 9.99 12345.678
printf '%s=%d\n' a 1 b 2 c 3
printf '%c%c%c\n' wolysh shell zig
printf "%d\n" "'A" "'a"

echo "--- strings"
printf '[%10s][%-10s][%.3s][%10.2s]\n' right left truncated ab
printf '%s\n' "multiple" "arguments" "reuse the format"
printf '%b\n' 'tab:\there' 'newline:\nnext' 'octal:\101\102'
printf 'percent: 100%%\n'
printf '%q\n' "it's a test" 'plain' 'a b'
printf '%s|' "" "x" ""; printf '\n'

echo "--- printf -v"
printf -v padded '%08.3f' 3.14159
printf -v line '%s-%s' left right
echo "padded=$padded line=$line"
declare -A box=()
printf -v 'box[size]' '%dx%d' 640 480
echo "box size: ${box[size]}"

echo "--- a receipt"
total=0
while IFS='|' read -r qty desc cents; do
    sub=$((qty * cents))
    total=$((total + sub))
    printf '%3d  %-18s %4d.%02d\n' "$qty" "$desc" $((sub / 100)) $((sub % 100))
done <<'R'
2|Coffee beans 1kg|1899
1|Filter papers|349
12|Mug|650
R
printf '%3s  %-18s %4d.%02d\n' '' TOTAL $((total / 100)) $((total % 100))
printf '%s\n' "missing args:"; printf '<%s> <%d> <%s>\n' only
