import Foundation
import Darwin

final class KekkaiSystemExtensionXPCService: NSObject, NSXPCListenerDelegate {
    static let shared = KekkaiSystemExtensionXPCService()

    private let lock = NSLock()
    private let listener: NSXPCListener
    private var connection: NSXPCConnection?
    private var authenticatedUserID: uid_t?
    private weak var transport: KekkaiXPCTransport?

    private override init() {
        let serviceName = (Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String
            ?? "group.jp.kotoba.kekkai.service"
        listener = NSXPCListener(machServiceName: serviceName)
        super.init()
        listener.delegate = self
    }

    private var hostCodeSigningRequirement: String? {
        let teamIdentifierPrefix = Bundle.main.infoDictionary?["KekkaiTeamIdentifierPrefix"] as? String
        return KekkaiXPCSigningRequirement.make(
            bundleIdentifier: "jp.kotoba.kekkai",
            teamIdentifierPrefix: teamIdentifierPrefix
        )
    }

    func start() {
        listener.resume()
    }

    func attach(_ transport: KekkaiXPCTransport) {
        lock.lock()
        self.transport = transport
        lock.unlock()
    }

    func detach(_ transport: KekkaiXPCTransport) {
        lock.lock()
        if self.transport === transport { self.transport = nil }
        lock.unlock()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard let requirement = hostCodeSigningRequirement else {
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: KekkaiTunnelExtensionProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: KekkaiTunnelHostProtocol.self)
        newConnection.exportedObject = KekkaiSystemExtensionHostSession(
            service: self,
            connection: newConnection
        )
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionEnded(newConnection)
        }
        newConnection.interruptionHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionInterrupted(newConnection)
        }
        newConnection.resume()
        return true
    }

    fileprivate func authenticateAndPromote(_ candidate: NSXPCConnection, withReply reply: @escaping (Bool) -> Void) {
        guard let userID = userID(for: candidate.processIdentifier) else {
            reply(false)
            return
        }

        lock.lock()
        if let authenticatedUserID, authenticatedUserID != userID {
            lock.unlock()
            reply(false)
            return
        }
        let previous = connection
        connection = candidate
        authenticatedUserID = userID
        lock.unlock()

        // The candidate reaches this method only after its code-signing requirement
        // permits the ping. Do not evict the live peer until that authenticated
        // handshake succeeds.
        if previous !== candidate { previous?.invalidate() }
        reply(true)
    }

    fileprivate func isCurrent(_ candidate: NSXPCConnection?) -> Bool {
        guard let candidate else { return false }
        lock.lock()
        let current = connection === candidate
        lock.unlock()
        return current
    }

    fileprivate func receivePacketFromNode(_ packet: Data, family: Int32, from candidate: NSXPCConnection?) {
        guard isCurrent(candidate) else { return }
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.receiveFromNode(packet, family: family)
    }

    fileprivate func receiveUnderlayFromNode(_ snapshot: Data, from candidate: NSXPCConnection?) {
        guard isCurrent(candidate) else { return }
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.receiveUnderlayFromNode(snapshot)
    }

    fileprivate func packetBridgeFailed(_ message: String, from candidate: NSXPCConnection?) {
        guard isCurrent(candidate) else { return }
        failActiveTransport(NSError(
            domain: "jp.kotoba.kekkai.bridge", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]))
    }

    func startPacketBridge(configuration: Data, completion: @escaping (NSError?) -> Void) {
        guard let proxy = hostProxy() else {
            completion(NSError(domain: "jp.kotoba.kekkai.xpc", code: 2,
                               userInfo: [NSLocalizedDescriptionKey: "Kekkai host app is not connected"]))
            return
        }
        proxy.startPacketBridge(configuration: configuration, withReply: completion)
    }

    func sendPacketToNode(_ packet: Data, family: Int32, completion: @escaping (NSError?) -> Void) {
        guard let proxy = hostProxy() else {
            completion(NSError(domain: "jp.kotoba.kekkai.xpc", code: 3,
                               userInfo: [NSLocalizedDescriptionKey: "Kekkai host app is not connected"]))
            return
        }
        proxy.sendPacketToNode(packet, family: family, withReply: completion)
    }

    func acknowledgeUnderlay(_ addresses: [String]) {
        hostProxy()?.acknowledgeUnderlay(addresses, withReply: { [weak self] error in
            if let error { self?.failActiveTransport(error) }
        })
    }

    func releaseUnderlayGuard(completion: @escaping () -> Void) {
        guard let proxy = hostProxy() else {
            completion()
            return
        }
        proxy.releaseUnderlayGuard { _ in completion() }
    }

    func stopPacketBridge() {
        hostProxy()?.stopPacketBridge(withReply: { _ in })
    }

    private func hostProxy() -> KekkaiTunnelHostProtocol? {
        lock.lock()
        let connection = self.connection
        lock.unlock()
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self] error in
            self?.failActiveTransport(error)
        } as? KekkaiTunnelHostProtocol
    }

    private func connectionEnded(_ ended: NSXPCConnection) {
        lock.lock()
        let wasCurrent = connection === ended
        if wasCurrent {
            connection = nil
            authenticatedUserID = nil
        }
        lock.unlock()
        guard wasCurrent else { return }
        failActiveTransport(NSError(
            domain: "jp.kotoba.kekkai.xpc", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Kekkai host app disconnected"]))
    }

    private func userID(for processIdentifier: pid_t) -> uid_t? {
        guard processIdentifier > 0 else { return nil }
        var info = proc_bsdinfo()
        let result = proc_pidinfo(
            processIdentifier,
            PROC_PIDTBSDINFO,
            0,
            &info,
            Int32(MemoryLayout<proc_bsdinfo>.size)
        )
        guard result == MemoryLayout<proc_bsdinfo>.size else { return nil }
        return info.pbi_uid
    }

    private func connectionInterrupted(_ interrupted: NSXPCConnection) {
        lock.lock()
        let isCurrent = connection === interrupted
        lock.unlock()
        guard isCurrent else { return }
        failActiveTransport(NSError(
            domain: "jp.kotoba.kekkai.xpc", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Kekkai host IPC was interrupted"]))
    }

    private func failActiveTransport(_ error: Error) {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.fail(error)
    }
}

private final class KekkaiSystemExtensionHostSession: NSObject, KekkaiTunnelExtensionProtocol {
    private weak var service: KekkaiSystemExtensionXPCService?
    private weak var connection: NSXPCConnection?

    init(service: KekkaiSystemExtensionXPCService, connection: NSXPCConnection) {
        self.service = service
        self.connection = connection
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        guard let service, let connection else {
            reply(false)
            return
        }
        service.authenticateAndPromote(connection, withReply: reply)
    }

    func receivePacketFromNode(_ packet: Data, family: Int32) {
        service?.receivePacketFromNode(packet, family: family, from: connection)
    }

    func receiveUnderlayFromNode(_ snapshot: Data) {
        service?.receiveUnderlayFromNode(snapshot, from: connection)
    }

    func packetBridgeFailed(_ message: String) {
        service?.packetBridgeFailed(message, from: connection)
    }
}
