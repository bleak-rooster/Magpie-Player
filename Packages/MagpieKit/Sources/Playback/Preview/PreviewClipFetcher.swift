import Foundation
import MagpieCore

/// Why a preview clip wasn't fetched.
public enum PreviewClipError: Error, Sendable, Equatable {
    /// Not https (or with user info), a hop to plain http, an empty clip or one far bigger than 30 seconds of audio.
    case refused
    /// Deezer answered something other than 200 (403 once the signed link has expired).
    case status(Int)
}

/// Round 14 A2 (D88): fetches a preview clip (the signed Deezer link `PreviewResolver` pinned) into memory for the preview
/// engine. Magpie fetches it rather than AVPlayer: the app allows plain http everywhere (the owner's servers), so AVPlayer
/// would follow a redirect to http; this session follows redirects to https only.
/// - No cookie, no cache, no login: an ephemeral session of its own.
/// - The clip lives in memory only while it plays, and is never written to disk or kept.
/// - The signed link is never logged (its `hdnea` query is a credential).
public struct PreviewClipFetcher: Sendable {
    /// A 30-second MP3 is about 0.5 MB; anything past this isn't a preview.
    public static let maxBytes = 4 * 1024 * 1024

    private let transport: HTTPTransport

    public init(transport: HTTPTransport = PreviewClipFetcher.defaultTransport()) {
        self.transport = transport
    }

    public func fetch(_ url: URL) async throws -> Data {
        guard Self.isAllowed(url) else { throw PreviewClipError.refused }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("audio/*", forHTTPHeaderField: "Accept")
        // Never `Log.request` here: the URL carries the signature.
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw PreviewClipError.status(response.statusCode) }
        // A transport that followed a redirect itself names where it ended: it must still be https.
        if let landed = response.url, !Self.isAllowed(landed) { throw PreviewClipError.refused }
        guard !data.isEmpty, data.count <= Self.maxBytes else { throw PreviewClipError.refused }
        return data
    }

    /// https, with a host, without user info.
    public static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host(), !host.isEmpty else { return false }
        return url.user == nil && url.password == nil
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
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        return config
    }

    public static func defaultTransport() -> HTTPTransport { Transport() }

    private struct Transport: HTTPTransport {
        static let session = URLSession(configuration: PreviewClipFetcher.sessionConfiguration(),
                                        delegate: HTTPSOnlyRedirects.shared, delegateQueue: nil)

        /// Streams the body so an oversized answer is cut off at `maxBytes` instead of read whole.
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let (bytes, response) = try await Self.session.bytes(for: request, delegate: HTTPSOnlyRedirects.shared)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard http.statusCode == 200 else { return (Data(), http) }
            if http.expectedContentLength > Int64(PreviewClipFetcher.maxBytes) { throw PreviewClipError.refused }
            var data = Data()
            data.reserveCapacity(max(0, min(Int(http.expectedContentLength), PreviewClipFetcher.maxBytes)))
            for try await byte in bytes {
                data.append(byte)
                if data.count > PreviewClipFetcher.maxBytes { throw PreviewClipError.refused }
            }
            return (data, http)
        }
    }

    /// Follows a redirect only to https without user info; anything else stops at the 3xx (a failure).
    public final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        public static let shared = HTTPSOnlyRedirects()

        public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest) async -> URLRequest? {
            guard let url = request.url, PreviewClipFetcher.isAllowed(url) else { return nil }
            var next = request
            next.httpShouldHandleCookies = false
            return next
        }
    }
}
