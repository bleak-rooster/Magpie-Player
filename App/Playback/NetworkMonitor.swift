import Foundation
import MagpieCore
import Network
import Observation

/// Where the app reads the network from (`NetworkMonitor`; tests supply a fake).
@MainActor
protocol NetworkStatusProviding: AnyObject {
    var status: NetworkStatus { get }
    /// Round 28 O1 (owner, 2026-11-15): Low Power Mode doubles the reconnect checks' spacing (D326).
    var isLowPowerMode: Bool { get }
}

extension NetworkStatusProviding {
    /// Fakes and the fixed network: never in Low Power Mode.
    var isLowPowerMode: Bool { false }
}

/// Wraps `NWPathMonitor`: connected, mobile data (or an expensive path) and Low Data Mode.
@MainActor @Observable
final class NetworkMonitor: NetworkStatusProviding {
    /// `NWPathMonitor` has no synchronous read, so this is Wi-Fi until the first path arrives (a moment after
    /// launch, on the main queue); a song started in that gap streams at the Wi-Fi quality.
    private(set) var status = NetworkStatus.wifi
    /// Round 28 O1 (D326): watched, so the reconnect schedule follows it.
    private(set) var isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private var powerObserver: NSObjectProtocol?

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
        powerObserver = NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isLowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled }
        }
    }

    isolated deinit {
        monitor.cancel()
        if let powerObserver { NotificationCenter.default.removeObserver(powerObserver) }
    }
}

/// UI tests pin the network (T23 fix round 1): the host Mac may be on an expensive hotspot, which the simulator reports
/// as mobile data, so manual downloads would rightly wait for Wi-Fi. `-MagpieNetwork wifi` counts only together with
/// `-MagpieUITesting YES`; a production launch never passes that, so it never honours the pin. `-MagpieNetwork cellular`
/// pins mobile data, so manual downloads wait for Wi-Fi (P1's Downloading now UI test).
#if DEBUG   // review M3: a Release build can't honour the pin at all
enum UITestNetworkPin {
    static func status(arguments: [String]) -> NetworkStatus? {
        func value(_ key: String) -> String? {
            guard let index = arguments.firstIndex(of: key), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        guard value("-MagpieUITesting") == "YES" else { return nil }
        switch value("-MagpieNetwork") {
        case "wifi": return .wifi
        case "cellular": return NetworkStatus(isConnected: true, isCellular: true, isConstrained: false)
        default: return nil
        }
    }
}
#endif

/// A network that never changes: hosted tests, which must not depend on the simulator host's connection (an
/// expensive or constrained path would change the stream quality, and with it the transcode fallback).
@MainActor
final class FixedNetwork: NetworkStatusProviding {
    let status: NetworkStatus
    init(_ status: NetworkStatus = .wifi) { self.status = status }
}
