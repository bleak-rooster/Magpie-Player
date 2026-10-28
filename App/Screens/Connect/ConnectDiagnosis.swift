import Foundation
import NavidromeKit

/// T3: which step of reaching the server failed, in plain words. Local Network is blamed only when it is the cause
/// (plan Review Focus 1): the owner's `homeserver` resolves only through Tailscale, so with Tailscale off the name
/// simply isn't found.
enum ConnectDiagnosis: Equatable {
    case localhostOnDevice, nameNotFound(String), atsBlocked, localNetworkDenied, timedOut(String), loginFailed,
         unreachable(String), other

    /// A phone, where `localhost` is the phone itself. False in the simulator (it shares the Mac's network).
    static var onDevice: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        true
        #endif
    }

    /// - Parameter pathDenied: a connection to `url` was just seen held back by the Local Network setting (the only
    ///   Local Network evidence used: a remembered "denied" may be stale).
    static func classify(_ error: Error, url: URL, pathDenied: Bool, onDevice: Bool) -> ConnectDiagnosis {
        let hostAndPort = ConnectErrorCopy.hostAndPort(url) ?? url.absoluteString
        let code = (error as? URLError)?.code
        let nameLookup = code == .cannotFindHost || code == .dnsLookupFailed
        if onDevice, ServerAddress.isLoopback(url) { return .localhostOnDevice }
        if (error as? NavidromeError) == .badCredentials { return .loginFailed }
        if code == .appTransportSecurityRequiresSecureConnection { return .atsBlocked }
        if ServerAddress.needsLocalNetworkPermission(url), AppModel.isConnectionError(error),
           pathDenied,
           !nameLookup || url.host(percentEncoded: false)?.lowercased().hasSuffix(".local") == true {
            return .localNetworkDenied
        }
        if nameLookup { return .nameNotFound(url.host(percentEncoded: false) ?? hostAndPort) }
        if code == .timedOut { return .timedOut(hostAndPort) }
        if AppModel.isConnectionError(error) { return .unreachable(hostAndPort) }
        return .other
    }

    var message: String {
        switch self {
        case .localNetworkDenied:
            "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network."
        case .localhostOnDevice:
            "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533."
        case .nameNotFound(let host):
            "This iPhone can't find \(host); check the name, or use the server's address instead."
        case .timedOut(let host):
            "\(host) didn't answer in time; check the server is on and reachable from this iPhone."
        case .atsBlocked: ConnectErrorCopy.needsHTTPS
        case .loginFailed: ConnectErrorCopy.badCredentials
        case .unreachable(let host): ConnectErrorCopy.unreachable(host)
        case .other: ConnectErrorCopy.generic
        }
    }
}
