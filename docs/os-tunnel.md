# Kekkai OS packet tunnel

## Boundary

The packet tunnel is split into three independently enforced layers:

1. `kotoba/kekkai/packet_plane.kotoba` is the authority-free packet decision.
   It accepts five bounded integers and returns a closed action/reason code.
2. The OS adapter owns Network Extension, `VpnService`, `/dev/net/tun`, or the
   first-party Windows device handle. It validates packet structure before
   invoking the compiled Kotoba decision.
3. Kekkai-node owns authenticated Noise sessions, signed-netmap route
   selection, direct/relay transport, revocation, and peer identity.

The `.kotoba` guest never receives an OS descriptor or ambient socket. The
shared ABI is `aiueos:capability@0.4.0/packet-device`; the host owns its
non-serializable grant resource.

## Full-tunnel route model

A signed netmap grants both session establishment and packet forwarding:

```clojure
{:netmap/peers
 [{:node/id "exit-jp"
   :node/status "authorized"
   :node/routes
   [{:route/family 4 :route/prefix [0 0 0 0] :route/bits 0}
    {:route/family 6 :route/prefix [0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0]
     :route/bits 0}]}]
 :netmap/edges
 [{:edge/from "laptop-001" :edge/to "exit-jp"
   :edge/capabilities [:overlay :tun]}]}
```

Route selection is longest-prefix. Two equal best routes are ambiguous and
therefore denied. The OS tunnel installs the validated prefixes from the
directed signed `:tun` grants. Relay and public mTLS management IPs are added as
host exclusions before the node releases queued underlay traffic.

## Platform adapters

| Platform | Privileged adapter | Packet-plane binding |
|---|---|---|
| iOS/iPadOS | `NEPacketTunnelProvider` | iOS static AOT host, five scalar arguments |
| macOS | `NEPacketTunnelProvider` | same Apple static AOT boundary |
| Android | `VpnService` | build-gated host adapter verified against compiled Kotoba; native isolated host is a release gate |
| Linux | `/dev/net/tun`, `IFF_TUN | IFF_NO_PI` | local framed bridge; Node rechecks signed route |
| Windows | `\\.\Global\KekkaiTun` contract | userspace host; first-party NDIS package required |

The Apple adapter first waits for the local-node bridge and its initial
underlay snapshot, then installs only route prefixes from currently authorized,
directed `:tun` grants in the verified signed netmap. A missing route set fails
startup without changing the host route table. A signed `0.0.0.0/0` or `::/0`
is an explicit full-tunnel grant; otherwise the OS uses split routes and normal
internet traffic stays on the existing path. DNS settings are changed only
when the provider configuration includes explicit servers. The node resolves
the configured STUN and signed relay destinations plus signed peer candidates;
the bridge publishes those IPs in a versioned `KKB1` control frame. The
provider adds them as host-route exclusions, then acknowledges the installed
address set. The node queues UDP sends to unacknowledged hosts. It fails startup
if any required host cannot be resolved. New candidate snapshots update
exclusions while the tunnel runs; the node pauses sends to changed hosts until
the updated routes are acknowledged, and refreshes DNS answers every 60
seconds. The node also resolves configured heartbeat and netmap API origins,
plus configured SSH mirror roots, and publishes their addresses through the
same exclusion snapshot so control-plane polling and Murakumo CLI downloads
stay on the physical underlay. Kekkai-node uses one dual-stack UDP socket for
IPv4 and IPv6, resolves relay and STUN hostnames to both address families, and
rechecks the route guard after asynchronous DNS before sending. STUN IPv6
mappings and relay literals use the `[address]:port` candidate format. The provider sets an MTU of at least
1280, validates IPv4 total length and IPv6
payload length, and drops unless the authenticated bridge is ready. The
menu-bar host runs `KekkaiLocalNodeTransport` in the logged-in user's context
and opens the Kekkai-node UNIX socket in that user's app-group container. The
global system extension never opens that per-user path. Instead,
`KekkaiXPCTransport` and the host relay bounded packet and underlay frames over
the app-group-scoped privileged XPC service named by
`NetworkExtension.NEMachServiceName`; both ends require the expected host or
system-extension bundle identifier signed by the same Team ID. The tunnel
provider configuration key `packetBridgePath` must match the node's
`:packet-bridge :path`; the host app
defaults to `group.jp.kotoba.kekkai` and lets the operator set the matching
node socket path. Node continues to enforce the signed netmap, Noise peer
identity, route grants, and relay/direct selection. A missing XPC connection or
node socket fails tunnel startup, and a later bridge failure cancels the
tunnel rather than routing packets outside it.
The XPC service supports one host bridge at a time. It rejects a replacement
while the provider is attached, and releases the host identity only after the
host has stopped its socket bridge. Disconnect the active tunnel before
connecting from another logged-in user's session.
When quitting the menu-bar host with a tunnel active, it waits for VPN teardown
and underlay release before closing the bridge and XPC connection.

`platform/apple/project.yml` generates a macOS menu-bar host app and embeds
`jp.kotoba.kekkai.tunnel.systemextension` in
`Contents/Library/SystemExtensions`. The system-extension form supports direct
macOS distribution; the Packet Tunnel app-extension form is App Store only.
The host requests system-extension activation when the operator clicks
Connect, then saves/loads the VPN profile and configures the shared socket
path. macOS may require an administrator to approve the extension in System
Settings. The host and extension must use the same Team ID and matching
provisioning profiles. The host needs the System Extension install entitlement
and `NSSystemExtensionUsageDescription`; the Developer ID Release configuration
uses `packet-tunnel-provider-systemextension` on both targets. The Debug
configuration uses the standard `packet-tunnel-provider` entitlement for Apple
Development signing. Both targets carry the `group.jp.kotoba.kekkai` app-group
entitlement, which also prefixes the XPC service name. Set the Kekkai node's
`:packet-bridge :path` to the same user-context socket path shown in the host
app. The node process and host app run as the same user; the privileged XPC
bridge carries frames into the system extension.

Build an arm64 app and extension without a Developer ID signature or provisioning profile with:

```sh
cd platform/apple
xcodegen generate --spec project.yml
KOTOBA_BIN=/path/to/amu/bin/kotoba \
KOTOBA_IOS_RUNTIME_DIR=/path/to/amu/runtime/ios \
KBB_ENGINE=/path/to/nbb/cli.js \
xcodebuild -project KekkaiTunnel.xcodeproj -scheme KekkaiTunnelHost \
  -configuration Debug -destination 'generic/platform=macOS' -sdk macosx \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```

The extension target's build phase compiles and links the macOS Kotoba packet
plane. This build proves the host app, system extension, and XPC bridge compile
and embed together; it does not prove signed activation, the XPC handshake, or
the live packet path. For a Developer ID Release build, provide the team ID and
the two profile names using `KEKKAI_DEVELOPER_TEAM_ID`,
`KEKKAI_HOST_DEVELOPER_ID_PROFILE`, and
`KEKKAI_EXTENSION_DEVELOPER_ID_PROFILE`. A system extension must be signed
with those matching Developer ID profiles, installed with the host app under
`/Applications`, and receive the required macOS approval before runtime
testing.

This XPC bridge is a host IPC boundary, not the overlay transport itself. The
signed Network Extension sandbox, XPC service entitlement, socket ownership,
provisioning profiles, and full packet flow must be verified in the installed
app before claiming an operative system tunnel. An unsigned build does not
prove the extension can communicate with the host or route live packets.

The provider currently learns exclusions through the local node's authenticated
netmap and authenticated peer discovery state. The local socket protocol gates
UDP datagrams to a host until the extension acknowledges its installed
exclusion routes. This closes the candidate-discovery race at the node's UDP
send boundary. The independent-network full-tunnel gate remains open until the
packaged extension and daemon pass this behavior on a second physical network.
Static relay exclusions alone are not enough. Do not enable this profile for
production full-route use yet.

The Android adapter creates a blocking dual-stack `VpnService`, parses and
bounds every packet, and drops while the injected Kekkai transport is not
ready. A native transport must call `VpnService.protect` on every relay,
discovery, and management socket before connecting.
Android `preBuild` compiles the authoritative `.kotoba` source to both the
Android KEXE and executable JavaScript, then checks the host adapter against
the executable artifact's boundary vectors. The KEXE is deliberately not
loaded inside the `VpnService` process: the compiler contract requires an
independently authenticating Android isolated-process host, and physical
Arm64-device evidence for that boundary remains a mobile release gate.

The Linux process has no network socket. It owns only `/dev/net/tun` and a
local Unix socket to the unprivileged Kekkai node, allowing systemd to restrict
it to `AF_UNIX` and `CAP_NET_ADMIN`.

Windows cannot provide a first-party full tunnel from userspace alone. The
userspace device contract and client are present, but a production NDIS/WDK
driver, Microsoft signing, physical Windows testing, installer, and rollback
evidence remain release gates. This repository does not silently substitute
Wintun or another market driver.

## Tailscale coexistence

Nothing in this change uninstalls or disables Tailscale.

- During migration, desktop route metrics decide whether Kekkai or Tailscale
  owns a destination.
- iOS and Android normally permit only one active packet VPN. Tailscale remains
  installed and enrolled, but cannot carry the same default route
  simultaneously with Kekkai `NetworkExtension`/`VpnService`.
- Public mTLS management remains outside both tunnels.
- Moving a device from Tailscale to Kekkai requires an explicit MDM command and
  can be rolled back without removing either application.

## Build and verification

```sh
npm test
npm run build:packet-plane
KOTOBA_BIN=/path/to/amu/bin/kotoba \
  KOTOBA_IOS_RUNTIME_DIR=/path/to/amu/runtime/ios \
  npm run test:apple-packet-plane
npm run test:android-tunnel
cargo check --manifest-path platform/desktop/Cargo.toml
swiftc -typecheck -framework NetworkExtension \
  platform/apple/Sources/KekkaiTunnel/*.swift
```

The Apple static packet-plane host currently targets arm64 macOS and requires
`KOTOBA_BIN` plus `KOTOBA_IOS_RUNTIME_DIR` when those tools are not next to the
Kekkai-node checkout. `package-macos` emits a macOS Mach-O object; the Apple
build script archives it with the static host and the Kekkai bridge.
If the Amu checkout has no local `node_modules/nbb/cli.js`, also set
`KBB_ENGINE` to an installed Nbb `cli.js` file.

Apple execution still requires the Network Extension and app-group capabilities
on the registered App IDs, a matching provisioning profile, code signing, and
installation/approval of the embedded extension. Those Apple-controlled
credentials are deployment inputs, not repository secrets. Only after the
signed extension opens the shared daemon socket and completes a physical
network run can this count as an operative system tunnel.
