import Foundation
import MagpieCore

/// What a preview resolved to.
public enum PreviewResolution: Sendable, Equatable {
    /// Deezer's signed MP3 link: hand it straight to the player, and never keep it (it expires in about 15 minutes).
    case playable(URL)
    /// Aurral has no preview for the song (404): show "No preview available".
    case noPreview
}

/// Why a preview wasn't resolved.
public enum PreviewError: Error, Sendable, Equatable {
    /// Not a single 302 to Deezer's HTTPS audio hosts (another host, plain http, a relative link, the bytes instead of
    /// a redirect, as a transport that followed the redirect itself gives, another redirect code).
    case refused
    /// Aurral or Deezer had a problem (502 when Deezer is down, 5xx).
    case unavailable(status: Int)
}

/// Round 14 A1 (D83, plan decision 3): turns an `AurralPreview` into something the player can play, safely.
/// - Fetches `<Aurral base>/api/deezer/preview/<id>.mp3` (open on Aurral) with no login, no cookie and no cache.
/// - Never follows a redirect itself; accepts exactly one 302 whose `Location` is `https://<host>.dzcdn.net/<path>`
///   (or `dzcdn.net` itself) on the default port, without user info.
/// - 404 → `.noPreview`; 5xx → `unavailable`; anything else is refused.
/// - Keeps nothing: every call asks Aurral again (A2's player resolves just before it plays).
public struct PreviewResolver: Sendable {
    public let base: URL
    private let transport: HTTPTransport

    /// `transport` defaults to `defaultTransport()`: its own ephemeral session that never follows a redirect.
    public init(base: URL, transport: HTTPTransport = PreviewResolver.defaultTransport()) {
        self.base = base
        self.transport = transport
    }

    public func resolve(_ preview: AurralPreview) async throws -> PreviewResolution {
        guard AurralRoute.route(method: "GET", path: preview.path) == .deezerPreview, let url = preview.url(on: base) else {
            throw PreviewError.refused
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        Log.request(request, category: "aurral")
        let (_, response) = try await transport.send(request)
        // Fix I1: decided by the status alone. URLSession hands back the answer's URL canonical (lower-cased scheme and
        // host), so comparing it with the asked URL refused every Aurral saved with capital letters; a transport that
        // followed the redirect itself can't hand back Aurral's 302 (it gives the bytes, a 200: refused below).
        switch response.statusCode {
        case 302:
            guard let location = response.value(forHTTPHeaderField: "Location"), let target = URL(string: location),
                  Self.isDeezerAudio(target) else { throw PreviewError.refused }
            return .playable(target)
        case 404: return .noPreview
        case 500..<600: throw PreviewError.unavailable(status: response.statusCode)
        default: throw PreviewError.refused
        }
    }

    /// `https://*.dzcdn.net/<path>` (or `https://dzcdn.net/<path>`), on the default port, without user info.
    public static func isDeezerAudio(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host()?.lowercased(), !host.isEmpty,
              url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              url.path().count > 1 else { return false }
        return host == "dzcdn.net" || host.hasSuffix(".dzcdn.net")
    }

    // MARK: - The real transport

    /// Ephemeral, no cookies, no cache.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 10
        return config
    }

    public static func defaultTransport() -> HTTPTransport { Transport() }

    private struct Transport: HTTPTransport {
        static let session = URLSession(configuration: PreviewResolver.sessionConfiguration(), delegate: NoRedirects.shared,
                                        delegateQueue: nil)
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (data, response) = try await Self.session.data(for: request, delegate: NoRedirects.shared)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    /// Never follows a redirect: URLSession then hands back the 3xx itself, for `resolve` to check.
    public final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        public static let shared = NoRedirects()

        public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest) async -> URLRequest? { nil }
    }
}
