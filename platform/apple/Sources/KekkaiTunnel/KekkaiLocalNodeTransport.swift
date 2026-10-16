import Darwin
import Foundation
import Network

/// User-context host adapter for the local framed socket served by
/// `kekkai.node.packet-bridge`. The menu-bar app owns this connection and
/// relays bounded frames to the global system extension over XPC. The Node
/// process owns signed-netmap checks, Noise sessions, route selection, and
/// revocation.
public final class KekkaiLocalNodeTransport: KekkaiPacketTransport {
    private enum BridgeError: LocalizedError {
        case missingSocketPath
        case invalidSocketPath
        case startTimedOut
        case notReady
        case disconnected
        case invalidFrame
        case invalidPacket
        case invalidControlFrame

        var errorDescription: String? {
            switch self {
            case .missingSocketPath: return "Kekkai packet bridge path is missing"
            case .invalidSocketPath: return "Kekkai packet bridge path must be absolute"
            case .startTimedOut: return "Kekkai packet bridge did not become ready in time"
            case .notReady: return "Kekkai packet bridge is not ready"
            case .disconnected: return "Kekkai packet bridge disconnected"
            case .invalidFrame: return "Kekkai packet bridge frame is invalid"
            case .invalidPacket: return "Kekkai packet is invalid"
            case .invalidControlFrame: return "Kekkai underlay control frame is invalid"
            }
        }
    }

    private static let maxPacketBytes = 65_575
    private static let maxFrameBytes = 262_144

    private let queue = DispatchQueue(label: "jp.kotoba.kekkai.local-node-transport")
    private let readyLock = NSLock()
    private var readyValue = false
    private var connection: NWConnection?
    private var receiveHandler: ((Data, NSNumber) -> Void)?
    private var underlayHandler: ((KekkaiUnderlaySnapshot) -> Void)?
    private var failureHandler: ((Error) -> Void)?
    private var startCompletion: ((Error?) -> Void)?
    private var startupTimeout: DispatchWorkItem?
    private var input = Data()
    private var startCompleted = false
    private var receiveStarted = false
    private var stopped = false
    private var terminalFailure = false

    public var ready: Bool {
        readyLock.lock()
        defer { readyLock.unlock() }
        return readyValue
    }

    public init() {}

    public func start(
        configuration: [String: Any],
        receive: @escaping (Data, NSNumber) -> Void,
        underlay: @escaping (KekkaiUnderlaySnapshot) -> Void,
        failure: @escaping (Error) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        queue.async {
            guard self.connection == nil else {
                completion(BridgeError.notReady)
                return
            }
            guard let path = self.socketPath(configuration) else {
                completion(BridgeError.missingSocketPath)
                return
            }
            guard path.hasPrefix("/") else {
                completion(BridgeError.invalidSocketPath)
                return
            }

            self.receiveHandler = receive
            self.underlayHandler = underlay
            self.failureHandler = failure
            self.startCompletion = completion
            let timeout = DispatchWorkItem { [weak self] in
                guard let self, !self.startCompleted else { return }
                self.fail(BridgeError.startTimedOut)
            }
            self.startupTimeout = timeout
            self.queue.asyncAfter(deadline: .now() + 15, execute: timeout)
            self.startCompleted = false
            self.receiveStarted = false
            self.stopped = false
            self.terminalFailure = false
            self.input.removeAll(keepingCapacity: false)

            let connection = NWConnection(to: .unix(path: path), using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self] state in
                self?.stateChanged(state)
            }
            connection.start(queue: self.queue)
        }
    }

    public func send(
        packet: Data,
        protocolFamily: NSNumber,
        completion: @escaping (Error?) -> Void
    ) {
        queue.async {
            guard !self.stopped, let connection = self.connection, self.ready else {
                completion(BridgeError.notReady)
                return
            }
            guard let parsed = Self.parse(packet),
                  parsed.family == protocolFamily.int32Value else {
                completion(BridgeError.invalidPacket)
                return
            }

            var length = UInt32(parsed.bytes.count).bigEndian
            var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
            frame.append(parsed.bytes)
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else {
                    completion(BridgeError.disconnected)
                    return
                }
                self.queue.async {
                    if let error { self.fail(error) }
                    completion(error)
                }
            })
        }
    }

    public func stop() {
        stop(completion: {})
    }

    public func stop(completion: @escaping () -> Void) {
        queue.async {
            self.stopped = true
            self.setReady(false)
            self.startCompletion = nil
            self.startupTimeout?.cancel()
            self.startupTimeout = nil
            self.receiveHandler = nil
            self.underlayHandler = nil
            self.failureHandler = nil
            self.input.removeAll(keepingCapacity: false)
            let connection = self.connection
            self.connection = nil
            guard let connection else {
                completion()
                return
            }
            if case .cancelled = connection.state {
                completion()
                return
            }
            connection.stateUpdateHandler = { [weak connection] state in
                guard case .cancelled = state else { return }
                connection?.stateUpdateHandler = nil
                completion()
            }
            connection.cancel()
        }
    }

    public func acknowledgeUnderlay(addresses: [String]) {
        queue.async {
            self.sendControlFrame(type: 2, payload: ["addresses": addresses])
        }
    }

    public func releaseUnderlayGuard(completion: @escaping () -> Void) {
        queue.async {
            guard self.connection != nil, !self.stopped else {
                completion()
                return
            }
            self.sendControlFrame(type: 4, payload: [:]) { _ in completion() }
        }
    }

    private func socketPath(_ configuration: [String: Any]) -> String? {
        if let path = configuration["packetBridgePath"] as? String {
            return path
        }
        #if os(macOS)
        return "/var/run/kekkai/packet.sock"
        #else
        return nil
        #endif
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            setReady(true)
            sendControlFrame(type: 3, payload: [:])
            if !startCompleted {
                startCompleted = true
                startupTimeout?.cancel()
                startupTimeout = nil
                let completion = startCompletion
                startCompletion = nil
                completion?(nil)
            }
            if !receiveStarted {
                receiveStarted = true
                receiveNext()
            }
        case .waiting:
            // Network.framework may recover automatically after a path change.
            setReady(false)
        case .failed(let error):
            fail(error)
        case .cancelled:
            if !stopped { fail(BridgeError.disconnected) }
        default:
            break
        }
    }

    private func receiveNext() {
        guard !stopped, !terminalFailure, let connection else { return }
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: Self.maxPacketBytes + MemoryLayout<UInt32>.size
        ) { [weak self] data, _, complete, error in
            guard let self, !self.stopped, !self.terminalFailure else { return }
            if let error {
                self.fail(error)
                return
            }
            if let data, !data.isEmpty {
                self.input.append(data)
                guard self.drainFrames() else { return }
            }
            if complete {
                self.fail(BridgeError.disconnected)
                return
            }
            self.receiveNext()
        }
    }

    /// Decode the same uint32-BE framing used by `kekkai.node.packet-bridge`.
    /// The loop handles both split headers and several packets in one read.
    private func drainFrames() -> Bool {
        while input.count >= MemoryLayout<UInt32>.size {
            let length = input.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard length > 0, length <= Self.maxFrameBytes else {
                fail(BridgeError.invalidFrame)
                return false
            }
            let frameSize = MemoryLayout<UInt32>.size + Int(length)
            guard input.count >= frameSize else { return true }

            let packet = input.subdata(in: 4..<frameSize)
            input.removeSubrange(0..<frameSize)
            if packet.starts(with: Self.underlayMagic) {
                guard let snapshot = Self.parseUnderlay(packet) else {
                    fail(BridgeError.invalidControlFrame)
                    return false
                }
                underlayHandler?(snapshot)
                continue
            }
            guard let parsed = Self.parse(packet) else {
                fail(BridgeError.invalidPacket)
                return false
            }
            let family = parsed.family == Int32(AF_INET) ? AF_INET : AF_INET6
            receiveHandler?(parsed.bytes, NSNumber(value: family))
        }
        return true
    }

    private func fail(_ error: Error) {
        guard !stopped, !terminalFailure else { return }
        terminalFailure = true
        startupTimeout?.cancel()
        startupTimeout = nil
        setReady(false)
        if !startCompleted {
            startCompleted = true
            let completion = startCompletion
            startCompletion = nil
            completion?(error)
        } else {
            failureHandler?(error)
        }
        connection?.cancel()
    }

    private func setReady(_ value: Bool) {
        readyLock.lock()
        readyValue = value
        readyLock.unlock()
    }

    private func sendControlFrame(
        type: UInt8,
        payload: [String: Any],
        completion: ((Error?) -> Void)? = nil
    ) {
        guard let connection,
              let json = try? JSONSerialization.data(withJSONObject: payload) else {
            completion?(BridgeError.disconnected)
            return
        }
        var body = Data([0x4b, 0x4b, 0x42, 0x31, type])
        body.append(json)
        var length = UInt32(body.count).bigEndian
        var frame = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        frame.append(body)
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else {
                completion?(BridgeError.disconnected)
                return
            }
            self.queue.async {
                if let error {
                    if type != 4 { self.fail(error) }
                    completion?(error)
                } else {
                    completion?(nil)
                }
            }
        })
    }

    private static func parse(_ packet: Data) -> (bytes: Data, family: Int32)? {
        guard let first = packet.first else { return nil }
        switch first >> 4 {
        case 4:
            guard packet.count >= 20 else { return nil }
            let headerLength = Int(first & 0x0f) * 4
            guard headerLength >= 20, packet.count >= headerLength else { return nil }
            let totalLength = (Int(packet[packet.startIndex + 2]) << 8)
                | Int(packet[packet.startIndex + 3])
            guard totalLength == packet.count, totalLength <= maxPacketBytes else { return nil }
            return (packet, Int32(AF_INET))
        case 6:
            guard packet.count >= 40 else { return nil }
            let payloadLength = (Int(packet[packet.startIndex + 4]) << 8)
                | Int(packet[packet.startIndex + 5])
            guard 40 + payloadLength == packet.count, packet.count <= maxPacketBytes else {
                return nil
            }
            return (packet, Int32(AF_INET6))
        default:
            return nil
        }
    }

    private static let underlayMagic = Data([0x4b, 0x4b, 0x42, 0x31, 0x01])

    private static func parseUnderlay(_ frame: Data) -> KekkaiUnderlaySnapshot? {
        guard frame.count > underlayMagic.count,
              let object = try? JSONSerialization.jsonObject(
                with: Data(frame.dropFirst(underlayMagic.count))),
              let json = object as? [String: Any],
              let ready = json["ready"] as? Bool,
              let addresses = json["addresses"] as? [String],
              addresses.count <= 4096,
              addresses.allSatisfy({ isIPAddress($0) }),
              let rawRoutes = json["routes"] as? [[String: Any]],
              rawRoutes.count <= 4096 else { return nil }
        let routes = rawRoutes.compactMap { route -> KekkaiNetworkRoute? in
            guard let family = route["family"] as? Int,
                  let prefix = route["prefix"] as? [Int],
                  let bits = route["bits"] as? Int else { return nil }
            return KekkaiNetworkRoute(
                family: family,
                prefix: prefix,
                prefixLength: bits)
        }
        guard routes.count == rawRoutes.count else { return nil }
        return KekkaiUnderlaySnapshot(
            ready: ready,
            addresses: addresses,
            routes: routes)
    }

    private static func isIPAddress(_ value: String) -> Bool {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
        var ipv6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1
    }
}
