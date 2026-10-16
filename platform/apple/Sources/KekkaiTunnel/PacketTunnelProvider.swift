import Foundation
import NetworkExtension

public final class PacketTunnelProvider: NEPacketTunnelProvider {
    private enum TunnelError: LocalizedError {
        case incompleteUnderlay
        case invalidUnderlay
        case noSignedRoutes
        case invalidSignedRoute

        var errorDescription: String? {
            switch self {
            case .incompleteUnderlay:
                return "Kekkai could not resolve every underlay endpoint; default routes were not installed"
            case .invalidUnderlay:
                return "Kekkai supplied an invalid underlay route address"
            case .noSignedRoutes:
                return "Kekkai has no authorized signed TUN routes; system routes were not changed"
            case .invalidSignedRoute:
                return "Kekkai supplied an invalid signed TUN route; system routes were not changed"
            }
        }
    }

    private let stateQueue = DispatchQueue(label: "jp.kotoba.kekkai.tunnel-state")
    private var transport: KekkaiPacketTransport?
    private var policy = KotobaPacketPolicy(mtu: 1280)
    private var running = false
    private var transportReady = false
    private var initialUnderlay: KekkaiUnderlaySnapshot?
    private var startCompletion: ((Error?) -> Void)?
    private var currentConfiguration: [String: Any] = [:]
    private var currentMTU = 1280
    private var underlayAddresses = Set<String>()
    private var appliedUnderlayAddresses = Set<String>()
    private var authorizedRoutes = Set<KekkaiNetworkRoute>()
    private var appliedAuthorizedRoutes = Set<KekkaiNetworkRoute>()
    private var settingsUpdateInFlight = false
    private var tunnelSettingsInstalled = false

    public override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard !running else {
            completionHandler(NSError(
                domain: "jp.kotoba.kekkai.tunnel", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "tunnel is already running"]))
            return
        }
        let transport = KekkaiTransportFactory.make()
        let configuration =
            (protocolConfiguration as? NETunnelProviderProtocol)?
                .providerConfiguration ?? [:]
        let mtu = min(max(configuration["mtu"] as? Int ?? 1280, 1280), 9000)
        policy = KotobaPacketPolicy(mtu: mtu)
        currentConfiguration = configuration
        currentMTU = mtu
        transportReady = false
        initialUnderlay = nil
        startCompletion = completionHandler
        underlayAddresses = []
        appliedUnderlayAddresses = []
        authorizedRoutes = []
        appliedAuthorizedRoutes = []
        tunnelSettingsInstalled = false
        settingsUpdateInFlight = false
        self.transport = transport

        transport.start(
            configuration: configuration,
            receive: { [weak self] packet, family in
                guard let self, self.running,
                      let parsed = ParsedPacket(packet),
                      self.policy.decide(
                        packet: parsed,
                        transportReady: transport.ready
                      ) == .overlay else { return }
                self.packetFlow.writePackets(
                    [parsed.bytes], withProtocols: [family])
            },
            underlay: { [weak self] snapshot in
                guard let self else { return }
                self.stateQueue.async {
                    self.acceptUnderlay(snapshot)
                }
            },
            failure: { [weak self] transportError in
                self?.cancelTunnelWithError(transportError)
            },
            completion: { [weak self] transportError in
                guard let self else {
                    transport.stop()
                    completionHandler(transportError)
                    return
                }
                self.stateQueue.async {
                    if let transportError {
                        self.finishStart(transportError)
                        return
                    }
                    self.transportReady = true
                    self.installInitialSettingsWhenReady()
                }
            })
    }

    public override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        running = false
        setTunnelNetworkSettings(nil) { [weak self] _ in
            guard let self else {
                completionHandler()
                return
            }
            let transport = self.transport
            self.transport = nil
            transport?.releaseUnderlayGuard {
                transport?.stop()
                completionHandler()
            }
        }
    }

    private func readPackets() {
        guard running, let transport else { return }
        packetFlow.readPackets { [weak self] packets, families in
            guard let self, self.running else { return }
            for (packet, family) in zip(packets, families) {
                guard let parsed = ParsedPacket(packet),
                      self.policy.decide(
                        packet: parsed,
                        transportReady: transport.ready
                      ) == .overlay else { continue }
                transport.send(
                    packet: parsed.bytes,
                    protocolFamily: family,
                    completion: { _ in /* denial/drop is recorded by runtime */ })
            }
            self.readPackets()
        }
    }

    private func acceptUnderlay(_ snapshot: KekkaiUnderlaySnapshot) {
        guard snapshot.ready,
              !snapshot.addresses.isEmpty,
              snapshot.addresses.allSatisfy(Self.isIPAddress) else {
            if tunnelSettingsInstalled {
                cancelTunnelWithError(TunnelError.incompleteUnderlay)
            } else {
                finishStart(TunnelError.incompleteUnderlay)
            }
            return
        }
        guard !snapshot.routes.isEmpty else {
            if tunnelSettingsInstalled {
                cancelTunnelWithError(TunnelError.noSignedRoutes)
            } else {
                finishStart(TunnelError.noSignedRoutes)
            }
            return
        }

        let previousAddresses = underlayAddresses
        let previousRoutes = authorizedRoutes
        underlayAddresses = Set(snapshot.addresses)
        authorizedRoutes = Set(snapshot.routes)
        initialUnderlay = snapshot
        guard underlayAddresses != previousAddresses
                || authorizedRoutes != previousRoutes else {
            if tunnelSettingsInstalled,
               !settingsUpdateInFlight,
               underlayAddresses == appliedUnderlayAddresses,
               authorizedRoutes == appliedAuthorizedRoutes {
                transport?.acknowledgeUnderlay(addresses: underlayAddresses.sorted())
            }
            installInitialSettingsWhenReady()
            return
        }
        if tunnelSettingsInstalled {
            applyUpdatedSettings()
        } else {
            installInitialSettingsWhenReady()
        }
    }

    private func installInitialSettingsWhenReady() {
        guard transportReady,
              let snapshot = initialUnderlay,
              snapshot.ready,
              !tunnelSettingsInstalled,
              !settingsUpdateInFlight,
              startCompletion != nil else { return }
        applySettings(isInitial: true)
    }

    private func applyUpdatedSettings() {
        guard tunnelSettingsInstalled, !settingsUpdateInFlight else { return }
        applySettings(isInitial: false)
    }

    private func applySettings(isInitial: Bool) {
        settingsUpdateInFlight = true
        let requestedUnderlayAddresses = underlayAddresses
        let requestedAuthorizedRoutes = authorizedRoutes
        let settings: NEPacketTunnelNetworkSettings
        do {
            settings = try makeSettings(
                configuration: currentConfiguration,
                mtu: currentMTU,
                underlayAddresses: requestedUnderlayAddresses,
                authorizedRoutes: requestedAuthorizedRoutes)
        } catch {
            settingsUpdateInFlight = false
            if isInitial {
                finishStart(error)
            } else {
                cancelTunnelWithError(error)
            }
            return
        }
        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            self.stateQueue.async {
                self.settingsUpdateInFlight = false
                if let error {
                    if isInitial {
                        self.finishStart(error)
                    } else {
                        self.cancelTunnelWithError(error)
                    }
                    return
                }
                self.tunnelSettingsInstalled = true
                self.appliedUnderlayAddresses = requestedUnderlayAddresses
                self.appliedAuthorizedRoutes = requestedAuthorizedRoutes
                self.transport?.acknowledgeUnderlay(
                    addresses: self.appliedUnderlayAddresses.sorted())
                if isInitial {
                    self.running = true
                    self.readPackets()
                    self.finishStart(nil)
                }
                if self.underlayAddresses != self.appliedUnderlayAddresses
                        || self.authorizedRoutes != self.appliedAuthorizedRoutes {
                    self.applyUpdatedSettings()
                }
            }
        }
    }

    private func finishStart(_ error: Error?) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        if error != nil {
            running = false
            setTunnelNetworkSettings(nil) { [weak self] _ in
                guard let self else {
                    completion(error)
                    return
                }
                let transport = self.transport
                self.transport = nil
                transport?.releaseUnderlayGuard {
                    transport?.stop()
                    completion(error)
                }
            }
            return
        }
        completion(error)
    }

    private func makeSettings(
        configuration: [String: Any],
        mtu: Int,
        underlayAddresses: Set<String>,
        authorizedRoutes: Set<KekkaiNetworkRoute>
    ) throws -> NEPacketTunnelNetworkSettings {
        guard !authorizedRoutes.isEmpty else { throw TunnelError.noSignedRoutes }
        let remote = configuration["remoteAddress"] as? String ?? "127.0.0.1"
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: remote)
        settings.mtu = NSNumber(value: mtu)

        let ipv4 = NEIPv4Settings(
            addresses: [configuration["ipv4Address"] as? String ?? "100.96.0.2"],
            subnetMasks: [configuration["ipv4Mask"] as? String ?? "255.255.255.255"])
        let ipv4Routes = authorizedRoutes
            .filter { $0.family == 4 }
            .sorted {
                if $0.prefix == $1.prefix {
                    return $0.prefixLength < $1.prefixLength
                }
                return $0.prefix.lexicographicallyPrecedes($1.prefix)
            }
            .compactMap(Self.ipv4Route)
        guard ipv4Routes.count == authorizedRoutes.filter({ $0.family == 4 }).count else {
            throw TunnelError.invalidSignedRoute
        }
        ipv4.includedRoutes = ipv4Routes
        let ipv4Exclusions = Set(configuration["relayIPv4"] as? [String] ?? [])
            .union(underlayAddresses.filter { Self.addressFamily($0) == AF_INET })
        ipv4.excludedRoutes = ipv4Exclusions.sorted().map {
                NEIPv4Route(destinationAddress: $0,
                            subnetMask: "255.255.255.255")
            }
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [configuration["ipv6Address"] as? String ?? "fd7a:6b65::2"],
            networkPrefixLengths: [128])
        let ipv6Routes = authorizedRoutes
            .filter { $0.family == 6 }
            .sorted {
                if $0.prefix == $1.prefix {
                    return $0.prefixLength < $1.prefixLength
                }
                return $0.prefix.lexicographicallyPrecedes($1.prefix)
            }
            .compactMap(Self.ipv6Route)
        guard ipv6Routes.count == authorizedRoutes.filter({ $0.family == 6 }).count else {
            throw TunnelError.invalidSignedRoute
        }
        ipv6.includedRoutes = ipv6Routes
        let ipv6Exclusions = Set(configuration["relayIPv6"] as? [String] ?? [])
            .union(underlayAddresses.filter { Self.addressFamily($0) == AF_INET6 })
        ipv6.excludedRoutes = ipv6Exclusions.sorted().map {
                NEIPv6Route(destinationAddress: $0, networkPrefixLength: 128)
            }
        settings.ipv6Settings = ipv6

        if let servers = configuration["dnsServers"] as? [String], !servers.isEmpty {
            let dns = NEDNSSettings(servers: servers)
            dns.matchDomains = configuration["dnsMatchDomains"] as? [String] ?? [""]
            settings.dnsSettings = dns
        }
        return settings
    }

    private static func ipv4Route(_ route: KekkaiNetworkRoute) -> NEIPv4Route? {
        guard let destination = networkAddress(route),
              let subnetMask = ipv4SubnetMask(route.prefixLength) else { return nil }
        return NEIPv4Route(destinationAddress: destination, subnetMask: subnetMask)
    }

    private static func ipv6Route(_ route: KekkaiNetworkRoute) -> NEIPv6Route? {
        guard let destination = networkAddress(route) else { return nil }
        return NEIPv6Route(
            destinationAddress: destination,
            networkPrefixLength: NSNumber(value: route.prefixLength))
    }

    private static func networkAddress(_ route: KekkaiNetworkRoute) -> String? {
        // The control-plane wire uses IP version numbers (4 and 6), while
        // AF_INET / AF_INET6 are platform socket-family constants (2 and 30 on
        // Darwin). Keep the wire enum separate from those C constants.
        let width = route.family == 4 ? 32 : route.family == 6 ? 128 : 0
        guard width > 0,
              route.prefix.count == width / 8,
              (0...width).contains(route.prefixLength),
              route.prefix.allSatisfy({ (0...255).contains($0) }) else { return nil }
        var bytes = route.prefix.map(UInt8.init)
        for index in bytes.indices {
            let remaining = route.prefixLength - index * 8
            let mask: UInt8
            if remaining >= 8 {
                mask = 0xff
            } else if remaining <= 0 {
                mask = 0
            } else {
                mask = UInt8((0xff << (8 - remaining)) & 0xff)
            }
            bytes[index] &= mask
        }
        if route.family == 4 {
            return bytes.map { String($0) }.joined(separator: ".")
        }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { destination in
            for index in bytes.indices { destination[index] = bytes[index] }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let result = output.withUnsafeMutableBufferPointer { buffer in
            inet_ntop(AF_INET6, &address, buffer.baseAddress, socklen_t(buffer.count))
        }
        return result == nil ? nil : String(cString: output)
    }

    private static func ipv4SubnetMask(_ prefixLength: Int) -> String? {
        guard (0...32).contains(prefixLength) else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4)
        for bit in 0..<prefixLength {
            bytes[bit / 8] |= UInt8(1 << (7 - bit % 8))
        }
        return bytes.map { String($0) }.joined(separator: ".")
    }

    private static func isIPAddress(_ value: String) -> Bool {
        addressFamily(value) != 0
    }

    private static func addressFamily(_ value: String) -> Int32 {
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return AF_INET }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return AF_INET6 }
        return 0
    }
}
