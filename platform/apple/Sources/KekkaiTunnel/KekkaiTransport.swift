import Foundation

public struct KekkaiNetworkRoute: Hashable {
    public let family: Int32
    public let prefix: [Int]
    public let prefixLength: Int

    public init?(family: Int, prefix: [Int], prefixLength: Int) {
        let width: Int
        switch family {
        case 4: width = 32
        case 6: width = 128
        default: return nil
        }
        guard prefix.count == width / 8,
              prefix.allSatisfy({ (0...255).contains($0) }),
              (0...width).contains(prefixLength) else { return nil }
        self.family = Int32(family)
        self.prefix = prefix
        self.prefixLength = prefixLength
    }
}

public struct KekkaiUnderlaySnapshot {
    public let ready: Bool
    public let addresses: [String]
    public let routes: [KekkaiNetworkRoute]

    public init(
        ready: Bool,
        addresses: [String],
        routes: [KekkaiNetworkRoute] = []
    ) {
        self.ready = ready
        self.addresses = addresses
        self.routes = routes
    }
}

public protocol KekkaiPacketTransport: AnyObject {
    var ready: Bool { get }
    func start(
        configuration: [String: Any],
        receive: @escaping (Data, NSNumber) -> Void,
        underlay: @escaping (KekkaiUnderlaySnapshot) -> Void,
        failure: @escaping (Error) -> Void,
        completion: @escaping (Error?) -> Void
    )
    func send(
        packet: Data,
        protocolFamily: NSNumber,
        completion: @escaping (Error?) -> Void
    )
    func acknowledgeUnderlay(addresses: [String])
    func releaseUnderlayGuard(completion: @escaping () -> Void)
    func stop()
}

public extension KekkaiPacketTransport {
    func acknowledgeUnderlay(addresses: [String]) {}
    func releaseUnderlayGuard(completion: @escaping () -> Void) { completion() }
}
