#!/bin/sh
# Stages the fff-smoke binary and the vendored dylib into an otherwise empty
# directory, strips the repository rpath, and proves the pinned FFF library
# loads relocatably via @loader_path with ad-hoc signatures.
set -eu

repo="$(cd "$(dirname "$0")/../.." && pwd)"
libdir="$repo/third_party/fff/lib/darwin-arm64"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

(cd "$repo" && go build -o "$stage/fff-smoke" ./tools/fff-smoke)
cp "$libdir/libfff_c.dylib" "$stage/"
# Drop every build-time rpath (the cgo link bakes in the repository path)
# so only the staged @loader_path can satisfy the dylib load.
otool -l "$stage/fff-smoke" | awk '/LC_RPATH/{grab=1} grab && /path /{print $2; grab=0}' |
while IFS= read -r rpath; do
	install_name_tool -delete_rpath "$rpath" "$stage/fff-smoke"
done
install_name_tool -add_rpath "@loader_path" "$stage/fff-smoke"
codesign --force --sign - "$stage/fff-smoke"
codesign --force --sign - "$stage/libfff_c.dylib"

# Run away from the repository so a leftover repo path cannot mask a
# packaging failure.
cd /
"$stage/fff-smoke"
