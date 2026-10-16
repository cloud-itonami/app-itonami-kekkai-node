#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler_bin=${KOTOBA_BIN:-}
if [ -z "$compiler_bin" ] && [ -x "$repo_dir/../compiler/bin/kotoba" ]; then
  compiler_bin="$repo_dir/../compiler/bin/kotoba"
fi
if [ -z "$compiler_bin" ] && [ -x "$repo_dir/../amu/bin/kotoba" ]; then
  compiler_bin="$repo_dir/../amu/bin/kotoba"
fi
if [ -z "$compiler_bin" ]; then
  compiler_bin=$(command -v kotoba || true)
fi
if [ -z "$compiler_bin" ] || [ ! -x "$compiler_bin" ]; then
  echo "set KOTOBA_BIN to the executable amu/bin/kotoba launcher" >&2
  exit 2
fi
source_file="$repo_dir/kotoba/kekkai/packet_plane.kotoba"
output_dir="$repo_dir/build/packet-plane"

mkdir -p "$output_dir"

"$compiler_bin" -M compile "$source_file" --target js \
  --policy "$repo_dir/kotoba/policy.edn" \
  --output "$output_dir/packet-plane.mjs"
"$compiler_bin" -M compile "$source_file" --target aarch64-android \
  --policy "$repo_dir/kotoba/policy.edn" \
  --output "$output_dir/packet-plane-android.kexe"
