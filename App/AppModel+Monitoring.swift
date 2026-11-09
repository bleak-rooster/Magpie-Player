import Foundation
import LidarrKit
import MagpieCore
import Observation
import Requests

/// Round 24 (owner, 2026-11-08, item 10; Q10): "Change what's monitored" and "Clean up unmatched songs" for an artist in
/// Lidarr, Magpie's or the owner's (D237–D244). Behind Settings › Lidarr "Let Magpie change what Lidarr monitors for my
/// artists" (off by default, per Lidarr: the gate refuses these writes while it is off, D243). The package does the work
/// (`MonitoringChanger`); this reads what the owner keeps (favourites, playlists, the phone) for it.
extension AppModel {
    /// The switch's UserDefaults key is the gate's (`LidarrWriteGate.monitoringChangesKey`); this only makes a change of
    /// it observable (the More menu and the switch read it).
    @MainActor @Observable final class MonitoringSwitch {
        static let shared = MonitoringSwitch()
        var revision = 0
    }

    /// "Let Magpie change what Lidarr monitors for my artists", for the connected Lidarr. False without one.
    var monitoringChangesAllowed: Bool {
        _ = MonitoringSwitch.shared.revision
        guard let scope = lidarrScope else { return false }
        return gateDefaults.bool(forKey: LidarrWriteGate.monitoringChangesKey(scope: scope))
    }

    func setMonitoringChangesAllowed(_ on: Bool) async {
        guard let scope = lidarrScope else { return }
        if let gate { await gate.setMonitoringChangesEnabled(on) } else {
            gateDefaults.set(on, forKey: LidarrWriteGate.monitoringChangesKey(scope: scope))
        }
        MonitoringSwitch.shared.revision += 1
        if on { Task { await monitoringChanger?.resumeAll() } }
    }

    /// The package's changer for the connected Lidarr, through the same gate and ledger as the requests. Nil without
    /// them (no Lidarr, signed out).
    var monitoringChanger: MonitoringChanger? {
        guard let client = lidarrClient, let gate, let ledger else { return nil }
        return MonitoringChanger(lidarr: client, gate: gate, ledger: ledger, roots: { [weak self] in
            await self?.gateRoots ?? WriteConfinement.Roots(mainRoot: nil, findsRoot: nil, findTagId: nil)
        })
    }

    /// What the owner keeps, read fresh (D242): his favourite songs and albums, every playlist he can see, and what's on
    /// the phone; and the favourites alone (to say why a song stays). Throws when the server can't be read, or there are
    /// more playlists than can be read on a tap: nothing is deleted then (when in doubt, keep).
    func monitoringKeepLists(artist: String) async throws -> (all: MonitoringKeepList, favourites: MonitoringKeepList) {
        try requireNotForcedOffline()
        let starred = try await request { try await $0.starred() }
        let playlists = try await request { try await $0.playlists() }
        guard playlists.count <= Self.monitoringPlaylistLimit else { throw MonitoringChangeError.unavailable }
        var saved: [Song] = []
        for playlist in playlists {
            let id = playlist.id
            saved += try await request { try await $0.playlist(id: id).1 }
        }
        let all = Self.monitoringKeepList(artist: artist, favourites: starred.songs, favouriteAlbums: starred.albums,
                                          saved: saved, onPhone: await offlineCatalog.songs())
        let favourites = Self.monitoringKeepList(artist: artist, favourites: starred.songs, favouriteAlbums: starred.albums,
                                                 saved: [], onPhone: [])
        return (all, favourites)
    }

    /// More playlists than this can't all be read on a tap: nothing is deleted then.
    static let monitoringPlaylistLimit = 500

    /// Any kept song's recording counts; titles and album titles only for this artist's songs (folded, "Jordan feat. Sam"
    /// counts as Jordan's). Loose matching only keeps more.
    nonisolated static func monitoringKeepList(artist: String, favourites: [Song], favouriteAlbums: [Album], saved: [Song],
                                               onPhone: [Song]) -> MonitoringKeepList {
        let name = MonitoringKeepList.fold(artist)
        let theirs = { (other: String) in !name.isEmpty && MonitoringKeepList.fold(other).contains(name) }
        let songs = favourites + saved + onPhone
        return MonitoringKeepList(recordings: Set(songs.compactMap { $0.recordingMBID?.rawValue }),
                                  titles: Set(songs.filter { theirs($0.artist) }.map(\.title)),
                                  albumTitles: Set(favouriteAlbums.filter { theirs($0.artist) }.map(\.name)))
    }
}
