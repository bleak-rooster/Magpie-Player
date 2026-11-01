import Foundation
import MagpieCore
import NavidromeKit

/// "Album artists only" (round 11 R11), for Library › Artists and the car's Artists alike.
///
/// Verified on the dev Navidrome 0.64.2: `getArtists` lists album artists only (each with `roles`), the same set as the
/// native `/api/artist?role=albumartist`; `/api/artist` without `role` lists every artist, track-only ones too (the
/// fixture's "Static Choir", roles artist + maincredit), and artists whose files are gone (`missing`, skipped).
/// `role=artist` and `role=maincredit` filter too; an unknown role answers an empty list (200), not an error. So on
/// keeps `getArtists` (any Subsonic server) and off reads `/api/artist` with no role filter.
extension AppModel {
    func libraryArtists() async throws -> [Artist] {
        if preferences.layout.albumArtistsOnly { return try await request { try await $0.artists() } }
        return try await request { try await $0.allArtists() }
    }
}
