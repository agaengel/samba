#!/usr/bin/env bash
# Update the pinned Alpine base tag and apk package versions in the Dockerfiles.
# Prints a markdown summary of the changes to stdout (empty if nothing changed).
set -euo pipefail
cd "$(dirname "$0")/.."

FILES=(Dockerfile Dockerfile.aarch64 Dockerfile.armhf)
PKGS=(bash samba shadow supervisor tzdata wsdd)
summary=""

base=$(sed -n 's|^FROM .*alpine:\([0-9.]*\)$|\1|p' Dockerfile)

# Newer Alpine release (e.g. 3.24 -> 3.25)?
major=${base%%.*}; minor=${base#*.}
while docker manifest inspect "alpine:$major.$((minor + 1))" >/dev/null 2>&1; do
    minor=$((minor + 1))
done
new_base="$major.$minor"
if [[ "$new_base" != "$base" ]]; then
    for f in "${FILES[@]}"; do
        sed -i "s|^\(FROM .*alpine:\)${base//./\\.}\$|\1$new_base|" "$f"
    done
    summary+="- Alpine base: \`$base\` -> \`$new_base\`"$'\n'
    base=$new_base
fi

# Latest package versions in that release's repositories
repo=$(docker run --rm "alpine:$base" sh -c "apk update -q >/dev/null; apk search -x ${PKGS[*]}")
for p in "${PKGS[@]}"; do
    var="APK_$(tr 'a-z' 'A-Z' <<<"$p")"
    new=$(grep -E "^$p-[0-9]" <<<"$repo" | sed "s/^$p-//" | sort -V | tail -n1 || true)
    [[ -n "$new" ]] || { echo "no version found for $p" >&2; exit 1; }
    old=$(sed -n "s/^ARG $var=//p" Dockerfile)
    if [[ "$old" != "$new" ]]; then
        for f in "${FILES[@]}"; do sed -i "s|^ARG $var=.*|ARG $var=$new|" "$f"; done
        summary+="- $p: \`$old\` -> \`$new\`"$'\n'
    fi
done
printf '%s' "$summary"
