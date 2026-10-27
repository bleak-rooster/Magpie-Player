import DesignSystem
import Foundation
import MagpieCore

// Finds in the car (Task 7.1d): the Finds tab, Keep as the system add-to-library button in Now Playing, and
// "Try it next" from search (D5, D6, D12, CarPlay H3/M1). Pure, so the rules are unit-tested; the app supplies the
// shelf, Keep and Try (`CarPlayLibrary`), the same ones the phone uses.

/// One find on the Finds tab: a song of the Finds library, as the phone's Finds shelf has it.
public struct CPFind: Sendable, Hashable {
    public var song: Song
    public var daysLeft: Int
    /// Not played yet.
    public var isNew: Bool

    public init(song: Song, daysLeft: Int, isNew: Bool) {
        self.song = song; self.daysLeft = daysLeft; self.isNew = isNew
    }

    /// The same text status and symbol as the phone's Finds row (D3).
    public var state: RowState { isNew ? .newFind : .find(daysLeft: daysLeft) }
}

/// What the Finds tab shows: New finds, then the other finds with their days left.
public struct CPFindsShelf: Sendable, Hashable {
    public var newFinds: [CPFind]
    public var finds: [CPFind]

    public init(newFinds: [CPFind], finds: [CPFind]) {
        self.newFinds = newFinds; self.finds = finds
    }
}

// MARK: - Keep (Now Playing)

/// The system add-to-library button, which is Keep for a find (D12, CarPlay M1). Shown only while the song playing is
/// a find that may be kept; while its Keep runs and after it, selected and disabled.
public enum CPKeepButton: Sendable, Hashable {
    case hidden, offered, keeping, kept

    public static func state(songId: String?, mayKeep: Bool, keeping: Set<String>, kept: Set<String>) -> CPKeepButton {
        guard let songId else { return .hidden }
        if kept.contains(songId) { return .kept }
        if keeping.contains(songId) { return .keeping }
        return mayKeep ? .offered : .hidden
    }

    public var isShown: Bool { self != .hidden }
    public var isEnabled: Bool { self == .offered }
    public var isSelected: Bool { self == .keeping || self == .kept }
}

/// What Keep says in the car. Release only, never Bring in more (D5). Describes; never instructs (D12).
public enum CPKeepResult: Sendable, Hashable {
    case moved, keptInPlace, stillMoving
    case changesOff, notSetUp, notAFind, moveFailed, needsAttention, unavailable

    /// The find is kept (or its move into the library is under way).
    public var isKept: Bool { self == .moved || self == .keptInPlace || self == .stillMoving }

    public var message: String {
        switch self {
        case .moved: "Kept. It's in your library now."
        case .keptInPlace: "Kept. It'll stay in your Finds folder for now."
        case .stillMoving: "Kept. It's moving into your library."
        case .changesOff: "Keeping is switched off on this iPhone."
        case .notSetUp: "Keeping isn't set up on this iPhone yet."
        case .notAFind: "This one can't be kept from here."
        case .moveFailed: "Couldn't keep it this time. It's still in your Finds."
        case .needsAttention: "Keeping this one didn't finish."
        case .unavailable: "Can't keep it right now."
        }
    }
}

// MARK: - Try it next (search)

/// Whether a not-yet song can be tried from the car, and how.
public enum CPTryOffer: Sendable, Hashable {
    /// Try isn't set up on the phone: the row only says the song isn't in the library.
    case unavailable
    /// Quick or Standard: it goes next in the queue once it's here.
    case next
    /// Patient ("Ask for it", D8): only asked for; it shows up in Finds or the library when it's home.
    case ask(intoFinds: Bool)

    /// D6 in the car: a find never interrupts something playing. With nothing playing, a "Try it next" starts a
    /// library mix seeded by the artist so the find has something to go next after (CarPlay H3).
    public func startsBridge(playing: Bool) -> Bool { self == .next && !playing }
}

/// The action sheet a not-yet row presents: "Try it next" / "Cancel" (CarPlay H3; titles ≤ 16 characters, L4).
public struct CPTrySheet: Sendable, Hashable {
    public static let cancel = "Cancel"

    public var title: String
    public var message: String
    public var confirm: String
}

extension CarPlayRows {
    /// The sheet for `recording`, or nil when Try isn't possible here. Says what will happen, given whether
    /// something is playing now.
    public static func trySheet(_ recording: ExternalRecording, offer: CPTryOffer, playing: Bool) -> CPTrySheet? {
        let by = "By \(display(recording.artist, unknownArtist))."
        let message: String
        let confirm: String
        switch offer {
        case .unavailable:
            return nil
        case .next:
            confirm = "Try it next"
            message = offer.startsBridge(playing: playing)
                ? "\(by) Songs from your library play until it's here, then it goes next."
                : "\(by) It goes next in your queue once it's here."
        case .ask(let intoFinds):
            confirm = "Ask for it"
            message = "\(by) This one is asked for, not played now. It shows up in your \(intoFinds ? "Finds" : "library") when it's home."
        }
        return CPTrySheet(title: display(recording.title, untitled), message: message, confirm: confirm)
    }
}

/// What "Try it next" did.
public enum CPTryResult: Sendable, Hashable {
    /// Patient: asked for only.
    case asked
    /// Something was playing: the find goes next once it's here.
    case queued
    /// Nothing was playing: the library mix started; the find goes next once it's here.
    case bridging
    case failed(CPTryProblem)
}

/// Why Try didn't start. Describes; never instructs (D12).
public enum CPTryProblem: Sendable, Hashable {
    case tooMany, notSetUp, unavailable, other

    public var message: String {
        switch self {
        case .tooMany: "Five songs are already on their way."
        case .notSetUp: "Bringing songs home isn't set up on this iPhone."
        case .unavailable: "Your requests can't be read right now."
        case .other: "That didn't work this time."
        }
    }
}

/// What the car's search found: the library's songs and albums, and songs from outside it ("Not in your library").
public struct CarPlaySearchResult: Sendable, Hashable {
    public var library: LibrarySearchResult
    public var notYet: [ExternalRecording]

    public init(library: LibrarySearchResult, notYet: [ExternalRecording] = []) {
        self.library = library; self.notYet = notYet
    }
}

/// The bridge (CarPlay H3, review D6): a library mix seeded by the tried song's artist that plays while the find
/// comes. Library songs only: the artist's first, then songs from the rest of the library; each song once, finds
/// left out.
public enum BridgeMix {
    public static let limit = 50
    /// Fewer of the artist's songs than this: top up from the rest of the library.
    public static let minimumFromArtist = 10

    public static func songs(artistSongs: [Song], fill: [Song], excluding: Set<String>, limit: Int = BridgeMix.limit,
                             shuffle: (inout [Song]) -> Void = { $0.shuffle() }) -> [Song] {
        var seen = excluding
        func fresh(_ songs: [Song]) -> [Song] { songs.filter { seen.insert($0.id).inserted } }
        var first = fresh(artistSongs)
        var rest = fresh(fill)
        shuffle(&first)
        shuffle(&rest)
        return Array((first + rest).prefix(max(0, limit)))
    }
}
