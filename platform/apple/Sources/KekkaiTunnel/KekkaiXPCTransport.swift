import Foundation

public final class KekkaiXPCTransport: KekkaiPacketTransport {
    private let lock = NSLock()
    private var readyValue = false
    private var receiveHandler: ((Data, NSNumber) -> Void)?
    private var underlayHandler: ((KekkaiUnderlaySnapshot) -> Void)?
    private var failureHandler: ((Error) -> Void)?
    private var startCompletion: ((Error?) -> Void)?

    public var ready: Bool {
        lock.lock()
        defer { lock.unlock() }
        return readyValue
    }

    public func start(
        configuration: [String: Any],
        receive: @escaping (Data, NSNumber) -> Void,
        underlay: @escaping (KekkaiUnderlaySnapshot) -> Void,
        failure: @escaping (Error) -> Void,
        completion: @escaping (Error?) -> Void
    ) {
        lock.lock()
        guard startCompletion == nil else {
            lock.unlock()
            completion(NSError(domain: "jp.kotoba.kekkai.xpc", code: 5,
                                userInfo: [NSLocalizedDescriptionKey: "Kekkai XPC transport is already starting"]))
            return
        }
        readyValue = false
        receiveHandler = receive
        underlayHandler = underlay
        failureHandler = failure
        startCompletion = completion
        lock.unlock()

        KekkaiSystemExtensionXPCService.shared.attach(self)
        do {
            let data = try JSONSerialization.data(withJSONObject: configuration, options: [.fragmentsAllowed])
            KekkaiSystemExtensionXPCService.shared.startPacketBridge(configuration: data) { [weak self] error in
                guard let self else { return }
                self.lock.lock()
                let completion = self.startCompletion
                self.startCompletion = nil
                self.readyValue = error == nil
                self.lock.unlock()
                completion?(error)
            }
        } catch {
            finishStart(error)
        }
    }

    public func send(packet: Data, protocolFamily: NSNumber, completion: @escaping (Error?) -> Void) {
        guard ready else {
            completion(NSError(domain: "jp.kotoba.kekkai.xpc", code: 6,
                                userInfo: [NSLocalizedDescriptionKey: "Kekkai host bridge is not ready"]))
            return
        }
        KekkaiSystemExtensionXPCService.shared.sendPacketToNode(
            packet, family: protocolFamily.int32Value, completion: completion)
    }

    public func acknowledgeUnderlay(addresses: [String]) {
        KekkaiSystemExtensionXPCService.shared.acknowledgeUnderlay(addresses)
    }

    public func releaseUnderlayGuard(completion: @escaping () -> Void) {
        KekkaiSystemExtensionXPCService.shared.releaseUnderlayGuard(completion: completion)
    }

    public func stop() {
        lock.lock()
        readyValue = false
        receiveHandler = nil
        underlayHandler = nil
        failureHandler = nil
        startCompletion = nil
        lock.unlock()
        KekkaiSystemExtensionXPCService.shared.detach(self)
        KekkaiSystemExtensionXPCService.shared.stopPacketBridge()
    }

    func receiveFromNode(_ packet: Data, family: Int32) {
        lock.lock()
        let handler = receiveHandler
        lock.unlock()
        handler?(packet, NSNumber(value: family))
    }

    func receiveUnderlayFromNode(_ data: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ready = object["ready"] as? Bool,
              let addresses = object["addresses"] as? [String],
              let rawRoutes = object["routes"] as? [[String: Any]] else {
            fail(NSError(domain: "jp.kotoba.kekkai.xpc", code: 7,
                         userInfo: [NSLocalizedDescriptionKey: "Kekkai host sent an invalid underlay snapshot"]))
            return
        }
        let routes = rawRoutes.compactMap { raw -> KekkaiNetworkRoute? in
            guard let family = raw["family"] as? Int,
                  let prefix = raw["prefix"] as? [Int],
                  let prefixLength = raw["prefixLength"] as? Int else { return nil }
            return KekkaiNetworkRoute(family: family, prefix: prefix, prefixLength: prefixLength)
        }
        guard routes.count == rawRoutes.count else {
            fail(NSError(domain: "jp.kotoba.kekkai.xpc", code: 8,
                         userInfo: [NSLocalizedDescriptionKey: "Kekkai host sent an invalid signed route"]))
            return
        }
        lock.lock()
        let handler = underlayHandler
        lock.unlock()
        handler?(KekkaiUnderlaySnapshot(ready: ready, addresses: addresses, routes: routes))
    }

    func fail(_ error: Error) {
        lock.lock()
        readyValue = false
        let start = startCompletion
        startCompletion = nil
        let failure = failureHandler
        lock.unlock()
        if let start { start(error) } else { failure?(error) }
    }

    private func finishStart(_ error: Error?) {
        lock.lock()
        let completion = startCompletion
        startCompletion = nil
        readyValue = error == nil
        lock.unlock()
        completion?(error)
    }
}
