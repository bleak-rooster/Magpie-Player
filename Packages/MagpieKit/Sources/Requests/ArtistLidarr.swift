import Foundation
import LidarrKit
import MagpieCore
import MatchIndex
import os

/// Where an artist of the library stands in Lidarr (priority round P3).
public enum ArtistLidarrState: Sendable, Equatable {
    /// "In Lidarr · Monitored", with "· Searching…" while Lidarr searches for the artist's albums.
    case monitored(lidarrId: Int, searching: Bool)
    /// "In Lidarr · Not monitored". Only an artist Magpie added (the ledger says so) may be monitored from Magpie.
    case notMonitored(lidarrId: Int, magpieAdded: Bool)
    /// "Not in Lidarr". `mbid`: the library's MusicBrainz id, the only one an add uses; nil: an add first asks Lidarr's
    /// search (`ArtistLidarr.candidates`) and the owner confirms the exact artist.
    case notInLidarr(mbid: MBID?)
}

public enum ArtistLidarrError: Error, Sendable, Equatable {
    /// "Allow Magpie to change Lidarr" is off.
    case changesOff
    /// The artist is in Lidarr already (perhaps added meanwhile): nothing is written.
    case alreadyInLidarr
    /// Lidarr's lookup doesn't know the MusicBrainz id.
    case notFound
    /// The owner's artist, not one Magpie added: never changed.
    case notMagpies
    /// Lidarr refused or didn't answer.
    case failed
}

/// An artist page's Lidarr line and its one action (P3): "Add to Lidarr and download" for an artist Lidarr doesn't
/// have, and "Monitor" for an unmonitored artist Magpie itself added. Every write goes through `LidarrWriteGate` (G1);
/// an artist Magpie didn't add is never written to (owner-data rule).
///
/// The add is a whole-artist monitor, not a Magpie request: requests are per release group, and their life
/// (Cancel unmonitors, Keep, Let go) doesn't fit "monitor everything". It goes into the main root with the Magpie
/// profiles and `magpie` tag (provisioned in v1), monitors every album (and new ones), and starts Lidarr's search for
/// missing albums. The ledger records the artist as Magpie's (same id and MBID, `LedgerEntry.created`).
public enum ArtistLidarr {
    /// Lidarr commands that mean it's searching for an artist's albums.
    static let searchCommands: Set<String> = ["artistsearch", "missingalbumsearch", "albumsearch"]
    /// An artist-level ledger entry for a whole-artist add: no album, and the artist's own MBID where a release
    /// group would be (no release group has an artist's MBID, so no request ever matches it).
    static func requestId(_ mbid: MBID) -> String { "artist-add:\(mbid.rawValue)" }

    // MARK: - Status

    /// The Lidarr artist for a library artist: by MusicBrainz id when the library knows it, otherwise by the match
    /// index's normalised name, and only when exactly one Lidarr artist has it.
    public static func match(name: String, mbid: MBID?, in artists: [LidarrArtist]) -> LidarrArtist? {
        if let mbid { return artists.first { $0.foreignArtistId == mbid } }
        let key = Normalize.name(name)
        guard !key.isEmpty else { return nil }
        let same = artists.filter { Normalize.name($0.artistName) == key }
        return same.count == 1 ? same[0] : nil
    }

    /// The state from what was read: Lidarr's artists, its commands and this server's ledger.
    public static func state(name: String, mbid: MBID?, artists: [LidarrArtist], commands: [CommandStatus],
                             ledger entries: [LedgerEntry]) -> ArtistLidarrState {
        guard let artist = match(name: name, mbid: mbid, in: artists) else { return .notInLidarr(mbid: mbid) }
        if artist.monitored {
            let searching = commands.contains {
                searchCommands.contains($0.name.lowercased()) && isRunning($0) && $0.artistIds.contains(artist.id)
            }
            return .monitored(lidarrId: artist.id, searching: searching)
        }
        // A kept artist is the owner's now (the gate refuses it too): no "Monitor" for it.
        let kept = entries.contains { $0.lidarrArtistId == artist.id && $0.keptAt != nil }
        return .notMonitored(lidarrId: artist.id, magpieAdded: !kept && entries.contains { $0.created(artist) })
    }

    static func isRunning(_ c: CommandStatus) -> Bool { ["queued", "started"].contains(c.status.lowercased()) }

    /// Reads Lidarr (GETs only) and the ledger. Never searches by name (I3: an add by name waits for the owner's tap,
    /// `candidates`), so a page view asks nothing of Lidarr's remote metadata.
    public static func read(name: String, mbid: MBID?, lidarr: LidarrClient, ledger: Ledger) async throws
        -> ArtistLidarrState {
        let artists = try await lidarr.artists()
        let commands = (try? await lidarr.commands()) ?? []
        let entries = (try? await ledger.entries) ?? []   // unreadable: nothing counts as Magpie's (fails safe)
        return state(name: name, mbid: mbid, artists: artists, commands: commands, ledger: entries)
    }

    // MARK: - Candidates (no MBID in the library)

    /// A MusicBrainz artist Lidarr's search offers for a library artist without an MBID.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public var mbid: MBID
        public var name: String
        public var disambiguation: String?
        public var type: String?
        public var id: String { mbid.rawValue }

        public init(mbid: MBID, name: String, disambiguation: String? = nil, type: String? = nil) {
            self.mbid = mbid; self.name = name; self.disambiguation = disambiguation; self.type = type
        }

        /// "Nirvana (US grunge band, Group)": what the confirmation names, so the owner sees exactly who is added.
        public var label: String {
            let detail = [disambiguation, type].compactMap { $0 }.filter { !$0.isEmpty }
            return detail.isEmpty ? name : "\(name) (\(detail.joined(separator: ", ")))"
        }
    }

    /// Controller ruling (I3): Lidarr's artist search for `name`, keeping only artists whose name is the same once case
    /// and diacritics are folded (one per MBID, in Lidarr's order). One: the confirmation names it; several: the owner
    /// picks; none: nothing can be added. GETs only.
    public static func candidates(name: String, lidarr: LidarrClient) async throws -> [Candidate] {
        let key = folded(name)
        guard !key.isEmpty else { return [] }
        var seen = Set<MBID>()
        return try await lidarr.artistLookup(term: name.trimmingCharacters(in: .whitespacesAndNewlines)).compactMap { row in
            guard let mbid = row.foreignArtistId, folded(row.artistName) == key, seen.insert(mbid).inserted else { return nil }
            return Candidate(mbid: mbid, name: row.artistName, disambiguation: row.disambiguation, type: row.artistType)
        }
    }

    static func folded(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Writes

    /// The add body: Lidarr's lookup row with Magpie's root folder, profiles and tags, everything monitored, and a
    /// search for missing albums started.
    static func addBody(lookup: JSONValue, setup: RequestRunner.Setup, follow: Bool = true) throws -> JSONValue {
        guard var o = lookup.objectValue else { throw ArtistLidarrError.notFound }
        let overrides: [String: JSONValue] = [
            "rootFolderPath": .string(setup.rootFolderPath),
            "qualityProfileId": .int(setup.qualityProfileId),
            "metadataProfileId": .int(setup.metadataProfileId),
            "monitored": .bool(true),
            "monitorNewItems": .string(follow ? "all" : "none"),
            "tags": .array(setup.tagIds.map { .int($0) }),
            "addOptions": .object([
                "monitor": .string("all"),
                "searchForMissingAlbums": .bool(true),
            ]),
        ]
        // As the runner's add: no second spelling of an overridden key, and never Lidarr's own id.
        let folded = Set(overrides.keys.map { $0.lowercased() } + ["id"])
        o = o.filter { !folded.contains($0.key.lowercased()) }
        o.merge(overrides) { _, new in new }
        return .object(o)
    }

    /// "Add to Lidarr and download": adds the artist through the gate and records it in the ledger as Magpie's.
    /// Refuses (writing nothing) when changes are off or Lidarr has the artist already. Returns its Lidarr id.
    /// R18: `setup` carries the chosen quality and release-types profiles; `follow` false monitors nothing new.
    public static func add(mbid: MBID, lidarr: LidarrClient, gate: LidarrWriteGate, ledger: Ledger,
                           setup: RequestRunner.Setup, follow: Bool = true) async throws -> Int {
        guard await gate.enabled else { throw ArtistLidarrError.changesOff }
        // Fresh: never a second add, never a write to an artist the owner added meanwhile.
        guard try await !lidarr.artists().contains(where: { $0.foreignArtistId == mbid }) else {
            throw ArtistLidarrError.alreadyInLidarr
        }
        guard let lookup = try await lidarr.artistLookupJSON(mbid: mbid) else { throw ArtistLidarrError.notFound }
        let body = try addBody(lookup: lookup, setup: setup, follow: follow)
        let data: Data
        do {
            data = try await gate.send("POST", "artist", body: body)
        } catch WriteGateError.disabled {
            throw ArtistLidarrError.changesOff
        } catch LidarrError.http(let status) where (400..<500).contains(status) {
            throw ArtistLidarrError.failed
        }
        guard let id = (try? JSONDecoder().decode(JSONValue.self, from: data))?["id"]?.intValue else {
            throw ArtistLidarrError.failed
        }
        // Without the entry the artist reads as the owner's, so Magpie never changes it: safe if this fails.
        do {
            try await ledger.record(LedgerEntry(lidarrArtistId: id, albumId: nil, rgMbid: mbid, createdArtist: true,
                                                wasMonitoredBefore: false, root: setup.rootFolderPath, mode: .fallback,
                                                send: .applied, requestId: requestId(mbid), artistMbid: mbid))
        } catch {
            Log.logger("requests").error("ledger not written for an added artist")
        }
        return id
    }

    private struct MonitorBody: Encodable, Sendable {
        var artistIds: [Int]
        var monitored: Bool
    }

    private struct SearchBody: Encodable, Sendable {
        var name: String
        var artistId: Int
    }

    /// "Monitor": monitors an artist Magpie added (the ledger says so, for the same id and MBID, read fresh) and
    /// searches for its albums. Any other artist is the owner's: refused, nothing sent.
    public static func monitor(lidarrId: Int, lidarr: LidarrClient, gate: LidarrWriteGate, ledger: Ledger) async throws {
        guard await gate.enabled else { throw ArtistLidarrError.changesOff }
        let artist = try await lidarr.artist(id: lidarrId)
        guard try await ledger.createdArtist(artist) else { throw ArtistLidarrError.notMagpies }
        guard !artist.monitored else { return }
        _ = try await gate.send("PUT", "artist/editor", body: MonitorBody(artistIds: [lidarrId], monitored: true))
        _ = try? await gate.send("POST", "command", body: SearchBody(name: "ArtistSearch", artistId: lidarrId))
    }
}
