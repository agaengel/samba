#!/usr/bin/env bash
# Delete the Docker Hub tags of a removed branch or closed PR.
#   scripts/cleanup-tags.sh branch <branch-name>
#   scripts/cleanup-tags.sh pr <number>
# Needs DOCKERHUB_REPO, DOCKERHUB_USERNAME, DOCKERHUB_TOKEN (token needs
# delete permission). DRY_RUN=1 only prints. TAGS_FILE=<file> reads the tag
# list from a file instead of Docker Hub (for tests).
# Limits: branches whose names sanitize to the same tag (feature/x and
# feature-x) or look like <other>-<x.y.z> share tags and are removed together;
# branch names that look like a version with a dot (1.0-wip, v2.1) are never
# cleaned up.
set -euo pipefail

kind="${1:?usage: kind name}"; name="${2:?usage: kind name}"
case "$kind" in
    branch) base=$(sed 's/[^a-zA-Z0-9._-]\+/-/g' <<<"$name") ;;  # as docker/metadata-action
    pr) [[ "$name" =~ ^[0-9]+$ ]] || { echo "PR number must be numeric: $name" >&2; exit 2; }
        base="pr-$name" ;;
    *) echo "unknown kind: $kind" >&2; exit 2 ;;
esac

# Tags built for a branch/PR are <base> and <base>-<x.y.z>; never touch the
# release tags (latest, 4.23, 4.23.8, 4.23.8-alpine3.24, v4.23.8-3).
matching() {
    local re="^$(sed 's/[.]/\\./g' <<<"$base")(-[0-9]+\.[0-9]+\.[0-9]+)?$"
    grep -E "$re" | grep -Ev '^(latest|v?[0-9]+\.[0-9]+(\.[0-9]+)*(-.*)?)$' || true
}

api=https://hub.docker.com/v2
if [[ -n "${TAGS_FILE:-}" ]]; then
    tags=$(matching <"$TAGS_FILE")
else
    jwt=$(jq -n --arg u "$DOCKERHUB_USERNAME" --arg p "$DOCKERHUB_TOKEN" '{username:$u,password:$p}' |
        curl -fsS -H 'Content-Type: application/json' -d @- "$api/users/login" | jq -er .token)
    url="$api/repositories/$DOCKERHUB_REPO/tags?page_size=100"
    all=""
    while [[ -n "$url" && "$url" != null ]]; do
        page=$(curl -fsS -H "Authorization: JWT $jwt" "$url")
        all+=$(jq -r '.results[].name' <<<"$page")$'\n'
        url=$(jq -r '.next' <<<"$page")
    done
    tags=$(matching <<<"$all")
fi

[[ -n "$tags" ]] || { echo "no tags to delete for $kind $name"; exit 0; }
rc=0
for t in $tags; do
    if [[ -n "${DRY_RUN:-}" || -n "${TAGS_FILE:-}" ]]; then
        echo "would delete $t"
    else
        echo "deleting $t"
        # keep going after a failure (e.g. tag already gone), report at the end
        curl -fsS -X DELETE -H "Authorization: JWT $jwt" \
            "$api/repositories/$DOCKERHUB_REPO/tags/$t/" >/dev/null || { echo "failed: $t" >&2; rc=1; }
    fi
done
exit $rc
