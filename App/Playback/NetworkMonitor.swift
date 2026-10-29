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
    private(set) var status = NetworkStatus.wifi
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let status = NetworkStatus(isConnected: path.status == .satisfied,
                                       isCellular: path.usesInterfaceType(.cellular) || path.isExpensive,
                                       isConstrained: path.isConstrained)
            Task { @MainActor in self?.status = status }
        }
        monitor.start(queue: DispatchQueue(label: "magpie.network"))
    }

    deinit { monitor.cancel() }
}

/// A network that never changes: hosted tests, which must not depend on the simulator host's connection (an
/// expensive or constrained path would change the stream quality, and with it the transcode fallback).
@MainActor
final class FixedNetwork: NetworkStatusProviding {
    let status: NetworkStatus
    init(_ status: NetworkStatus = .wifi) { self.status = status }
}
