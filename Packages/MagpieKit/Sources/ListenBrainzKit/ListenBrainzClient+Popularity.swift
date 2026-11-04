import Foundation
import MagpieCore

extension ListenBrainzClient {
    /// Round 14 A1 (D84): an artist's most-listened songs worldwide, most first:
    /// `GET https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/:artist_mbid` (listenbrainz-server
    /// `webserver/views/popularity_api.py`, blueprint at `/1/popularity`). The answer is a bare list of
    /// `{artist_mbids, artist_name, recording_mbid, recording_name, release_mbid, release_name, length (ms),
    /// total_listen_count, ...}`. ListenBrainz requires a user token on its popularity routes, so without one nothing
    /// is asked (`unauthorized`). Rows without a title or an artist name are dropped; the artist asked for stands in
    /// when a row names no artist MBID.
    public func topRecordingsForArtist(_ artist: MBID, limit: Int = 25) async throws -> [ExternalRecording] {
        guard token != nil else { throw ListenBrainzError.unauthorized }
        let data = try await api("1/popularity/top-recordings-for-artist/\(artist.rawValue)")
        guard let rows = try? JSONDecoder().decode(LossyArray<TopRecordingRow>.self, from: data) else {
            throw ListenBrainzError.decoding
        }
        return Array(rows.values.lazy.compactMap { $0.recording(artist: artist) }.prefix(max(0, limit)))
    }
}

private struct TopRecordingRow: Decodable {
    var artist_mbids: [String]?
    var artist_name: String?
    var recording_mbid: String?
    var recording_name: String?
    var release_mbid: String?
    var release_name: String?
    /// Milliseconds.
    var length: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        artist_mbids = try? c.decodeIfPresent([String].self, forKey: .artist_mbids)
        artist_name = try? c.decodeIfPresent(String.self, forKey: .artist_name)
        recording_mbid = try? c.decodeIfPresent(String.self, forKey: .recording_mbid)
        recording_name = try? c.decodeIfPresent(String.self, forKey: .recording_name)
        release_mbid = try? c.decodeIfPresent(String.self, forKey: .release_mbid)
        release_name = try? c.decodeIfPresent(String.self, forKey: .release_name)
        length = try? c.decodeIfPresent(Double.self, forKey: .length)
    }

    enum CodingKeys: String, CodingKey {
        case artist_mbids, artist_name, recording_mbid, recording_name, release_mbid, release_name, length
    }

    func recording(artist: MBID) -> ExternalRecording? {
        guard let title = recording_name?.capped, !title.isEmpty,
              let name = artist_name?.capped, !name.isEmpty else { return nil }
        let release = release_name?.capped
        return ExternalRecording(recordingMBID: recording_mbid.flatMap(MBID.init),
                                 artistMBID: artist_mbids?.lazy.compactMap(MBID.init).first ?? artist,
                                 title: title, artist: name,
                                 releaseTitle: (release?.isEmpty == false) ? release : nil,
                                 duration: length.flatMap { $0 > 0 && $0.isFinite && $0 < 1e9 ? $0 / 1000 : nil },
                                 source: .listenBrainz, releaseMBID: release_mbid.flatMap(MBID.init))
    }
}
