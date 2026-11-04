import Foundation
import MagpieCore

/// Reads and writes the preference areas, one UserDefaults key each. A missing, corrupt or partly bad area
/// loads as far as it can (`PreferenceArea.decode`); a save writes only the areas that changed.
struct PreferencesStore {
    let defaults: UserDefaults

    init(defaults: UserDefaults) { self.defaults = defaults }

    func load() -> Preferences {
        Preferences(layout: read(), playback: read(), downloads: read(), scrobbling: read(), genres: read(), carPlay: carPlay())
    }

    /// The car's area. Round 14 fix round 1 (I1, D109): when the phone's saved Home predates round 14 (it is about to
    /// be migrated, D106) and the car follows it, the car's list as it was is saved now, once, so the car's Home
    /// doesn't move with the phone's new order.
    private func carPlay() -> CarPlayPreferences {
        let car: CarPlayPreferences = read()
        guard let kept = car.keepingRound13Home(storedLayout: defaults.data(forKey: LayoutPreferences.key)) else { return car }
        write(kept, car)
        return kept
    }

    func save(_ new: Preferences, previous: Preferences) {
        write(new.layout, previous.layout)
        write(new.playback, previous.playback)
        write(new.downloads, previous.downloads)
        write(new.scrobbling, previous.scrobbling)
        write(new.genres, previous.genres)
        write(new.carPlay, previous.carPlay)   // round 13: Settings › CarPlay
    }

    private func read<A: PreferenceArea>() -> A { A.decode(defaults.data(forKey: A.key)) }

    private func write<A: PreferenceArea>(_ new: A, _ previous: A) {
        guard new != previous else { return }
        guard let data = new.encoded() else { return }   // logged by `encoded()`; the old value stays
        defaults.set(data, forKey: A.key)
    }
}
