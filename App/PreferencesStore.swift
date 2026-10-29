import Foundation
import MagpieCore

/// Reads and writes the five preference areas, one UserDefaults key each. A missing, corrupt or partly bad area
/// loads as far as it can (`PreferenceArea.decode`); a save writes only the areas that changed.
struct PreferencesStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> Preferences {
        Preferences(layout: read(), playback: read(), downloads: read(), scrobbling: read(), genres: read())
    }

    func save(_ new: Preferences, previous: Preferences) {
        write(new.layout, previous.layout)
        write(new.playback, previous.playback)
        write(new.downloads, previous.downloads)
        write(new.scrobbling, previous.scrobbling)
        write(new.genres, previous.genres)
    }

    private func read<A: PreferenceArea>() -> A { A.decode(defaults.data(forKey: A.key)) }

    private func write<A: PreferenceArea>(_ new: A, _ previous: A) {
        guard new != previous else { return }
        guard let data = new.encoded() else { return }   // logged by `encoded()`; the old value stays
        defaults.set(data, forKey: A.key)
    }
}
