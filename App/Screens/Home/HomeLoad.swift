import MagpieCore

/// What Home has read, and what a change needs read next (Task 20; Task 21 moved it out of `HomeView` to test it).
/// A section counts as read only once it answered: one that failed is read again on the next change, and says
/// "Couldn't load" until then unless an earlier shelf of it is still on screen.
struct HomeLoad: Equatable {
    /// What a read depends on. The songs on the phone count only while Downloaded shows, the genre preferences only
    /// while Genres shows.
    struct Key: Hashable {
        var sections: [HomeSection]
        var offline: Bool
        var onPhone: Int?
        var genres: GenrePreferences?

        static func make(sections: [HomeSection], offline: Bool, onPhone: Int?, genres: GenrePreferences) -> Key {
            Key(sections: sections, offline: offline, onPhone: sections.contains(.downloaded) ? onPhone : nil,
                genres: sections.contains(.genres) ? genres : nil)
        }
    }

    /// The sections one read asks for, and the read sections it keeps.
    struct Read: Equatable {
        var sections: [HomeSection]
        var kept: Set<HomeSection>
        /// Everything again: asked for (pull to refresh), the first read, or offline or back online.
        var fresh: Bool
    }

    /// The shelves read so far, by section; a section read with nothing in it has none.
    private(set) var found: [HomeSection: HomeShelf] = [:]
    /// Sections whose last read failed.
    private(set) var failed: Set<HomeSection> = []
    /// Sections read (with or without tiles) for `key`.
    private(set) var done: Set<HomeSection> = []
    private(set) var key: Key?

    init() {}

    /// Home's saved shelves (P5): on screen at once, none of them read yet, so the first read reads everything.
    init(cached shelves: [HomeShelf]) {
        for shelf in shelves { found[shelf.section] = shelf }
    }

    /// What a read for `want` asks for: the sections not read yet (all of them when fresh), Downloaded again when the
    /// songs on the phone changed, Genres again when the genre preferences changed. Made for you has its own shelf.
    func read(for want: Key, fresh: Bool) -> Read {
        let fresh = fresh || key == nil || want.offline != key?.offline
        var kept = fresh ? [] : done
        if want.onPhone != key?.onPhone { kept.remove(.downloaded) }
        if want.genres != key?.genres { kept.remove(.genres) }
        return Read(sections: want.sections.filter { $0 != .madeForYou && !kept.contains($0) }, kept: kept, fresh: fresh)
    }

    /// Records what `read` found. A failed section keeps any shelf already on screen and isn't marked read. An
    /// `unread` section (its read was cut short, P5) is left as it was: its shelf stays, it isn't read, and it isn't
    /// a failure.
    mutating func record(_ read: Read, for want: Key, shelves: [HomeShelf], failed newlyFailed: Set<HomeSection>,
                         unread: Set<HomeSection> = []) {
        if read.fresh {
            found = found.filter { want.sections.contains($0.key) }
            failed = []
        }
        let answered = read.sections.filter { !unread.contains($0) }
        for section in answered where !newlyFailed.contains(section) { found[section] = nil }
        for shelf in shelves { found[shelf.section] = shelf }
        failed = failed.subtracting(answered).union(newlyFailed)
        done = read.kept.union(answered).subtracting(newlyFailed)
        key = want
    }

    /// Round 13 Z2: `sections` count as not read (what they show changed elsewhere): the next read asks for them
    /// again. Their shelves stay on screen meanwhile.
    mutating func forget(_ sections: Set<HomeSection>) {
        done.subtract(sections)
    }

    /// Round 13 Z2 (review M5): `sections`' shelves go too (they belong to someone else now) and are read again.
    mutating func drop(_ sections: Set<HomeSection>) {
        for section in sections { found[section] = nil }
        done.subtract(sections)
        failed.subtract(sections)
    }

    /// Whether a read for `want` would still ask for something: a section that failed, or one not read yet (P5).
    func needsRead(_ want: Key) -> Bool { !read(for: want, fresh: false).sections.isEmpty }

    /// Whether `section` shows "Couldn't load": its read failed and no earlier shelf of it is on screen.
    func showsFailure(_ section: HomeSection) -> Bool { failed.contains(section) && found[section] == nil }
}
