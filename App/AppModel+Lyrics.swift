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
    /// L fix round 1 (I1): background reads in flight at once, each left to finish (nd-lyrics may be fetching).
    nonisolated static let maxBackgroundReads = 3

    /// Find lyrics online: off by default, per phone (D311).
    var findOnline = false { didSet { defaults?.set(findOnline, forKey: Self.findOnlineKey) } }

    /// One song's kept answers: the server's (`nil` lyrics = none) and LRCLIB's (`nil` = none).
    struct Entry: Equatable {
        var library: Lyrics??
        var online: FoundLyrics??
    }

    /// A server read in flight: `quiet` for the background ask (no failover, never counted towards going offline).
    struct Read {
        var task: Task<Result<Lyrics?, any Error>, Never>
        var quiet: Bool
    }

    @ObservationIgnored private var defaults: UserDefaults?
    @ObservationIgnored private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var askedServer = BoundedSet(capacity: LyricsKeeper.askedCapacity)
    @ObservationIgnored private var askedOnline = BoundedSet(capacity: LyricsKeeper.askedCapacity)
    /// The server reads in flight, by song.
    @ObservationIgnored var inFlight: [String: Read] = [:]
    /// The song whose background read waits for a free slot (only ever the current song; not yet marked asked).
    @ObservationIgnored var waiting: String?
    /// Bumped by `forget()`: an answer that lands after it is dropped.
    @ObservationIgnored private(set) var generation = 0
    @ObservationIgnored var lrclib: LrcLib?
    /// The server's extensions, read quietly by the background ask when the session hadn't read them yet.
    @ObservationIgnored var extensions: Set<String>?
    /// How long the pane waits for the server before LRCLIB is asked (D311: 6 s; tests shorten it).
    @ObservationIgnored var serverWait: Duration = .seconds(6)
    /// How long a server read may take (D310: 20 s; tests shorten it).
    @ObservationIgnored var serverDeadline: Duration = .seconds(20)
    /// L fix round 1 (LL3): how long an LRCLIB call may take in all (tests shorten it).
    @ObservationIgnored var onlineDeadline: Duration = .seconds(15)

    var backgroundReads: Int { inFlight.values.filter(\.quiet).count }
    var readsInFlight: Int { inFlight.count }

    func attach(defaults: UserDefaults, lrclib: LrcLib) {
        self.defaults = nil   // reading the switch writes nothing: off stays unset
        findOnline = defaults.object(forKey: Self.findOnlineKey) as? Bool ?? false
        self.defaults = defaults
        self.lrclib = lrclib
    }

    func hasAskedServer(_ id: String) -> Bool { askedServer.contains(id) }
    func noteAskedServer(_ id: String) { askedServer.insert(id) }
    func forgetAskedServer(_ id: String) { askedServer.remove(id) }
    func hasAskedOnline(_ id: String) -> Bool { askedOnline.contains(id) }
    func noteAskedOnline(_ id: String) { askedOnline.insert(id) }
    func forgetAskedOnline(_ id: String) { askedOnline.remove(id) }

    /// The server's kept answer: nil when none is kept, `.some(nil)` when it had none.
    func library(_ id: String) -> Lyrics?? { touch(id); return entries[id]?.library ?? nil }
    func online(_ id: String) -> FoundLyrics?? { touch(id); return entries[id]?.online ?? nil }

    func keepLibrary(_ id: String, _ lyrics: Lyrics?) {
        let usable = lyrics.flatMap { $0.lines.isEmpty ? nil : $0 }
        update(id) { $0.library = .some(usable) }
    }

    func keepOnline(_ id: String, _ found: FoundLyrics?) { update(id) { $0.online = .some(found) } }

    /// D313: what's kept for the pane: the server's lyrics first, then LRCLIB's (only while Find lyrics online is on,
    /// L fix round 1 M4); nil when neither has any.
    func shown(_ id: String) -> ShownLyrics? {
        if case .some(.some(let lyrics)) = library(id) { return .lines(lyrics, .library) }
        if findOnline, case .some(let found) = online(id) { return ShownLyrics(online: found) }
        return nil
    }

    /// Sign-out: every answer, every "asked", and the reads in flight.
    func forget() {
        generation += 1
        inFlight.values.forEach { $0.task.cancel() }
        inFlight = [:]
        waiting = nil
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
        mutating func remove(_ id: String) {
            guard members.remove(id) != nil else { return }
            order.removeAll { $0 == id }
        }
    }
}

/// What the background ask watches (L fix round 1 M2): the current song, and whether a read can go now, so a song that
/// started offline or before sign-in is asked once Magpie is online and signed in.
private struct LyricsTriggerInputs: Equatable {
    var songId: String?
    var signedIn: Bool
    var offline: Bool
}

/// A background read given up before it was sent (offline by then): not counted as asked.
private struct LyricsReadSkipped: Error {}

/// Round 27 L (owner, 2026-11-14, items 14 and 15).
///
/// D310: nd-lyrics fetches lyrics only when a client asks the server for them (Navidrome walks `LyricsPriority`, so the
/// plugin runs only for a song with no lyrics in or beside its file). So Magpie asks — `getLyricsBySongId`, the
/// ordinary read — when a song becomes current, online, signed in, the server advertising `songLyrics`, once per song
/// per session, whether or not the pane is open; the answer is kept for the pane. Nothing else goes on the wire.
/// L fix round 1 (I1): every background read runs to its 20 s deadline (a skip never abandons it), at most three at
/// once; with three out, the current song's waits for a slot and is asked only if it is still current then. The
/// background read is quiet (I2): the current client, no failover, never counted towards going offline. The pane's
/// reads go through `request` as every other screen's do.
///
/// D311: with Find lyrics online on, the pane asks LRCLIB (`LrcLib`) when the server had none or hasn't answered in
/// 6 s; the server's read goes on either way, and its answer is used next time (D313: what's on show stays).
extension AppModel {
    /// Called once from `init`: the switch, LRCLIB's client, and the watcher on the current song.
    func watchLyrics() {
        lyricsKeeper.attach(defaults: appDefaults,
                            lrclib: LrcLib(transport: LrcLibTransport(), userAgent: LrcLib.userAgent(version: Self.marketingVersion)))
        lyricsWatch = Task { [weak self, player] in
            let inputs = Observations { @MainActor [weak self] in
                LyricsTriggerInputs(songId: player.queue.current?.song.id, signedIn: self?.session != nil,
                                    offline: self?.isOffline ?? true)
            }
            for await input in inputs {
                guard let self else { return }
                self.lyricsSongBecameCurrent(input.songId)
            }
        }
    }

    /// Sign-out: the kept lyrics and the reads under way.
    func forgetLyrics() { lyricsKeeper.forget() }

    /// D310: the background ask for the song now current (the main player's queue: never a preview, which plays in its
    /// own player).
    func lyricsSongBecameCurrent(_ id: String?) {
        guard let id, session != nil, !isOffline, !lyricsKeeper.hasAskedServer(id) else { return }
        let generation = lyricsKeeper.generation
        Task { [weak self] in
            guard let self, await self.lyricsQuietlyAdvertised() else { return }
            guard self.lyricsKeeper.generation == generation, self.player.queue.current?.song.id == id else { return }
            self.startBackgroundRead(id)
        }
    }

    /// I1: a background read for `id` unless it was asked or is under way; with three out, it waits for a slot.
    func startBackgroundRead(_ id: String) {
        let keeper = lyricsKeeper
        guard session != nil, !isOffline, keeper.inFlight[id] == nil, !keeper.hasAskedServer(id) else { return }
        guard keeper.backgroundReads < LyricsKeeper.maxBackgroundReads else { keeper.waiting = id; return }
        if keeper.waiting == id { keeper.waiting = nil }
        startLyricsRead(id, quiet: true)
    }

    /// A slot freed: the waiting song's read starts if it is still the current song; otherwise it is dropped, not asked.
    private func startWaitingLyricsRead() {
        let keeper = lyricsKeeper
        guard let id = keeper.waiting, keeper.backgroundReads < LyricsKeeper.maxBackgroundReads else { return }
        keeper.waiting = nil
        guard player.queue.current?.song.id == id else { return }
        startBackgroundRead(id)
    }

    /// One server read for `id`, kept when it answers. Quiet reads (the background ask) use the current client with no
    /// failover and check Offline mode just before sending (M3); the others go through `request`.
    @discardableResult
    func startLyricsRead(_ id: String, quiet: Bool) -> Task<Result<Lyrics?, any Error>, Never> {
        let keeper = lyricsKeeper
        keeper.noteAskedServer(id)
        let generation = keeper.generation, deadline = keeper.serverDeadline
        let task = Task { [weak self] () -> Result<Lyrics?, any Error> in
            let result = await Deadline.run(deadline) { [weak self] () async throws -> Lyrics? in
                guard let self else { throw CancellationError() }
                if quiet {
                    guard let client = await self.quietLyricsClient() else { throw LyricsReadSkipped() }
                    return try await client.lyrics(songId: id)
                }
                return try await self.request { try await $0.lyrics(songId: id) }
            }
            guard let self, self.lyricsKeeper.generation == generation else { return result }
            switch result {
            case .success(let lyrics): self.lyricsKeeper.keepLibrary(id, lyrics)
            case .failure(let error) where error is LyricsReadSkipped: self.lyricsKeeper.forgetAskedServer(id)
            case .failure: break
            }
            return result
        }
        keeper.inFlight[id] = LyricsKeeper.Read(task: task, quiet: quiet)
        Task { [weak self, keeper] in
            _ = await task.value
            guard keeper.generation == generation else { return }
            if keeper.inFlight[id]?.task == task { keeper.inFlight[id] = nil }
            // Fix round 2 (N1): a finished quiet read frees its slot even when the pane's retry already took its place.
            if quiet || keeper.inFlight[id] == nil { self?.startWaitingLyricsRead() }
        }
        return task
    }

    /// M3: the client for a quiet read, nil when Offline mode (or signing out) means nothing may be sent now.
    private func quietLyricsClient() -> NavidromeClient? {
        guard !isOffline else { return nil }
        return session?.client
    }

    /// I2: the pane's server read. One under way for the song is awaited; a quiet one that failed is tried once more
    /// through `request` (which fails over and reconnects).
    func paneLyricsRead(_ id: String) async -> Result<Lyrics?, any Error> {
        if let running = lyricsKeeper.inFlight[id] {
            let result = await running.task.value
            guard running.quiet, case .failure(let error) = result, !(error is CancellationError) else { return result }
            return await startLyricsRead(id, quiet: false).value
        }
        return await startLyricsRead(id, quiet: false).value
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

    /// What the pane shows for `song`. Kept answers first, without a read (D310); offline, only those (D313; the pane
    /// says it's offline, M1). `fresh` (Try again) reads the server afresh; LRCLIB is still asked at most once per song
    /// per session.
    func lyricsForPane(_ song: Song, fresh: Bool = false) async throws -> ShownLyrics? {
        let keeper = lyricsKeeper
        if !fresh, let kept = keeper.shown(song.id) { return kept }
        guard session != nil, !isOffline else { return nil }
        let advertises = (try? await serverAdvertises("songLyrics")) ?? false
        let keptNone: Bool = if case .some(.none) = keeper.library(song.id) { true } else { false }
        guard advertises, fresh || !keptNone else { return await onlineLyrics(song) }
        let read = Task { [weak self] () -> Result<Lyrics?, any Error> in
            guard let self else { return .failure(CancellationError()) }
            return await self.paneLyricsRead(song.id)
        }
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

    /// LRCLIB's answer for `song`: only with the switch on, online, and once per song per session (D311), within 15 s
    /// in all (LL3). A call the pane gave up on (cancelled) is neither kept nor counted as asked (LL4).
    func onlineLyrics(_ song: Song) async -> ShownLyrics? {
        let keeper = lyricsKeeper
        guard keeper.findOnline, session != nil, !isOffline, let lrclib = keeper.lrclib else { return nil }
        if case .some(let found) = keeper.online(song.id) { return ShownLyrics(online: found) }
        guard !keeper.hasAskedOnline(song.id) else { return nil }
        keeper.noteAskedOnline(song.id)
        let generation = keeper.generation
        let (title, artist, album, duration) = (song.title, song.artist, song.album, song.duration)
        let result = await Deadline.run(keeper.onlineDeadline) {
            await lrclib.get(title: title, artist: artist, album: album, duration: duration)
        }
        guard keeper.generation == generation else { return nil }
        switch result {
        case .success(let found):
            keeper.keepOnline(song.id, found)
            return ShownLyrics(online: found)
        case .failure(let error) where error is CancellationError:
            keeper.forgetAskedOnline(song.id)
            return nil
        case .failure:
            return nil   // past the limit: asked, nothing kept
        }
    }

    private static func library(_ result: Result<Lyrics?, any Error>) throws -> ShownLyrics? {
        let lyrics = try result.get()
        guard let lyrics, !lyrics.lines.isEmpty else { return nil }
        return .lines(lyrics, .library)
    }
}
