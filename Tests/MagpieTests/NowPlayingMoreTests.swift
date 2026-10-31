import Foundation
import MagpieCore
import NavidromeKit
import Playback
import Requests
import SwiftUI
import Testing
@testable import Magpie

/// R9 (the More menu, in the appraisal's groups) and R10 (the album and artist names open their pages on the current
/// tab; offline the downloaded pages, else disabled).
@MainActor @Suite(.serialized) struct NowPlayingMoreTests {
    private func makeModel() -> (AppModel, UserDefaults) {
        let defaults = UserDefaults(suiteName: "NowPlayingMoreTests.\(UUID().uuidString)")!
        let model = AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                             matchIndexDirectory: nil, dataDirectory: nil, engine: FakeEngine(), defaults: defaults,
                             systemNowPlaying: false, notifications: false)
        return (model, defaults)
    }

    private let song = Song(id: "s1", title: "Harbour Lights", artist: "Judie Tzuke", artistId: "ar1", album: "The Cat Is Out",
                            albumId: "al1", duration: 232, suffix: "flac", bitRate: 1011, genre: "Pop")

    @Test func moreMenuGroupsForALibrarySong() {
        let (model, _) = makeModel()
        model.player.play([song], startAt: 0)
        let links = NowPlayingLinks.resolve(song, offline: false, catalog: nil)
        let items = model.nowPlayingMoreItems(song, lyricsMode: false, links: links)
        #expect(items.titles == [["Add to playlist…"], ["Download"], ["Go to album", "Go to artist"], ["Song info"]],
                "no Keep for a library song; no Favourite while the star shows; no Sleep timer, no Share")
        #expect(items.album == .album(id: "al1") && items.artist == .artist(id: "ar1"))

        // Lyrics mode hides the star, so Favourite moves into More (appraisal §4).
        let lyrics = model.nowPlayingMoreItems(song, lyricsMode: true, links: links)
        #expect(lyrics.titles[0] == ["Add to playlist…", "Favourite"])
        var starred = song
        starred.starred = true
        model.player.play([starred], startAt: 0)
        #expect(model.nowPlayingMoreItems(starred, lyricsMode: true, links: links).titles[0] == ["Add to playlist…", "Unfavourite"])
    }

    @Test func findGroupComesFirst() {
        let items = NowPlayingMoreItems(keep: RequestID(), notForMe: RequestID(), favourite: nil, download: .remove,
                                        album: nil, artist: nil)
        #expect(items.titles == [["Keep", "Not for me…"], ["Add to playlist…"], ["Remove download"],
                                 ["Go to album", "Go to artist"], ["Song info"]])
    }

    @Test func songInfoShowsTheFactsAndNeverThePath() {
        let details = SongDetails(song: song, year: 1985, size: 34_567_890, playCount: 12, suffix: "flac", bitRate: 1011,
                                  samplingRate: 44100, bitDepth: 16)
        let info = SongInfo(song: song, details: details, source: .stream(.aacMedium))
        let byLabel = Dictionary(uniqueKeysWithValues: info.rows.map { ($0.label, $0.value) })
        #expect(info.rows.map(\.label) == ["Title", "Artist", "Album", "Year", "Genre", "Duration", "Playing",
                                           "Original format", "File size", "Plays"])
        #expect(byLabel["Title"] == "Harbour Lights" && byLabel["Artist"] == "Judie Tzuke" && byLabel["Album"] == "The Cat Is Out")
        #expect(byLabel["Year"] == "1985" && byLabel["Genre"] == "Pop" && byLabel["Duration"] == "3:52")
        #expect(byLabel["Playing"] == "AAC 160 kbps, streaming")
        #expect(byLabel["Original format"] == "FLAC · \(1011.formatted()) kbps · 44.1 kHz · 16-bit")
        #expect(byLabel["File size"] == ByteCountFormatter.string(fromByteCount: 34_567_890, countStyle: .file))
        #expect(byLabel["Plays"] == "12")
        #expect(!info.rows.contains { $0.label.localizedCaseInsensitiveContains("path") })

        // On the phone, in the original; offline (no details): what the song itself says, nothing invented.
        let local = SongInfo(song: song, details: nil, source: .onPhone(.original))
        #expect(local.rows.first { $0.label == "Playing" }?.value == "Original (FLAC), on this iPhone")
        #expect(local.rows.map(\.label) == ["Title", "Artist", "Album", "Genre", "Duration", "Playing", "Original format"])
        #expect(SongInfo.original(suffix: nil, bitRate: nil, samplingRate: nil, bitDepth: nil) == nil)
        #expect(SongInfo.original(suffix: "mp3", bitRate: 320, samplingRate: 48000, bitDepth: nil) == "MP3 · 320 kbps · 48 kHz")
    }

    @Test func songInfoReadsWhereTheSoundComesFrom() async {
        let (model, _) = makeModel()
        model.player.play([song], startAt: 0)
        model.updatePreferences { $0.downloads.offlineMode = .on }   // nothing asked of the server
        let info = await model.songInfo(song)
        #expect(info.rows.first { $0.label == "Playing" }?.value
                == SongInfo.playing(.stream(model.currentStreamQuality), originalSuffix: "flac"))
        #expect(info.rows.first { $0.label == "Playing" }?.value.hasSuffix(", streaming") == true)
        #expect(!info.rows.contains { $0.label == "File size" || $0.label == "Plays" })
    }

    /// Online the server's pages; offline the downloaded pages if the song is downloaded, otherwise none (disabled).
    @Test func linksOnlineOfflineAndDisabled() throws {
        #expect(NowPlayingLinks.resolve(song, offline: false, catalog: nil)
                == NowPlayingLinks(album: .album(id: "al1"), artist: .artist(id: "ar1")))
        var noIds = song
        noIds.albumId = nil
        noIds.artistId = nil
        #expect(NowPlayingLinks.resolve(noIds, offline: false, catalog: nil) == NowPlayingLinks())

        let meta = String(decoding: try JSONEncoder().encode(AudioMetadata(song)), as: UTF8.self)
        let entry = try JSONDecoder().decode(AudioEntry.self, from: Data(
            #"{"songId":"s1","quality":"original","fileName":"s1.flac","size":1,"kind":"download","metadata":\#(meta)}"#.utf8))
        let catalog = OfflineCatalog(entries: [entry], playlists: [])
        let offline = NowPlayingLinks.resolve(song, offline: true, catalog: catalog)
        #expect(offline == NowPlayingLinks(album: .album(id: "al1"), artist: .artist(id: "ar1")))
        #expect(catalog.album(id: "al1") != nil, "the downloaded album page opens")
        let other = Song(id: "s2", title: "Other", artist: "X", artistId: "ar2", album: "Y", albumId: "al2", duration: 60)
        #expect(NowPlayingLinks.resolve(other, offline: true, catalog: catalog) == NowPlayingLinks(), "not on the phone: disabled")
        #expect(NowPlayingLinks.resolve(song, offline: true, catalog: nil) == NowPlayingLinks())
    }

    /// The link pushes onto the tab the user is on (no tab switch).
    @Test func linksPushOntoTheCurrentTab() {
        let navigator = TabNavigator()
        navigator.tab = .library
        navigator.push(.artist(id: "ar1"))
        #expect(navigator.library.count == 1 && navigator.home.isEmpty && navigator.search.isEmpty)
        #expect(navigator.tab == .library)
        navigator.tab = .search
        navigator.push(.album(id: "al1"))
        #expect(navigator.search.count == 1 && navigator.depth == 1)
        navigator.tab = .home
        navigator.push(.album(id: "al1"))
        #expect(navigator.home.count == 1)
    }

    /// The page's links as the view reads them: online the server's pages; offline with nothing on the phone, none
    /// (the buttons are disabled).
    @Test func modelLinksFollowOfflineMode() async {
        let (model, _) = makeModel()
        model.player.play([song], startAt: 0)
        #expect(await model.nowPlayingLinks(song) == NowPlayingLinks(album: .album(id: "al1"), artist: .artist(id: "ar1")))
        model.updatePreferences { $0.downloads.offlineMode = .on }
        #expect(await model.nowPlayingLinks(song) == NowPlayingLinks(), "offline and not downloaded: disabled")
    }
}
