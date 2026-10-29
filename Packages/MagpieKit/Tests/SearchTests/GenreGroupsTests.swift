import Foundation
import MagpieCore
import Testing
@testable import Search

struct GenreGroupsTests {
    @Test(arguments: [("Indie Rock","rock"),("Alt-Rock","rock"),("Death Metal","metal"),("Metalcore","metal"),
                      ("Pop Punk","punk"),("Hip Hop","hiphop"),("Trap","hiphop"),("R&B","rnb"),("Neo-Soul","rnb"),
                      ("dnb","electronic"),("Drum & Bass","electronic"),("Dubstep","electronic"),("Ambient","electronic"),
                      ("J-Pop","pop"),("K-Pop","pop"),("Électronique","electronic"),("Bossa Nova","jazz"),
                      ("Reggaeton","latin"),("Soundtrack","soundtrack"),("Afrobeats","world"),("Chanson","world"),
                      ("Rhythm & Blues","rnb"),("Polka Noir","other"),("","other")])
    func groupIds(_ genre: String, _ expected: String) { #expect(GenreGroups.groupId(for: genre) == expected) }

    @Test(arguments: [("Synthpop","electronic"),("Post-Rock","rock"),("Trip Hop","electronic"),("Trip-Hop","electronic"),
                      ("Indie Folk","country"),("Alt-Country","country"),("HipHop","hiphop"),("Hip-Hop","hiphop"),
                      ("Hardcore Hip Hop","hiphop"),("KPop","pop"),("JPop","pop"),("Alternative","rock"),("Indie","rock"),
                      ("New Wave","rock"),("Post-Punk","rock"),("Disco","electronic"),("Dance","electronic"),("House","electronic"),
                      ("EDM","electronic"),("Psychedelic","rock"),("Industrial","electronic"),("Dub Techno","electronic"),
                      ("Electro Swing","electronic"),("Liquid Funk","electronic"),("Liquid Drum & Bass","electronic"),
                      ("Drum 'n' Bass","electronic"),("Drum \u{2019}n\u{2019} Bass","electronic"),("Chamber Pop","pop"),
                      ("Gospel","rnb"),("Rock'n'Roll","rock"),("Post\u{2011}Rock","rock")])
    func moreGroupIds(_ genre: String, _ expected: String) { #expect(GenreGroups.groupId(for: genre) == expected) }

    @Test func dashesAndSpacesNormalise() {
        #expect(GenreGroups.key("Trip\u{2013}Hop") == "trip hop")
        #expect(GenreGroups.split("Rock\u{00A0}&\u{00A0}  Pop") == ["Rock", "Pop"])
        #expect(GenreGroups.split("Drum\u{00A0}&\u{00A0}Bass") == ["Drum & Bass"])
    }

    @Test func duplicateCustomGroupsGiveOneSection() {
        var p = GenrePreferences.defaultValue
        p.customGroups = ["custom.a", "custom.a", "rock"]
        p.groupNames["custom.a"] = "A"
        p.assignments[GenreGroups.key("Polka")] = "custom.a"
        let s = GenreGroups.grouped([Genre(name: "Polka", songCount: 1, albumCount: 1)], preferences: p)
        #expect(s.map(\.group.id) == ["custom.a"])
    }

    @Test func hiddenGroupKeepsOtherHalfOfMultiValue() {
        var p = GenrePreferences.defaultValue
        p.hidden = ["rock"]
        let s = GenreGroups.grouped([Genre(name: "Rock; Electronic", songCount: 4, albumCount: 1)], preferences: p)
        #expect(s.map(\.group.id) == ["electronic"] && s[0].genres.count == 1)
    }

    @Test func twoThousandGenresAreFast() {
        let names = ["Rock", "Death Metal", "Hip Hop", "Drum & Bass", "Rock & Pop", "Polka", "Bossa Nova", "Synthpop"]
        let genres = (0..<2000).map { Genre(name: "\(names[$0 % names.count]) \($0)", songCount: 1, albumCount: 1) }
        let start = ContinuousClock.now
        let s = GenreGroups.grouped(genres, preferences: .defaultValue)
        #expect(ContinuousClock.now - start < .milliseconds(50))
        #expect(!s.isEmpty)
    }

    @Test func builtInOrderAndNames() {
        #expect(GenreGroups.builtIn.map(\.id) == ["rock", "pop", "electronic", "hiphop", "rnb", "jazz", "blues", "classical",
                                                  "country", "metal", "punk", "reggae", "latin", "world", "soundtrack", "other"])
        #expect(GenreGroups.builtIn.map(\.name).contains("Hip-Hop & Rap"))
    }

    @Test func keyFolds() {
        #expect(GenreGroups.key("  Électro_Pop-Rock  ") == "electro pop rock")
        #expect(GenreGroups.key("R&B") == "r&b")
    }

    @Test func splitting() {
        #expect(GenreGroups.split("Rock; Pop") == ["Rock", "Pop"])
        #expect(GenreGroups.split("Rock/Pop") == ["Rock", "Pop"])
        #expect(GenreGroups.split("Folk, Country") == ["Folk", "Country"])
        #expect(GenreGroups.split("Rock & Pop") == ["Rock", "Pop"])
        #expect(GenreGroups.split("Drum & Bass") == ["Drum & Bass"])
        #expect(GenreGroups.split("Rhythm & Blues") == ["Rhythm & Blues"])
        #expect(GenreGroups.split("Rock & Roll") == ["Rock & Roll"])
    }

    @Test func groupedOrderAndCounts() {
        let s = GenreGroups.grouped([Genre(name: "Indie Rock", songCount: 10, albumCount: 1),
                                     Genre(name: "Alt Rock", songCount: 20, albumCount: 2),
                                     Genre(name: "Ambient", songCount: 12, albumCount: 2),
                                     Genre(name: "Empty", songCount: 0, albumCount: 0)], preferences: .defaultValue)
        #expect(s.map(\.group.id) == ["rock", "electronic"])
        #expect(s[0].genres.map(\.name) == ["Alt Rock", "Indie Rock"] && s[0].albumCount == 3 && s[0].songCount == 30)
    }

    @Test func overridesRenameHideAndCustom() {
        var p = GenrePreferences.defaultValue
        p.assignments[GenreGroups.key("Ambient")] = "rock"
        p.groupNames["rock"] = "Guitars"
        p.customGroups = ["custom.dinner"]; p.groupNames["custom.dinner"] = "Dinner"
        p.assignments[GenreGroups.key("Chanson")] = "custom.dinner"
        let s = GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1), Genre(name: "Chanson", songCount: 1, albumCount: 1)], preferences: p)
        #expect(s.map(\.group.name) == ["Guitars", "Dinner"])
        p.hidden = ["rock"]
        #expect(GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1)], preferences: p).isEmpty)
    }

    @Test func multiValueCountsInBothGroups() {
        let s = GenreGroups.grouped([Genre(name: "Rock; Electronic", songCount: 4, albumCount: 1)], preferences: .defaultValue)
        #expect(s.map(\.group.id) == ["rock", "electronic"])
        #expect(s.allSatisfy { $0.genres.map(\.name) == ["Rock; Electronic"] && $0.albumCount == 1 })
    }

    @Test func staleAssignmentFallsBackToRules() {
        var p = GenrePreferences.defaultValue
        p.assignments[GenreGroups.key("Ambient")] = "custom.gone"
        let s = GenreGroups.grouped([Genre(name: "Ambient", songCount: 1, albumCount: 1)], preferences: p)
        #expect(s.map(\.group.id) == ["electronic"])
    }

    @Test func customGroupsKeepCreationOrderAfterBuiltIn() {
        var p = GenrePreferences.defaultValue
        p.customGroups = ["custom.b", "custom.a"]
        p.groupNames = ["custom.b": "B", "custom.a": "A"]
        p.assignments = [GenreGroups.key("Polka"): "custom.a", GenreGroups.key("Zydeco"): "custom.b", GenreGroups.key("Pop"): "pop"]
        let s = GenreGroups.grouped(["Polka", "Zydeco", "Pop"].map { Genre(name: $0, songCount: 1, albumCount: 1) }, preferences: p)
        #expect(s.map(\.group.name) == ["Pop", "B", "A"])
    }

    @Test func allGenresIsFlatSortedAndSkipsEmpty() {
        let g = GenreGroups.allGenres([Genre(name: "zouk", songCount: 1, albumCount: 1), Genre(name: "Blues", songCount: 2, albumCount: 1),
                                       Genre(name: "Empty", songCount: 0, albumCount: 0)])
        #expect(g.map(\.name) == ["Blues", "zouk"])
    }
}
