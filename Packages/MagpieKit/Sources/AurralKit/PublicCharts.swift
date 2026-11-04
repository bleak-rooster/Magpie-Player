import Foundation
import MagpieCore

/// Round 14 A4 (D91): Top Australia when Aurral's chart region isn't Australia (plan decision 6). Two public charts,
/// no key and no account: Deezer's "Top Australia" playlist (1313616925) and Apple's AU most-played albums.
///
/// - Each call goes to exactly one pinned https host (`api.deezer.com`, `rss.marketingtools.apple.com`) and one fixed
///   path; nothing the owner typed or Aurral sent is put into it. No Authorization, no cookies.
/// - The answer must come from the same pinned host over https (a redirect anywhere else is refused), be at most
///   `maxBytes`, and is read leniently: a bad entry is dropped, lists are capped at 100.
/// - Deezer's own signed preview links are never kept: a Deezer song's preview is Aurral's `/api/deezer/preview/<id>.mp3`
///   for the same Deezer id, so previews still go through Aurral and its dzcdn pin (D83, D88).
/// - Pictures are kept only from Deezer's and Apple's https image hosts (`*.dzcdn.net`, `*.mzstatic.com`).
public struct PublicChartsClient: Sendable {
    public static let deezerHost = "api.deezer.com"
    public static let appleHost = "rss.marketingtools.apple.com"
    /// Deezer's "Top Australia" editorial playlist (owned by Deezer's charts user; verified 100 songs).
    public static let topAustraliaPlaylist = "1313616925"
    public static let maxBytes = 1_500_000
    static let cap = 100

    public enum Failure: Error, Sendable, Equatable {
        /// The answer came from somewhere other than the pinned https host.
        case refused
        case http(Int)
        case tooLarge
        case decoding
    }

    private let transport: HTTPTransport
    private let timeout: TimeInterval

    public init(transport: HTTPTransport, timeout: TimeInterval = 8) {
        self.transport = transport
        self.timeout = timeout
    }

    /// The fixed URLs (nothing variable in them).
    static let topAustraliaURL = URL(string: "https://api.deezer.com/playlist/1313616925/tracks?limit=100")!
    static let appleAlbumsURL = URL(string: "https://rss.marketingtools.apple.com/api/v2/au/music/most-played/100/albums.json")!

    /// Deezer's Top Australia, in chart order (position 1 first), as Aurral-shaped songs.
    public func topAustralia() async throws -> [AurralSong] {
        let data = try await get(Self.topAustraliaURL, host: Self.deezerHost)
        guard let root = object(data) as? [String: Any] else { throw Failure.decoding }
        var songs: [AurralSong] = []
        for t in root.objects("data", cap: Self.cap) {
            guard let id = t.idText("id"), let preview = AurralPreview(trackId: id), let title = t.text("title"),
                  let artist = t.dict("artist")?.text("name") else { continue }
            let album = t.dict("album")
            let albumId = album?.idText("id").flatMap { AurralRoute.isDigits(Substring($0), max: 20) ? $0 : nil }
            let seconds = t.int("duration").flatMap { $0 > 0 && $0 < 86_400 ? $0 : nil }
            songs.append(AurralSong(key: id, trackName: title, artistName: artist, albumName: album?.text("title"),
                                    deezerAlbumId: albumId, durationMs: seconds.map { $0 * 1000 },
                                    artwork: Self.image(album?.string("cover_medium"), hostSuffix: "dzcdn.net"),
                                    largeArtwork: Self.image(album?.string("cover_xl"), hostSuffix: "dzcdn.net"),
                                    preview: preview, position: songs.count + 1))
        }
        return songs
    }

    /// Apple's AU most-played albums, in chart order (no previews, no MusicBrainz ids).
    public func australianAlbums() async throws -> [AurralChartAlbum] {
        let data = try await get(Self.appleAlbumsURL, host: Self.appleHost)
        guard let root = object(data) as? [String: Any], let feed = root.dict("feed") else { throw Failure.decoding }
        var albums: [AurralChartAlbum] = []
        for a in feed.objects("results", cap: Self.cap) {
            guard let id = a.idText("id"), AurralRoute.isDigits(Substring(id), max: 20), let name = a.text("name"),
                  let artist = a.text("artistName") else { continue }
            let art = a.string("artworkUrl100")?.replacingOccurrences(of: "100x100bb", with: "500x500bb")
            albums.append(AurralChartAlbum(key: id, name: name, artistName: artist,
                                           artwork: Self.image(art, hostSuffix: "mzstatic.com"),
                                           releaseDate: a.text("releaseDate"),
                                           genre: a.objects("genres", cap: 5).lazy.compactMap { $0.text("name") }.first,
                                           position: albums.count + 1))
        }
        return albums
    }

    /// A picture only from `hostSuffix` (or a subdomain of it), over https, with no user info.
    static func image(_ text: String?, hostSuffix: String) -> AurralImage? {
        guard let text, let url = URL(string: text), url.scheme?.lowercased() == "https", url.user == nil,
              url.password == nil, let host = url.host()?.lowercased(),
              host == hostSuffix || host.hasSuffix("." + hostSuffix) else { return nil }
        return AurralImage(text)
    }

    private func get(_ url: URL, host: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport.send(request)
        // The answer must be the pinned host's, over https (a redirect elsewhere is refused).
        guard let answered = response.url, answered.scheme?.lowercased() == "https",
              answered.host()?.lowercased() == host, answered.user == nil else { throw Failure.refused }
        guard response.statusCode == 200 else { throw Failure.http(response.statusCode) }
        guard data.count <= Self.maxBytes else { throw Failure.tooLarge }
        return data
    }
}
