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

    /// How many rows Downloading now has (cheap: no progress read).
    var downloadActivityCount: Int { downloads?.activityCount ?? 0 }

    /// Manual downloads still to finish.
    var hasActiveDownloads: Bool { downloads?.hasActiveDownloads ?? false }

    /// "Keep Magpie open to finish downloading": only with "Download in the background" off (R1).
    var showsKeepOpen: Bool { downloads?.showsKeepOpen ?? false }

    /// Albums just loaded from the server: their song counts backfill downloads saved without one (builds 8 and 9).
    func noteAlbumSongCounts(_ albums: [Album]) {
        guard let downloads else { return }
        var counts: [String: Int] = [:]
        for album in albums {
            let count = album.songs.map(\.count) ?? album.songCount
            if count > 0 { counts[album.id] = count }
        }
        Task { await downloads.noteAlbumSongCounts(counts) }
    }

    /// The scene phase: with "Download in the background" off (P1, foreground only), downloads and pre-downloads wait
    /// in the background and go on when Magpie is back. Playback carries on as normal.
    func scenePhaseChanged(_ phase: ScenePhase) {
        downloads?.setPresence(active: phase == .active, background: phase == .background)
        monitoringSceneChanged(active: phase == .active)   // R24H fix round 4 (D-L2)
    }

    /// A manager built while Magpie isn't open (a launch for the car, or for the background session's events) knows it;
    /// it holds only with "Download in the background" off. Hosted tests run in the foreground.
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

    /// R1: "Paused · 2.1 of 8.4 MB" for a download that resumes from where it stopped.
    static func paused(_ progress: DownloadProgress) -> String { "Paused \u{00B7} \(self.progress(progress))" }

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
