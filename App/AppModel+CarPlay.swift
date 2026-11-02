import CarPlayUI
import Foundation
import MagpieCore
import MatchIndex
import Playback
import Requests
import Search

/// What CarPlay reads and does for Finds (Task 7.1d), on top of what the phone already has: the Finds tab is the
/// phone's Finds shelf, Keep is the phone's Keep (the find's release only: no Bring in more from the car, D5), and
/// "Try it next" is the phone's Try, landing by the one landing rule (D6). Not for me isn't offered in the car.
extension AppModel {
    /// T3: whether Local Network explains an out-of-reach library in the car: denied when known off, pending while
    /// never answered, and (fix round 2) only when the server's address needs the permission. A public or Tailscale
    /// address that is out of reach shows the normal out-of-reach state.
    var carPlayLocalNetwork: CPLocalNetwork {
        guard let base = session?.activeBase ?? session?.endpoint.bases.first,
              ServerAddress.needsLocalNetworkPermission(base) else { return .fine }
        switch localNetwork.state {
        case .denied: return .denied
        case .unknown: return .pending
        case .granted, .notNeeded: return .fine
        }
    }

    // MARK: - Finds tab

    /// New finds and the finds with days left, as the phone's Finds shelf has them; nil when no Finds library is
    /// chosen (the phone shows no Finds either).
    var carPlayFinds: CPFindsShelf? {
        guard findsSetup?.library != nil else { return nil }
        let shelf = findsShelf()
        func finds(_ items: [FindsShelf.Item]) -> [CPFind] {
            items.map { CPFind(song: $0.song, daysLeft: $0.daysLeft, isNew: $0.isNew) }
        }
        return CPFindsShelf(newFinds: finds(shelf.newFinds), finds: finds(shelf.finds))
    }

    // MARK: - Keep (Now Playing)

    /// The request Keep goes through for the find `songId`: exactly when the phone's Finds row offers Keep.
    private func carPlayKeepRequest(songId: String) -> RequestID? {
        guard findsSetup?.library != nil, let song = findSongs.first(where: { $0.id == songId }) else { return nil }
        return FindsShelf.keepRequest(for: song, in: requests)
    }

    func carPlayMayKeep(songId: String) -> Bool { carPlayKeepRequest(songId: songId) != nil }

    /// Keep from the car, through the same Keep as the phone (the runner checks everything on fresh state).
    func carPlayKeep(songId: String) async -> CPKeepResult {
        guard let id = carPlayKeepRequest(songId: songId) else { return .notAFind }
        do {
            return CPKeepResult(try await keepFind(id))
        } catch {
            return CPKeepResult(error: error)
        }
    }

    // MARK: - Search

    /// Outside sources' deadline in the car: CPSearchTemplate shows one list per query and can't add rows later, so
    /// the library's rows never wait long for them (D4).
    static let carPlaySourceTimeout: Duration = .milliseconds(1500)
    /// The library keeps the car's earlier limit: only the request's own timeout (no 3 s cut-off as on the phone,
    /// where the band can follow later).
    static let carPlayLibraryTimeout: Duration = .seconds(60)

    /// The phone's merged search with a short deadline for outside sources: library songs and albums, then songs not
    /// in the library (albums and artists from outside aren't offered in the car).
    func carPlaySearch(_ query: String) async throws -> CarPlaySearchResult {
        if isOffline {   // Task 14: what's on the phone, nothing from the server or outside
            let found = await OfflineSearch(catalog: offlineCatalog).sections(query)
            return CarPlaySearchResult(library: LibrarySearchResult(songs: found.songs + found.recentlyPlayed,
                                                                    albums: found.albums), notYet: [])
        }
        let sections = try await mergedSearch(libraryTimeout: Self.carPlayLibraryTimeout,
                                                sourceTimeout: Self.carPlaySourceTimeout).runReportingLibraryFailure(query)
        return CarPlaySearchResult(library: LibrarySearchResult(songs: sections.songs, albums: sections.albums),
                                   notYet: sections.notYet.songs, onTheirWay: carPlayOnTheirWay(sections.notYet.songs))
    }

    /// R20: the status of each not-yet song that already has a request on its way (by index), as the phone's row says
    /// it. A Ready one is left as it was: Try it next lands the song that's already here (the runner returns it).
    func carPlayOnTheirWay(_ songs: [ExternalRecording]) -> [Int: String] {
        var statuses: [Int: String] = [:]
        for (i, recording) in songs.enumerated() {
            if let request = RequestLinks.request(for: recording, in: requests), request.isActive {
                statuses[i] = RequestCopy.status(request, context: waitContext)
            }
        }
        return statuses
    }

    // MARK: - Try it next (D6, CarPlay H3)

    var carPlayTryOffer: CPTryOffer {
        guard case .available(let tier) = tryAvailability else { return .unavailable }
        return tier.asksInsteadOfWaiting ? .ask(intoFinds: triesGoIntoFinds) : .next
    }

    /// The phone's Try for `recording`. It never interrupts the queue: when it is ready it lands by `LandingRule` (no
    /// wait screen in the car, so it goes next, right after the current song, playing or paused). With an empty queue,
    /// a library mix seeded by the artist starts at once, so the find has something to go next after and the app keeps
    /// running on real audio (the audio session starts only when it plays). Patient requests are only asked for.
    func tryNext(_ recording: ExternalRecording) async -> CPTryResult {
        let offer = carPlayTryOffer
        guard offer != .unavailable else { return .failed(.notSetUp) }
        let id: RequestID
        do {
            id = try await tryRecording(recording)
        } catch {
            return .failed(CPTryProblem(error))
        }
        guard offer == .next else { return .asked }
        guard offer.startsBridge(queueEmpty: player.queue.current == nil) else { return .queued }
        let mix = await bridgeMix(seededBy: recording.artist)
        // Something started meanwhile, or the find already landed: leave the queue as it is.
        guard offer.startsBridge(queueEmpty: player.queue.current == nil), !landedRequests.contains(id) else {
            return .queued
        }
        guard !mix.isEmpty else {
            startsWhenLanded.insert(id)   // B-M7: no banner to tap in the car; it plays once it's here
            return .noMix
        }
        play(mix, startAt: 0)
        return .bridging
    }

    /// Library songs only (never finds): the artist's (by normalised name), then songs from a few random albums
    /// when the artist has few. Empty when the library doesn't answer.
    func bridgeMix(seededBy artist: String) async -> [Song] {
        // Until the Finds library's songs are known, every library song might be a find (fails closed): read it first.
        if findsLibraryId != nil, findIdsCache?.ids == nil { await refreshFinds() }
        let name = Normalize.name(artist)
        let found = (try? await request { try await $0.search(artist, songCount: 100, albumCount: 0, artistCount: 0) })?.songs ?? []
        let byArtist = found.filter { Normalize.name($0.artist) == name }
        var fill: [Song] = []
        if byArtist.count < BridgeMix.minimumFromArtist {
            let albums = (try? await request { try await $0.albumList(.random, size: 4, offset: 0) }) ?? []
            for album in albums {
                let id = album.id
                fill += (try? await request { try await $0.album(id: id) })?.songs ?? []
            }
        }
        let finds = Set((byArtist + fill).filter(isFind).map(\.id))
        return BridgeMix.songs(artistSongs: byArtist, fill: fill, excluding: finds)
    }
}

extension CPKeepResult {
    init(_ outcome: RequestRunner.KeepOutcome) {
        switch outcome {
        case .moved: self = .moved
        case .keptInPlace: self = .keptInPlace
        case .stillMoving, .queued: self = .stillMoving   // Y5: queued reads as "it'll be there soon" in the car
        }
    }

    init(error: Error) {
        switch error as? RequestRunner.KeepError {
        case .changesOff?: self = .changesOff
        case .notSetUp?: self = .notSetUp
        case .notAFind?: self = .notAFind
        case .moveFailed?: self = .moveFailed
        case .needsAttention?: self = .needsAttention
        case .collision?: self = .notAFind   // Y5 C1: "This one can't be kept from here."; the phone says why
        case .unavailable?, nil: self = .unavailable
        }
    }
}

extension CPTryProblem {
    init(_ error: Error) {
        switch error as? RequestRunner.TryError {
        case .tooMany?: self = .tooMany
        case .changesOff?, .notSetUp?: self = .notSetUp
        case .unavailable?: self = .unavailable
        case nil: self = .other
        }
    }
}
