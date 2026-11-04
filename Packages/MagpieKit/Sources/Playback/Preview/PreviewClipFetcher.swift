import AurralKit
import Foundation
import MagpieCore

/// Why a preview clip wasn't fetched.
public enum PreviewClipError: Error, Sendable, Equatable {
    /// Not Deezer's https audio hosts (`*.dzcdn.net`) at any hop, an empty clip or one far bigger than 30 seconds of audio.
    case refused
    /// Deezer answered something other than 200 (403 once the signed link has expired).
    case status(Int)
}

/// Round 14 A2 (D88, fix I1): fetches a preview clip (the signed Deezer link `PreviewResolver` pinned) into memory for the
/// preview engine. Magpie fetches it rather than AVPlayer: the app allows plain http everywhere (the owner's servers), so
/// AVPlayer would follow any redirect. Here every hop, and where the answer finally landed, must be Deezer's https audio
/// hosts (`PreviewResolver.isDeezerAudio`, A1's own check: https, `dzcdn.net` or `*.dzcdn.net`, default port, no user
/// info); anything else is refused (plan decision 3).
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
        // A transport that followed a redirect itself names where it ended: it must still be Deezer's audio hosts.
        if let landed = response.url, !Self.isAllowed(landed) { throw PreviewClipError.refused }
        guard !data.isEmpty, data.count <= Self.maxBytes else { throw PreviewClipError.refused }
        return data
    }

    /// Deezer's https audio hosts only (A1's check, so the resolver and every later hop share one rule).
    public static func isAllowed(_ url: URL) -> Bool { PreviewResolver.isDeezerAudio(url) }

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

        /// Reads the body as it arrives, in the chunks URLSession hands over, and cancels past `maxBytes` (or at once
        /// when the headers already say it is bigger).
        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            let download = ClipDownload()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    download.start(request, session: Self.session, continuation: continuation)
                }
            } onCancel: { download.cancel() }
        }
    }

    /// One clip's download: a data task whose delegate keeps to Deezer's hosts and caps the body.
    private final class ClipDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionDataTask?
        private var refused = false

        func start(_ request: URLRequest, session: URLSession,
                   continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            let task = session.dataTask(with: request)
            task.delegate = self
            lock.withLock { self.continuation = continuation; self.task = task }
            task.resume()
        }

        func cancel() { lock.withLock { task }?.cancel() }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            await HTTPSOnlyRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                        newRequest: request)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
            -> URLSession.ResponseDisposition {
            guard let http = response as? HTTPURLResponse else { return .cancel }
            lock.withLock { self.response = http }
            if http.statusCode == 200, http.expectedContentLength > Int64(PreviewClipFetcher.maxBytes) {
                lock.withLock { refused = true }
                return .cancel
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let over = lock.withLock {
                data.append(chunk)
                if data.count > PreviewClipFetcher.maxBytes { refused = true; data = Data() }
                return refused
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, data, response, refused) = lock.withLock {
                defer { self.continuation = nil; self.data = Data() }
                return (self.continuation, self.data, self.response, self.refused)
            }
            if refused {
                continuation?.resume(throwing: PreviewClipError.refused)
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: (data, response))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }

    /// Follows a redirect only to Deezer's https audio hosts; anything else stops at the 3xx (a failure).
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
