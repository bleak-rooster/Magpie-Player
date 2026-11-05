import Foundation
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Search
import Testing
@testable import Magpie

private func values(_ url: URL?, _ name: String) -> [String] {
    (url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems ?? [])
        .filter { $0.name == name }.compactMap(\.value)
}

private let rockGenres = [Genre(name: "Indie Rock", songCount: 10, albumCount: 1), Genre(name: "Alt Rock", songCount: 20, albumCount: 2)]

/// Round 15 C4 (owner, build 15: "There also has to be a way to filter and sort the albums when you open up Genres"):
/// a group's and a genre's albums through Navidrome's native list, sorted and filtered by the server a page at a time;
/// the Subsonic list sorted on the phone where the native list is missing; the albums on the phone offline and for
/// Downloaded only; the last sort kept per kind of page.
extension GenresAppTests {
    /// `/api/genre` names the two genres; `/api/album` answers `total` albums a page at a time and notes each read.
    private func stubNativeAlbums(total: Int = 250) -> Recorder {
        let seen = Recorder()
        transport.inner.stub(pathSuffix: "/api/genre", body: Data(#"""
        [{"id":"g-indie","name":"Indie Rock"},{"id":"g-alt","name":"Alt Rock"},{"id":"g-amb","name":"Ambient"}]
        """#.utf8))
        transport.inner.stub(pathSuffix: "/api/album") { request in
            seen.add(request)
            let start = Int(values(request.url, "_start").first ?? "0") ?? 0
            let end = Int(values(request.url, "_end").first ?? "0") ?? 0
            let rows = (start..<min(end, total)).map {
                #"{"id":"n\#($0)","name":"Native \#($0)","albumArtist":"A","maxYear":\#(1970 + $0 % 50),"songCount":1}"#
            }
            return MockTransport.Response(status: 200, body: Data("[\(rows.joined(separator: ","))]".utf8),
                                          headers: ["X-Total-Count": "\(total)"])
        }
        return seen
    }

    private func albumReads(_ seen: Recorder) -> [URL] { seen.urls.filter { $0.path.hasSuffix("/api/album") } }

    @Test func c4AGroupsAlbumsComeFromTheServerSortedAndFilteredAPageAtATime() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let seen = stubNativeAlbums()
        let browser = GenreAlbumBrowser(kind: .group)
        await browser.start(model: model, genres: rockGenres)
        #expect(browser.origin == .server && browser.total == 250)
        #expect(browser.albums.value?.count == GenreAlbumPager.pageSize, "one page, never the whole group")
        let first = try #require(albumReads(seen).first)
        #expect(values(first, "_sort") == ["name"] && values(first, "_order") == ["ASC"])
        #expect(values(first, "genre_id") == ["g-indie", "g-alt"] && values(first, "_end") == ["100"])

        await browser.loadMore()
        #expect(browser.albums.value?.count == 200)
        #expect(values(try #require(albumReads(seen).last), "_start") == ["100"])

        await browser.pick(.oldest)
        let sorted = try #require(albumReads(seen).last)
        #expect(values(sorted, "_sort") == ["max_year"] && values(sorted, "_order") == ["ASC"])
        #expect(values(sorted, "_start") == ["0"], "a new sort starts at the top")

        await browser.toggle(genre: "Indie Rock")
        #expect(values(try #require(albumReads(seen).last), "genre_id") == ["g-indie"], "the sub-genre chip")
        await browser.setFavouritesOnly(true)
        await browser.setText("atlas")
        let filtered = try #require(albumReads(seen).last)
        #expect(values(filtered, "starred") == ["true"] && values(filtered, "name") == ["atlas"])
        #expect(browser.filter.isActive)
        await browser.clearFilters()
        let cleared = try #require(albumReads(seen).last)
        #expect(values(cleared, "genre_id") == ["g-indie", "g-alt"] && values(cleared, "starred").isEmpty)
        #expect(browser.sort == .oldest, "Clear leaves the sort")
        #expect(!browser.decades.isEmpty, "the decades the group spans")
    }

    /// D143: the last sort is kept per kind of page (groups, genres), across a relaunch; filters are not.
    @Test func c4TheLastSortIsKeptPerKindOfPage() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        let seen = stubNativeAlbums()
        let group = GenreAlbumBrowser(kind: .group)
        await group.start(model: model, genres: rockGenres)
        await group.pick(.recentlyAdded)
        await group.setFavouritesOnly(true)
        #expect(model.preferences.genres.groupSort == .recentlyAdded)
        #expect(model.preferences.genres.genreSort == .name, "a genre's page keeps its own")

        let relaunched = makeModel(fetcher: FakeFetcher())
        #expect(relaunched.preferences.genres.groupSort == .recentlyAdded)
        let again = GenreAlbumBrowser(kind: .group)
        await again.start(model: model, genres: rockGenres)
        #expect(again.sort == .recentlyAdded && !again.filter.isActive)
        // The last page read (the decades' single-album reads follow it).
        let read = try #require(albumReads(seen).last { values($0, "_end") == ["100"] })
        #expect(values(read, "_sort") == ["recently_added"] && values(read, "_order") == ["DESC"])
        let genre = GenreAlbumBrowser(kind: .genre)
        await genre.start(model: model, genres: [rockGenres[0]])
        #expect(genre.sort == .name)
        await genre.pick(.mostPlayed)
        #expect(model.preferences.genres.genreSort == .mostPlayed && model.preferences.genres.groupSort == .recentlyAdded)
    }

    /// D144: a server without the native list (404 here) still gets a sorted, filtered page: the Subsonic list as before
    /// (at most 500 albums a genre), sorted and filtered on the phone.
    @Test func c4WithoutTheNativeListTheSubsonicListIsSortedOnThePhone() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        transport.inner.stub(pathSuffix: "/api/genre", body: Data(#"[{"id":"g-indie","name":"Indie Rock"},{"id":"g-alt","name":"Alt Rock"}]"#.utf8))
        transport.inner.stub(pathSuffix: "/api/album", status: 404, body: Data())
        let browser = GenreAlbumBrowser(kind: .group)
        await browser.start(model: model, genres: rockGenres)
        #expect(browser.origin == .subsonic)
        #expect(browser.albums.value?.map(\.id) == ["a1", "a2", "a3"])
        await browser.pick(.random)
        #expect(Set(browser.albums.value?.map(\.id) ?? []) == ["a1", "a2", "a3"])
        await browser.toggle(genre: "Alt Rock")
        #expect(Set(browser.albums.value?.map(\.id) ?? []) == ["a2", "a3"], "only Alt Rock's")
        await browser.setText("a3")
        #expect(browser.albums.value?.map(\.id) == ["a3"])
    }

    /// Offline, and Downloaded only: the albums on the phone in the picked genres, sorted on the phone; offline nothing is
    /// sent.
    @Test func c4OfflineAndDownloadedOnlyUseTheAlbumsOnThePhone() async throws {
        let model = try await signedInModel(fetcher: FakeFetcher())
        _ = stubNativeAlbums()
        model.download([song("s1", genre: "Indie Rock", album: "al1"), song("s3", genre: "Alt Rock", album: "al2"),
                        song("s4", genre: "Ambient", album: "al3")], reason: .song)
        await model.downloads!.settled()
        let browser = GenreAlbumBrowser(kind: .group)
        await browser.start(model: model, genres: rockGenres)
        await browser.setDownloadedOnly(true)
        #expect(browser.origin == .phone)
        #expect(Set(browser.albums.value?.map(\.id) ?? []) == ["al1", "al2"])

        model.updatePreferences { $0.downloads.offlineMode = .on }
        let seen = Recorder()
        transport.setHook { seen.add($0) }
        defer { transport.setHook(nil) }
        let offline = GenreAlbumBrowser(kind: .group)
        await offline.start(model: model, genres: rockGenres)
        await offline.toggle(genre: "Indie Rock")
        #expect(offline.origin == .phone && offline.albums.value?.map(\.id) == ["al1"])
        #expect(seen.urls.isEmpty, "sent: \(seen.urls.map(\.path))")
    }
}
