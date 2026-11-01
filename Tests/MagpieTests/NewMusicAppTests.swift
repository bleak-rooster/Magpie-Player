import Foundation
import LidarrKit
import MagpieCore
import MagpieTestSupport
import NavidromeKit
import Requests
import Testing
@testable import Magpie

/// R18 + R20 in the app: Only in your Finds (mixed artists aren't), the main library (auto-pick and picker), Add with
/// my defaults on and off (one confirmation or the Add sheet, preset with When you add an artist), the find menus'
/// Keep, the copy, and the scan after a Keep using the main library.
@MainActor @Suite(.serialized) struct NewMusicAppTests {
    let defaults = UserDefaults(suiteName: "magpie-tests-newmusic-\(UUID().uuidString)")!

    static func song(_ id: String, album: String) -> Song {
        Song(id: id, title: id, artist: "Aurora Field", album: album, albumId: album, duration: 200)
    }

    static func album(_ id: String) -> Album {
        Album(id: id, name: id, artist: "Aurora Field", songCount: 1, duration: 200)
    }

    // MARK: - Only in your Finds

    @Test func onlyInFindsNeedsEveryAlbumInFinds() {
        let finds = [Self.song("s1", album: "a1"), Self.song("s2", album: "a2")]
        #expect(AppModel.onlyInFinds(albumIds: ["a1", "a2"], findSongs: finds))
        #expect(AppModel.onlyInFinds(albumIds: ["a1"], findSongs: finds))
        #expect(!AppModel.onlyInFinds(albumIds: ["a1", "main"], findSongs: finds),
                "mixed: an album in your library means not only in Finds")
        #expect(!AppModel.onlyInFinds(albumIds: [], findSongs: finds), "nothing known: not")
        #expect(!AppModel.onlyInFinds(albumIds: ["a1"], findSongs: []), "no finds: not")
    }

    // MARK: - Main library

    @Test func mainLibraryIsPickedWhenThereIsOnlyOne() {
        let finds = NavidromeLibrary(id: 2, name: "Finds", path: "/music/finds")
        let main = NavidromeLibrary(id: 1, name: "Music", path: "/music/library")
        let other = NavidromeLibrary(id: 3, name: "Audiobooks", path: "/books")
        #expect(AppModel.autoMainLibrary([main, finds], findsLibrary: finds) == main)
        #expect(AppModel.autoMainLibrary([main, finds, other], findsLibrary: finds) == nil, "several: the owner picks")
        #expect(AppModel.autoMainLibrary([finds], findsLibrary: finds) == nil)
        #expect(AppModel.mainLibraryChoices([main, finds, other], findsLibrary: finds) == [main, other],
                "the Finds library is never the main library")
    }

    @Test func mainLibraryPickerReconcilesAndSaves() {
        let finds = NavidromeLibrary(id: 2, name: "Finds", path: "/music/finds")
        let main = NavidromeLibrary(id: 1, name: "Music", path: "/music/library")
        let other = NavidromeLibrary(id: 3, name: "Audiobooks", path: "/books")
        let model = Self.model(defaults)
        model.findsSetup = FindsSetup(lidarrScope: "l", navidromeScope: "n", useFindsFolder: true,
                                      findsRoot: "/music/finds", library: finds)
        #expect(model.needsMainLibrary([main, finds, other]))
        model.reconcileMainLibrary([main, finds, other])
        #expect(model.findsSetup?.mainLibrary == nil, "never guessed among several")
        model.chooseMainLibrary(other)
        #expect(model.findsSetup?.mainLibrary == other)
        model.chooseMainLibrary(finds)
        #expect(model.findsSetup?.mainLibrary == other, "the Finds library can't be chosen")
        #expect(!model.needsMainLibrary([main, finds, other]))
        model.reconcileMainLibrary([main, finds])
        #expect(model.findsSetup?.mainLibrary == main, "the chosen one is gone: the only other one is picked")
        let data = try? JSONEncoder().encode(model.findsSetup)
        #expect(data.flatMap { try? JSONDecoder().decode(FindsSetup.self, from: $0) }?.mainLibrary == main,
                "stored with the Finds setup")
    }

    /// The scan after a Keep: the artist's folder in the library it landed in; when that can't be told, the whole
    /// main library (instead of a plain scan of everything).
    @Test func keepScansTheMainLibraryWhenTheFolderIsUnknown() {
        let finds = NavidromeLibrary(id: 2, name: "Finds", path: "/music/finds")
        let main = NavidromeLibrary(id: 1, name: "Music", path: "/music/library")
        #expect(AppModel.keepScanTargets(to: "/music/library/Aurora Field", findsLibrary: finds, mapping: nil,
                                         libraries: [main, finds], mainLibrary: main) == ["2:", "1:Aurora Field"])
        #expect(AppModel.keepScanTargets(to: "/elsewhere/Aurora Field", findsLibrary: finds, mapping: nil,
                                         libraries: [main, finds], mainLibrary: main) == ["2:", "1:"])
        #expect(AppModel.keepScanTargets(to: "/elsewhere/Aurora Field", findsLibrary: finds, mapping: nil,
                                         libraries: [finds], mainLibrary: main).isEmpty, "a main library that's gone")
    }

    // MARK: - Add with my defaults (R18 simple mode, R20)

    @Test func addWithMyDefaultsIsOnByDefaultAndSaved() {
        let settings = NewMusicSettings(defaults: defaults)
        #expect(settings.withMyDefaults, "default ON (owner)")
        #expect(settings.whenYouAdd == DownloadChoices(what: .wholeArtist, types: ReleaseTypes(kinds: .albumsAndEPs, studio: true),
                                                         quality: .lossless, follow: false))
        settings.withMyDefaults = false
        settings.whenYouAdd.types.live = true
        settings.whenYouAdd.quality = .smaller
        let again = NewMusicSettings(defaults: defaults)
        #expect(!again.withMyDefaults)
        #expect(again.whenYouAdd.types.live && again.whenYouAdd.quality == .smaller)
    }

    @Test func onShowsOneConfirmationOffShowsTheSheet() {
        var mine = DownloadChoices.defaults
        mine.types.soundtrack = true
        #expect(AddRoute.route(withMyDefaults: true, defaults: mine, albumContext: false, candidates: 1) == .confirm(mine))
        #expect(AddRoute.route(withMyDefaults: false, defaults: mine, albumContext: false, candidates: 1) == .sheet(mine),
                "off: the sheet, preset with the defaults")
        #expect(AddRoute.route(withMyDefaults: true, defaults: mine, albumContext: false, candidates: 3) == .sheet(mine),
                "several artists of the name: the sheet asks which")
        var album = mine
        album.what = .thisAlbum
        #expect(AddRoute.route(withMyDefaults: true, defaults: album, albumContext: false, candidates: 1) == .confirm(mine),
                "Just this album only with an album in context")
        #expect(AddRoute.route(withMyDefaults: true, defaults: album, albumContext: true, candidates: 1) == .confirm(album))
    }

    @Test func theConfirmationSaysTheDefaultsInOneLine() {
        #expect(NewMusicCopy.confirmTitle(.add, "Aurora Field") == "Add Aurora Field to your library?")
        #expect(NewMusicCopy.summary(.defaults, duration: 14 * 3600)
                == "Their albums and EPs \u{00B7} Lossless \u{00B7} about 14 hours of music")
        var choices = DownloadChoices(quality: .smaller, follow: true)
        choices.types.live = true
        #expect(NewMusicCopy.summary(choices, duration: nil)
                == "Their albums and EPs with live albums \u{00B7} Smaller files \u{00B7} Following new releases")
        #expect(NewMusicCopy.primary(.afterKeep(kept: "Kept")) == "Add more")
        #expect(NewMusicCopy.title(.afterKeep(kept: "Kept"), "Aurora Field") == "Kept. Add more from Aurora Field?")
        #expect(NewMusicCopy.cancel(.afterKeep(kept: "Kept")) == "Not now")
        #expect(NewMusicCopy.keepArtist("Aurora Field") == "Keep Aurora Field")
        #expect(NewMusicCopy.isLotOfMusic(51 * 3600) && !NewMusicCopy.isLotOfMusic(nil))
    }

    @Test func theRowsPickTheReleaseTypes() {
        var c = DownloadChoices.defaults
        c.types.live = true
        let everything = AddWhat.everything.applied(to: c)
        #expect(everything.types.kinds == .albumsEPsAndSingles && everything.types.live, "the toggles stay")
        #expect(AddWhat(everything) == .everything)
        #expect(AddWhat(AddWhat.albums.applied(to: c)) == .albums)
        #expect(AddWhat.thisAlbum.applied(to: c).what == .thisAlbum)
    }

    // MARK: - Keep from a find's menus

    @Test func aFindsMenuOffersKeepOnlyForAReadyFind() {
        let model = Self.model(defaults)
        #expect(model.keepRequests(songIds: ["a"]).isEmpty)
        #expect(model.artistKeepState(songIds: ["a"]) == .outside, "no Magpie request: added outside Magpie")
        let ready = FindsShelfTests.readyFindRequest(songId: "a")
        model.requests = [ready]
        #expect(model.keepRequests(songIds: ["a", "a"]) == [ready.id], "one per request")
        #expect(model.artistKeepState(songIds: ["a"]) == .keepable)
        model.newMusic.keepsRunning = [ready.id]
        #expect(model.keepRequests(songIds: ["a"]).isEmpty, "no second Keep while one runs")
        #expect(model.artistKeepState(songIds: ["a"]) == .keeping)
        var waiting = ready
        waiting.state = .importing
        model.newMusic.keepsRunning = []
        model.requests = [waiting]
        #expect(model.artistKeepState(songIds: ["a"]) == .later, "Magpie's own find, not ready: never 'Added outside Magpie'")
        model.requests = []
    }

    static func model(_ defaults: UserDefaults) -> AppModel {
        AppModel(store: SessionStore(keychain: KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")),
                 lidarrStore: MemoryLidarrStore(), tokenStore: MemoryTokenStore(), matchIndexDirectory: nil,
                 dataDirectory: FileManager.default.temporaryDirectory.appending(path: "NewMusic-\(UUID().uuidString)"),
                 gateDefaultsSuite: "magpie-tests-gate-\(UUID().uuidString)", transport: HostSwitchTransport(),
                 probeTransport: HostSwitchTransport(), engine: FakeEngine(), defaults: defaults,
                 systemNowPlaying: false, notifications: false)
    }
}
