import Foundation
import MagpieCore
import Testing
@testable import Magpie

/// Task H1: a blank name from the server (an artist, song or album with no name, or only spaces) never leaves a
/// broken sentence in the M6/M7 copy ("Bring in more from ?", " is ready", "“” and every song on it…").
@Suite struct BlankNameCopyTests {
    @Test func bringInMoreTitle() {
        #expect(BringInCopy.title("Sigur R\u{F3}s") == "Bring in more from Sigur R\u{F3}s?")
        #expect(BringInCopy.title("") == "Bring in more from this artist?")
        #expect(BringInCopy.title(" \n") == "Bring in more from this artist?")
    }

    @Test func playNowBannerTitle() {
        let song = Song(id: "s", title: "東京事変", artist: "A", album: "B", duration: 1)
        #expect(LandingCopy.title(song) == "東京事変 is ready")
        var blank = song
        blank.title = "  "
        #expect(LandingCopy.title(blank) == "Your song is ready")
    }

    @Test func notForMeConfirmWithABlankAlbum() {
        #expect(NotForMeCopy.confirmMessage(album: " ", permanent: true)
            == "This song and the rest of its release leave your Finds. This deletes the files permanently.")
        #expect(NotForMeCopy.confirmMessage(album: "Lowlands", permanent: false)
            == "\u{201C}Lowlands\u{201D} and every song on it leave your Finds. Its files go to your recycle bin.")
    }
}
