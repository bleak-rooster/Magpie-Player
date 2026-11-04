import Foundation
import MagpieCore
import MagpieTestSupport
import Testing
@testable import AurralKit

/// Round 14 A1: Aurral 2.13's Discover answers, decoded leniently. Fixtures are built from 2.13.0's source shapes
/// (docs/research/aurral-discover.md): `routes/discovery/handlers/main.ts` (`toDiscoveryArtist`),
/// `services/discovery/trendingCharts.ts`, `services/importLists/deezerPlaylists.ts`,
/// `services/discovery/editorialPlaylists.ts`, `services/apiClients/deezer.ts`, `services/unifiedSearchService.ts`,
/// `services/searchService.ts` and `routes/artists/handlers/releaseGroup.ts`.
@Suite struct DiscoverDecodingTests {
    static let mbidA = "a74b1b7f-71a5-4011-9441-d0b5e4122711"

    static let recommendations = Data(#"""
    {"recommendations":[
      {"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","navigateTo":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"Stub Arrows",
       "type":"Artist","image":null,"tags":["indie pop","dream pop"],"matchedTags":["indie pop"],"sourceArtist":"Seed One",
       "sourceArtists":["Seed One"],"sourceType":"similar","supportingSeeds":[{"artistName":"Seed One"},{"artistName":null}],
       "discoveryTier":"close","discoveryDepth":1,"firstDiscoveredAt":"2026-11-02T10:00:00.000Z","score":0.82,
       "scoreTotal":12,"matchPercent":82,"popularityLabel":"Rising","popularityRank":3,"listeners":120000,"playcount":2400000},
      {"id":null,"navigateTo":null,"name":"No Id Band","discoveryDepth":3,"firstDiscoveredAt":1793000000000,
       "image":"https://example.org/x.jpg"},
      {"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":""},
      "junk", 7
    ],
    "recommendationCount":2,"globalTop":[{"id":"f59c5520-5f46-4d2c-b2c4-822eabf53419","name":"Low Tide Club"}],
    "basedOn":[{"name":"Seed One","source":"library"},{"source":"x"}],"topTags":["indie pop"],"topGenres":["indie",3],
    "lastUpdated":"2026-11-04T00:00:00.000Z","isEnriching":true,"configured":true}
    """#.utf8)

    @Test func recommendations() throws {
        let r = try AurralRecommendations.decode(Self.recommendations)
        #expect(r.artists.count == 2, "the nameless one and the junk dropped")
        let a = r.artists[0]
        #expect(a.mbid == MBID(Self.mbidA) && a.name == "Stub Arrows")
        #expect(a.tags == ["indie pop", "dream pop"] && a.matchedTags == ["indie pop"])
        #expect(a.sourceArtists == ["Seed One"] && a.supportingSeeds == ["Seed One"])
        #expect(a.discoveryDepth == 1 && a.isFurtherOut == false)
        #expect(a.matchPercent == 82 && a.popularityLabel == "Rising" && a.listeners == 120_000)
        #expect(a.firstDiscoveredAt == ISO8601DateFormatter().date(from: "2026-11-02T10:00:00Z"))
        let b = r.artists[1]
        #expect(b.mbid == nil && b.discoveryDepth == 3 && b.isFurtherOut)
        #expect(b.firstDiscoveredAt == Date(timeIntervalSince1970: 1_793_000_000))
        #expect(b.image?.url(on: URL(string: "http://aurral:3001")!)?.absoluteString == "https://example.org/x.jpg")
        #expect(r.globalTop.map(\.name) == ["Low Tide Club"])
        #expect(r.basedOn == [AurralSeed(name: "Seed One", source: "library")])
        #expect(r.topTags == ["indie pop"] && r.topGenres == ["indie"])
        #expect(r.isEnriching && r.configured == true)
        #expect(r.lastUpdated != nil)
    }

    static let trending = Data(#"""
    {"region":"AU","updatedAt":1793000000000,
     "songs":{"playlistId":"1313616925","playlistName":"Top Australia","libraryPlaylistId":null,
       "items":[
         {"key":"3135556","trackName":"Harbour Lights","artistName":"Stub Arrows","albumName":"Wide Open","deezerAlbumId":"302127",
          "durationMs":180000,"artworkUrl":"https://cdn-images.dzcdn.net/images/cover/a/250x250.jpg",
          "largeArtworkUrl":"https://cdn-images.dzcdn.net/images/cover/a/1000x1000.jpg",
          "preview_url":"/api/deezer/preview/3135556.mp3","position":1,"movement":0},
         {"key":"3135557","trackName":"Paper Moon","artistName":"Stub Arrows","preview_url":null,"position":2,"movement":3},
         {"key":"3135558","trackName":"Night Drive","artistName":"Low Tide Club","position":3,"movement":-2,
          "preview_url":"https://evil.example/x.mp3"},
         {"key":"3135559","trackName":"Southerly","artistName":"Mallee Fowl","position":4,"movement":"new"},
         {"key":"3135560","trackName":"Odd","artistName":"Mallee Fowl","position":5,"movement":"up"},
         {"key":"3135561","artistName":"No Title"}
       ],
       "spotlight":{"ranks":[3,2,1,null,1,"x"],"daysAtTop":9}},
     "albums":[{"key":"1440857781","name":"Wide Open","artistName":"Stub Arrows",
                "artworkUrl":"https://is1-ssl.mzstatic.com/image/thumb/x/500x500bb.jpg","releaseDate":"2026-10-01",
                "genre":"Alternative","position":1}],
     "genreShare":{"total":1,"other":0,"genres":[{"name":"Alternative","count":1}]},
     "artists":[{"key":"27","name":"Stub Arrows","imageUrl":"https://cdn-images.dzcdn.net/images/artist/27/1000x1000.jpg",
                 "fans":1200,"mbid":"a74b1b7f-71a5-4011-9441-d0b5e4122711","position":1},
                {"key":"28","name":"Guess","imageUrl":null,"fans":null,"mbid":"not-an-mbid","position":2}],
     "genres":[{"id":132,"name":"Pop","covers":["https://cdn-images.dzcdn.net/1.jpg",null,"javascript:alert(1)"],
                "artists":["Stub Arrows","Low Tide Club"]},{"id":"116","name":"Rap"},{"name":"No id"}]}
    """#.utf8)

    @Test func trending() throws {
        let t = try AurralTrending.decode(Self.trending)
        #expect(t.region == "AU" && t.updatedAt == Date(timeIntervalSince1970: 1_793_000_000))
        let songs = try #require(t.songs)
        #expect(songs.playlistId == "1313616925" && songs.playlistName == "Top Australia" && songs.libraryPlaylistId == nil)
        #expect(songs.items.count == 5, "the song without a title dropped")
        let first = songs.items[0]
        #expect(first.key == "3135556" && first.trackName == "Harbour Lights" && first.albumName == "Wide Open")
        #expect(first.deezerAlbumId == "302127" && first.duration == 180 && first.position == 1)
        #expect(first.movement == .same)
        #expect(first.preview?.trackId == "3135556")
        #expect(first.largeArtwork?.url(on: URL(string: "http://aurral:3001")!) != nil)
        #expect(songs.items[1].movement == .up(3) && songs.items[1].preview == nil)
        #expect(songs.items[2].movement == .down(2))
        #expect(songs.items[2].preview == nil, "a preview that isn't Aurral's own path is dropped")
        #expect(songs.items[3].movement == .new)
        #expect(songs.items[4].movement == nil)
        #expect(songs.spotlight == AurralSpotlight(ranks: [3, 2, 1, nil, 1, nil], daysAtTop: 9))
        #expect(t.albums?.first?.name == "Wide Open" && t.albums?.first?.genre == "Alternative")
        #expect(t.artists?.first?.mbid == MBID(Self.mbidA) && t.artists?.first?.fans == 1_200)
        #expect(t.artists?.last?.mbid == nil)
        #expect(t.genres.map(\.id) == [132, 116])
        let base = URL(string: "http://aurral:3001")!
        #expect(t.genres[0].covers.compactMap { $0.url(on: base) }.count == 1, "only http(s) and Aurral paths")
        #expect(t.genres[0].artists == ["Stub Arrows", "Low Tide Club"])
    }

    /// A section that never loaded is null; the rest still read (D: each section on its own).
    @Test func trendingWithSectionsMissing() throws {
        let t = try AurralTrending.decode(Data(#"{"region":null,"updatedAt":null,"songs":null,"albums":null,"artists":null,"genres":[]}"#.utf8))
        #expect(t.region == nil && t.songs == nil && t.albums == nil && t.artists == nil && t.genres.isEmpty)
        #expect(t.isEmpty)
        #expect(throws: AurralError.decoding) { _ = try AurralTrending.decode(Data("[]".utf8)) }
    }

    @Test func genreChart() throws {
        let c = try AurralGenreChart.decode(Data(#"""
            {"id":132,"name":"Pop","region":"AU","updatedAt":1793000000000,
             "items":[{"key":"1","trackName":"A","artistName":"B","preview_url":"/api/deezer/preview/1.mp3","position":1}]}
            """#.utf8))
        #expect(c.id == 132 && c.name == "Pop" && c.items.first?.preview?.trackId == "1")
        #expect(throws: AurralError.decoding) { _ = try AurralGenreChart.decode(Data(#"{"error":"x"}"#.utf8)) }
    }

    @Test func editorialShelfAndPlaylist() throws {
        let shelf = try AurralEditorialShelf.decode(Data(#"""
            {"forYou":[{"id":"908622995","name":"Indie Pop Picks","description":null,"trackCount":40,
                        "artworkUrl":"https://cdn-images.dzcdn.net/p.jpg","curator":"Deezer Pop Editor"},
                       {"id":"abc","name":"Not a Deezer id"},{"id":12,"name":"Numeric id"}],
             "genres":[{"id":0,"name":"Popular","playlists":[{"id":"1313616925","name":"Top Australia","trackCount":100}]},
                       {"id":132,"name":"Pop","playlists":[]},{"name":"No id","playlists":[]}]}
            """#.utf8))
        #expect(shelf.forYou.map(\.id) == ["908622995", "12"])
        #expect(shelf.forYou[0].trackCount == 40 && shelf.forYou[0].curator == "Deezer Pop Editor")
        #expect(shelf.genres.map(\.name) == ["Popular", "Pop"])
        #expect(shelf.genres[0].playlists.first?.name == "Top Australia")

        let playlist = try AurralEditorialPlaylist.decode(Data(#"""
            {"id":"908622995","name":"Indie Pop Picks","description":"Fresh","curator":"Deezer","artworkUrl":null,
             "tracks":[{"artistName":"Stub Arrows","trackName":"Harbour Lights","albumName":"Wide Open","durationMs":180000,
                        "preview_url":"/api/deezer/preview/3135556.mp3","artworkUrl":null,"deezerAlbumId":"302127"},
                       {"artistName":"X","trackName":"No preview","preview_url":null}],
             "libraryPlaylistId":"static-1"}
            """#.utf8))
        #expect(playlist.id == "908622995" && playlist.libraryPlaylistId == "static-1")
        #expect(playlist.tracks.count == 2)
        #expect(playlist.tracks[0].key == "3135556", "an editorial song's Deezer id comes from its preview path")
        #expect(playlist.tracks[1].key == nil && playlist.tracks[1].preview == nil)
    }

    @Test func editorialLinksAndAdd() throws {
        let links = try AurralEditorialLinks.decode(Data(#"{"artistMbid":"a74b1b7f-71a5-4011-9441-d0b5e4122711","albumMbid":null}"#.utf8))
        #expect(links.artistMBID == MBID(Self.mbidA) && links.albumMBID == nil)
        let added = try AurralEditorialAddResult.decode(Data(#"{"playlistId":"static-1","name":"Picks","alreadyAdded":false,"tracksQueued":40}"#.utf8))
        #expect(added == AurralEditorialAddResult(playlistId: "static-1", name: "Picks", alreadyAdded: false, tracksQueued: 40))
        let again = try AurralEditorialAddResult.decode(Data(#"{"playlistId":"static-1","name":"Picks","alreadyAdded":true}"#.utf8))
        #expect(again.alreadyAdded && again.tracksQueued == nil)
        #expect(throws: AurralError.decoding) { _ = try AurralEditorialAddResult.decode(Data(#"{"name":"x"}"#.utf8)) }
    }

    @Test func artistPreview() throws {
        let songs = try AurralSong.decodeArtistPreview(Data(#"""
            {"tracks":[{"id":"3135556","title":"Harbour Lights","album":"Wide Open","artworkUrl":"https://cdn-images.dzcdn.net/a.jpg",
                        "preview_url":"/api/deezer/preview/3135556.mp3","duration_ms":180000},
                       {"id":7,"title":"Numeric","preview_url":"/api/deezer/preview/7.mp3","duration_ms":0},
                       {"title":"No id"}]}
            """#.utf8), artistName: "Stub Arrows")
        #expect(songs.count == 2)
        #expect(songs[0].trackName == "Harbour Lights" && songs[0].artistName == "Stub Arrows" && songs[0].albumName == "Wide Open")
        #expect(songs[0].duration == 180 && songs[0].preview?.trackId == "3135556")
        #expect(songs[1].key == "7" && songs[1].duration == nil)
    }

    @Test func search() throws {
        let unified = try AurralUnifiedSearch.decode(Data(#"""
            {"query":"arrows","mode":"full","top":null,
             "catalog":{"artists":[{"type":"artist","source":"brainzmash","id":"a74b1b7f-71a5-4011-9441-d0b5e4122711",
                                    "name":"Stub Arrows","sortName":"Arrows, Stub","inLibrary":true,"hasMbid":true},
                                   {"type":"artist","source":"library","id":"lib-7","name":"Local Only","inLibrary":true}],
                        "albums":[{"type":"album","id":"1dc4c347-a1db-32aa-b14f-bc9cc507b843","title":"Wide Open",
                                   "artistName":"Stub Arrows","artistMbid":"a74b1b7f-71a5-4011-9441-d0b5e4122711",
                                   "primaryType":"Album","secondaryTypes":["Live",4],"releaseDate":"2026-10-01",
                                   "coverUrl":"/api/artists/release-group/1dc4c347-a1db-32aa-b14f-bc9cc507b843/cover","inLibrary":false},
                                  {"type":"album","id":null,"albumMbid":"1dc4c347-a1db-32aa-b14f-bc9cc507b843","title":"Lib",
                                   "artistName":"X","inLibrary":true}],
                        "tracks":[]},
             "localSearchConfigured":true}
            """#.utf8))
        #expect(unified.artists.map(\.name) == ["Stub Arrows", "Local Only"])
        #expect(unified.artists[0].mbid == MBID(Self.mbidA) && unified.artists[0].inLibrary)
        #expect(unified.artists[1].mbid == nil)
        #expect(unified.albums[0].mbid == MBID("1dc4c347-a1db-32aa-b14f-bc9cc507b843") && unified.albums[0].secondaryTypes == ["Live"])
        #expect(unified.albums[0].cover?.url(on: URL(string: "http://aurral:3001/sub")!)?.absoluteString
                == "http://aurral:3001/sub/api/artists/release-group/1dc4c347-a1db-32aa-b14f-bc9cc507b843/cover")
        #expect(unified.albums[1].mbid == MBID("1dc4c347-a1db-32aa-b14f-bc9cc507b843"), "a library album's albumMbid")

        let page = try AurralSearchPage<AurralSearchAlbum>.decode(Data(#"""
            {"scope":"album","count":30,"offset":24,"hasMore":false,
             "items":[{"type":"album","id":"1dc4c347-a1db-32aa-b14f-bc9cc507b843","title":"Wide Open","artistName":"Stub Arrows"}]}
            """#.utf8))
        #expect(page.count == 30 && page.offset == 24 && !page.hasMore && page.items.count == 1)
        let artists = try AurralSearchPage<AurralSearchArtist>.decode(Data(#"""
            {"scope":"artist","count":30,"offset":0,"items":[{"type":"artist","id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"A"}]}
            """#.utf8))
        #expect(artists.hasMore, "no hasMore on artists: worked out from count and offset")
    }

    @Test func releaseGroupTracks() throws {
        let tracks = try AurralReleaseGroupTrack.decodeList(Data(#"""
            [{"id":"1c5d7c4e-1f3b-4a6e-9d2c-7b1a2f3e4d51","mbid":"1c5d7c4e-1f3b-4a6e-9d2c-7b1a2f3e4d51","title":"Track 1",
              "trackName":"Track 1","trackNumber":1,"discNumber":1,"position":1,
              "releaseMbid":"b5cdfb5f-35a5-4bc5-bbca-57839a71813a","length":201000,
              "preview_url":"/api/deezer/preview/3135556.mp3","previewProvider":"deezer","previewTrackId":"3135556"},
             {"id":"x","title":"No mbid","trackNumber":0,"length":null,"preview_url":null},
             {"trackNumber":3}]
            """#.utf8))
        #expect(tracks.count == 2)
        #expect(tracks[0].mbid == MBID("1c5d7c4e-1f3b-4a6e-9d2c-7b1a2f3e4d51") && tracks[0].title == "Track 1")
        #expect(tracks[0].trackNumber == 1 && tracks[0].discNumber == 1 && tracks[0].duration == 201)
        #expect(tracks[0].releaseMBID == MBID("b5cdfb5f-35a5-4bc5-bbca-57839a71813a") && tracks[0].preview?.trackId == "3135556")
        #expect(tracks[1].mbid == nil && tracks[1].preview == nil)
    }

    @Test func queuedAnswers() throws {
        #expect(try AurralQueued.decode(Data(#"{"success":true,"flowId":"f","queued":true,"operationId":"op-1"}"#.utf8))
                == AurralQueued(queued: true, operationId: "op-1"))
        #expect(try AurralQueued.decode(Data("{}".utf8)).queued == false)
    }

    // MARK: - Junk

    /// Seeded junk through every decoder: never a crash, only a value or `AurralError.decoding`.
    @Test func junkNeverTraps() throws {
        let seeds: [(Data, (Data) throws -> Void)] = [
            (Self.recommendations, { _ = try AurralRecommendations.decode($0) }),
            (Self.trending, { _ = try AurralTrending.decode($0) }),
            (Self.trending, { _ = try AurralGenreChart.decode($0) }),
            (Data(#"{"forYou":[{"id":"1","name":"a"}],"genres":[{"id":0,"name":"b","playlists":[{"id":"2","name":"c"}]}]}"#.utf8),
             { _ = try AurralEditorialShelf.decode($0) }),
            (Data(#"{"id":"1","name":"a","tracks":[{"artistName":"x","trackName":"y","preview_url":"/api/deezer/preview/1.mp3"}]}"#.utf8),
             { _ = try AurralEditorialPlaylist.decode($0) }),
            (Data(#"{"tracks":[{"id":"1","title":"t","preview_url":"/api/deezer/preview/1.mp3","duration_ms":1000}]}"#.utf8),
             { _ = try AurralSong.decodeArtistPreview($0, artistName: "a") }),
            (Data(#"{"catalog":{"artists":[{"id":"a74b1b7f-71a5-4011-9441-d0b5e4122711","name":"a"}],"albums":[{"id":"x","title":"t","artistName":"a"}]}}"#.utf8),
             { _ = try AurralUnifiedSearch.decode($0) }),
            (Data(#"{"count":3,"offset":0,"items":[{"id":"x","title":"t","artistName":"a"}]}"#.utf8),
             { _ = try AurralSearchPage<AurralSearchAlbum>.decode($0) }),
            (Data(#"[{"mbid":"x","title":"t","trackNumber":1,"length":1000}]"#.utf8), { _ = try AurralReleaseGroupTrack.decodeList($0) }),
            (Data(#"{"playlistId":"p","alreadyAdded":false,"tracksQueued":3}"#.utf8), { _ = try AurralEditorialAddResult.decode($0) }),
            (Data(#"{"artistMbid":"a74b1b7f-71a5-4011-9441-d0b5e4122711"}"#.utf8), { _ = try AurralEditorialLinks.decode($0) }),
            (CapabilitiesTests.bootstrap213(), { _ = try AurralBootstrap.decode($0) }),
        ]
        var fuzzer = JSONFuzzer(seed: 0xA1_2013, hugeArrayCount: 3_000)
        var decoded = 0, refused = 0
        for (seed, decode) in seeds {
            for _ in 0..<250 {
                do { try decode(fuzzer.mutate(seed)); decoded += 1 } catch {
                    #expect(error as? AurralError == .decoding, "\(error)")
                    refused += 1
                }
            }
        }
        #expect(decoded > 500 && refused > 50)
    }

    /// A playlist of thousands of songs is capped (Aurral itself stops at 2,000).
    @Test func hugeListsAreCapped() throws {
        let track = #"{"artistName":"x","trackName":"y"}"#
        let body = #"{"id":"1","name":"a","tracks":["# + Array(repeating: track, count: 5_000).joined(separator: ",") + "]}"
        #expect(try AurralEditorialPlaylist.decode(Data(body.utf8)).tracks.count == 2_000)
    }
}
