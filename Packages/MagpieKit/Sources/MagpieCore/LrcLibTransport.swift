import Foundation

/// Round 27 L fix round 1 (security LL1, LL2; D311): the transport for Find lyrics online, the one direct call to an
/// outside lyrics site. Like Aurral's open transport (`AurralOpenTransport`, D110):
/// - its own ephemeral session: no cookie store, no credential store, no URLCache, nothing on disk;
/// - never follows a redirect, not even within the same origin: URLSession hands the 3xx back and `LrcLib` treats it
///   as none (`SameOriginRedirects` would follow a same-origin GET);
/// - reads the body as it arrives and stops past `maxBytes` (at once when the headers already say it is bigger).
/// It names no host: `LrcLib` builds and checks the one request it sends. `scripts/check-writes.sh` pins that the app
/// makes `LrcLib` only with this transport, and that this file never follows a redirect.
public struct LrcLibTransport: HTTPTransport {
    public init() {}

    /// Ephemeral, no cookies, no credentials, no cache; 15 s for a request.
    public static func sessionConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        return config
    }

    static let session = URLSession(configuration: sessionConfiguration(), delegate: NoRedirects.shared, delegateQueue: nil)

    /// Every answer is capped; without a cap of its own, `LrcLib.maxResponseBytes`.
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await send(request, maxBytes: LrcLib.maxResponseBytes)
    }

    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        let download = Download(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(request, session: Self.session, continuation: continuation)
            }
        } onCancel: { download.cancel() }
    }

    /// Never follows a redirect: URLSession then hands back the 3xx itself.
    final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirects()

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    /// One answer: a data task that never follows a redirect and caps the body (`ResponseTooLarge` past it).
    private final class Download: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let maxBytes: Int
        private let lock = NSLock()
        private var data = Data()
        private var response: HTTPURLResponse?
        private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        private var task: URLSessionDataTask?
        private var tooLarge = false
        private var cancelled = false

        init(maxBytes: Int) { self.maxBytes = max(0, maxBytes) }

        /// A call cancelled before it starts sends nothing.
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
            let over = http.expectedContentLength > Int64(maxBytes)
            lock.withLock { self.response = http; if over { tooLarge = true } }
            return over ? .cancel : .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let over = lock.withLock {
                guard !tooLarge else { return true }
                if data.count + chunk.count > maxBytes { tooLarge = true; data = Data(); return true }
                data.append(chunk)
                return false
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            let (continuation, data, response, tooLarge) = lock.withLock {
                defer { self.continuation = nil; self.data = Data() }
                return (self.continuation, self.data, self.response, self.tooLarge)
            }
            if tooLarge {
                continuation?.resume(throwing: ResponseTooLarge())
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
