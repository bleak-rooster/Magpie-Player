import Foundation
import LidarrKit
import MagpieCore

/// Round 15 C3 (D135, D136): Add to library of a new artist, and a library-artist trial's ledger mark (kept out of
/// RequestRunner.swift: only hook lines there).
extension RequestRunner {
    /// D136 (review M2): the owner's own Add defaults for a new artist: the metadata profile for their release types
    /// (made by the app through the gate), and whether new releases are followed.
    public struct LibraryAddProfile: Sendable, Equatable {
        public var metadataProfileId: Int
        public var follow: Bool
        public init(metadataProfileId: Int, follow: Bool) { self.metadataProfileId = metadataProfileId; self.follow = follow }
    }

    /// Add to library of a new artist: the main root, tag `magpie`, "Magpie Lossless Preferred" (made by the app before it
    /// asks; without it the add waits and is never sent with Fast Start).
    static func libraryDestination(_ setup: Setup) throws -> (setup: Setup, mode: LedgerMode) {
        guard let quality = setup.libraryQualityProfileId else { throw WriteGateError.disabled }
        var target = setup
        target.qualityProfileId = quality
        return (target, .fallback)
    }

    /// The whole discography the owner's Add defaults name (their metadata profile, their following), monitored; no search
    /// on add: this release is searched first by the runner, then the rest (`ArtistSearch`, after it).
    static func addLibraryArtistBody(lookup: JSONValue, setup: Setup, request: MagpieRequest?) throws -> JSONValue {
        guard var o = lookup.objectValue else { throw RunnerAddFailure() }
        let overrides: [String: JSONValue] = [
            "rootFolderPath": .string(setup.rootFolderPath),
            "qualityProfileId": .int(setup.qualityProfileId),
            "metadataProfileId": .int(request?.libraryMetadataProfileId ?? setup.metadataProfileId),
            "monitored": .bool(true),
            "monitorNewItems": .string(request?.libraryFollow == true ? "all" : "none"),
            "tags": .array(setup.tagIds.map { .int($0) }),
            "addOptions": .object(["monitor": .string("all"), "searchForMissingAlbums": .bool(false)]),
        ]
        let folded = Set(overrides.keys.map { $0.lowercased() } + ["id"])
        o = o.filter { !folded.contains($0.key.lowercased()) }
        o.merge(overrides) { _, new in new }
        return .object(o)
    }

    struct RunnerAddFailure: Error {}

    /// After this release's search, the rest of a new artist Magpie added for Add to library (once; the gate allows
    /// ArtistSearch only for an artist Magpie added). A failure is left: Lidarr's monitoring carries on.
    func searchDiscography(_ id: RequestID) async {
        guard let r = request(id), r.addToLibrary, r.addSent, r.discographySearched != true,
              let artistId = r.lidarrArtistId else { return }
        await mutate(id) { $0.discographySearched = true }
        _ = try? await gate.send("POST", "command", body: ArtistSearchBody(name: "ArtistSearch", artistId: artistId))
    }

    private struct ArtistSearchBody: Encodable, Sendable {
        var name: String
        var artistId: Int
    }

    /// D147: a Try of a release of an artist already in the library, which Magpie monitors now: read just before, it is
    /// unmonitored with no files. Only such an album may later be rejected (its files deleted). Returns whether it is one.
    func markTrial(_ entry: inout LedgerEntry, _ r: MagpieRequest, mode: LedgerMode, needsMonitor: Bool, album: LidarrAlbum) -> Bool {
        let trial = r.askedAsTry && !r.addToLibrary && mode == .fallback && needsMonitor && !entry.createdArtist
            && album.trackFileCount == 0
        if trial {
            entry.trialHadNoFiles = true
            entry.trialExpiresAt = now().addingTimeInterval(TimeInterval(Self.trialDays) * 86_400)
        }
        return trial
    }
}
