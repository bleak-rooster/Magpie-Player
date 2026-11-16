import Foundation
import Playback
import Testing
@testable import Magpie

/// Round 28 crash hunt (R28X): a page record's write is an await; the account can switch during it. What follows the
/// write (its cover, D334) belongs to the account that read the page: after a switch the old manager fetches nothing,
/// which would go out on the new account's session into a scope being erased.
extension OfflineRecordsAppTests {
    @Test func records_accountSwitchDuringTheWriteFetchesNoCover() async throws {
        let model = try await signedIn()
        await download(model, [Self.song("s1")])
        let jordans = try #require(model.downloads)
        var album = Self.album()
        album.coverArtId = "al-switch"
        jordans.afterRecordWriteForTesting = { [self] in
            model.signOut()
            await model.downloadsTeardown?.value
            try? await model.signIn(urls: [URL(string: "http://192.168.1.2:4533")!], username: "sam", password: "pw-o2")
            await model.downloads?.settled()
            _ = self
        }
        await model.recordAlbumPage(album, songs: [Self.song("s1")], into: jordans)
        jordans.afterRecordWriteForTesting = nil
        await jordans.settled()
        await model.downloads?.settled()
        #expect(model.downloads !== jordans, "signed in to another account during the write")
        #expect(!fetcher.urls.contains { $0.query?.contains("id=al-switch") == true },
                "no cover for jordan's record fetched after the switch")
    }
}
