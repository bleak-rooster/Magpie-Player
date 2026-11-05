import Foundation
import MagpieCore

/// One track of a Lidarr album (`GET /track?albumId=`): which recording it is and which track file holds it (Y5:
/// Ready per recording, I8; the kept MP3 is found again by its track, C3).
public struct LidarrTrack: Sendable, Equatable, Decodable {
    public var id: Int
    public var albumId: Int?
    /// 0 or missing: no file yet.
    public var trackFileId: Int?
    public var foreignTrackId: String?
    public var foreignRecordingId: String?

    public init(id: Int, albumId: Int?, trackFileId: Int?, foreignTrackId: String?, foreignRecordingId: String?) {
        self.id = id; self.albumId = albumId; self.trackFileId = trackFileId
        self.foreignTrackId = foreignTrackId; self.foreignRecordingId = foreignRecordingId
    }

    public var hasFile: Bool { (trackFileId ?? 0) > 0 }

    /// Round 15 C3 (review I5): the track's title (a library trial's songs are matched by title and path).
    public var title: String?

    enum CodingKeys: String, CodingKey { case id, albumId, trackFileId, foreignTrackId, foreignRecordingId, title }
}

extension LidarrClient {
    /// The album's tracks. Reads only.
    public func tracks(albumId: Int) async throws -> [LidarrTrack] {
        let (data, response) = try await connection.get("track", [URLQueryItem(name: "albumId", value: String(albumId))])
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw LidarrError.unauthorized
        default: throw LidarrError.http(status: response.statusCode)
        }
        do { return try JSONDecoder().decode(LossyArray<LidarrTrack>.self, from: data).values } catch {
            throw LidarrError.decoding
        }
    }

    /// Y5 (item 9.7): Lidarr's clock, from the `Date` header of a fresh `GET /system/status`. Nil when the answer has
    /// no usable header, was served from a cache (an `Age` header) or wasn't a 200 (M4).
    public func serverDate() async throws -> Date? {
        let (_, response) = try await connection.get("system/status")
        guard response.statusCode == 200 else {
            if [401, 403].contains(response.statusCode) { throw LidarrError.unauthorized }
            return nil
        }
        guard response.value(forHTTPHeaderField: "Age") == nil,
              let text = response.value(forHTTPHeaderField: "Date") else { return nil }
        return Self.httpDate(text)
    }

    /// RFC 9110 IMF-fixdate (`Sun, 02 Nov 2026 17:37:00 GMT`).
    public static func httpDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f.date(from: text)
    }
}
