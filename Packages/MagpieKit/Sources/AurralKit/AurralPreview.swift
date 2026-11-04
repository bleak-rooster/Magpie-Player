import Foundation
import MagpieCore

/// Round 14 A1 (D83): a song's 30-second preview, as Aurral names it: `preview_url` = `/api/deezer/preview/<id>.mp3`
/// (Aurral 2.13 `services/apiClients/deezer.ts` `deezerPreviewPath`). Only that exact shape is kept: any other
/// `preview_url` (another host, another route) is dropped when decoding. The URL is always made on the configured
/// Aurral base; the signed Deezer link it redirects to is never kept (`PreviewResolver`).
public struct AurralPreview: Sendable, Hashable, Codable {
    /// Deezer's track id (1–20 digits).
    public let trackId: String

    public init?(trackId: String) {
        guard AurralRoute.isDigits(Substring(trackId), max: 20) else { return nil }
        self.trackId = trackId
    }

    /// From Aurral's `preview_url` path; nil for anything but `/api/deezer/preview/<digits>.mp3`.
    public init?(path: String) {
        let prefix = "/api/deezer/preview/"
        guard path.hasPrefix(prefix), path.hasSuffix(".mp3") else { return nil }
        let id = path.dropFirst(prefix.count).dropLast(4)
        self.init(trackId: String(id))
    }

    /// The path as Magpie sends it (relative to the Aurral base).
    public var path: String { "api/deezer/preview/\(trackId).mp3" }

    /// The preview on the configured Aurral.
    public func url(on base: URL) -> URL? { ServerEndpoint(bases: [base]).url(base, path: path) }
}

/// Round 14 A1: an image Aurral names: an absolute http(s) URL (Deezer's or Apple's CDN), or a path on Aurral itself
/// (`/api/...`, made on the configured base). Anything else (`javascript:`, `file:`, `..`) is dropped when decoding.
public struct AurralImage: Sendable, Hashable, Codable {
    public let raw: String

    public init?(_ raw: String?) {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty, raw.count <= 2_048,
              !raw.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        if raw.hasPrefix("/") {
            guard raw.hasPrefix("/api/"), !raw.contains("//"), !raw.contains(".."), !raw.contains("\\") else { return nil }
        } else {
            guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                  url.host()?.isEmpty == false, url.user == nil, url.password == nil else { return nil }
        }
        self.raw = raw
    }

    /// The image's URL (an Aurral path made on `base`).
    public func url(on base: URL) -> URL? {
        guard raw.hasPrefix("/") else { return URL(string: raw) }
        var text = base.absoluteString
        while text.hasSuffix("/") { text.removeLast() }
        return URL(string: text + raw)
    }
}
