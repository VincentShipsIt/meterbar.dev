import Foundation

/// Resolves the address `meterbar serve` binds to. Loopback is the default
/// and requires nothing extra; reaching any other interface is an explicit
/// opt-in the caller must request and be warned about (docs/cli-json-schema.md).
nonisolated public enum ServeBindConfiguration {
    public static let loopbackHost = "127.0.0.1"
    public static let allInterfacesHost = "0.0.0.0"

    public struct Resolution: Sendable {
        public let host: String
        public let isRemoteExposed: Bool
        public let warning: String?
    }

    public static func resolve(allowRemote: Bool) -> Resolution {
        guard allowRemote else {
            return Resolution(host: loopbackHost, isRemoteExposed: false, warning: nil)
        }
        return Resolution(
            host: allInterfacesHost,
            isRemoteExposed: true,
            warning: "meterbar serve is bound to all network interfaces (--allow-remote). Usage and "
                + "cost data will be reachable from other devices on this network; anyone with the "
                + "printed bearer token can read it."
        )
    }
}
