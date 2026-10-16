import Foundation

final class KekkaiSystemExtensionXPCService: NSObject, NSXPCListenerDelegate, KekkaiTunnelExtensionProtocol {
    static let shared = KekkaiSystemExtensionXPCService()

    private let lock = NSLock()
    private let listener: NSXPCListener
    private var connection: NSXPCConnection?
    private weak var transport: KekkaiXPCTransport?

    private override init() {
        let serviceName = (Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String
            ?? "group.jp.kotoba.kekkai.service"
        listener = NSXPCListener(machServiceName: serviceName)
        super.init()
        listener.delegate = self
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
        let serviceName = (Bundle.main.infoDictionary?["NetworkExtension"] as? [String: Any])?["NEMachServiceName"] as? String
        guard let requirement = KekkaiXPCSigningRequirement.make(
            bundleIdentifier: "jp.kotoba.kekkai",
            machServiceName: serviceName
        ) else {
            return false
        }
        newConnection.setCodeSigningRequirement(requirement)
        newConnection.exportedInterface = NSXPCInterface(with: KekkaiTunnelExtensionProtocol.self)
        newConnection.remoteObjectInterface = NSXPCInterface(with: KekkaiTunnelHostProtocol.self)
        newConnection.exportedObject = self
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            self.connectionEnded(newConnection)
        }
        newConnection.interruptionHandler = { [weak self] in
            self?.failActiveTransport(NSError(
                domain: "jp.kotoba.kekkai.xpc", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Kekkai host IPC was interrupted"]))
        }

        lock.lock()
        let previous = connection
        connection = newConnection
        lock.unlock()
        previous?.invalidate()
        newConnection.resume()
        return true
    }

    func ping(withReply reply: @escaping (Bool) -> Void) {
        reply(true)
    }

    func receivePacketFromNode(_ packet: Data, family: Int32) {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.receiveFromNode(packet, family: family)
    }

    func receiveUnderlayFromNode(_ snapshot: Data) {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.receiveUnderlayFromNode(snapshot)
    }

    func packetBridgeFailed(_ message: String) {
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
        if connection === ended { connection = nil }
        lock.unlock()
        failActiveTransport(NSError(
            domain: "jp.kotoba.kekkai.xpc", code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Kekkai host app disconnected"]))
    }

    private func failActiveTransport(_ error: Error) {
        lock.lock()
        let transport = self.transport
        lock.unlock()
        transport?.fail(error)
    }
}
