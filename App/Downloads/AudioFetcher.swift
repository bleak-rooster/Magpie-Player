import Foundation
import MagpieCore

/// Fetches one audio file (or cover) to a temporary file the caller then owns.
protocol AudioFetching: Sendable {
    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?)
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

    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.allowsCellularAccess = allowsCellular
        let (downloaded, response) = try await session.download(for: request)
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
