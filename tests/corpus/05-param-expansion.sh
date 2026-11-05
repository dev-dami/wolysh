#!/usr/bin/env bash
# Parameter expansion on file names, URLs and defaults.

paths=(
    /var/log/nginx/access.log.2.gz
    ./src/main.zig
    archive.tar.xz
    README
    "/home/user/My Documents/report.final.pdf"
)

for p in "${paths[@]}"; do
    base=${p##*/}
    dir=${p%/*}
    [[ $dir == "$p" ]] && dir=.
    printf '%s\n' "$p"
    printf '  dir=%s base=%s stem=%s root=%s ext=%s allext=%s\n' \
        "$dir" "$base" "${base%.*}" "${base%%.*}" "${base##*.}" "${base#*.}"
done

url="https://example.com:8443/path/to/page?q=1&r=2"
proto=${url%%://*}
rest=${url#*://}
hostport=${rest%%/*}
host=${hostport%:*}
port=${hostport##*:}
query=${url#*\?}
echo "proto=$proto host=$host port=$port query=$query"

s="the quick brown fox jumps over the lazy dog"
echo "${s^^}"
echo "${s^}"
echo "${s//the/a}"
echo "${s/the/one}"
echo "${s// /_}"
echo "${s/#the/THE}"
echo "${s/%dog/cat}"
echo "length=${#s} sub=${s:4:5} tail=${s: -3} from10=${s:10}"

unset maybe
empty=""
echo "unset default: ${maybe:-fallback}"
echo "empty default: ${empty:-fallback} / [${empty-kept-empty}]"
echo "alt: ${s:+present} [${maybe:+absent}]"
: "${maybe:=assigned}"
echo "after := $maybe"

NAME=World
ref=NAME
echo "indirect: ${!ref}"

title="hello WORLD"
echo "${title,,} | ${title^^} | ${title,}"

ver="v1.22.3-rc1"
v=${ver#v}
v=${v%%-*}
minor=${v#*.}
minor=${minor%%.*}
echo "major=${v%%.*} minor=$minor patch=${v##*.}"

slug="  Mixed Case Title: Here!  "
slug=${slug,,}
slug=${slug//[^a-z0-9]/-}
while [[ $slug == *--* ]]; do slug=${slug//--/-}; done
slug=${slug#-}
slug=${slug%-}
echo "slug=$slug"
