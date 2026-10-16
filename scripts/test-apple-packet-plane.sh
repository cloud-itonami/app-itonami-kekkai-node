#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$repo_dir/build/packet-plane-apple"}
"$repo_dir/scripts/build-apple-packet-plane.sh" "$output_dir"
xcrun --sdk macosx clang -arch arm64 \
  "$repo_dir/test/apple_packet_plane_smoke.c" \
  "$output_dir/libKekkaiPacketPlane.a" \
  -o "$output_dir/apple-packet-plane-smoke"
"$output_dir/apple-packet-plane-smoke"
