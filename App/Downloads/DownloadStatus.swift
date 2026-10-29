/// What a song, album or playlist shows about its downloads (D3: text plus symbol, never shape alone).
enum DownloadStatus: Equatable {
    case none, downloaded, downloading(done: Int, total: Int), waitingForWiFi, full

    var text: String {
        switch self {
        case .none: ""
        case .downloaded: "Downloaded"
        case let .downloading(done, total): "Downloading \(done) of \(total)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .full: "Downloads are full"
        }
    }

    var symbol: String {
        switch self {
        case .none: ""
        case .downloaded: "arrow.down.circle.fill"
        case .downloading: "arrow.down.circle.dotted"
        case .waitingForWiFi: "wifi"
        case .full: "externaldrive.badge.exclamationmark"
        }
    }
}
