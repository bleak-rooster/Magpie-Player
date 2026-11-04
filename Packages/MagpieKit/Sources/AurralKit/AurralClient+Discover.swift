import Foundation
import MagpieCore

// Round 14 A1: the Aurral 2.13 calls (docs/research/aurral-discover.md). Every one goes through `ok`, so through
// `AurralRoute`'s allow-list (route, verb and query names) and the session. Callers check `AurralCapabilities` first:
// on an Aurral without the route these answer `notFound`.

extension AurralClient {
    // MARK: - What this Aurral can do (D79, D80)

    /// `GET /api/health/bootstrap`, signed in (so it names the user's permissions and the download sources).
    public func bootstrap() async throws -> AurralBootstrap {
        try AurralBootstrap.decode(try await ok(method: "GET", path: "api/health/bootstrap"))
    }

    /// `GET /api/auth/me`: the signed-in user and their permissions.
    public func me() async throws -> AurralUser {
        try AurralUser.decodeMe(try await ok(method: "GET", path: "api/auth/me"))
    }

    // MARK: - Recommended, Trending, Discover playlists (reads)

    /// `GET /api/discover?limit=&offset=`: the signed-in user's recommended artists (Aurral clamps limit to 1–200).
    /// Aurral may start its own per-user refresh when the list is stale, as opening its Recommended page does.
    public func recommendations(limit: Int = 50, offset: Int = 0) async throws -> AurralRecommendations {
        try AurralRecommendations.decode(try await ok(method: "GET", path: "api/discover", query: [
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 200)))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ]))
    }

    /// `GET /api/discover/trending`: the charts (each section nil until it has loaded).
    public func trending() async throws -> AurralTrending {
        try AurralTrending.decode(try await ok(method: "GET", path: "api/discover/trending"))
    }

    /// `GET /api/discover/trending/genres/:id`: one genre's chart; nil while Aurral hasn't fetched it yet (404).
    public func trendingGenre(_ id: Int) async throws -> AurralGenreChart? {
        guard (0...999_999).contains(id) else { throw AurralError.forbidden("genre \(id)") }
        do { return try AurralGenreChart.decode(try await ok(method: "GET", path: "api/discover/trending/genres/\(id)")) }
        catch AurralError.notFound { return nil }
    }

    /// `GET /api/discover/editorial`: the Discover playlists ("For you", then a shelf per genre).
    public func editorialShelf() async throws -> AurralEditorialShelf {
        try AurralEditorialShelf.decode(try await ok(method: "GET", path: "api/discover/editorial"))
    }

    /// `GET /api/discover/editorial/:id`: a Discover playlist's songs (`id` is Deezer's, digits only).
    public func editorialPlaylist(_ id: String) async throws -> AurralEditorialPlaylist {
        guard AurralRoute.isDigits(Substring(id), max: 20) else { throw AurralError.forbidden("editorial \(id.count) chars") }
        return try AurralEditorialPlaylist.decode(try await ok(method: "GET", path: "api/discover/editorial/" + id))
    }

    /// `GET /api/discover/editorial/links?artist&album&albumId`: the artist's and album's MBIDs for a Deezer song.
    public func editorialLinks(artist: String, album: String?, deezerAlbumId: String?) async throws -> AurralEditorialLinks {
        guard let artist = Self.queryText(artist) else { throw AurralError.forbidden("links without an artist") }
        var query = [URLQueryItem(name: "artist", value: artist)]
        if let album = Self.queryText(album) { query.append(URLQueryItem(name: "album", value: album)) }
        if let id = deezerAlbumId, AurralRoute.isDigits(Substring(id), max: 20) { query.append(URLQueryItem(name: "albumId", value: id)) }
        return try AurralEditorialLinks.decode(try await ok(method: "GET", path: "api/discover/editorial/links", query: query))
    }

    /// `GET /api/artists/:mbid/preview?artistName=`: the artist's top songs with previews (up to 6).
    public func artistPreview(_ mbid: MBID, artistName: String?) async throws -> [AurralSong] {
        let name = Self.queryText(artistName)
        let data = try await ok(method: "GET", path: "api/artists/\(mbid.rawValue)/preview",
                                query: name.map { [URLQueryItem(name: "artistName", value: $0)] } ?? [])
        return try AurralSong.decodeArtistPreview(data, artistName: name ?? "")
    }

    // MARK: - Search (reads)

    /// `GET /api/search/unified?q&mode=full&limit` (Aurral caps limit at 30): catalog artists and albums.
    public func searchUnified(_ q: String, limit: Int = 20) async throws -> AurralUnifiedSearch {
        guard let q = Self.queryText(q) else { throw AurralError.forbidden("empty search") }
        return try AurralUnifiedSearch.decode(try await ok(method: "GET", path: "api/search/unified", query: [
            URLQueryItem(name: "q", value: q), URLQueryItem(name: "mode", value: "full"),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 30)))),
        ]))
    }

    /// `GET /api/search?q&scope=artist&limit&offset`: one page of artists (Load more).
    public func searchArtists(_ q: String, limit: Int = 24, offset: Int = 0) async throws -> AurralSearchPage<AurralSearchArtist> {
        try AurralSearchPage.decode(try await searchPage(q, scope: "artist", limit: limit, offset: offset))
    }

    /// `GET /api/search?q&scope=album&limit&offset`: one page of albums (Load more).
    public func searchAlbums(_ q: String, limit: Int = 24, offset: Int = 0) async throws -> AurralSearchPage<AurralSearchAlbum> {
        try AurralSearchPage.decode(try await searchPage(q, scope: "album", limit: limit, offset: offset))
    }

    private func searchPage(_ q: String, scope: String, limit: Int, offset: Int) async throws -> Data {
        guard let q = Self.queryText(q) else { throw AurralError.forbidden("empty search") }
        return try await ok(method: "GET", path: "api/search", query: [
            URLQueryItem(name: "q", value: q), URLQueryItem(name: "scope", value: scope),
            URLQueryItem(name: "limit", value: String(max(1, min(limit, 100)))),
            URLQueryItem(name: "offset", value: String(max(0, offset))),
        ])
    }

    /// `GET /api/artists/release-group/:mbid/tracks`: an album's songs, with previews where Aurral matched them.
    public func releaseGroupTracks(_ mbid: MBID, artistMBID: MBID?, artistName: String?, albumTitle: String?,
                                   deezerAlbumId: String? = nil) async throws -> [AurralReleaseGroupTrack] {
        var query: [URLQueryItem] = []
        if let artistMBID { query.append(URLQueryItem(name: "artistMbid", value: artistMBID.rawValue)) }
        if let name = Self.queryText(artistName) { query.append(URLQueryItem(name: "artistName", value: name)) }
        if let title = Self.queryText(albumTitle) { query.append(URLQueryItem(name: "albumTitle", value: title)) }
        if let id = deezerAlbumId, AurralRoute.isDigits(Substring(id), max: 20) {
            query.append(URLQueryItem(name: "deezerAlbumId", value: id))
        }
        return try AurralReleaseGroupTrack.decodeList(
            try await ok(method: "GET", path: "api/artists/release-group/\(mbid.rawValue)/tracks", query: query))
    }

    // MARK: - A flow's songs (read)

    /// `GET /api/playlists/jobs/:playlistId`: one flow's songs and their progress; nil when Aurral doesn't know it
    /// (or it isn't this user's).
    public func playlistJobs(_ playlistId: String) async throws -> [AurralJob]? {
        guard AurralRoute.isPlainId(Substring(playlistId)) else { throw AurralError.forbidden("jobs \(playlistId.count) chars") }
        do { return try AurralJob.decodeList(try await ok(method: "GET", path: "api/playlists/jobs/" + playlistId)) }
        catch AurralError.notFound { return nil }
    }

    /// Text for a query parameter: trimmed, nil when empty, capped at 200 characters.
    static func queryText(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return String(t.prefix(200))
    }
}
