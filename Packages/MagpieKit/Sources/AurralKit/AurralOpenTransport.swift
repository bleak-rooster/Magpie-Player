import Foundation
import MagpieCore

/// Round 14 A7 (D110, D111): the transport for Aurral's open routes (the preview clip `?download` and the image proxy's
/// pictures). Never sends a login (its callers build no Authorization), and:
/// - an ephemeral session of its own: no cookies, no URLCache, nothing on disk;
/// - never follows a redirect: URLSession hands the 3xx back, and the caller refuses it;
/// - reads the body as it arrives and stops past `maxBytes` (or at once when the headers already say it is bigger).
public struct AurralOpenTransport: HTTPTransport {
    /// No open answer Magpie takes is bigger (a 30-second MP3 is about 0.5 MB; Aurral's pictures are 150 KB).
    public static let maxBytes = 4 * 1024 * 1024

    public init() {}

    /// Ephemeral, no cookies, no cache.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 40
        return config
    }

    static let session = URLSession(configuration: sessionConfiguration(), delegate: NoRedirects.shared, delegateQueue: nil)

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let download = CappedDownload()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(request, session: Self.session, continuation: continuation)
            }
        } onCancel: { download.cancel() }
    }

    /// Thrown when the answer is bigger than `maxBytes`.
    public struct TooLarge: Error, Sendable {}

    /// Never follows a redirect: URLSession then hands back the 3xx itself, for the caller to refuse.
    public final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        public static let shared = NoRedirects()

        public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                               newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// One answer's download: a data task that never follows a redirect and caps the body.
    private final class CappedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionDataTask?
        private var tooLarge = false
        private var cancelled = false

        /// Fix round 1 M1: a call cancelled before it starts sends nothing.
        func start(_ request: URLRequest, session: URLSession,
                   continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
            let task = session.dataTask(with: request)
            task.delegate = self
            let go = lock.withLock { () -> Bool in
                guard !cancelled else { return false }
                self.continuation = continuation; self.task = task
                return true
            }
            guard go else { return continuation.resume(throwing: CancellationError()) }
            task.resume()
        }

        func cancel() { lock.withLock { cancelled = true; return task }?.cancel() }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async
            -> URLSession.ResponseDisposition {
            guard let http = response as? HTTPURLResponse else { return .cancel }
            lock.withLock { self.response = http }
            if http.expectedContentLength > Int64(AurralOpenTransport.maxBytes) {
                lock.withLock { tooLarge = true }
                return .cancel
            }
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let over = lock.withLock {
                data.append(chunk)
                if data.count > AurralOpenTransport.maxBytes { tooLarge = true; data = Data() }
                return tooLarge
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, data, response, tooLarge) = lock.withLock {
                defer { self.continuation = nil; self.data = Data() }
                return (self.continuation, self.data, self.response, self.tooLarge)
            }
            if tooLarge {
                continuation?.resume(throwing: TooLarge())
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let response {
                continuation?.resume(returning: (data, response))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}

extension URL {
    /// Round 14 A7: the same origin as `other` (scheme, host case-insensitively, and port, default ports filled in).
    func isSameOrigin(as other: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            return (scheme, host.hasSuffix(".") ? String(host.dropLast()) : host, port)
        }
        guard let a = origin(self), let b = origin(other), user == nil, password == nil else { return false }
        return a == b
    }
}
