import Foundation
import MagpieCore

/// Bytes received so far and bytes expected (-1 or 0 when the server didn't say).
typealias FetchProgress = @Sendable (_ received: Int64, _ expected: Int64) -> Void

/// Fetches one audio file (or cover) to a temporary file the caller then owns.
protocol AudioFetching: Sendable {
    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?)
    /// The same, reporting progress (P1, Downloading now) at most about 4 times a second.
    func fetch(_ url: URL, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> (file: URL, mimeType: String?)
}

extension AudioFetching {
    /// Fetchers that can't tell progress (test fakes) report none.
    func fetch(_ url: URL, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> (file: URL, mimeType: String?) {
        try await fetch(url, allowsCellular: allowsCellular)
    }
}

/// Download tasks on an ephemeral session with no URLCache: the URLs carry Subsonic auth (`u`, `t`, `s`), so
/// nothing about them is written to disk. Redirects stay within the origin. Cancelling the calling task cancels
/// the download, and no partial file is left behind.
struct URLSessionAudioFetcher: AudioFetching {
    enum FetchError: Error { case status(Int) }

    private let session: URLSession

    init(session: URLSession = SameOriginRedirects.session(configuration: URLSessionTransport.defaultConfiguration())) {
        self.session = session
    }

    /// Tests check it keeps no URLCache.
    var configuration: URLSessionConfiguration { session.configuration }

    /// How often progress is read off the task (P1: at most about 4 times a second).
    static let progressInterval = Duration.milliseconds(250)

    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        try await fetch(url, allowsCellular: allowsCellular, progress: { _, _ in })
    }

    func fetch(_ url: URL, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> (file: URL, mimeType: String?) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.allowsCellularAccess = allowsCellular
        // The task's own byte counts, read on a timer: never more often than `progressInterval`.
        let capture = TaskCapture()
        let reporter = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.progressInterval)
                guard !Task.isCancelled, let task = capture.task else { continue }
                progress(task.countOfBytesReceived, task.countOfBytesExpectedToReceive)
            }
        }
        defer { reporter.cancel() }
        let (downloaded, response) = try await session.download(for: request, delegate: capture)
        // The caller owns the file: move it out of URLSession's hands under a name of our own.
        let file = FileManager.default.temporaryDirectory.appending(path: "magpie-audio-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.moveItem(at: downloaded, to: file)
        } catch {
            try? FileManager.default.removeItem(at: downloaded)
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            try? FileManager.default.removeItem(at: file)
            throw FetchError.status(status)
        }
        return (file, response.mimeType)
    }
}

/// Hands over the URLSession task an async download creates, so its progress can be read. A task delegate is asked
/// first, so it applies the same-origin redirect policy itself (Security M1) rather than rely on the session's.
private final class TaskCapture: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _task: URLSessionTask?

    var task: URLSessionTask? { lock.withLock { _task } }

    func urlSession(_ session: URLSession, didCreateTask task: URLSessionTask) {
        lock.withLock { _task = task }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        await SameOriginRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: request)
    }
}
