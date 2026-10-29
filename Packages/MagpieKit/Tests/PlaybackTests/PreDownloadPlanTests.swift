import Foundation
import Testing
import MagpieCore
import Playback

@Suite struct PreDownloadPlanTests {
    func song(_ id: String) -> Song { Song(id: id, title: "T\(id)", artist: "A", album: "B", duration: 200) }

    @Test func planSkipsLocalAndDuplicates() {
        let up = ["a", "b", "c", "a", "d", "e"].map(song)
        #expect(PreDownloadPlan.songs(upcoming: up, count: 3, isLocal: { $0 == "b" }).map(\.id) == ["a", "c", "d"])
        #expect(PreDownloadPlan.songs(upcoming: up, count: 0, isLocal: { _ in false }).isEmpty)
    }

    @Test func planStopsShortWhenEverythingIsLocal() {
        let up = ["a", "b"].map(song)
        #expect(PreDownloadPlan.songs(upcoming: up, count: 3, isLocal: { _ in true }).isEmpty)
        #expect(PreDownloadPlan.songs(upcoming: up, count: 5, isLocal: { _ in false }).map(\.id) == ["a", "b"])
    }
}
