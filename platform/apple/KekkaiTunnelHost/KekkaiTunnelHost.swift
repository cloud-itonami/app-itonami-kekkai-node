import AppKit
import NetworkExtension

@NSApplicationMain
final class KekkaiTunnelHost: NSObject, NSApplicationDelegate {
    private let providerBundleIdentifier = "jp.kotoba.kekkai.tunnel"
    private let socketDefaultsKey = "packetBridgePath"
    private let appGroupIdentifier = "group.jp.kotoba.kekkai"
    private var statusItem: NSStatusItem!
    private var manager: NETunnelProviderManager?
    private var statusObserver: NSObjectProtocol?

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
        }
        loadManager { [weak self] in self?.refreshMenu() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
        }
    }

    @objc private func connect(_ sender: Any?) {
        loadManager { [weak self] in
            guard let self, let manager = self.manager else { return }
            let tunnel = NETunnelProviderProtocol()
            tunnel.providerBundleIdentifier = self.providerBundleIdentifier
            tunnel.serverAddress = "Kekkai"
            guard let socketPath = self.currentSocketPath() else {
                self.showError("Configure a packet socket inside the Kekkai shared container", nil)
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
        alert.informativeText = "Set the Kekkai node's :packet-bridge :path to the same socket path."
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
        switch status {
        case .connected: label = "Kekkai: Connected"
        case .connecting, .reasserting: label = "Kekkai: Connecting…"
        case .disconnecting: label = "Kekkai: Disconnecting…"
        default: label = "Kekkai: Disconnected"
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
