#!/usr/bin/env bash
# IFS: splitting PATH-like strings, read -a, joining with "$*", empty fields.

search_path="/usr/local/bin:/usr/bin::/opt/tools/bin:"

# Split with a local IFS inside a function.
split_path() {
    local IFS=:
    local -a parts
    read -ra parts <<< "$1"
    local i
    for i in "${!parts[@]}"; do
        printf '  %d [%s]\n' "$i" "${parts[i]:-.}"
    done
    echo "  ${#parts[@]} entries"
}
echo "PATH entries:"
split_path "$search_path"
echo "IFS is back to default: $([[ $IFS == $' \t\n' ]] && echo yes || echo no)"

# Unquoted expansion with a custom IFS drops nothing but the separators.
data="a,b,,c"
IFS=,
set -- $data
echo "set -- gives $# fields:" "$@"
unset IFS
set -- $data
echo "with default IFS: $# field(s)"

# Whitespace IFS collapses runs; non-whitespace IFS keeps empty fields.
line="  lots   of    spaces  "
read -ra words <<< "$line"
echo "whitespace split: ${#words[@]} words -> $(printf '<%s>' "${words[@]}")"
IFS=';' read -ra cells <<< "x;;y; z ;"
echo "semicolon split: ${#cells[@]} cells -> $(printf '<%s>' "${cells[@]}")"
IFS=' ;' read -ra mixed <<< "x ; y;;z"
echo "mixed split: ${#mixed[@]} cells -> $(printf '<%s>' "${mixed[@]}")"

# read assigns the remainder to the last variable.
IFS=: read -r key value <<< "Content-Type: text/html; charset=utf-8"
echo "key=[$key] value=[${value# }]"
IFS== read -r k v rest <<< "a=b=c=d"
echo "k=$k v=$v rest=$rest"

# "$*" joins with the first character of IFS; "$@" keeps the words.
set -- red green "light blue"
IFS=,
echo "joined: $*"
IFS='|-'
echo "joined: $*"
unset IFS
echo "joined: $*"
printf '[%s] ' "$@"; echo

# Parse /etc/passwd-style records without touching the real file.
while IFS=: read -r user _ uid _ _ home shell; do
    ((uid >= 1000)) || continue
    printf '%-6s %5d %-12s %s\n' "$user" "$uid" "$home" "${shell##*/}"
done <<'PASSWD'
root:x:0:0:root:/root:/bin/bash
alice:x:1000:1000:Alice:/home/alice:/bin/bash
daemon:x:2:2:daemon:/sbin:/usr/sbin/nologin
bob:x:1001:1001:Bob,,,:/home/bob:/bin/zsh
PASSWD

# Splitting a command substitution on newlines only.
IFS=$'\n'
files=($(printf '%s\n' "one file.txt" "two file.txt"))
unset IFS
echo "newline split: ${#files[@]} -> ${files[1]}"
