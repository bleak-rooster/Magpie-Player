import DesignSystem
import Foundation
import NavidromeKit
import Requests
import SwiftUI
import Testing
@testable import Magpie

/// H3 visual pass: copy on the listening screens, the record placeholder's contrast, the Connect error's port and
/// the artist monogram. Layout itself is checked by screenshots.
@Suite struct VisualPassTests {
    private static let services = ["Lidarr", "Navidrome", "MusicBrainz", "ListenBrainz", "Tubifarry", "Soulseek"]

    /// I5: the Try sheet, Home's card and the Finds actions describe the music and point to Settings without
    /// naming a service (§5; Settings itself names its switches). M6: curly quotes and "›", never ' " or ">".
    @Test func settingsPointersNameNoServices() {
        let tries = [TryAvailability.noLidarr, .addressNotAllowed, .changesOff, .notSetUp, .noRoot].compactMap(\.message)
        #expect(tries.count == 5)
        let texts = tries + [
            HomeCopy.finishSettingUp(connected: true), HomeCopy.finishSettingUp(connected: false), HomeCopy.finishFinds,
            KeepCopy.changesOff, KeepCopy.notSetUp, NotForMeCopy.changesOff, NotForMeCopy.notSetUp,
            BringInCopy.message(for: RequestRunner.BringInError.changesOff),
            BringInCopy.message(for: RequestRunner.BringInError.notSetUp),
            TryCopy.changesOff, TryCopy.notSetUp,
        ]
        for text in texts {
            for name in Self.services { #expect(!text.contains(name), "§5: \(text)") }
            #expect(!text.contains("\"") && !text.contains(">"), "M6: \(text)")
            #expect(text.firstMatch(of: /(^|\s)'/) == nil, "M6: straight opening quote in \(text)")
        }
        for text in tries + [HomeCopy.finishSettingUp(connected: true), HomeCopy.finishFinds, KeepCopy.changesOff, NotForMeCopy.changesOff] {
            #expect(text.contains("Settings"), "still says where to go: \(text)")
        }
    }

    /// M6: one wording for music you don't have, everywhere.
    @Test func notInYourLibraryHasNoYet() {
        #expect(RowState.notYet.statusText == "Not in your library")
        #expect(RowState.notYet.voiceOverValue == "Not in your library")
    }

    /// M4: the bare record (no art yet) stands out from the page at 3:1 or more in every character and scheme
    /// (WCAG 1.4.11, non-text contrast).
    @Test func recordPlaceholderMeetsNonTextContrast() {
        var failures: [String] = []
        for character in DesignSystem.Character.allCases {
            for scheme in [ColorScheme.light, .dark] {
                let p = Theme(character: character).colors(for: scheme)
                let dark = character == .immersive || scheme == .dark
                let ratio = Contrast.ratio(RecordArt.placeholder(dark: dark), on: p.bg)
                if ratio < 3 { failures.append("\(character) \(scheme) = \(ratio)") }
            }
        }
        #expect(failures.isEmpty, "\(failures)")
    }

    /// M9: "Couldn't reach host:port." when a port was given, so a typo in the port shows.
    @Test func unreachableNamesThePort() {
        let withPort = [ProbeFailure(url: URL(string: "http://127.0.0.1:9")!, error: URLError(.cannotConnectToHost))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(withPort)).hasPrefix("Couldn't reach 127.0.0.1:9."))
        let direct = URLError(.cannotFindHost, userInfo: [NSURLErrorFailingURLErrorKey: URL(string: "https://music.example.com:4533")!])
        #expect(ConnectErrorCopy.message(for: direct) == ConnectErrorCopy.unreachable("music.example.com:4533"))
        let noPort = [ProbeFailure(url: URL(string: "https://music.example.com")!, error: URLError(.timedOut))]
        #expect(ConnectErrorCopy.message(for: SignInError.unreachable(noPort)) == ConnectDiagnosis.timedOut("music.example.com").message)
    }

    /// M2: an artist without a picture shows their initials, not an empty circle.
    @Test func artistMonogram() {
        #expect(ArtistMonogram.initials("The Midnight Cartographers") == "MC")
        #expect(ArtistMonogram.initials("Björk") == "B")
        #expect(ArtistMonogram.initials("ada okafor") == "AO")
        #expect(ArtistMonogram.initials("Kites Over Lagos") == "KO")
        #expect(ArtistMonogram.initials("The") == "T")
        #expect(ArtistMonogram.initials("  ") == nil)
        #expect(ArtistMonogram.initials("!!!") == nil, "no letters: the symbol instead")
    }
}
