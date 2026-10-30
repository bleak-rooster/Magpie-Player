import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Observation
import Requests

/// R18 + R20: how music comes into your library. "Only in your Finds" and Keep <artist>, the Add sheet (Add to your
/// library, Add more to your library, and Add more after a Keep), "Add with my defaults" and "When you add an artist"
/// (Settings › New music), and the main library next to the Finds library.
///
/// Owner-data rule: only artists the ledger says Magpie added are ever changed (the gate checks it again); for
/// anything else the app says "Added outside Magpie. Change it where you added it."

/// What these screens say (design language §5, the round-11 glossary: no service names, "download" means this
/// iPhone only).
enum NewMusicCopy {
    static let onlyInFinds = "Only in your Finds"
    static let keep = "Keep"
    static let addedOutside = "Added outside Magpie. Change it where you added it."
    static let addToLibrary = "Add to your library"
    static let addMoreToLibrary = "Add more to your library"
    static let addMore = "Add more"
    static let notNow = "Not now"
    static let cancel = "Cancel"
    static let done = "Done"
    static let loading = "Looking at what there is\u{2026}"
    static let whatHeader = "What to add"
    static let kindsHeader = "Kinds"
    static let qualityHeader = "Quality"
    static let follow = "Follow new releases"
    static let followNote = "New albums come in by themselves."
    static let lotOfMusic = "That's a lot of music. It can take a while to arrive."
    /// Past this, the Add sheet says it's a lot of music (UX appraisal §5).
    static let lotOfMusicHours: TimeInterval = 50 * 3600
    static let withMyDefaults = "Add with my defaults"
    static let withMyDefaultsFooter = "On: one tap adds with the choices below. Off: you choose each time."
    static let whenYouAdd = "When you add an artist"
    static let mainLibrary = "Main library"
    static let mainFolder = "Main folder"
    static let mainLibraryFooter = "Your main collection: where kept finds and new music land. Magpie picks it when there's only one."

    static func name(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "this artist" : trimmed
    }

    static func keepArtist(_ artist: String) -> String {
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? keep : "Keep \(trimmed)"
    }

    static func addTitle(_ artist: String) -> String { "Add \(name(artist)) to your library" }
    static func addMoreTitle(_ artist: String) -> String { "Add more from \(name(artist))" }
    static func keptTitle(_ artist: String) -> String { "Kept. Add more from \(name(artist))?" }

    static func what(_ what: AddWhat) -> String {
        switch what {
        case .albumsAndEPs: "Their albums and EPs"
        case .albums: "Just albums"
        case .everything: "Everything, singles too"
        case .thisAlbum: "Just this album"
        }
    }

    static let studio = "Studio albums"
    static let live = "Live albums"
    static let soundtracks = "Soundtracks"

    static func quality(_ quality: DownloadChoices.Quality) -> String {
        switch quality {
        case .lossless: "Lossless"
        case .smaller: "Smaller files"
        }
    }

    /// "about 14 hours of music", or nil when the length isn't known (A5: never guessed).
    static func hours(_ duration: TimeInterval?) -> String? { BringInCopy.size(duration) }

    /// The one-line summary under "Add with my defaults"' confirmation: "Their albums and EPs · Lossless · about 14
    /// hours of music", plus "· Following new releases".
    static func summary(_ choices: DownloadChoices, duration: TimeInterval?) -> String {
        var parts = [what(AddWhat(choices)), quality(choices.quality)]
        let kinds = [choices.types.live ? "live albums" : nil, choices.types.soundtrack ? "soundtracks" : nil].compactMap { $0 }
        if choices.what == .wholeArtist, !kinds.isEmpty { parts[0] += " with " + kinds.joined(separator: " and ") }
        if choices.what == .wholeArtist, !choices.types.studio { parts[0] += ", no studio albums" }
        if let hours = hours(duration) { parts.append(hours) }
        if choices.follow { parts.append("Following new releases") }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func message(for error: Error) -> String {
        switch error {
        case ArtistLidarrError.changesOff, WriteGateError.disabled:
            "Adding music is switched off. Turn it on in Settings."
        case ArtistLidarrError.notMagpies: addedOutside
        case ArtistLidarrError.profileConflict(let name), RequestRunner.BringInError.profileConflict(let name):
            "Your server already has a profile called \u{201C}\(name)\u{201D} set up differently. Magpie won't change it, so nothing was added."
        case ArtistLidarrError.notFound: "Couldn't find this artist to add. Try again later."
        case ArtistLidarrError.alreadyInLidarr: "That artist is in your library already."
        case NewMusicError.notSetUp: "Adding music needs one more step in Settings."
        default: "Couldn't add it this time. Try again in a moment."
        }
    }
}

enum NewMusicError: Error, Equatable {
    /// Magpie's profiles or main root aren't set up yet.
    case notSetUp
}

/// The Add sheet's "What to add" rows: a whole-artist kind, or the one album (only with an album in context).
enum AddWhat: String, CaseIterable, Identifiable {
    case albumsAndEPs, albums, everything, thisAlbum
    var id: String { rawValue }

    init(_ choices: DownloadChoices) {
        guard choices.what == .wholeArtist else { self = .thisAlbum; return }
        self = switch choices.types.kinds {
        case .albums: .albums
        case .albumsAndEPs: .albumsAndEPs
        case .albumsEPsAndSingles: .everything
        }
    }

    /// `choices` with this row chosen (the kinds toggles stay as they are).
    func applied(to choices: DownloadChoices) -> DownloadChoices {
        var c = choices
        switch self {
        case .thisAlbum: c.what = .thisAlbum
        case .albums: c.what = .wholeArtist; c.types.kinds = .albums
        case .albumsAndEPs: c.what = .wholeArtist; c.types.kinds = .albumsAndEPs
        case .everything: c.what = .wholeArtist; c.types.kinds = .albumsEPsAndSingles
        }
        return c
    }
}

/// "Add with my defaults" (default on) and "When you add an artist" (Settings › New music), saved on this iPhone;
/// and which Keep the app is running for a find menu (`FindsKeepFlow`).
@MainActor @Observable final class NewMusicSettings {
    nonisolated static let withMyDefaultsKey = "magpie.newMusic.addWithMyDefaults"
    nonisolated static let whenYouAddKey = "magpie.newMusic.whenYouAdd"

    @ObservationIgnored private let defaults: UserDefaults

    /// On: every add skips the sheet for one confirmation with the defaults. Off: the Add sheet, preset with them.
    var withMyDefaults: Bool { didSet { defaults.set(withMyDefaults, forKey: Self.withMyDefaultsKey) } }
    /// What an add uses (with Add with my defaults on) or starts from (off).
    var whenYouAdd: DownloadChoices {
        didSet { defaults.set(try? JSONEncoder().encode(whenYouAdd), forKey: Self.whenYouAddKey) }
    }
    /// A Keep asked for from a find's menu or an artist page, run by the `FindsKeepFlow` of `host`.
    var keeping: KeepFlowRequest?

    init(defaults: UserDefaults) {
        self.defaults = defaults
        withMyDefaults = defaults.object(forKey: Self.withMyDefaultsKey) as? Bool ?? true
        whenYouAdd = defaults.data(forKey: Self.whenYouAddKey)
            .flatMap { try? JSONDecoder().decode(DownloadChoices.self, from: $0) } ?? .defaults
    }
}

/// Keep, asked for from outside the Finds shelf: the songs it is about (a find, or an artist's finds).
struct KeepFlowRequest: Identifiable, Equatable {
    let id = UUID()
    /// The `FindsKeepFlow` that runs it (the one over the screen the menu is on).
    let host: String
    let songIds: [String]
    let artist: String
}

extension AppModel {
    // MARK: - Only in your Finds

    /// An artist "Only in your Finds": every album of theirs has songs in the Finds library, as last read. Mixed
    /// artists (some albums in your library) aren't; nothing known means not.
    nonisolated static func onlyInFinds(albumIds: [String], findSongs: [Song]) -> Bool {
        guard !albumIds.isEmpty else { return false }
        let inFinds = Set(findSongs.compactMap(\.albumId))
        return albumIds.allSatisfy(inFinds.contains)
    }

    func isOnlyInFinds(albums: [Album]) -> Bool { Self.onlyInFinds(albumIds: albums.map(\.id), findSongs: findSongs) }

    /// The artist's songs in the Finds library, as last read.
    func findSongs(of albums: [Album]) -> [Song] {
        let ids = Set(albums.map(\.id))
        return findSongs.filter { $0.albumId.map(ids.contains) ?? false }
    }

    /// The ready find Keep goes through for any of these songs (the newest), if one has nothing else under way.
    func keepRequest(songIds: [String]) -> RequestID? {
        let ids = Set(songIds)
        return requests.last {
            guard let song = $0.songId, ids.contains(song) else { return false }
            return $0.isFind && FindsShelf.keepRequest(for: Song(id: song, title: "", artist: "", album: "", duration: 0),
                                                       in: [$0]) != nil
        }?.id
    }

    /// The ledger says Magpie added the request's artist (read now). Unreadable or unknown: not Magpie's.
    func magpieAddedArtist(of id: RequestID) async -> Bool {
        guard let artistId = requests.first(where: { $0.id == id })?.lidarrArtistId, let ledger,
              let entries = try? await ledger.entries else { return false }
        return entries.contains { $0.lidarrArtistId == artistId && $0.createdArtist }
    }

    // MARK: - Profiles for the choices

    func qualityProfileId(_ quality: DownloadChoices.Quality) -> Int? {
        switch quality {
        case .lossless: lidarrSetup?.losslessProfileId
        case .smaller: lidarrSetup?.fastStartProfileId
        }
    }

    // MARK: - Add more, after a Keep

    /// What the choices would bring in for a kept find (no writes). `types`: the whole-artist release types.
    func afterKeepOffer(_ id: RequestID, types: ReleaseTypes) async -> BringInLoad {
        await bringInOffer(id, types: types)
    }

    /// The releases the choices bring in from `offer`, and how long that is.
    nonisolated static func pick(_ offer: RequestRunner.BringInOffer, _ choices: DownloadChoices) -> RequestRunner.BringInOption? {
        offer.options[choices.bringInChoice]
    }

    /// Brings in what the choices say for a kept find, with their release types and quality.
    func addMore(afterKeep id: RequestID, choices: DownloadChoices, offered: [Int]?, artist: String) async -> BringInReply {
        guard let quality = qualityProfileId(choices.quality) else {
            return BringInReply(message: NewMusicCopy.message(for: NewMusicError.notSetUp))
        }
        let choice: RequestRunner.BringInChoice? = (offered?.isEmpty ?? false) ? nil : choices.bringInChoice
        return await bringIn(id, choice: choice, offered: offered, follow: choices.follow, artist: artist,
                             types: choices.what == .wholeArtist ? choices.types : nil, qualityProfileId: quality)
    }

    // MARK: - Add to your library (an artist not in it yet)

    /// Adds the artist with the choices: Magpie's profiles for the quality and release types, Follow new releases.
    /// Returns its id.
    func addArtist(mbid: MBID, choices: DownloadChoices) async throws -> Int {
        try requireNotForcedOffline()
        guard let client = lidarrClient, let gate, let ledger else { throw ArtistLidarrError.failed }
        guard var setup = lidarrSetup?.runnerSetup, let quality = qualityProfileId(choices.quality) else {
            throw NewMusicError.notSetUp
        }
        setup.qualityProfileId = quality
        return try await ArtistLidarr.add(mbid: mbid, lidarr: client, gate: gate, ledger: ledger, setup: setup,
                                          follow: choices.follow, types: choices.types)
    }

    // MARK: - Add more to your library (an artist Magpie added)

    func addMoreToLibrary(lidarrId: Int, choices: DownloadChoices) async throws {
        try requireNotForcedOffline()
        guard let client = lidarrClient, let gate, let ledger else { throw ArtistLidarrError.failed }
        guard let quality = qualityProfileId(choices.quality) else { throw NewMusicError.notSetUp }
        try await ArtistLidarr.addMore(lidarrId: lidarrId, lidarr: client, gate: gate, ledger: ledger,
                                       types: choices.types, qualityProfileId: quality, follow: choices.follow)
    }

    /// How long the artist's releases of these types that aren't in yet are (monitored ones only: Add more searches
    /// for those). Nil when unknown.
    func addMoreDuration(lidarrId: Int, types: ReleaseTypes) async -> TimeInterval? {
        guard let client = lidarrClient, !isOffline, let albums = try? await client.albums(artistId: lidarrId) else { return nil }
        return Self.missingDuration(albums, types: types)
    }

    nonisolated static func missingDuration(_ albums: [LidarrAlbum], types: ReleaseTypes) -> TimeInterval? {
        let missing = albums.filter {
            types.includes(albumType: $0.albumType, secondaryTypes: $0.secondaryTypes) && ($0.trackFileCount ?? 0) == 0
        }
        let lengths = missing.compactMap(\.duration)
        return !missing.isEmpty && lengths.count == missing.count ? lengths.reduce(0, +) : nil
    }

    // MARK: - Main library (R18)

    /// The one library besides the Finds library, when there is exactly one; nil otherwise (the owner picks).
    nonisolated static func autoMainLibrary(_ libraries: [NavidromeLibrary], findsLibrary: NavidromeLibrary?) -> NavidromeLibrary? {
        let others = libraries.filter { $0.id != findsLibrary?.id }
        return others.count == 1 ? others[0] : nil
    }

    /// The libraries the main library can be: every one but the Finds library.
    nonisolated static func mainLibraryChoices(_ libraries: [NavidromeLibrary], findsLibrary: NavidromeLibrary?) -> [NavidromeLibrary] {
        libraries.filter { $0.id != findsLibrary?.id }
    }

    /// After the libraries are read: a main library that's gone, or is now the Finds library, is dropped, and with
    /// exactly one other library it's picked.
    func reconcileMainLibrary(_ libraries: [NavidromeLibrary]) {
        guard var setup = findsSetup else { return }
        let choices = Self.mainLibraryChoices(libraries, findsLibrary: setup.library)
        var main = setup.mainLibrary.flatMap { current in choices.first { $0.id == current.id } }
        if main == nil { main = Self.autoMainLibrary(libraries, findsLibrary: setup.library) }
        guard main != setup.mainLibrary else { return }
        setup.mainLibrary = main
        findsSetup = setup
        findsStore.save(setup)
    }

    func chooseMainLibrary(_ library: NavidromeLibrary) {
        guard var setup = findsSetup, library.id != setup.library?.id else { return }
        setup.mainLibrary = library
        findsSetup = setup
        findsStore.save(setup)
    }

    /// A main library has to be chosen: more than one library besides the Finds library, and none chosen.
    func needsMainLibrary(_ libraries: [NavidromeLibrary]) -> Bool {
        findsSetup?.mainLibrary == nil && Self.mainLibraryChoices(libraries, findsLibrary: findsSetup?.library).count > 1
    }
}
