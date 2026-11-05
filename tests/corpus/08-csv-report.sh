#!/usr/bin/env bash
# CSV processing: IFS=, read loops, per-group totals, sort and cut, a table.
set -euo pipefail

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
csv=$dir/sales.csv

cat > "$csv" <<'CSV'
region,rep,product,units,unit_price
north,alice,widget,10,250
south,bob,gadget,3,1999
north,carol,gizmo,25,75
east,dave,widget,7,250
south,erin,widget,12,250
east,frank,gizmo,40,75
north,alice,gadget,2,1999
CSV

declare -A region_total=() rep_units=()
rows=0 grand=0
{
    read -r header
    while IFS=, read -r region rep product units price; do
        amount=$((units * price))
        region_total[$region]=$(( ${region_total[$region]:-0} + amount ))
        rep_units[$rep]=$(( ${rep_units[$rep]:-0} + units ))
        grand=$((grand + amount))
        rows=$((rows + 1))
    done
} < "$csv"

IFS=, read -ra columns <<< "$header"
echo "columns (${#columns[@]}): ${columns[*]}"
echo "rows: $rows"

money() { printf '%d.%02d' $(($1 / 100)) $(($1 % 100)); }

printf '%-8s %12s %6s\n' REGION AMOUNT SHARE
printf '%s\n' "----------------------------"
for r in $(printf '%s\n' "${!region_total[@]}" | sort); do
    t=${region_total[$r]}
    printf '%-8s %12s %5d%%\n' "$r" "$(money "$t")" $((t * 100 / grand))
done
printf '%-8s %12s\n' TOTAL "$(money "$grand")"

echo "units by rep (most first):"
for rep in "${!rep_units[@]}"; do
    printf '%s %s\n' "${rep_units[$rep]}" "$rep"
done | sort -k1,1nr -k2,2 | while read -r n who; do
    printf '  %-6s %3d\n' "$who" "$n"
done

mapfile -t body < <(cut -d, -f2- "$csv")
unset 'body[0]'
echo "distinct products: $(printf '%s\n' "${body[@]}" | cut -d, -f2 | sort -u | tr '\n' ' ')"
widget_rows=0
while IFS=, read -r _ _ product _; do
    [[ $product == widget ]] && widget_rows=$((widget_rows + 1))
done < "$csv"
echo "widget rows: $widget_rows"
largest=$(printf '%s\n' "${body[@]}" | sort -t, -k3,3nr | cut -d, -f1,3 | { read -r l; echo "$l"; })
echo "largest order: ${largest/,/ with } units"
