import Foundation
import MagpieCore

/// One slot in the play queue. The same song may appear many times; each slot has its own `id`.
public struct QueueEntry: Identifiable, Hashable, Codable, Sendable {
    public let id: UUID
    public let song: Song

    public init(id: UUID = UUID(), song: Song) {
        self.id = id; self.song = song
    }
}

/// The play queue: a `main` list (history, current, rest) plus an `upNext` list that plays before
/// the rest of `main`. When an Up Next entry starts playing it moves into `main` right after the
/// previous current entry, so `main[..<currentIndex]` is always what has played, in order.
public struct PlayQueue: Codable, Sendable {
    public private(set) var upNext: [QueueEntry] = []
    public private(set) var main: [QueueEntry] = []
    public private(set) var currentIndex: Int?

    public init() {}

    public var current: QueueEntry? { currentIndex.map { main[$0] } }

    /// What plays after `current`, in order: Up Next, then the rest of `main`.
    public var upcoming: [QueueEntry] {
        let rest = currentIndex.map { Array(main[($0 + 1)...]) } ?? []
        return upNext + rest
    }

    public mutating func replace(with songs: [Song], startAt: Int) {
        main = songs.map { QueueEntry(song: $0) }
        upNext = []
        currentIndex = main.isEmpty ? nil : min(max(startAt, 0), main.count - 1)
    }

    /// Puts `songs` at the front of Up Next (ahead of anything already there). Starts an idle queue.
    public mutating func playNext(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard currentIndex != nil else { return startIdle(with: songs) }
        upNext.insert(contentsOf: songs.map { QueueEntry(song: $0) }, at: 0)
    }

    /// Appends `songs` to the end of `main`. Starts an idle queue.
    public mutating func addToEnd(_ songs: [Song]) {
        guard !songs.isEmpty else { return }
        guard currentIndex != nil else { return startIdle(with: songs) }
        main.append(contentsOf: songs.map { QueueEntry(song: $0) })
    }

    private mutating func startIdle(with songs: [Song]) {
        let first = main.count
        main.append(contentsOf: songs.map { QueueEntry(song: $0) })
        currentIndex = first
    }

    /// Moves to the next entry and returns it, or returns nil (leaving `current` as is) at the end.
    @discardableResult
    public mutating func advance() -> QueueEntry? {
        guard let i = currentIndex else { return nil }
        if !upNext.isEmpty {
            main.insert(upNext.removeFirst(), at: i + 1)
        } else if i + 1 >= main.count {
            return nil
        }
        currentIndex = i + 1
        return current
    }

    /// Moves to the previous entry and returns it, or returns nil at the start.
    @discardableResult
    public mutating func back() -> QueueEntry? {
        guard let i = currentIndex, i > 0 else { return nil }
        currentIndex = i - 1
        return current
    }

    /// Removes an entry. Removing the current entry makes the next one current (Up Next first);
    /// when nothing follows, the queue goes idle (`current == nil`).
    public mutating func remove(id: UUID) {
        if let u = upNext.firstIndex(where: { $0.id == id }) {
            upNext.remove(at: u)
            return
        }
        guard let m = main.firstIndex(where: { $0.id == id }) else { return }
        main.remove(at: m)
        guard let i = currentIndex else { return }
        if m < i {
            currentIndex = i - 1
        } else if m == i {
            if !upNext.isEmpty {
                main.insert(upNext.removeFirst(), at: i)
            } else if i >= main.count {
                currentIndex = nil
            }
        }
    }

    /// Moves an upcoming entry to position `index` within `upcoming`. Positions inside the Up Next
    /// range land in Up Next; later positions land in `main`; at the seam an entry keeps its list.
    /// Current and played entries don't move.
    public mutating func move(id: UUID, to index: Int) {
        guard let i = currentIndex else { return }
        let entry: QueueEntry
        let fromUpNext: Bool
        if let u = upNext.firstIndex(where: { $0.id == id }) {
            entry = upNext.remove(at: u); fromUpNext = true
        } else if let m = main.firstIndex(where: { $0.id == id }), m > i {
            entry = main.remove(at: m); fromUpNext = false
        } else {
            return
        }
        let target = min(max(index, 0), upNext.count + (main.count - i - 1))
        // At the seam between the two lists, an entry stays in the list it came from.
        if target < upNext.count || (target == upNext.count && fromUpNext) {
            upNext.insert(entry, at: target)
        } else {
            main.insert(entry, at: i + 1 + (target - upNext.count))
        }
    }

    /// Drops everything that would play after the current entry (Up Next and the rest of `main`).
    public mutating func clearUpcoming() {
        upNext = []
        guard let i = currentIndex else { return }
        main.removeSubrange((i + 1)...)
    }

    /// Makes the first entry of `main` current (repeat all) and returns it.
    @discardableResult
    public mutating func wrapToStart() -> QueueEntry? {
        guard !main.isEmpty else { return nil }
        currentIndex = 0
        return current
    }

    /// Puts `main` back in the order of `order` (entry ids); entries not listed keep their relative
    /// order after the listed ones. The current entry stays current.
    public mutating func restoreOrder(_ order: [UUID]) {
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let currentId = current?.id
        main = main.enumerated().sorted { a, b in
            let ra = rank[a.element.id] ?? Int.max, rb = rank[b.element.id] ?? Int.max
            return ra != rb ? ra < rb : a.offset < b.offset
        }.map(\.element)
        if let currentId { currentIndex = main.firstIndex { $0.id == currentId } }
    }

    /// Shuffles `main` deterministically for `seed`, keeping the current entry first and current.
    /// Up Next keeps its order.
    public mutating func shuffle(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        if let i = currentIndex {
            let cur = main.remove(at: i)
            main.shuffle(using: &rng)
            main.insert(cur, at: 0)
            currentIndex = 0
        } else {
            main.shuffle(using: &rng)
        }
    }
}

/// Small seedable generator so a shuffle can be reproduced (tests, restored sessions).
struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
