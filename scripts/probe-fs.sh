#!/bin/sh
# Runs a FUSE file system in test mode (fusermount3 publishes its endpoint
# instead of running mount(8), so no FSKit is involved) and feeds
# fusetta-probe commands from stdin. Needs `swift build` first.
#
#   printf 'ls /\ncat /hello\n' | scripts/probe-fs.sh build/libfuse/example/hello_ll
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/fusetta-probe.XXXXXX")
trap 'kill $fs_pid 2>/dev/null || true; rm -rf "$tmp"' EXIT
mkdir "$tmp/mnt"
export FUSETTA_ENDPOINT_FILE="$tmp/endpoint"
# libfuse runs the mount helper from $PATH.
export PATH="$root/.build/debug:$PATH"
fs=$1; shift
"$fs" "$@" -f "$tmp/mnt" >"$tmp/fs.log" 2>&1 &
fs_pid=$!
i=0
while [ ! -s "$tmp/endpoint" ]; do
  i=$((i + 1)); [ $i -gt 50 ] && { echo "no endpoint"; cat "$tmp/fs.log"; exit 1; }
  sleep 0.1
done
"$root/.build/debug/fusetta-probe" "$(cat "$tmp/endpoint")" - || status=$?
wait $fs_pid 2>/dev/null || true
if [ -s "$tmp/fs.log" ]; then echo "--- fs log"; cat "$tmp/fs.log"; fi
exit ${status:-0}
