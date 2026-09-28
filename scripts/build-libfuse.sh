#!/bin/sh
# Builds upstream libfuse 3 (LGPL-2.1) for macOS.
#
# Applies patches/libfuse-$version-darwin.patch to the release tarball and
# builds it with meson. The Darwin mount backend needs libfuse's custom I/O
# (-Denable-custom-io).
#
#   scripts/build-libfuse.sh                 # build into build/libfuse
#   PREFIX=/usr/local scripts/build-libfuse.sh install
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
PREFIX=${PREFIX:-/usr/local}
version=3.18.3
sha256=bcd19582c5e30f7fe45dd86a5540e998590aa01903afc7ebcbeea6c8ac5421ee
tarball=build/fuse-$version.tar.gz
src=build/libfuse-src
out=build/libfuse

mkdir -p build
if [ ! -f "$tarball" ]; then
  curl -fsSL --retry 3 -o "$tarball.part" \
    "https://github.com/libfuse/libfuse/releases/download/fuse-$version/fuse-$version.tar.gz"
  mv "$tarball.part" "$tarball"
fi
if ! echo "$sha256  $tarball" | shasum -a 256 -c -s; then
  echo "checksum mismatch for $tarball; removed it, run again" >&2
  rm -f "$tarball"
  exit 1
fi
rm -rf "$src"
mkdir -p "$src"
tar -xzf "$tarball" -C "$src" --strip-components 1
patch -s -d "$src" -p1 < "patches/libfuse-$version-darwin.patch"

if [ ! -f "$out/build.ninja" ]; then
  meson setup "$out" "$src" --prefix "$PREFIX" \
    -Dexamples=true -Dtests=false -Dutils=false -Duseroot=false \
    -Denable-custom-io=true
fi
ninja -C "$out"

if [ "${1:-}" = install ]; then
  ninja -C "$out" install
fi
