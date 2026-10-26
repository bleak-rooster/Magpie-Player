import Foundation
import MagpieCore
import os
import Search
import Testing
@testable import Magpie

/// A sleep that lasts until the test releases it, and ends early (throwing) when cancelled.
final class ManualSleeper: @unchecked Sendable {
    private struct State {
        var next = 0
        var waiters: [Int: CheckedContinuation<Void, Error>] = [:]
        var cancelled: Set<Int> = []
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    var waiting: Int { state.withLock { $0.waiters.count } }

    func sleep(_ duration: Duration) async throws {
        let id = state.withLock { s -> Int in s.next += 1; return s.next }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let cancelledAlready = state.withLock { s -> Bool in
                    if s.cancelled.contains(id) { return true }
                    s.waiters[id] = c
                    return false
                }
                if cancelledAlready { c.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Void, Error>? in
                s.cancelled.insert(id)
                return s.waiters.removeValue(forKey: id)
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func releaseAll() {
        let all = state.withLock { s -> [CheckedContinuation<Void, Error>] in
            defer { s.waiters = [:] }
            return Array(s.waiters.values)
        }
        all.forEach { $0.resume() }
    }
}

final class FakeSearch: @unchecked Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: [String]())
    var queries: [String] { calls.withLock { $0 } }
    var result = LibrarySearchResult(songs: [Song(id: "s1", title: "Harbour Lights", artist: "Corin Hale",
                                                  album: "Saltwater Hymns", duration: 200)],
                                     albums: [], artists: [Artist(id: "a1", name: "Corin Hale", albumCount: 2)])
    var failure: Error?

    func callAsFunction(_ q: String) async throws -> LibrarySearchResult {
        calls.withLock { $0.append(q) }
        if let failure { throw failure }
        return result
    }
}

@MainActor
@Suite struct SearchViewModelTests {
    let sleeper = ManualSleeper()
    let fake = FakeSearch()

    func makeModel() -> SearchModel {
        let fake = self.fake, sleeper = self.sleeper
        return SearchModel(search: { q, _ in .library(try await fake(q), query: q) }, sleep: { try await sleeper.sleep($0) })
    }

    /// Lets the model's task run until it is waiting out the debounce.
    func untilDebouncing(_ n: Int = 1) async {
        for _ in 0..<1000 where sleeper.waiting < n { await Task.yield() }
        #expect(sleeper.waiting == n)
    }

    @Test func debouncesAndCancels() async {
        let model = makeModel()
        model.update(query: "h")
        model.update(query: "ha")
        model.update(query: "har")
        await untilDebouncing()
        #expect(fake.queries.isEmpty, "nothing is sent while the user is still typing")
        sleeper.releaseAll()
        await model.settle()
        #expect(fake.queries == ["har"], "3 rapid queries make exactly 1 request")
        #expect(model.results.songs.map(\.id) == ["s1"])
        #expect(model.phase == .done)
    }

    @Test func emptyQueryClears() async {
        let model = makeModel()
        model.update(query: "har")
        await untilDebouncing()
        sleeper.releaseAll()
        await model.settle()
        #expect(!model.results.isEmpty)

        model.update(query: "  ")
        #expect(model.results.isEmpty)
        #expect(model.phase == .idle)
        #expect(fake.queries == ["har"], "an empty query sends nothing")
    }

    @Test func emptyQueryCancelsPendingSearch() async {
        let model = makeModel()
        model.update(query: "har")
        await untilDebouncing()
        model.update(query: "")
        sleeper.releaseAll()
        await model.settle()
        #expect(fake.queries.isEmpty)
        #expect(model.results.isEmpty)
        #expect(model.phase == .idle)
    }

    @Test func libraryRowsShowBeforeTheNotYetBand() async {
        let gate = ManualSleeper()
        let library = SearchSections.library(fake.result, query: "har")
        var full = library
        full.notYet = NotYetSections(songs: [ExternalRecording(title: "Harbour Wall", artist: "Ines Morrow",
                                                               source: .listenBrainz)])
        let sleeper = self.sleeper, done = full
        let model = SearchModel(search: { _, early in
            await early(library)
            try await gate.sleep(.seconds(5))     // the outside sources are still out
            return done
        }, sleep: { try await sleeper.sleep($0) })
        model.update(query: "har")
        await untilDebouncing()
        sleeper.releaseAll()
        for _ in 0..<1000 where gate.waiting == 0 { await Task.yield() }
        #expect(model.results == library)
        #expect(model.phase == .searching)
        gate.releaseAll()
        await model.settle()
        #expect(model.results == full)
        #expect(model.phase == .done)
    }

    @Test func failureShowsMessageAndKeepsNothingStale() async {
        fake.failure = URLError(.notConnectedToInternet)
        let model = makeModel()
        model.update(query: "har")
        await untilDebouncing()
        sleeper.releaseAll()
        await model.settle()
        #expect(model.results.isEmpty)
        if case .failed = model.phase {} else { Issue.record("expected failed, got \(model.phase)") }
    }
}

@Suite struct SearchSectionsTests {
    static func song(_ id: String, _ title: String) -> Song {
        Song(id: id, title: title, artist: "X", album: "Y", duration: 100)
    }

    @Test func topResultPrefersExactArtistThenAlbumThenSong() {
        let r = LibrarySearchResult(
            songs: [Self.song("s", "Corin Hale")],
            albums: [Album(id: "al", name: "Corin Hale", artist: "X", songCount: 1, duration: 1)],
            artists: [Artist(id: "ar", name: "corin hale", albumCount: 1)])
        #expect(SearchSections.library(r, query: "Corin Hale").top == .artist(r.artists[0]))
        var noArtist = r; noArtist.artists = []
        #expect(SearchSections.library(noArtist, query: "Corin Hale").top == .album(r.albums[0]))
    }

    @Test func topResultIgnoresCaseAndAccents() {
        let r = LibrarySearchResult(artists: [Artist(id: "ar", name: "Beyoncé", albumCount: 1)])
        #expect(SearchSections.library(r, query: "BEYONCE").top == .artist(r.artists[0]))
    }

    @Test func topResultFallsBackToPrefixThenFirstSong() {
        let r = LibrarySearchResult(
            songs: [Self.song("1", "Other"), Self.song("2", "Harbour Lights")],
            artists: [Artist(id: "ar", name: "Harbour Band", albumCount: 1)])
        #expect(SearchSections.library(r, query: "harb").top == .artist(r.artists[0]), "prefix match")
        #expect(SearchSections.library(r, query: "zzz").top == .song(r.songs[0]), "else the first song")
    }

    @Test func emptyResultHasNoTop() {
        let s = SearchSections.library(LibrarySearchResult(), query: "x")
        #expect(s.isEmpty && s.top == nil)
    }

    @Test func recentSearchesKeepNewestFirstWithoutDuplicates() {
        let defaults = UserDefaults(suiteName: "RecentSearches-\(UUID().uuidString)")!
        let recents = RecentSearches(defaults: defaults)
        recents.add("lullaby"); recents.add("Corin Hale"); recents.add("LULLABY"); recents.add("  ")
        #expect(recents.items == ["LULLABY", "Corin Hale"])
        for i in 0..<10 { recents.add("q\(i)") }
        #expect(recents.items.count == RecentSearches.limit)
        recents.clear()
        #expect(recents.items.isEmpty)
    }
}
