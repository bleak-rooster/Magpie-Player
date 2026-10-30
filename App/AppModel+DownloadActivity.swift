import DesignSystem
import Foundation
import MagpieCore
import SwiftUI
import UIKit

/// Downloads visibility (P1): the Downloaded marks, Downloading now, and the foreground-only rule.
extension AppModel {
    /// What's on the phone as a download, for the marks; empty when signed out.
    var downloadIndex: DownloadIndex { downloads?.index ?? DownloadIndex() }

    /// What song rows read for their mark (set once at the root as `songIsDownloaded`).
    var songIsDownloaded: @MainActor @Sendable (String) -> Bool {
        { [weak self] id in self?.downloads?.index.isDownloaded(id) ?? false }
    }

    /// Downloading now's rows: running, waiting, then failed.
    var downloadActivity: [DownloadActivityItem] { downloads?.activity ?? [] }

    /// Manual downloads still to finish: "Keep Magpie open to finish downloading" shows while true.
    var hasActiveDownloads: Bool { downloads?.hasActiveDownloads ?? false }

    /// The scene phase (P1, foreground only): in the background downloads and pre-downloads wait; they go on when
    /// Magpie is back. Playback carries on as normal.
    func scenePhaseChanged(_ phase: ScenePhase) {
        downloads?.setPresence(active: phase == .active, background: phase == .background)
    }

    /// A manager built while Magpie isn't open (a launch for the car) starts held. Hosted tests run in the foreground.
    func applyLaunchPresence(to manager: DownloadManager) {
        guard !Self.isHostedTest else { return }
        let state = UIApplication.shared.applicationState
        manager.setPresence(active: state == .active, background: state == .background)
    }
}

/// The copy Downloading now and Library › Downloads share (§5 voice).
enum DownloadActivityCopy {
    static let keepOpen = "Keep Magpie open to finish downloading"
    static let title = "Downloading now"
    static let empty = "Nothing downloading"

    /// "Downloading now · 3".
    static func row(_ count: Int) -> String { "\(title) \u{00B7} \(count)" }

    /// "1.2 of 8.4 MB"; just "1.2 MB" when the size isn't known.
    static func progress(_ progress: DownloadProgress) -> String {
        let received = megabytes(progress.received)
        guard let expected = progress.expected else { return "\(received) MB" }
        return "\(received) of \(megabytes(expected)) MB"
    }

    private static func megabytes(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0)) / 1_000_000
        return value.formatted(.number.precision(.fractionLength(1)))
    }
}
