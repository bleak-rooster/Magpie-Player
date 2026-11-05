import Foundation
import LidarrKit
import MagpieCore

/// Round 15 C3 (D139, D147): a trial of a release of an artist already in the main library (Lidarr keeps one folder per
/// artist, so it can't go into the Finds folder). Keep clears the mark; Reject deletes exactly that album's track files
/// (`ConfinedShape.trialDelete`, which proves from the ledger and fresh reads that Magpie monitored the album when it
/// was unmonitored with no files) and unmonitors it. Never anything else of the artist, never the artist. Expiry is as
/// Finds' (D10): the date is shown; nothing is removed by itself.
extension RequestRunner {
    /// Days a trial lasts before its date passes (the same as the app shows for finds).
    public static let trialDays = 14

    public enum TrialError: Error, Equatable {
        /// "Allow Magpie to change Lidarr" is off. Nothing was written.
        case changesOff
        /// Not an open library trial (kept, rejected, or never recorded as one). Nothing was written.
        case notATrial
        /// The gate refused on fresh state (the album changed, has other files, was kept…). Nothing was written.
        case refused
        /// Lidarr or the ledger can't be read right now. Nothing was written.
        case unavailable
        /// The files went but the album couldn't be unmonitored: it needs a look.
        case needsAttention
    }

    /// Keep: the trial mark goes; the album stays, monitored, with the artist's own profile. No Reject after this.
    public func keepTrial(_ id: RequestID) async throws {
        guard !stopped, await load() else { throw TrialError.unavailable }
        guard let r = request(id), r.isLibraryTrial, let albumId = r.albumId else { throw TrialError.notATrial }
        let at = now()
        do { try await ledger.update(albumId: albumId) { $0.trialKeptAt = at } } catch { throw TrialError.unavailable }
        await mutate(id) { $0.trialKept = true }
    }

    /// Reject: the album's track files (all of them, that album only), then the album unmonitored.
    public func rejectTrial(_ id: RequestID) async throws {
        guard !stopped, await load() else { throw TrialError.unavailable }
        guard let r = request(id), r.isLibraryTrial, let albumId = r.albumId else { throw TrialError.notATrial }
        guard await gate.enabled else { throw TrialError.changesOff }
        let files: [TrackFile]
        do { files = try await lidarr.trackFiles(albumId: albumId) } catch { throw TrialError.unavailable }
        if !files.isEmpty {
            do {
                let ids = files.map(\.id)
                _ = try await gate.send("DELETE", "trackfile/bulk", body: TrackFileIdsBody(trackFileIds: ids), confinedAs: .trialDelete)
            } catch WriteGateError.disabled {
                throw TrialError.changesOff
            } catch is WriteGateError {
                throw TrialError.refused
            } catch {
                throw TrialError.unavailable
            }
        }
        do {
            _ = try await gate.send("PUT", "album/monitor", body: TrialMonitorBody(albumIds: [albumId], monitored: false))
        } catch {
            let at = now()
            try? await ledger.update(albumId: albumId) { $0.trialRejectedAt = at }
            await mutate(id) { $0.trialRejected = true }
            throw TrialError.needsAttention
        }
        let at = now()
        try? await ledger.update(albumId: albumId) {
            $0.trialRejectedAt = at
            $0.closedAt = at
        }
        await mutate(id) {
            $0.trialRejected = true
            $0.state = .dismissed
        }
        try? await library.startScan()   // the songs leave the library
    }

    private struct TrialMonitorBody: Encodable, Sendable {
        var albumIds: [Int]
        var monitored: Bool
    }
}
