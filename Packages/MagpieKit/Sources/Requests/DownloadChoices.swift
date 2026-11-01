import Foundation
import LidarrKit

/// R18: how music comes in when it's added to your library, brought in, or added from an artist page: this album
/// only or the whole artist (with its release types), the quality, and whether new releases follow. Settings ›
/// Requests › Download defaults holds one; with Simple downloads on, those defaults are used every time.
public struct DownloadChoices: Codable, Hashable, Sendable {
    public enum What: String, Codable, CaseIterable, Sendable {
        case thisAlbum
        case wholeArtist
    }

    public enum Quality: String, Codable, CaseIterable, Sendable {
        /// FLAC: the "Magpie Lossless" quality profile.
        case lossless
        /// MP3: the "Magpie Fast Start" quality profile (MP3-320 or V0, no upgrade).
        case smaller
    }

    public var what: What
    public var types: ReleaseTypes
    public var quality: Quality
    public var follow: Bool

    public init(what: What = .wholeArtist, types: ReleaseTypes = .standard, quality: Quality = .lossless,
                follow: Bool = false) {
        self.what = what; self.types = types; self.quality = quality; self.follow = follow
    }

    /// The owner defaults: the whole artist, Albums + EPs, Studio, Lossless, not following new releases.
    public static let defaults = DownloadChoices()

    private enum CodingKeys: String, CodingKey { case what, types, quality, follow }

    /// Missing or unknown fields read as the defaults (saved choices outlive builds).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        what = (try? c.decodeIfPresent(What.self, forKey: .what)) ?? d.what
        types = (try? c.decodeIfPresent(ReleaseTypes.self, forKey: .types)) ?? d.types
        quality = (try? c.decodeIfPresent(Quality.self, forKey: .quality)) ?? d.quality
        follow = (try? c.decodeIfPresent(Bool.self, forKey: .follow)) ?? d.follow
    }

    /// The Bring in more choice these make.
    public var bringInChoice: RequestRunner.BringInChoice { what == .thisAlbum ? .thisAlbum : .everything }
}
