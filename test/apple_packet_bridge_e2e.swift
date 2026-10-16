import Darwin
import Foundation

@main
struct ApplePacketBridgeE2E {
    private static let packet = Data([
        0x45, 0, 0, 20, 0, 0, 0, 0, 64, 6, 0, 0,
        10, 0, 0, 1, 203, 0, 113, 9
    ])

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("usage: apple-packet-bridge-e2e <unix-socket-path>\n", stderr)
            exit(2)
        }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: Int32?
        var packetSubmitted = false
        let transport = KekkaiLocalNodeTransport()

        func finish(_ code: Int32, _ message: String) {
            lock.lock()
            guard result == nil else {
                lock.unlock()
                return
            }
            result = code
            lock.unlock()
            print(message)
            semaphore.signal()
        }

        transport.start(
            configuration: ["packetBridgePath": CommandLine.arguments[1]],
            receive: { _, _ in
                finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: unexpected reverse packet")
            },
            underlay: { snapshot in
                lock.lock()
                let shouldSubmit = !packetSubmitted
                packetSubmitted = true
                lock.unlock()
                guard shouldSubmit else { return }

                let hasAuthorizedDefaultRoute = snapshot.routes.contains {
                    $0.family == 4 && $0.prefix == [0, 0, 0, 0] && $0.prefixLength == 0
                }
                guard snapshot.ready,
                      snapshot.addresses.contains("127.0.0.1"),
                      hasAuthorizedDefaultRoute else {
                    finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: invalid underlay snapshot")
                    return
                }
                transport.acknowledgeUnderlay(addresses: snapshot.addresses)
                transport.send(packet: packet, protocolFamily: NSNumber(value: AF_INET)) { error in
                    if let error {
                        finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: \(error)")
                    } else {
                        transport.releaseUnderlayGuard {
                            finish(0, "APPLE_PACKET_BRIDGE_E2E_OK: Swift adapter sent raw IPv4; exit receipt is checked by the Kekkai harness")
                        }
                    }
                }
            },
            failure: { error in
                finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: \(error)")
            },
            completion: { error in
                if let error {
                    finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: \(error)")
                }
            })

        if semaphore.wait(timeout: .now() + 20) == .timedOut {
            finish(1, "APPLE_PACKET_BRIDGE_E2E_FAILED: timeout")
        }
        transport.stop()
        exit(result ?? 1)
    }
}
