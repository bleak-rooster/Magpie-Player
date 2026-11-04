import Foundation
import MagpieCore

/// What a preview resolved to.
public enum PreviewResolution: Sendable, Equatable {
    /// The clip's bytes, as Aurral sent them: hand them straight to the player, held in memory only while it plays.
    case clip(Data)
    /// Aurral has no preview for the song (404): show "No preview available".
    case noPreview
}

/// Why a preview wasn't resolved.
public enum PreviewError: Error, Sendable, Equatable {
    /// Not the clip from the configured Aurral: any redirect, an answer from another host, another status, an empty
    /// body, something that isn't audio, or more than a preview's size.
    case refused
    /// Aurral or Deezer had a problem (502 when Deezer is down, 5xx).
    case unavailable(status: Int)
}

/// Round 14 A1 (D83), A7 (D110, plan decision 11: no direct calls to Deezer from the phone): fetches a preview clip
/// through Aurral. `GET <Aurral base>/api/deezer/preview/<id>.mp3?download` (open on Aurral): Aurral fetches the clip
/// from Deezer itself and answers 200 `audio/mpeg` with the bytes, so the phone never contacts Deezer's CDN.
/// - No login, no cookie, no cache; its own transport (`AurralOpenTransport`), which never follows a redirect.
/// - Any 3xx is refused; the answer must come from the configured Aurral host (scheme, host case-insensitively, port).
/// - 200 with audio, not empty, at most `maxBytes` → `.clip`; 404 → `.noPreview`; 5xx → `unavailable`; anything else
///   is refused.
/// - Keeps nothing and logs no bytes: every call asks Aurral again (the player resolves just before it plays).
public struct PreviewResolver: Sendable {
    /// A 30-second MP3 is about 0.5 MB; anything past this isn't a preview.
    public static let maxBytes = 4 * 1024 * 1024

    public let base: URL
    private let transport: HTTPTransport

    /// `transport` defaults to `defaultTransport()`: its own ephemeral session that never follows a redirect.
    public init(base: URL, transport: HTTPTransport = PreviewResolver.defaultTransport()) {
        self.base = base
        self.transport = transport
    }

    public func resolve(_ preview: AurralPreview) async throws -> PreviewResolution {
        guard AurralRoute.isAllowed(method: "GET", path: preview.path, query: AurralPreview.downloadQuery),
              let url = preview.url(on: base) else { throw PreviewError.refused }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        Log.request(request, category: "aurral")
        let data: Data, response: HTTPURLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch is AurralOpenTransport.TooLarge {
            throw PreviewError.refused
        }
        // The answer must be Aurral's own (a transport that followed a redirect names where it landed). Compared as an
        // origin: URLSession hands the answer's URL back canonical (lower-cased scheme and host; fix I1).
        if let landed = response.url, !landed.isSameOrigin(as: url) { throw PreviewError.refused }
        switch response.statusCode {
        case 200:
            let type = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard type.hasPrefix("audio/"), !data.isEmpty, data.count <= Self.maxBytes else { throw PreviewError.refused }
            return .clip(data)
        case 404: return .noPreview
        case 500..<600: throw PreviewError.unavailable(status: response.statusCode)
        default: throw PreviewError.refused   // every 3xx included: never followed
        }
    }

    // MARK: - The real transport

    /// Ephemeral, no cookies, no cache.
    public static func sessionConfiguration() -> URLSessionConfiguration { AurralOpenTransport.sessionConfiguration() }

    public static func defaultTransport() -> HTTPTransport { AurralOpenTransport() }
}
