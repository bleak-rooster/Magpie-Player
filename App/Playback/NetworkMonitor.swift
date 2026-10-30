import MagpieCore
import Network
import Observation

/// Where the app reads the network from (`NetworkMonitor`; tests supply a fake).
@MainActor
protocol NetworkStatusProviding: AnyObject {
    var status: NetworkStatus { get }
}

/// Wraps `NWPathMonitor`: connected, mobile data (or an expensive path) and Low Data Mode.
@MainActor @Observable
final class NetworkMonitor: NetworkStatusProviding {
    /// `NWPathMonitor` has no synchronous read, so this is Wi-Fi until the first path arrives (a moment after
    /// launch, on the main queue); a song started in that gap streams at the Wi-Fi quality.
    private(set) var status = NetworkStatus.wifi
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        // Updates arrive on the main queue in order, so none is overtaken by a later one.
        monitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                self?.status = NetworkStatus(isConnected: path.status == .satisfied,
                                             isCellular: path.usesInterfaceType(.cellular) || path.isExpensive,
                                             isConstrained: path.isConstrained)
            }
        }
        monitor.start(queue: .main)
    }

    deinit { monitor.cancel() }
}

/// UI tests pin the network (T23 fix round 1): the host Mac may be on an expensive hotspot, which the simulator reports
/// as mobile data, so manual downloads would rightly wait for Wi-Fi. `-MagpieNetwork wifi` counts only together with
/// `-MagpieUITesting YES`; a production launch never passes that, so it never honours the pin.
enum UITestNetworkPin {
    static func status(arguments: [String]) -> NetworkStatus? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard value("-MagpieUITesting") == "YES", value("-MagpieNetwork") == "wifi" else { return nil }
        return .wifi
    }
}

/// A network that never changes: hosted tests, which must not depend on the simulator host's connection (an
/// expensive or constrained path would change the stream quality, and with it the transcode fallback).
@MainActor
final class FixedNetwork: NetworkStatusProviding {
    let status: NetworkStatus
    init(_ status: NetworkStatus = .wifi) { self.status = status }
}
