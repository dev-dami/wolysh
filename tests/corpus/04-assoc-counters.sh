#!/usr/bin/env bash
# Associative arrays as counters and lookup tables over an access log.
set -u

declare -A hits=() bytes=() status_count=()
declare -A status_name=([200]=OK [301]="Moved" [404]="Not Found" [500]="Server Error")

while read -r ip method path code size; do
    [[ -z $ip || $ip == \#* ]] && continue
    hits[$ip]=$(( ${hits[$ip]:-0} + 1 ))
    bytes[$ip]=$(( ${bytes[$ip]:-0} + size ))
    ((status_count[$code]++)) || true
done <<'LOG'
# ip method path status bytes
10.0.0.1 GET /index.html 200 512
10.0.0.2 GET /missing 404 0
10.0.0.1 GET /about 200 1024
10.0.0.3 POST /api 500 64
10.0.0.2 GET /old 301 0
10.0.0.1 GET /contact 200 256

10.0.0.3 GET /index.html 200 512
LOG

echo "distinct clients: ${#hits[@]}"
for ip in $(printf '%s\n' "${!hits[@]}" | sort); do
    printf '%-10s hits=%d bytes=%d\n' "$ip" "${hits[$ip]}" "${bytes[$ip]}"
done

echo "by status:"
for code in $(printf '%s\n' "${!status_count[@]}" | sort -n); do
    printf '  %s %-12s %d\n' "$code" "${status_name[$code]:-unknown}" "${status_count[$code]}"
done

if [[ -n ${hits[10.0.0.9]+set} ]]; then
    echo "10.0.0.9 seen"
else
    echo "10.0.0.9 not seen"
fi

unset 'hits[10.0.0.2]'
echo "after removal: $(printf '%s\n' "${!hits[@]}" | sort | tr '\n' ' ')"

# Top client by bytes.
top='' best=-1
for ip in "${!bytes[@]}"; do
    if ((bytes[$ip] > best)); then
        best=${bytes[$ip]}; top=$ip
    fi
done
echo "top client: $top ($best bytes)"

declare -A lower=()
for k in "${!status_name[@]}"; do lower[$k]=${status_name[$k],,}; done
for k in $(printf '%s\n' "${!lower[@]}" | sort -n); do echo "$k=${lower[$k]}"; done
