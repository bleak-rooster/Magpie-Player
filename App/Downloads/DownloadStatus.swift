/// What a song, album or playlist shows about its downloads (D3: text plus symbol, never shape alone).
enum DownloadStatus: Equatable {
    case none, downloaded, downloading(done: Int, total: Int), waitingForWiFi, full, failed
    /// Offline (Task 14, ruling b): manual downloads wait for the server, not for Wi-Fi.
    case waitingForConnection
    /// Some of an album's or playlist's songs are downloaded with it and nothing is on its way (one was removed on
    /// its own): "Download the rest" is offered.
    case partial(done: Int, total: Int)

    var text: String {
        switch self {
        case .none: ""
        case .downloaded: "Downloaded"
        case let .downloading(done, total): "Downloading \(done) of \(total)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .waitingForConnection: "Waiting for a connection"
        case .full: "Downloads are full"
        case .failed: "Couldn't download"
        case let .partial(done, total): "\(done) of \(total) downloaded"
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .downloaded: "arrow.down.circle.fill"
        case .downloading: "arrow.down.circle.dotted"
        case .waitingForWiFi: "wifi"
        case .waitingForConnection: "wifi.slash"
        case .full: "externaldrive.badge.exclamationmark"
        case .failed: "exclamationmark.circle"
        case .partial: "arrow.down.circle"   // the Downloaded symbol, unfilled: partly there
        }
    }
}
