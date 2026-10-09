#!/bin/sh
# Mirrors Herdr's agent-detection manifests into the embedded manifest
# directory and records the upstream commit. Usage:
#
#   tools/herdr-manifests/sync.sh [ref]   # branch, tag or commit; default: Herdr's default branch
#
# Manifests Herdr no longer ships are removed. Afterwards run
# `go test ./internal/terminal/...`: the engine refuses (panics on) a manifest
# that uses a rule feature it does not implement, naming the rule.
set -eu

ref=${1:-HEAD}
repo=https://github.com/herdrdev/herdr.git
root=$(cd "$(dirname "$0")/../.." && pwd)
dest=$root/internal/terminal/agentrules/manifests

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git -C "$work" init --quiet
git -C "$work" fetch --quiet --depth 1 "$repo" "$ref"
git -C "$work" checkout --quiet FETCH_HEAD
commit=$(git -C "$work" rev-parse HEAD)

src=$work/src/detect/manifests
if ! ls "$src"/*.toml >/dev/null 2>&1; then
	echo "no manifests at src/detect/manifests in herdr $ref" >&2
	exit 1
fi

rm -f "$dest"/*.toml
cp "$src"/*.toml "$dest"/
echo "$commit" >"$dest/HERDR_COMMIT"
echo "synced $(ls "$src"/*.toml | wc -l | tr -d ' ') manifests from herdr $commit"
