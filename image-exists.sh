#!/usr/bin/env bash
# Exit 0 if the image tag exists, 1 if it does not, 2 on any other error.
set -uo pipefail
out=$(docker buildx imagetools inspect "$1" 2>&1) && exit 0
# GHCR answers "denied" for a package that does not exist yet. Counting that
# as absent is safe: publishing to a package we cannot read fails at the push.
if grep -Eqi 'not found|manifest unknown|name unknown|denied|403 forbidden' <<<"$out"; then
  exit 1
fi
echo "$out" >&2
exit 2
