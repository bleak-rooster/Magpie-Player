import Foundation

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Round 14 S14 M1 (D115): the answer, at most `maxBytes` long; a bigger one throws `ResponseTooLarge`.
    /// `URLSessionTransport` reads the body as it arrives and stops at the cap; any other transport checks the size of
    /// what it read (the default below).
    func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse)
}

/// The answer was bigger than the caller's cap (nothing of it is kept).
public struct ResponseTooLarge: Error, Sendable, Equatable {
    public init() {}
}

extension HTTPTransport {
    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await send(request)
        guard data.count <= maxBytes else { throw ResponseTooLarge() }
        return (data, response)
    }
}

public struct URLSessionTransport: HTTPTransport {
    public let timeout: TimeInterval
    private let session: URLSession

    /// Subsonic auth rides in the query string (`u`, `t`, `s`), so the default session is ephemeral
    /// and has no URLCache: nothing is written to disk.
    public static func defaultConfiguration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }

    public init(timeout: TimeInterval = 15,
                session: URLSession = SameOriginRedirects.session(configuration: URLSessionTransport.defaultConfiguration())) {
        self.timeout = timeout
        self.session = session
    }

    /// The configuration of the session in use (tests check it keeps no URLCache).
    var sessionConfiguration: URLSessionConfiguration { session.configuration }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        // The redirect policy is set per task too, so it holds whatever session was passed in (M1).
        let (data, response) = try await session.data(for: request, delegate: SameOriginRedirects.shared)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return (data, http)
    }

    /// S14 M1: refuses at once a Content-Length over `maxBytes`, and stops reading a body that grows past it. The
    /// redirect rules are the same as `send(_:)`'s (`SameOriginRedirects`).
    public func send(_ request: URLRequest, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        try Task.checkCancellation()
        let download = CappedDataTask(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                download.start(request, session: session, continuation: continuation)
            }
        } onCancel: { download.cancel() }
    }
}

/// One capped answer: a data task whose own delegate applies `SameOriginRedirects` and stops past `maxBytes`.
private final class CappedDataTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
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
                    newRequest request: URLRequest) async -> URLRequest? {
        await SameOriginRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: request)
    }

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
