import Foundation
import MagpieCore

public enum ListenType: String, Sendable { case single, playingNow = "playing_now", importBatch = "import" }

public struct Listen: Sendable, Hashable, Codable {
    /// Unused (and omitted from the body) for `.playingNow`.
    public var listenedAt: Date?
    public var trackName: String
    public var artistName: String
    public var releaseName: String?
    public var durationMs: Int?
    public var recordingMBID: MBID?

    public init(listenedAt: Date?, trackName: String, artistName: String, releaseName: String? = nil,
                durationMs: Int? = nil, recordingMBID: MBID? = nil) {
        self.listenedAt = listenedAt; self.trackName = trackName; self.artistName = artistName
        self.releaseName = releaseName; self.durationMs = durationMs; self.recordingMBID = recordingMBID
    }
}

extension ListenBrainzError {
    /// What a failed send means for the play (T16 review): send it again later, give up on it, or stop sending
    /// until a new token is saved.
    public enum Disposition: Sendable, Equatable { case retry, permanent, invalidToken }

    /// 429, 5xx, timeouts and anything else unexpected are retried; 400, 413 and the other 4xx are permanent (the
    /// same listens would be refused again); 401/403 mean the token is no longer valid.
    public var disposition: Disposition {
        switch self {
        case .unauthorized: .invalidToken
        case .invalidListen: .permanent
        case .http(let status) where status == 429: .retry
        case .http(let status) where (400..<500).contains(status): .permanent
        case .http, .timedOut, .decoding: .retry
        }
    }
}

extension ListenBrainzClient {
    public static let maxListensPerCall = 100

    /// One request. The caller chunks: more than `maxListensPerCall` listens throws `.http(status: 413)` without sending.
    /// It only sends; the scrobble router decides whether a play may go out at all (D29).
    public func submitListens(_ listens: [Listen], type: ListenType) async throws {
        guard let token else { throw ListenBrainzError.unauthorized }
        let tooMany = listens.count > Self.maxListensPerCall
        let wrongCount = type != .importBatch && listens.count != 1
        guard !listens.isEmpty, !tooMany, !wrongCount else { throw ListenBrainzError.http(status: 413) }
        // `single` and `import` must say when each listen happened; the router always does, this is the backstop.
        if type != .playingNow, listens.contains(where: { $0.listenedAt == nil }) { throw ListenBrainzError.invalidListen }
        guard let url = ServerEndpoint(bases: [Self.apiBase]).url(Self.apiBase, path: "1/submit-listens") else {
            throw URLError(.badURL)
        }
        let payload = listens.map { listen -> [String: Any] in
            var info: [String: Any] = ["submission_client": "Magpie", "submission_client_version": clientVersion,
                                       "media_player": "Magpie"]
            if let ms = listen.durationMs { info["duration_ms"] = ms }
            if let mbid = listen.recordingMBID { info["recording_mbid"] = mbid.rawValue }
            var meta: [String: Any] = ["artist_name": listen.artistName, "track_name": listen.trackName,
                                       "additional_info": info]
            if let release = listen.releaseName { meta["release_name"] = release }
            var item: [String: Any] = ["track_metadata": meta]
            if type != .playingNow, let at = listen.listenedAt { item["listened_at"] = Int(at.timeIntervalSince1970) }
            return item
        }
        let body: [String: Any] = ["listen_type": type.rawValue, "payload": payload]
        var request = URLRequest(url: url)
        // G1 allowlist: listenbrainz submit-listens
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = apiTimeout
        Log.request(request, category: "listenbrainz")  // method, redacted URL and headers only; never the body
        let limiter = self.limiter
        _ = try await sendWithDeadline(request, seconds: apiTimeout, before: { try await limiter?.wait() })
    }
}
