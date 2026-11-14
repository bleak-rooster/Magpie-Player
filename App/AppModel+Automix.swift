import Foundation
import MagpieCore
import NavidromeKit
import Observation
import Playback
import Search

/// What an Automix starts from: the song playing (Now Playing ⋯) or a library artist (the artist page's action bar).
struct AutomixSeed: Identifiable {
    enum Kind {
        case song(Song)
        /// `first`: the artist's first top song when the page knows one; else one of their songs starts it. `albums`:
        /// the page's albums, for that song and the artist's own songs.
        case artist(id: String, name: String, first: Song?, albums: [Album])
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
}

/// Round 27 A (plan §8, final copy; D305): what the Automix sheet, its entry points and its notices say.
enum AutomixCopy {
    static let title = "Automix"
    static let menuItem = "Automix\u{2026}"
    static let actionBar = "Automix"
    static let symbol = "wand.and.stars"
    static let lengthLabel = "Length"
    static let varietyLabel = "Variety"
    static let note = "Replaces what\u{2019}s coming up. Songs you chose with Play next stay."
    static let start = "Start Automix"
    static let adding = "Adding songs to your Automix\u{2026}"
    static let none = "Couldn\u{2019}t find songs like this in your library."

    static func intro(_ seed: AutomixSeed) -> String {
        switch seed.kind {
        case .song(let song): "Songs like \u{201C}\(song.title)\u{201D} from your library, added after it."
        case .artist(_, let name, _, _): "Songs like \(name)\u{2019}s from your library, starting with one of theirs."
        }
    }

    static func length(_ length: Automix.Length) -> String { "\(length.rawValue) songs" }

    static func variety(_ variety: Automix.Variety) -> String {
        switch variety {
        case .close: "Close"
        case .balanced: "Balanced"
        case .adventurous: "Adventurous"
        }
    }

    static func footer(_ variety: Automix.Variety) -> String {
        switch variety {
        case .close: "Mostly this artist and the ones nearest them."
        case .balanced: "Close matches with a few further out."
        case .adventurous: "Further afield, with fewer repeats of any one artist."
        }
    }

    static func added(_ n: Int) -> String { n == 1 ? "Automix added 1 song." : "Automix added \(n) songs." }
}

/// Round 27 A (owner items 1 and 17, 2026-11-14; D304, D307): the one running queue builder, for Automix and Play top
/// songs' fill. It adds songs behind what's playing, and only while the queue is still its own: its current entry or the
/// last entry it added is still there (a new play from anywhere replaces both, so it stops). A new build cancels the
/// running one; sign-out cancels it.
@MainActor final class QueueBuilder {
    /// The longest Automix waits for Navidrome's similar songs (then the fallbacks), and each other read the builders make.
    nonisolated static let readWait: Duration = .seconds(20)
    /// Songs are added this many at a time.
    nonisolated static let batch = 10
    /// Albums of the seed artist read for their songs, at most.
    nonisolated static let artistAlbums = 20
    /// Songs of the seed's genre read, at most (one page).
    nonisolated static let genreSongs = 100

    /// The running build (tests await it).
    private(set) var task: Task<Void, Never>?
    /// Bumped by every build and every cancel: a build only changes the queue while it is the newest.
    private(set) var generation = 0
    /// The queue entries the running build owns, and the last one it added.
    var entries: Set<UUID> = []
    var anchor: UUID?
    /// Tests: the deadlines' clock, the mix's random seed (nil: random) and each batch as it is added.
    var sleep: Deadline.Sleep = { try await Task.sleep(for: $0) }
    var seed: UInt64?
    var onAppend: (([Song]) -> Void)?

    /// Starts `work` as the builder (cancelling the one running) and returns its generation.
    @discardableResult
    func start(_ work: @escaping @MainActor (_ generation: Int) async -> Void) -> Int {
        cancel()
        let mine = generation
        task = Task { @MainActor in await work(mine) }
        return mine
    }

    /// Stops the running build; nothing more is added.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        entries = []
        anchor = nil
    }

    func isCurrent(_ generation: Int) -> Bool { generation == self.generation && !Task.isCancelled }
}

/// Round 27 A (owner item 17, 2026-11-14: "When you hit automix, it find similar songs within your library and puts them
/// into the queue. It doesn't necessarily make a playlist for you. You should be able to select the length of the
/// automix and also select how variable you want the selection. It should then build the queue in the background while
/// playing the first song."; owner Q5: replaces what's coming up, Play next songs stay; D305–D308). Library songs only:
/// Navidrome's similar songs (`getSimilarSongs2`), then the seed artist's and genre's songs (`Automix.pick`). Nothing is
/// saved as a playlist and nothing is written anywhere.
extension AppModel {
    nonisolated static let automixLengthKey = "magpie.automix.length"
    nonisolated static let automixVarietyKey = "magpie.automix.variety"

    /// The sheet's Length, remembered on the phone (default 50 songs).
    var automixLength: Automix.Length {
        get { Automix.Length(rawValue: appDefaults.integer(forKey: Self.automixLengthKey)) ?? .standard }
        set { appDefaults.set(newValue.rawValue, forKey: Self.automixLengthKey) }
    }

    /// The sheet's Variety, remembered on the phone (default Balanced).
    var automixVariety: Automix.Variety {
        get { appDefaults.string(forKey: Self.automixVarietyKey).flatMap(Automix.Variety.init) ?? .standard }
        set { appDefaults.set(newValue.rawValue, forKey: Self.automixVarietyKey) }
    }

    /// Now Playing ⋯ offers Automix… for `song`: online, signed in, and not a find (Finds are never mixed, D29's spirit).
    func automixAvailable(for song: Song) -> Bool {
        session != nil && !isOffline && !OfflineCatalog.isLocalId(song.id) && !isFind(song)
    }

    /// The library artist page offers Automix: online, signed in, a server artist, not one only in your Finds.
    func automixAvailable(artistId: String, albums: [Album]) -> Bool {
        session != nil && !isOffline && !OfflineCatalog.isLocalId(artistId) && !isOnlyInFinds(albums: albums)
    }

    /// Starts an Automix (the sheet's Start Automix). From a song: it plays on and what's coming up is replaced (Play next
    /// songs stay). From an artist: their first top song (else one of theirs) plays at once, Play next songs after it.
    /// The rest arrives in the background in batches of ten; the choices are remembered.
    func startAutomix(_ seed: AutomixSeed, length: Automix.Length, variety: Automix.Variety) {
        automixLength = length
        automixVariety = variety
        libraryEdits.notify(AutomixCopy.adding, symbol: AutomixCopy.symbol)
        queueBuilder.start { [weak self] generation in
            await self?.buildAutomix(seed, length: length.rawValue, variety: variety, generation: generation)
        }
    }

    // MARK: - The build (D306, D307)

    private func buildAutomix(_ seed: AutomixSeed, length: Int, variety: Automix.Variety, generation: Int) async {
        let builder = queueBuilder
        var history: [Song]
        let seedId: String, artistId: String?, albums: [Album]
        switch seed.kind {
        case .song(let song):
            player.replaceUpcoming(with: [])
            history = [song]
            if let current = player.queue.current?.song, current.id != song.id { history.append(current) }
            (seedId, artistId, albums) = (song.id, song.artistId, [])
        case .artist(let id, _, let first, let pageAlbums):
            let start: Song?
            if let first, !isExcludedFromMix(first) { start = first } else { start = await oneSong(of: pageAlbums) }
            guard builder.isCurrent(generation) else { return }
            guard let start else { return libraryEdits.notify(AutomixCopy.none, symbol: "exclamationmark.triangle") }
            let playNext = player.queue.upNext.map(\.song)
            player.play([start], startAt: 0)
            if !playNext.isEmpty { player.playNext(playNext) }
            history = [start]
            (seedId, artistId, albums) = (id, id, pageAlbums)
        }
        builder.entries = Set(player.queue.current.map { [$0.id] } ?? [])
        builder.anchor = player.queue.current?.id

        var rng = Automix.Generator(seed: builder.seed ?? .random(in: .min ... .max))
        let genre = history.first?.genre
        // Close always takes the artist's own songs; Adventurous always the genre's; the rest only when short.
        async let similarRead = similarSongs(seedId)
        async let ownRead: [Song]? = variety == .close ? artistSongs(artistId, albums: albums) : nil
        var candidates = Automix.Candidates(similar: await similarRead)
        var own = await ownRead
        var ofGenre = variety == .adventurous ? await genreSongs(genre, using: &rng) : nil
        candidates.artistSongs = own ?? []
        candidates.genreSongs = ofGenre ?? []
        guard builder.isCurrent(generation) else { return }

        var placed: [Song] = []
        let excluded = mixExclusion()
        let first = Automix.pick(candidates, length: length, variety: variety, history: history, excluded: excluded,
                                 using: &rng)
        guard appendToMix(first, placed: &placed, generation: generation) else { return }
        if placed.count < length {
            if own == nil { own = await artistSongs(artistId, albums: albums) }
            if ofGenre == nil { ofGenre = await genreSongs(genre, using: &rng) }
            guard builder.isCurrent(generation) else { return }
            candidates.artistSongs = own ?? []
            candidates.genreSongs = ofGenre ?? []
            let more = Automix.pick(candidates, length: length - placed.count, variety: variety, history: history + placed,
                                    played: Set(placed.map(\.id)), excluded: excluded, using: &rng)
            guard appendToMix(more, placed: &placed, generation: generation) else { return }
        }
        guard builder.isCurrent(generation) else { return }
        if placed.isEmpty {
            libraryEdits.notify(AutomixCopy.none, symbol: "exclamationmark.triangle")
        } else {
            libraryEdits.notify(AutomixCopy.added(placed.count), symbol: "checkmark.circle")
        }
    }

    /// Never mixed in (D306): a Discover copy (its id is one Discover knows, or it lives in one of Discover's
    /// libraries), a find (the Finds library, or a find on trial).
    func isExcludedFromMix(_ song: Song) -> Bool { mixExclusion()(song) }

    /// `isExcludedFromMix` as things stand now, to hand to the pure selection.
    func mixExclusion() -> @Sendable (Song) -> Bool {
        let (known, discover, findsLibrary, finds) = (knownAurralSongIds, discoverLibraryIds, findsLibraryId, findsIdentity)
        return { song in
            if known.contains(song.id) || finds.isFind(song) { return true }
            guard let library = song.libraryId else { return false }
            return discover.contains(library) || library == findsLibrary
        }
    }

    /// The builder's queue check (D307): the queue is still the running build's own when its current entry, or the last
    /// entry it added, is still in it.
    func queueIsStillMix() -> Bool {
        let builder = queueBuilder
        let main = player.queue.main
        if let anchor = builder.anchor, main.contains(where: { $0.id == anchor }) { return true }
        if let current = player.queue.current?.id, builder.entries.contains(current) { return true }
        return false
    }

    /// Adds `songs` behind the queue in batches of ten while it is still the build's own; false when it stopped.
    func appendToMix(_ songs: [Song], placed: inout [Song], generation: Int) -> Bool {
        let builder = queueBuilder
        var rest = songs[...]
        while !rest.isEmpty {
            guard builder.isCurrent(generation), queueIsStillMix() else { return false }
            let batch = Array(rest.prefix(QueueBuilder.batch))
            rest = rest.dropFirst(batch.count)
            let before = Set(player.queue.main.map(\.id))
            player.addToEnd(batch)
            let added = player.queue.main.filter { !before.contains($0.id) }.map(\.id)
            builder.entries.formUnion(added)
            builder.anchor = added.last ?? builder.anchor
            placed += batch
            builder.onAppend?(batch)
        }
        return builder.isCurrent(generation)
    }

    // MARK: - The reads (library only, each bounded)

    /// Navidrome's similar songs for a song or an artist (at most 200), within `QueueBuilder.readWait`; none on a failure.
    private func similarSongs(_ id: String) async -> [Song] {
        let wait = QueueBuilder.readWait
        let result = await Deadline.run(wait, sleep: queueBuilder.sleep) { @MainActor in
            try await self.request { try await $0.similarSongs(id: id, count: 200) }
        }
        return (try? result.get()) ?? []
    }

    /// The seed artist's own songs (their newest albums, at most `QueueBuilder.artistAlbums`); nil without an artist id.
    /// Songs credited to another artist on those albums (a compilation) are left out.
    private func artistSongs(_ artistId: String?, albums known: [Album]) async -> [Song]? {
        guard let artistId, !artistId.isEmpty, !OfflineCatalog.isLocalId(artistId) else { return nil }
        let wait = QueueBuilder.readWait
        let result = await Deadline.run(wait, sleep: queueBuilder.sleep) { @MainActor in
            try await self.request { client in
                let albums = known.isEmpty ? try await client.artist(id: artistId).1 : known
                let ids = albums.sorted { ($0.year ?? 0) > ($1.year ?? 0) }.prefix(QueueBuilder.artistAlbums).map(\.id)
                let byId = try await KeyedGather.values(Array(ids)) { id in try await client.album(id: id).songs ?? [] }
                return ids.flatMap { byId[$0] ?? [] }
            }
        }
        let songs = (try? result.get()) ?? []
        return songs.filter { $0.artistId == nil || $0.artistId == artistId }
    }

    /// A page of the genre's songs from a random place in it (the genre's count from `getGenres`); nil without a genre.
    private func genreSongs<R: RandomNumberGenerator>(_ genre: String?, using rng: inout R) async -> [Song]? {
        guard let genre, !genre.isEmpty else { return nil }
        let wait = QueueBuilder.readWait, page = QueueBuilder.genreSongs
        let genres = await Deadline.run(wait, sleep: queueBuilder.sleep) { @MainActor in
            try await self.request { try await $0.genres() }
        }
        let count = ((try? genres.get()) ?? []).first { $0.name == genre }?.songCount ?? 0
        let offset = count > page ? Int.random(in: 0...(count - page), using: &rng) : 0
        let result = await Deadline.run(wait, sleep: queueBuilder.sleep) { @MainActor in
            try await self.request { try await $0.songs(genre: genre, count: page, offset: offset) }
        }
        return (try? result.get()) ?? []
    }

    /// One of the artist's songs, from one of their albums at random, to start a mix with when no top song is known.
    private func oneSong(of albums: [Album]) async -> Song? {
        guard let album = albums.randomElement() else { return nil }
        let wait = QueueBuilder.readWait
        let result = await Deadline.run(wait, sleep: queueBuilder.sleep) { @MainActor in
            try await self.request { try await $0.album(id: album.id).songs ?? [] }
        }
        return ((try? result.get()) ?? []).filter { !isExcludedFromMix($0) }.randomElement()
    }
}
