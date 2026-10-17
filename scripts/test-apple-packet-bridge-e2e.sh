#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
verification_root="${KEKKAI_VERIFICATION_ROOT:-/Users/junkawasaki/github/workspaces/codex}"
kotoba_root="${KOTOBALANG_ROOT:-$(cd "$repo_root/../../../../kotoba-lang" && pwd)}"
amu_root="$kotoba_root/amu"
KBB_HOME="${KBB_HOME:-$amu_root}"
KBB_ENGINE="${KBB_ENGINE:-$KBB_HOME/node_modules/nbb/cli.js}"
mkdir -p "$verification_root"
test_root="$(mktemp -d "$verification_root/k-XXXXXX")"
chmod 700 "$test_root"
trap 'rm -rf "$test_root"' EXIT INT TERM

swift_binary="$test_root/apple-packet-bridge-e2e"
swiftc -swift-version 5 -module-cache-path "$test_root/module-cache" -framework Network \
  "$repo_root/platform/apple/Sources/KekkaiTunnel/KekkaiTransport.swift" \
  "$repo_root/platform/apple/Sources/KekkaiTunnel/KekkaiLocalNodeTransport.swift" \
  "$repo_root/test/apple_packet_bridge_e2e.swift" \
  -o "$swift_binary"

classpath="$repo_root/src:$repo_root/test:$kotoba_root/bytes/src:$kotoba_root/noise/src:$kotoba_root/org-ietf-dns/src:$kotoba_root/org-ietf-turn/src:$kotoba_root/org-ietf-ed25519/src:$kotoba_root/tech-ipfs-specs-ipns/src:$kotoba_root/io-multiformats/src:$kotoba_root/error/src:$kotoba_root/io/src:$kotoba_root/coll/src:$kotoba_root/edn/src:$kotoba_root/text/src:$kotoba_root/langgraph/src"
cd "$repo_root"
TMPDIR="$test_root" \
KEKKAI_APPLE_PACKET_TRANSPORT_HARNESS="$swift_binary" \
KBB_HOME="$KBB_HOME" \
KBB_ENGINE="$KBB_ENGINE" \
kbb --backend sci --classpath "$classpath" test/tun_e2e.cljk
