import Foundation
import MagpieCore

/// Round 23 (owner, 2026-11-07, D191–D193): what a removed artist leaves behind, read before it goes (Lidarr drops an
/// artist's history and blocklist rows with the artist, so nothing is left to read afterwards).

/// One row of Lidarr's blocklist (`GET /blocklist`), only what the clean-up needs.
public struct BlocklistEntry: Sendable, Equatable, Decodable {
    public var id: Int
    public var artistId: Int?
    public var albumIds: [Int]
    public var sourceTitle: String

    public init(id: Int, artistId: Int?, albumIds: [Int] = [], sourceTitle: String = "") {
        self.id = id; self.artistId = artistId; self.albumIds = albumIds; self.sourceTitle = sourceTitle
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        id = try c.requiredInt("id")
        artistId = c.int("artistId")
        albumIds = (c.value("albumIds", as: LossyArray<Int>.self)?.values ?? [])
        sourceTitle = c.text("sourceTitle") ?? ""
    }
}

struct BlocklistPage: Decodable {
    var records: [BlocklistEntry]
    var totalRecords: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        records = c.value("records", as: LossyArray<BlocklistEntry>.self)?.values ?? []
        totalRecords = c.int("totalRecords")
    }
}

/// One file Lidarr imported for an artist, from its history (`trackFileImported`): where Lidarr picked it up
/// (`droppedPath`, as Lidarr sees the download client's folder) and the download it came from.
public struct ImportedFrom: Sendable, Equatable {
    public var droppedPath: String
    public var downloadId: String?
    public var albumId: Int?

    public init(droppedPath: String, downloadId: String? = nil, albumId: Int? = nil) {
        self.droppedPath = droppedPath; self.downloadId = downloadId; self.albumId = albumId
    }

    /// The folder the file sat in (its last component) and the file's name, both as Lidarr spelled them; nil when the
    /// path doesn't have both (a file straight in the download root never names a folder of its own).
    public var folderAndFile: (folder: String, file: String)? {
        let parts = droppedPath.replacingOccurrences(of: "\\", with: "/").split(separator: "/").map(String.init)
        guard parts.count >= 2, let file = parts.last, !file.isEmpty else { return nil }
        return (parts[parts.count - 2], file)
    }
}

struct ArtistHistoryRow: Decodable {
    var eventType: String?
    var downloadId: String?
    var albumId: Int?
    var artistId: Int?
    var droppedPath: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        eventType = c.value("eventType", as: String.self)
        downloadId = c.value("downloadId", as: String.self).flatMap { $0.isEmpty ? nil : $0 }
        albumId = c.int("albumId")
        artistId = c.int("artistId")
        // `data` is a string dictionary; Lidarr's JSON spells its keys camelCase ("droppedPath"). Read it loosely.
        if let data = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey("data")) {
            let key = data.allKeys.first { $0.stringValue.lowercased() == "droppedpath" }
            droppedPath = key.flatMap { (try? data.decodeIfPresent(String.self, forKey: $0)) ?? nil }
        }
    }
}

extension LidarrClient {
    /// Pages read at most (`pageSize` rows each): a blocklist longer than this is read no further.
    static let blocklistPageLimit = 40

    /// The blocklist rows of one artist, every page read (`GET /blocklist?page=&pageSize=`; Lidarr's blocklist has no
    /// artist filter). Throws when a page can't be read: a partial list never counts as all of it.
    public func blocklist(artistId: Int, pageSize: Int = 250) async throws -> [BlocklistEntry] {
        try await blocklistEntries(pageSize: pageSize).filter { $0.artistId == artistId }
    }

    /// Every blocklist row (`GET /blocklist?page=&pageSize=`), at most `blocklistPageLimit` pages. Read only.
    public func blocklistEntries(pageSize: Int = 250) async throws -> [BlocklistEntry] {
        var out: [BlocklistEntry] = [], page = 1, seen = 0
        while page <= Self.blocklistPageLimit {
            let data = try await ok("blocklist", [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "pageSize", value: String(pageSize)),
                URLQueryItem(name: "sortKey", value: "date"), URLQueryItem(name: "sortDirection", value: "descending"),
            ])
            let decoded: BlocklistPage
            do { decoded = try JSONDecoder().decode(BlocklistPage.self, from: data) } catch { throw LidarrError.decoding }
            out += decoded.records
            seen += decoded.records.count
            guard !decoded.records.isEmpty, let total = decoded.totalRecords, seen < total else { break }
            page += 1
        }
        return out
    }

    /// The files Lidarr's history says it imported for this artist (`GET /history/artist?artistId=`), with where each
    /// was picked up. Read only.
    public func importedFiles(artistId: Int) async throws -> [ImportedFrom] {
        let data = try await ok("history/artist", [URLQueryItem(name: "artistId", value: String(artistId))])
        let rows: [ArtistHistoryRow]
        do { rows = try JSONDecoder().decode(LossyArray<ArtistHistoryRow>.self, from: data).values } catch {
            throw LidarrError.decoding
        }
        return rows.compactMap { r in
            guard r.eventType?.lowercased() == "trackfileimported", r.artistId == nil || r.artistId == artistId,
                  let path = r.droppedPath, !path.isEmpty else { return nil }
            return ImportedFrom(droppedPath: path, downloadId: r.downloadId, albumId: r.albumId)
        }
    }
}
