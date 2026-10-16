import AppKit
import NetworkExtension
import SystemExtensions

@NSApplicationMain
final class KekkaiTunnelHost: NSObject, NSApplicationDelegate, OSSystemExtensionRequestDelegate {
    private let providerBundleIdentifier = "jp.kotoba.kekkai.tunnel"
    private let socketDefaultsKey = "packetBridgePath"
    private let appGroupIdentifier = "group.jp.kotoba.kekkai"
    private var statusItem: NSStatusItem!
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?
    private var extensionRequest: OSSystemExtensionRequest?
    private var extensionActivationCompletion: ((Error?) -> Void)?
    private var extensionApprovalPending = false
    private let extensionConnectionLock = NSLock()
    private var extensionConnection: NSXPCConnection?
    private let bridgeLock = NSLock()
    private var nodeTransport: KekkaiLocalNodeTransport?
    private var nodeTransportOwner: NSXPCConnection?
    private var nodeTransportStopInFlight = false
    private var nodeTransportStopOwner: NSXPCConnection?
    private var nodeTransportStopCompletions: [() -> Void] = []
    private var pendingBridgeStarts: [(
        configuration: [String: Any],
        originConnection: NSXPCConnection,
        reply: (NSError?) -> Void
    )] = []
    private var terminationInProgress = false
    private var terminationCleanupStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "Kekkai"
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMenu()
            self?.finishTerminationIfTunnelStopped()
        }
        loadManager { [weak self] in self?.refreshMenu() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removeStatusObserver()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        bridgeLock.lock()
        terminationInProgress = true
        bridgeLock.unlock()
        switch manager?.connection.status ?? .invalid {
        case .connected, .connecting, .reasserting:
            manager?.connection.stopVPNTunnel()
        case .disconnecting:
            break
        case .invalid, .disconnected:
            finishTerminationIfTunnelStopped()
        @unknown default:
            manager?.connection.stopVPNTunnel()
        }
        return .terminateLater
    }

    private func finishTerminationIfTunnelStopped() {
        bridgeLock.lock()
        let isTerminating = terminationInProgress
        bridgeLock.unlock()
        guard isTerminating, !terminationCleanupStarted else { return }
        switch manager?.connection.status ?? .invalid {
        case .connected, .connecting, .reasserting, .disconnecting:
            return
        case .invalid, .disconnected:
            break
        @unknown default:
            return
        }
        terminationCleanupStarted = true
        stopNodeTransport { [weak self] in
            guard let self else { return }
            self.extensionConnectionLock.lock()
            let connection = self.extensionConnection
            self.extensionConnection = nil
            self.extensionConnectionLock.unlock()
            connection?.invalidate()
            self.removeStatusObserver()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    private func removeStatusObserver() {
        guard let statusObserver else { return }
        NotificationCenter.default.removeObserver(statusObserver)
        self.statusObserver = nil
    }

    @objc private func connect(_ sender: Any?) {
        activateSystemExtension { [weak self] error in
            guard let self else { return }
            if let error {
                self.showError("Could not activate the Kekkai system extension", error)
                return
            }
            self.connectToSystemExtension { [weak self] connectionError in
                guard let self else { return }
                if let connectionError {
                    self.showError("Could not connect to the Kekkai system extension", connectionError)
                    return
                }
                self.loadManager { [weak self] in
                    guard let self, let manager = self.manager else { return }
                    self.configureAndStartTunnel(manager)
                }
            }
        }
    }

    private func configureAndStartTunnel(_ manager: NETunnelProviderManager) {
        let tunnel = NETunnelProviderProtocol()
        tunnel.providerBundleIdentifier = providerBundleIdentifier
        tunnel.serverAddress = "Kekkai"
        guard let socketPath = currentSocketPath() else {
            showError("Configure a packet socket inside the Kekkai shared container", nil)
            return
        }
        tunnel.providerConfiguration = [
            "packetBridgePath": socketPath,
            "mtu": 1280
        ]
        manager.protocolConfiguration = tunnel
        manager.localizedDescription = "Kekkai"
        manager.isEnabled = true
        manager.saveToPreferences { [weak self, weak manager] error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showError("Could not save the Kekkai VPN profile", error)
                    return
                }
                guard let manager else { return }
                manager.loadFromPreferences { error in
                    DispatchQueue.main.async {
                        if let error {
                            self.showError("Could not load the Kekkai VPN profile", error)
                        } else {
                            do {
                                try manager.connection.startVPNTunnel()
                            } catch {
                                self.showError("Could not start the Kekkai tunnel", error)
                            }
                        }
                        self.refreshMenu()
                    }
                }
            }
        }
    }

    private func connectToSystemExtension(completion: @escaping (Error?) -> Void) {
        extensionConnectionLock.lock()
        let existingConnection = extensionConnection
        extensionConnectionLock.unlock()
        if let existingConnection {
            ping(existingConnection, completion: completion)
            return
        }
        let serviceName = Bundle.main.object(forInfoDictionaryKey: "KekkaiMachServiceName") as? String
            ?? "group.jp.kotoba.kekkai.service"
        let teamIdentifier = Bundle.main.object(forInfoDictionaryKey: "KekkaiSigningTeamID") as? String
        guard let requirement = KekkaiXPCSigningRequirement.make(
            bundleIdentifier: providerBundleIdentifier,
            teamIdentifier: teamIdentifier
        ) else {
            completion(NSError(domain: "jp.kotoba.kekkai.xpc", code: 9,
                                userInfo: [NSLocalizedDescriptionKey: "Kekkai signing team is not configured"]))
            return
        }
        let connection = NSXPCConnection(machServiceName: serviceName, options: .privileged)
        connection.setCodeSigningRequirement(requirement)
        connection.remoteObjectInterface = NSXPCInterface(with: KekkaiTunnelExtensionProtocol.self)
        connection.exportedInterface = NSXPCInterface(with: KekkaiTunnelHostProtocol.self)
        connection.exportedObject = self
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.extensionConnectionLock.lock()
            let wasCurrent = self.extensionConnection === connection
            if wasCurrent {
                self.extensionConnection = nil
            }
            self.extensionConnectionLock.unlock()
            if wasCurrent { self.stopNodeTransport(from: connection) }
        }
        connection.interruptionHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.extensionConnectionLock.lock()
            let isCurrent = self.extensionConnection === connection
            if isCurrent { self.extensionConnection = nil }
            self.extensionConnectionLock.unlock()
            if isCurrent {
                connection.invalidate()
                self.stopNodeTransport(from: connection)
            }
        }
        extensionConnectionLock.lock()
        extensionConnection = connection
        extensionConnectionLock.unlock()
        connection.resume()
        ping(connection, completion: completion)
    }

    private func ping(_ connection: NSXPCConnection, completion: @escaping (Error?) -> Void) {
        let completionLock = NSLock()
        var didComplete = false
        let completeOnce: (Error?) -> Void = { [weak self, weak connection] error in
            completionLock.lock()
            guard !didComplete else {
                completionLock.unlock()
                return
            }
            didComplete = true
            completionLock.unlock()
            if error != nil, let self, let connection {
                self.extensionConnectionLock.lock()
                let wasCurrent = self.extensionConnection === connection
                if wasCurrent { self.extensionConnection = nil }
                self.extensionConnectionLock.unlock()
                if wasCurrent { self.stopNodeTransport(from: connection) }
                connection.invalidate()
            }
            DispatchQueue.main.async { completion(error) }
        }
        guard let extensionProxy = connection.remoteObjectProxyWithErrorHandler({ error in
            completeOnce(error)
        }) as? KekkaiTunnelExtensionProtocol else {
            completeOnce(NSError(domain: "jp.kotoba.kekkai.xpc", code: 10,
                                  userInfo: [NSLocalizedDescriptionKey: "Kekkai system extension proxy is unavailable"]))
            return
        }
        extensionProxy.ping { available in
            completeOnce(available ? nil : NSError(
                domain: "jp.kotoba.kekkai.xpc", code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Kekkai system extension did not become ready"]))
        }
    }

    func startPacketBridge(configuration: Data, withReply reply: @escaping (NSError?) -> Void) {
        guard let originConnection = NSXPCConnection.current() else {
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 16,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai bridge request has no XPC peer"]))
            return
        }
        guard let configuration = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any] else {
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 12,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai packet bridge configuration is invalid"]))
            return
        }
        guard isCurrentExtensionConnection(originConnection) else {
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai bridge request came from a stale XPC peer"]))
            return
        }
        bridgeLock.lock()
        guard isCurrentExtensionConnection(originConnection) else {
            bridgeLock.unlock()
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 17,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai bridge request came from a stale XPC peer"]))
            return
        }
        if terminationInProgress {
            bridgeLock.unlock()
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 19,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai host is shutting down"]))
            return
        }
        if nodeTransportStopInFlight {
            pendingBridgeStarts.append((configuration, originConnection, reply))
            bridgeLock.unlock()
            return
        }
        guard nodeTransport == nil else {
            bridgeLock.unlock()
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 13,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai packet bridge is already running"]))
            return
        }
        let transport = KekkaiLocalNodeTransport()
        nodeTransport = transport
        nodeTransportOwner = originConnection
        bridgeLock.unlock()

        startNodeTransport(transport, configuration: configuration, reply: reply)
    }

    private func startNodeTransport(
        _ transport: KekkaiLocalNodeTransport,
        configuration: [String: Any],
        reply: @escaping (NSError?) -> Void
    ) {
        transport.start(
            configuration: configuration,
            receive: { [weak self] packet, family in
                self?.extensionProxy()?.receivePacketFromNode(packet, family: family.int32Value)
            },
            underlay: { [weak self] snapshot in
                guard let self,
                      let data = try? JSONSerialization.data(withJSONObject: [
                        "ready": snapshot.ready,
                        "addresses": snapshot.addresses,
                        "routes": snapshot.routes.map { [
                            "family": Int($0.family),
                            "prefix": $0.prefix,
                            "prefixLength": $0.prefixLength
                        ] as [String: Any] }
                      ]) else { return }
                self.extensionProxy()?.receiveUnderlayFromNode(data)
            },
            failure: { [weak self] error in
                self?.extensionProxy()?.packetBridgeFailed(error.localizedDescription)
            },
            completion: { error in reply(error as NSError?) })
    }

    func sendPacketToNode(_ packet: Data, family: Int32, withReply reply: @escaping (NSError?) -> Void) {
        bridgeLock.lock()
        let transport = nodeTransport
        bridgeLock.unlock()
        guard let transport else {
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 14,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai node socket is not connected"]))
            return
        }
        transport.send(packet: packet, protocolFamily: NSNumber(value: family)) { error in
            reply(error as NSError?)
        }
    }

    func acknowledgeUnderlay(_ addresses: [String], withReply reply: @escaping (NSError?) -> Void) {
        bridgeLock.lock()
        let transport = nodeTransport
        bridgeLock.unlock()
        guard let transport else {
            reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 15,
                          userInfo: [NSLocalizedDescriptionKey: "Kekkai node socket is not connected"]))
            return
        }
        transport.acknowledgeUnderlay(addresses: addresses)
        reply(nil)
    }

    func releaseUnderlayGuard(withReply reply: @escaping (NSError?) -> Void) {
        bridgeLock.lock()
        let transport = nodeTransport
        bridgeLock.unlock()
        guard let transport else {
            reply(nil)
            return
        }
        transport.releaseUnderlayGuard { reply(nil) }
    }

    func stopPacketBridge(withReply reply: @escaping (NSError?) -> Void) {
        guard let originConnection = NSXPCConnection.current(),
              isCurrentExtensionConnection(originConnection) else {
            reply(nil)
            return
        }
        stopNodeTransport(from: originConnection) { reply(nil) }
    }

    private func isCurrentExtensionConnection(_ candidate: NSXPCConnection) -> Bool {
        extensionConnectionLock.lock()
        defer { extensionConnectionLock.unlock() }
        return extensionConnection === candidate
    }

    private func extensionProxy() -> KekkaiTunnelExtensionProtocol? {
        extensionConnectionLock.lock()
        let connection = extensionConnection
        extensionConnectionLock.unlock()
        guard let connection else { return nil }
        return connection.remoteObjectProxyWithErrorHandler { [weak self, weak connection] error in
            guard let self, let connection else { return }
            self.extensionConnectionLock.lock()
            let isCurrent = self.extensionConnection === connection
            self.extensionConnectionLock.unlock()
            guard isCurrent else { return }
            self.stopNodeTransport(from: connection)
            DispatchQueue.main.async {
                self.showError("Kekkai system extension connection failed", error)
            }
        } as? KekkaiTunnelExtensionProtocol
    }

    private func stopNodeTransport(
        from originConnection: NSXPCConnection? = nil,
        completion: @escaping () -> Void = {}
    ) {
        bridgeLock.lock()
        if nodeTransportStopInFlight {
            let ownsStoppingTransport = originConnection == nil || nodeTransportStopOwner === originConnection
            let cancelledStarts: [(
                configuration: [String: Any],
                originConnection: NSXPCConnection,
                reply: (NSError?) -> Void
            )]
            if let originConnection {
                cancelledStarts = pendingBridgeStarts.filter { $0.originConnection === originConnection }
                pendingBridgeStarts.removeAll { $0.originConnection === originConnection }
            } else {
                cancelledStarts = pendingBridgeStarts
                pendingBridgeStarts.removeAll(keepingCapacity: false)
            }
            guard ownsStoppingTransport || !cancelledStarts.isEmpty else {
                bridgeLock.unlock()
                completion()
                return
            }
            nodeTransportStopCompletions.append(completion)
            bridgeLock.unlock()
            cancelledStarts.forEach {
                $0.reply(NSError(domain: "jp.kotoba.kekkai.bridge", code: 18,
                                 userInfo: [NSLocalizedDescriptionKey: "Kekkai bridge start was superseded by a stop"]))
            }
            return
        }
        if let originConnection, nodeTransportOwner !== originConnection {
            bridgeLock.unlock()
            completion()
            return
        }
        let transport = nodeTransport
        guard let transport else {
            bridgeLock.unlock()
            completion()
            return
        }
        nodeTransport = nil
        nodeTransportStopOwner = nodeTransportOwner
        nodeTransportOwner = nil
        nodeTransportStopInFlight = true
        nodeTransportStopCompletions.append(completion)
        bridgeLock.unlock()
        transport.stop { [weak self] in
            guard let self else { return }
            self.bridgeLock.lock()
            let pendingStarts = self.pendingBridgeStarts
            self.pendingBridgeStarts.removeAll(keepingCapacity: false)
            var rejectedStarts: [((NSError?) -> Void, NSError)] = []
            for pending in pendingStarts {
                guard !self.terminationInProgress else {
                    rejectedStarts.append((pending.reply, NSError(
                        domain: "jp.kotoba.kekkai.bridge", code: 19,
                        userInfo: [NSLocalizedDescriptionKey: "Kekkai host is shutting down"])))
                    continue
                }
                guard self.isCurrentExtensionConnection(pending.originConnection) else {
                    rejectedStarts.append((pending.reply, NSError(
                        domain: "jp.kotoba.kekkai.bridge", code: 17,
                        userInfo: [NSLocalizedDescriptionKey: "Kekkai bridge request came from a stale XPC peer"])))
                    continue
                }
                guard self.nodeTransport == nil else {
                    rejectedStarts.append((pending.reply, NSError(
                        domain: "jp.kotoba.kekkai.bridge", code: 13,
                        userInfo: [NSLocalizedDescriptionKey: "Kekkai packet bridge is already running"])))
                    continue
                }
                let nextTransport = KekkaiLocalNodeTransport()
                self.nodeTransport = nextTransport
                self.nodeTransportOwner = pending.originConnection
                self.startNodeTransport(nextTransport, configuration: pending.configuration, reply: pending.reply)
            }
            self.nodeTransportStopOwner = nil
            self.nodeTransportStopInFlight = false
            let completions = self.nodeTransportStopCompletions
            self.nodeTransportStopCompletions.removeAll(keepingCapacity: false)
            self.bridgeLock.unlock()
            rejectedStarts.forEach { $0.0($0.1) }
            completions.forEach { $0() }
        }
    }

    private func activateSystemExtension(completion: @escaping (Error?) -> Void) {
        guard extensionActivationCompletion == nil else {
            completion(NSError(
                domain: "jp.kotoba.kekkai.tunnel", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Kekkai extension activation is already in progress"]))
            return
        }
        extensionActivationCompletion = completion
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: providerBundleIdentifier,
            queue: .main
        )
        request.delegate = self
        extensionRequest = request
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        guard request.identifier == providerBundleIdentifier else { return }
        extensionApprovalPending = true
        refreshMenu()
    }

    func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension extensionProperties: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        guard isAtLeastSystemExtensionVersion(
            extensionProperties.bundleVersion,
            than: existing.bundleVersion
        ) else { return .cancel }
        return .replace
    }

    private func isAtLeastSystemExtensionVersion(_ candidate: String, than installed: String) -> Bool {
        func components(_ version: String) -> [Int]? {
            let parts = version.split(separator: ".", omittingEmptySubsequences: false)
            guard (1...3).contains(parts.count) else { return nil }
            let values = parts.compactMap { Int($0) }
            return values.count == parts.count ? values : nil
        }

        guard let candidate = components(candidate),
              let installed = components(installed) else { return false }
        for index in 0..<max(candidate.count, installed.count) {
            let candidatePart = index < candidate.count ? candidate[index] : 0
            let installedPart = index < installed.count ? installed[index] : 0
            if candidatePart != installedPart { return candidatePart > installedPart }
        }
        return true
    }

    func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        guard request.identifier == providerBundleIdentifier else { return }
        switch result {
        case .completed:
            finishSystemExtensionActivation(nil)
        case .willCompleteAfterReboot:
            finishSystemExtensionActivation(NSError(
                domain: "jp.kotoba.kekkai.tunnel", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Restart macOS before connecting the Kekkai tunnel"]))
        @unknown default:
            finishSystemExtensionActivation(NSError(
                domain: "jp.kotoba.kekkai.tunnel", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Kekkai extension activation returned an unknown result"]))
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        guard request.identifier == providerBundleIdentifier else { return }
        finishSystemExtensionActivation(error)
    }

    private func finishSystemExtensionActivation(_ error: Error?) {
        extensionApprovalPending = false
        extensionRequest = nil
        let completion = extensionActivationCompletion
        extensionActivationCompletion = nil
        refreshMenu()
        completion?(error)
    }

    @objc private func disconnect(_ sender: Any?) {
        manager?.connection.stopVPNTunnel()
        refreshMenu()
    }

    @objc private func configureSocket(_ sender: Any?) {
        guard let directory = appGroupDirectory else {
            showError("The Kekkai app-group container is unavailable. Sign the app with its registered app-group profile first.", nil)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Kekkai packet bridge"
        alert.informativeText = "Set the Kekkai node's :packet-bridge :path to this socket. The host app bridges it to the system extension over XPC."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: currentSocketPath()
                                ?? directory.appendingPathComponent("packet.sock").path)
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let socketPath = canonicalSocketPath(value, in: directory) else {
            showError("The packet socket must be inside the Kekkai shared app-group container", nil)
            return
        }
        UserDefaults.standard.set(socketPath, forKey: socketDefaultsKey)
    }

    private func loadManager(_ completion: @escaping () -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { [weak self] managers, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    self.showError("Could not load VPN preferences", error)
                    completion()
                    return
                }
                self.manager = managers?.first(where: {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == self.providerBundleIdentifier
                }) ?? NETunnelProviderManager()
                completion()
            }
        }
    }

    private var appGroupDirectory: URL? {
        FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
    }

    private func currentSocketPath() -> String? {
        guard let directory = appGroupDirectory else { return nil }
        let path = UserDefaults.standard.string(forKey: socketDefaultsKey)
            ?? directory.appendingPathComponent("packet.sock").path
        return canonicalSocketPath(path, in: directory)
    }

    private func canonicalSocketPath(_ path: String, in directory: URL) -> String? {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let candidate = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard candidate != root, candidate.hasPrefix(root + "/") else { return nil }
        return candidate
    }

    private func refreshMenu() {
        guard let statusItem else { return }
        let status = manager?.connection.status ?? .disconnected
        let label: String
        if extensionApprovalPending {
            label = "Kekkai: Approve in System Settings"
        } else {
            switch status {
            case .connected: label = "Kekkai: Connected"
            case .connecting, .reasserting: label = "Kekkai: Connecting…"
            case .disconnecting: label = "Kekkai: Disconnecting…"
            default: label = "Kekkai: Disconnected"
            }
        }
        statusItem.button?.title = label

        let menu = NSMenu()
        menu.addItem(withTitle: "Connect", action: #selector(connect(_:)), keyEquivalent: "")
        menu.addItem(withTitle: "Disconnect", action: #selector(disconnect(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Configure Packet Bridge Socket…",
                     action: #selector(configureSocket(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Kekkai", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func showError(_ title: String, _ error: Error?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error?.localizedDescription ?? ""
        alert.runModal()
    }
}
