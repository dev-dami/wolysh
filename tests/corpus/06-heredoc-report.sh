#!/usr/bin/env bash
# Here-documents and here-strings: generated files, literal blocks, tab stripping.
set -eu

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

project="wolysh"
version="1.0.0"
authors=(ada grace linus)

cat > "$work/README" <<EOF
# $project $version

Authors: ${authors[*]}
Author count: ${#authors[@]}
Build: \$(make) is not run here, but $(echo substituted) is.
EOF

cat > "$work/install.sh" <<'EOF'
#!/bin/sh
# Literal: $HOME and $(pwd) are not expanded.
prefix=${PREFIX:-/usr/local}
echo "installing to $prefix"
EOF

if true; then
	cat <<-EOF
	Indented block for $project:
		every leading tab is stripped, even two
	end of block
	EOF
fi

echo "--- README"
cat "$work/README"
echo "--- install.sh"
cat "$work/install.sh"
echo "--- line counts"
printf 'README %s\n' "$(wc -l < "$work/README")"
printf 'install.sh %s\n' "$(wc -l < "$work/install.sh")"

# Here-strings feed single values to read and to filters.
read -r first second rest <<< "alpha beta gamma delta"
echo "first=$first second=$second rest=$rest"
IFS=: read -r user _ uid gid _ home shell <<< "deploy:x:1001:1001:Deploy User:/srv/deploy:/bin/bash"
echo "user=$user uid=$uid gid=$gid home=$home shell=$shell"
upper=$(tr '[:lower:]' '[:upper:]' <<< "$project rocks")
echo "$upper"
words=$(wc -w <<< "one two three four")
echo "words=$words"

# A here-document as the input of a loop.
total=0
while read -r item qty price; do
    line=$((qty * price))
    total=$((total + line))
    printf '%-8s %3d x %4d = %6d\n' "$item" "$qty" "$price" "$line"
done <<ITEMS
widget 3 250
gadget 1 1999
gizmo 12 75
ITEMS
printf '%-8s %21d\n' total "$total"

# A here-document passed to a function.
indent() { while IFS= read -r l; do printf '    %s\n' "$l"; done; }
indent <<'END'
keep $this
and   this
END
