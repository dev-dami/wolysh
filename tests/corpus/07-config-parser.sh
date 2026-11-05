#!/usr/bin/env bash
# An INI file parser: sections, comments, trimming, quoting and typed lookups.
set -euo pipefail

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/app.ini" <<'INI'
; global settings
name = demo app
debug=false

[server]
host   =  0.0.0.0
port = 8080   # inline comment
  workers = 4

[database]
url = "postgres://db:5432/app"
pool=10
# commented = out
timeout = 2.5s

[empty]
[features]
beta = yes
legacy = no
INI

declare -A conf=()
sections=()

trim() {
    local s=$1
    s=${s#"${s%%[![:space:]]*}"}
    s=${s%"${s##*[![:space:]]}"}
    printf '%s' "$s"
}

section=global
sections+=("$section")
lineno=0
while IFS= read -r raw || [[ -n $raw ]]; do
    lineno=$((lineno + 1))
    line=$(trim "${raw%%[#;]*}")
    [[ -z $line ]] && continue
    if [[ $line =~ ^\[([A-Za-z0-9_]+)\]$ ]]; then
        section=${BASH_REMATCH[1]}
        sections+=("$section")
        continue
    fi
    if [[ $line =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
        key=${BASH_REMATCH[1]}
        value=${BASH_REMATCH[2]}
        value=${value#\"}
        value=${value%\"}
        conf[$section.$key]=$value
    else
        echo "line $lineno: cannot parse: $raw"
    fi
done < "$tmp/app.ini"

get() { local v=${conf[$1]-}; printf '%s' "${v:-$2}"; }
is_true() { case ${1,,} in yes|true|on|1) return 0 ;; *) return 1 ;; esac; }

echo "sections: ${sections[*]}"
for s in "${sections[@]}"; do
    echo "[$s]"
    for k in $(printf '%s\n' "${!conf[@]}" | sort); do
        [[ $k == "$s".* ]] && printf '  %-10s = %s\n' "${k#*.}" "${conf[$k]}"
    done
done

port=$(get server.port 80)
echo "listen on $(get server.host 127.0.0.1):$((port + 1)) with $(get server.workers 1) workers"
echo "missing key gives default: $(get server.tls off)"
for f in beta legacy missing; do
    if is_true "$(get "features.$f" no)"; then echo "feature $f: on"; else echo "feature $f: off"; fi
done
