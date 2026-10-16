import Foundation

public enum KekkaiTransportFactory {
    private static let lock = NSLock()
    private static var builder: (() -> KekkaiPacketTransport)?

    /// A native Kekkai runtime can install a direct transport before the
    /// provider starts. Otherwise the provider uses the host-mediated XPC
    /// bridge, keeping the Node socket in the logged-in user's app-group
    /// container while the Network Extension runs in the global context.
    public static func install(_ value: @escaping () -> KekkaiPacketTransport) {
        lock.lock()
        defer { lock.unlock() }
        precondition(builder == nil, "Kekkai transport factory already installed")
        builder = value
    }

    static func make() -> KekkaiPacketTransport {
        lock.lock()
        let installedBuilder = builder
        lock.unlock()
        return installedBuilder?() ?? KekkaiXPCTransport()
    }
}
