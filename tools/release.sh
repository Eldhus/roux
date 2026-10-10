#!/bin/sh
# A roux release in dist/: the platform as roc's URL package
# (HASH.tar.zst, from `roc bundle`) and the tools, static, as
# roux-VERSION-x86_64-linux.tar.gz (roux, roux-db, roux-load). Then
#   gh release create vVERSION dist/* --title ... --notes ...
# An app names the platform by the release's URL:
#   https://github.com/Eldhus/roux/releases/download/vVERSION/HASH.tar.zst
#
# Needs the pinned Zig and roc (.zig-version, .roc-version, installed side
# by side as README says), `strip` (binutils), tar and gzip. The platform's
# host and musl go without debug information: roc unpacks a URL package up
# to 10 MB by default. Leaves the working tree's host as `zig build
# platform` makes it.
set -eu
cd "$(dirname "$0")/.."
zig=$HOME/.local/share/zig/zig-x86_64-linux-$(cat .zig-version)/zig
roc_version=$(cat .roc-version)
roc=$HOME/.local/share/roc-nightly/roc_nightly-linux_x86_64-${roc_version#nightly-}/roc

rm -rf dist
mkdir -p dist/stage/platform/targets/x64musl dist/tools

# The tools: static (musl), running the `roc` on PATH.
"$zig" build tools -Dtarget=x86_64-linux-musl -Droc=roc -p dist/tools
version=$(dist/tools/bin/roux version 2>&1 | sed -n 's/^roux \([^,]*\),.*/\1/p')
[ -n "$version" ] || { echo "release: no version from roux" >&2; exit 1; }

# The platform: its Roc modules, the host without debug information, musl.
"$zig" build platform -Dhost-strip=true
cp platform/*.roc dist/stage/platform/
cp platform/targets/x64musl/libhost.a platform/targets/x64musl/crt1.o \
	dist/stage/platform/targets/x64musl/
strip --strip-debug -o dist/stage/platform/targets/x64musl/libc.a \
	platform/targets/x64musl/libc.a
"$zig" build platform # the working tree's host, with its debug information again

(cd dist/stage/platform && "$roc" bundle --output-dir ../.. --compression 19 \
	main.roc $(ls *.roc | grep -v '^main\.roc$') targets/x64musl/*)

tar -C dist/tools/bin -czf "dist/roux-$version-x86_64-linux.tar.gz" roux roux-db roux-load
rm -rf dist/stage dist/tools
echo "roux $version, for roc $roc_version:"
ls -l dist
for bundle in dist/*.tar.zst; do
	echo "platform URL: https://github.com/Eldhus/roux/releases/download/v$version/$(basename "$bundle")"
done
