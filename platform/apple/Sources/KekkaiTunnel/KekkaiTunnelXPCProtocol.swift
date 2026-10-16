import Foundation

enum KekkaiXPCSigningRequirement {
    static func make(bundleIdentifier: String, machServiceName: String?) -> String? {
        guard let machServiceName else { return nil }
        let teamIdentifier = machServiceName.split(separator: ".", maxSplits: 1).first.map(String.init)
        guard let teamIdentifier,
              teamIdentifier.count == 10,
              teamIdentifier.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) else {
            return nil
        }
        return "anchor apple generic and identifier \"\(bundleIdentifier)\" and certificate leaf[subject.OU] = \"\(teamIdentifier)\""
    }
}

@objc(KekkaiTunnelHostProtocol)
public protocol KekkaiTunnelHostProtocol {
    func startPacketBridge(configuration: Data, withReply reply: @escaping (NSError?) -> Void)
    func sendPacketToNode(_ packet: Data, family: Int32, withReply reply: @escaping (NSError?) -> Void)
    func acknowledgeUnderlay(_ addresses: [String], withReply reply: @escaping (NSError?) -> Void)
    func releaseUnderlayGuard(withReply reply: @escaping (NSError?) -> Void)
    func stopPacketBridge(withReply reply: @escaping (NSError?) -> Void)
}

@objc(KekkaiTunnelExtensionProtocol)
public protocol KekkaiTunnelExtensionProtocol {
    func ping(withReply reply: @escaping (Bool) -> Void)
    func receivePacketFromNode(_ packet: Data, family: Int32)
    func receiveUnderlayFromNode(_ snapshot: Data)
    func packetBridgeFailed(_ message: String)
}
