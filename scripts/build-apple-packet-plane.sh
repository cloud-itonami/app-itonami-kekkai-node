#!/bin/sh
set -eu

repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
output_dir=${1:-"$repo_dir/build/packet-plane-apple"}

compiler_bin=${KOTOBA_BIN:-}
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

runtime_dir=${KOTOBA_IOS_RUNTIME_DIR:-"$repo_dir/../amu/runtime/ios"}
if [ ! -f "$runtime_dir/kotoba_ios_host.c" ] ||
   [ ! -f "$runtime_dir/kotoba_ios_host.h" ]; then
  echo "set KOTOBA_IOS_RUNTIME_DIR to the directory containing kotoba_ios_host.c/.h" >&2
  exit 2
fi

case "$(uname -m)" in
  arm64|aarch64) ;;
  *) echo "the Apple static packet-plane host currently requires arm64 macOS" >&2; exit 2 ;;
esac

source_file="$repo_dir/kotoba/kekkai/packet_plane.kotoba"
mkdir -p "$output_dir"

"$compiler_bin" -M check "$source_file" \
  --policy "$repo_dir/kotoba/policy.edn"
"$compiler_bin" -M compile "$source_file" --target aarch64-macos \
  --policy "$repo_dir/kotoba/policy.edn" \
  --output "$output_dir/packet-plane-macos.kexe"
"$compiler_bin" -M package-macos \
  "$output_dir/packet-plane-macos.kexe" --entry decide \
  --output "$output_dir/packet-plane-macos.o" \
  --manifest-output "$output_dir/packet-plane-macos.edn"

xcrun --sdk macosx clang -arch arm64 -I "$runtime_dir" \
  '-DKOTOBA_IOS_TARGET="aarch64-macos-kotoba-v1"' \
  -c "$runtime_dir/kotoba_ios_host.c" \
  -o "$output_dir/kotoba_ios_host.o"
xcrun --sdk macosx clang -arch arm64 -I "$runtime_dir" \
  -I "$repo_dir/platform/apple/Native" \
  '-DKEKKAI_KOTOBA_TARGET_PROFILE="aarch64-macos-kotoba-v1"' \
  -c "$repo_dir/platform/apple/Native/KotobaPacketPlaneBridge.c" \
  -o "$output_dir/KotobaPacketPlaneBridge.o"

# package-ios emits a Mach-O object file (despite historical callers using
# the .S suffix); archive that object directly instead of feeding it back to
# the assembler.
xcrun libtool -static -o "$output_dir/libKekkaiPacketPlane.a" \
  "$output_dir/packet-plane-macos.o" \
  "$output_dir/kotoba_ios_host.o" \
  "$output_dir/KotobaPacketPlaneBridge.o"

echo "built $output_dir/libKekkaiPacketPlane.a"
