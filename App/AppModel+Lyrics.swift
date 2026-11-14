import Foundation
import MagpieCore
import NavidromeKit
import Observation
import Playback

/// Round 27 L (owner, 2026-11-14): where the lyrics on show came from (D313).
enum LyricsSource: Sendable, Equatable {
    case library
    case online
}

/// Round 27 L (owner, 2026-11-14): what the Lyrics pane shows for a song: lines, or the instrumental note (D311–D313).
enum ShownLyrics: Sendable, Equatable {
    case lines(Lyrics, LyricsSource)
    case instrumental(LyricsSource)

    nonisolated static let libraryFooter = "Lyrics from your library"
    nonisolated static let onlineFooter = "Lyrics found online"
    nonisolated static let instrumentalNote = "No lyrics: it\u{2019}s an instrumental."

    var source: LyricsSource {
        switch self {
        case .lines(_, let source), .instrumental(let source): source
        }
    }

    /// D313: the pane's footer says where the lyrics came from.
    var footer: String { source == .library ? Self.libraryFooter : Self.onlineFooter }

    init?(online found: FoundLyrics?) {
        switch found {
        case .lines(let lyrics)? where !lyrics.lines.isEmpty: self = .lines(lyrics, .online)
        case .instrumental?: self = .instrumental(.online)
        default: return nil
        }
    }
}

/// Round 27 L (owner, 2026-11-14, items 14 and 15): the lyrics Magpie has asked for this session, and the Find lyrics
/// online switch.
///
/// D310: the server is asked once per song per session, in the background, when the song becomes current; the answer
/// (lyrics or none) is kept here for the pane, for the last 100 songs. D311: LRCLIB is asked at most once per song per
/// session, only from the pane. Memory only: nothing is saved, and sign-out forgets it all (the switch stays: it's the
/// phone's).
@MainActor @Observable final class LyricsKeeper {
    nonisolated static let findOnlineKey = "magpie.lyrics.findOnline"
    /// Songs whose answers are kept (least recently used go first).
    nonisolated static let capacity = 100
    /// Songs remembered as asked this session (far more than are kept: a "none" isn't asked again).
    nonisolated static let askedCapacity = 5_000

    /// Find lyrics online: off by default, per phone (D311).
    var findOnline = false { didSet { defaults?.set(findOnline, forKey: Self.findOnlineKey) } }

    /// One song's kept answers: the server's (`nil` lyrics = none) and LRCLIB's (`nil` = none).
    struct Entry: Equatable {
        var library: Lyrics??
        var online: FoundLyrics??
    }

    @ObservationIgnored private var defaults: UserDefaults?
    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var askedServer = BoundedSet(capacity: LyricsKeeper.askedCapacity)
    @ObservationIgnored private var askedOnline = BoundedSet(capacity: LyricsKeeper.askedCapacity)
    /// The one server read in flight (D310: at most one).
    @ObservationIgnored var inFlight: (songId: String, task: Task<Result<Lyrics?, any Error>, Never>)?
    /// Bumped by `forget()`: an answer that lands after it is dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored var lrclib: LrcLib?
    /// The server's extensions, read quietly by the background ask when the session hadn't read them yet.
    @ObservationIgnored var extensions: Set<String>?
    /// How long the pane waits for the server before LRCLIB is asked (D311: 6 s; tests shorten it).
    @ObservationIgnored var serverWait: Duration = .seconds(6)
    /// How long a server read may take (D310: 20 s; tests shorten it).
    @ObservationIgnored var serverDeadline: Duration = .seconds(20)

    func attach(defaults: UserDefaults, lrclib: LrcLib) {
        self.defaults = nil   // reading the switch writes nothing: off stays unset
        findOnline = defaults.object(forKey: Self.findOnlineKey) as? Bool ?? false
        self.defaults = defaults
        self.lrclib = lrclib
    }

    func hasAskedServer(_ id: String) -> Bool { askedServer.contains(id) }
    func noteAskedServer(_ id: String) { askedServer.insert(id) }
    func hasAskedOnline(_ id: String) -> Bool { askedOnline.contains(id) }
    func noteAskedOnline(_ id: String) { askedOnline.insert(id) }

    /// The server's kept answer: nil when none is kept, `.some(nil)` when it had none.
    func library(_ id: String) -> Lyrics?? { touch(id); return entries[id]?.library ?? nil }
    func online(_ id: String) -> FoundLyrics?? { touch(id); return entries[id]?.online ?? nil }

    func keepLibrary(_ id: String, _ lyrics: Lyrics?) {
        let usable = lyrics.flatMap { $0.lines.isEmpty ? nil : $0 }
        update(id) { $0.library = .some(usable) }
    }

    func keepOnline(_ id: String, _ found: FoundLyrics?) { update(id) { $0.online = .some(found) } }

    /// D313: what's kept for the pane: the server's lyrics first, then LRCLIB's; nil when neither has any.
    func shown(_ id: String) -> ShownLyrics? {
        if case .some(.some(let lyrics)) = library(id) { return .lines(lyrics, .library) }
        if case .some(let found) = online(id) { return ShownLyrics(online: found) }
        return nil
    }

    /// Sign-out: every answer, every "asked", and the read in flight.
    func forget() {
        generation += 1
        inFlight?.task.cancel()
        inFlight = nil
        extensions = nil
        entries = [:]
        order = []
        askedServer = BoundedSet(capacity: Self.askedCapacity)
        askedOnline = BoundedSet(capacity: Self.askedCapacity)
    }

    private func update(_ id: String, _ change: (inout Entry) -> Void) {
        var entry = entries[id] ?? Entry()
        change(&entry)
        entries[id] = entry
        touch(id)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    private func touch(_ id: String) {
        guard entries[id] != nil else { return }
        order.removeAll { $0 == id }
        order.append(id)
    }

    /// Insertion-ordered, oldest dropped past `capacity`.
    struct BoundedSet {
        let capacity: Int
        private var members: Set<String> = []
        private var order: [String] = []
        init(capacity: Int) { self.capacity = capacity }
        func contains(_ id: String) -> Bool { members.contains(id) }
        mutating func insert(_ id: String) {
            guard members.insert(id).inserted else { return }
            order.append(id)
            if order.count > capacity { members.remove(order.removeFirst()) }
        }
    }
}

/// Round 27 L (owner, 2026-11-14, items 14 and 15).
///
/// D310: nd-lyrics fetches lyrics only when a client asks the server for them (Navidrome walks `LyricsPriority`, so the
/// plugin runs only for a song with no lyrics in or beside its file). So Magpie asks — `getLyricsBySongId`, the
/// ordinary read — when a song becomes current, online, signed in, the server advertising `songLyrics`, once per song
/// per session, whether or not the pane is open; the answer is kept for the pane. Nothing else goes on the wire.
///
/// D311: with Find lyrics online on, the pane asks LRCLIB (`LrcLib`) when the server had none or hasn't answered in
/// 6 s; the server's read goes on either way, and its answer is used next time (D313: what's on show stays).
extension AppModel {
    /// Called once from `init`: the switch, LRCLIB's client, and the watcher on the current song.
    func watchLyrics() {
        lyricsKeeper.attach(defaults: appDefaults,
                            lrclib: LrcLib(transport: transport, userAgent: LrcLib.userAgent(version: Self.marketingVersion)))
        lyricsWatch = Task { [weak self, player] in
            for await id in Observations({ @MainActor in player.queue.current?.song.id }) {
                guard let self else { return }
                self.lyricsSongBecameCurrent(id)
            }
        }
    }

    /// Sign-out: the kept lyrics and the read under way.
    func forgetLyrics() { lyricsKeeper.forget() }

    /// D310: the background ask for the song now current (the main player's queue: never a preview, which plays in its
    /// own player).
    func lyricsSongBecameCurrent(_ id: String?) {
        guard let id, session != nil, !isOffline, !lyricsKeeper.hasAskedServer(id) else { return }
        let generation = lyricsKeeper.generation
        Task { [weak self] in
            guard let self, await self.lyricsQuietlyAdvertised() else { return }
            guard self.lyricsKeeper.generation == generation, self.player.queue.current?.song.id == id,
                  !self.isOffline, !self.lyricsKeeper.hasAskedServer(id) else { return }
            _ = self.serverLyricsRead(id)
        }
    }

    /// The server's read for `id`: the one in flight when it's for the same song, otherwise a new one (a newer song stops
    /// waiting for the older answer; the older song is never asked again by the trigger). Its answer is kept.
    func serverLyricsRead(_ id: String) -> Task<Result<Lyrics?, any Error>, Never> {
        let keeper = lyricsKeeper
        if let running = keeper.inFlight, running.songId == id { return running.task }
        keeper.inFlight?.task.cancel()
        keeper.noteAskedServer(id)
        let generation = keeper.generation, deadline = keeper.serverDeadline
        let task = Task { [weak self] () -> Result<Lyrics?, any Error> in
            let result = await Deadline.run(deadline) { [weak self] () async throws -> Lyrics? in
                guard let self else { throw CancellationError() }
                // Quiet: the current client, no failover, never counted towards going offline (a background read
                // mustn't take the app offline during a blip).
                guard let client = await self.session?.client else { throw NavidromeError.noReachableServer }
                return try await client.lyrics(songId: id)
            }
            guard let self, self.lyricsKeeper.generation == generation else { return result }
            if case .success(let lyrics) = result { self.lyricsKeeper.keepLibrary(id, lyrics) }
            return result
        }
        keeper.inFlight = (id, task)
        Task { [keeper] in
            _ = await task.value
            if keeper.inFlight?.task == task { keeper.inFlight = nil }
        }
        return task
    }

    /// Whether the server advertises `songLyrics`: the session's known extensions, else one quiet read of them (no
    /// failover, never counted towards going offline), kept until sign-out.
    func lyricsQuietlyAdvertised() async -> Bool {
        if let known = advertisedExtensions { return known.contains("songLyrics") }
        if let known = lyricsKeeper.extensions { return known.contains("songLyrics") }
        guard let client = session?.client, !isOffline else { return false }
        let generation = lyricsKeeper.generation
        guard let found = try? await client.extensions() else { return false }
        if lyricsKeeper.generation == generation { lyricsKeeper.extensions = found }
        return found.contains("songLyrics")
    }

    /// The Lyrics button shows when the server advertises `songLyrics` or Find lyrics online is on (D311, D314).
    func lyricsButtonAvailable() async -> Bool {
        if lyricsKeeper.findOnline { return true }
        return (try? await serverAdvertises("songLyrics")) ?? false
    }

    /// What the pane shows for `song`. Kept answers first, without a read (D310); offline, only those (D313). `fresh`
    /// (Try again) reads the server afresh; LRCLIB is still asked at most once per song per session.
    func lyricsForPane(_ song: Song, fresh: Bool = false) async throws -> ShownLyrics? {
        let keeper = lyricsKeeper
        if !fresh, let kept = keeper.shown(song.id) { return kept }
        guard session != nil, !isOffline else { return nil }
        let advertises = await lyricsQuietlyAdvertised()
        let keptNone: Bool = if case .some(.none) = keeper.library(song.id) { true } else { false }
        guard advertises, fresh || !keptNone else { return await onlineLyrics(song) }
        let read = serverLyricsRead(song.id)
        guard keeper.findOnline else { return try Self.library(await read.value) }
        // D311: the server first, for up to 6 s; its read goes on behind whatever LRCLIB answers.
        switch await Deadline.run(keeper.serverWait, { await read.value }) {
        case .success(let result):
            if case .success(let lyrics?) = result, !lyrics.lines.isEmpty { return .lines(lyrics, .library) }
            if case .failure(let error) = result, error is CancellationError { throw error }
            if let online = await onlineLyrics(song) { return online }
            return try Self.library(result)
        case .failure(let error) where error is CancellationError:
            throw error
        case .failure:
            if let online = await onlineLyrics(song) { return online }
            return try Self.library(await read.value)
        }
    }

    /// LRCLIB's answer for `song`: only with the switch on, online, and once per song per session (D311).
    func onlineLyrics(_ song: Song) async -> ShownLyrics? {
        let keeper = lyricsKeeper
        guard keeper.findOnline, session != nil, !isOffline, let lrclib = keeper.lrclib else { return nil }
        if case .some(let found) = keeper.online(song.id) { return ShownLyrics(online: found) }
        guard !keeper.hasAskedOnline(song.id) else { return nil }
        keeper.noteAskedOnline(song.id)
        let generation = keeper.generation
        let found = await lrclib.get(title: song.title, artist: song.artist, album: song.album, duration: song.duration)
        guard keeper.generation == generation else { return nil }
        keeper.keepOnline(song.id, found)
        return ShownLyrics(online: found)
    }

    private static func library(_ result: Result<Lyrics?, any Error>) throws -> ShownLyrics? {
        let lyrics = try result.get()
        guard let lyrics, !lyrics.lines.isEmpty else { return nil }
        return .lines(lyrics, .library)
    }
}
