import Foundation

/// What the network is like right now, reduced to what the app acts on. The app's `NetworkMonitor` fills it from
/// `NWPath`; tests pass values.
public struct NetworkStatus: Sendable, Equatable {
    public var isConnected: Bool
    /// Mobile data, or any path the system calls expensive (a personal hotspot).
    public var isCellular: Bool
    /// Low Data Mode is on for the path (on Wi-Fi too).
    public var isConstrained: Bool

    public init(isConnected: Bool, isCellular: Bool, isConstrained: Bool) {
        self.isConnected = isConnected; self.isCellular = isCellular; self.isConstrained = isConstrained
    }

    public static let wifi = NetworkStatus(isConnected: true, isCellular: false, isConstrained: false)
}

public extension PlaybackPreferences {
    /// Mobile data and Low Data Mode both use the mobile quality.
    func quality(for status: NetworkStatus) -> StreamQuality {
        status.isCellular || status.isConstrained ? cellular : wifi
    }
}
