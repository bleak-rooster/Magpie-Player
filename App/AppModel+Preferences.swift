import Foundation
import MagpieCore

extension AppModel {
    /// The one way to change a preference: applies `change` to a copy, normalises every area, saves the areas that
    /// changed, publishes the result and lets each feature react.
    func updatePreferences(_ change: (inout Preferences) -> Void) {
        let old = preferences
        var new = old
        change(&new)
        new = new.normalised()
        guard new != old else { return }
        preferencesStore.save(new, previous: old)
        preferences = new
        preferencesDidChange(from: old)
    }

    /// The fan-out: one line per feature that reacts to a changed preference (later tasks add theirs here).
    func preferencesDidChange(from old: Preferences) {
        // Only what the upcoming songs are built from: the stream quality now, and ReplayGain.
        let oldQuality = old.playback.quality(for: network.status)
        if currentStreamQuality != oldQuality || preferences.playback.replayGain != old.playback.replayGain {
            qualityBox.set(currentStreamQuality)
            replayGainBox.set(preferences.playback.replayGain)
            player.upcomingURLsChanged()
        }
        // Downloads: a setting may let waiting downloads go (mobile data, a bigger limit); favourites follow the toggle.
        if preferences.downloads != old.downloads { downloads?.retryWaiting() }
        if preferences.downloads.keepFavourites != old.downloads.keepFavourites { keepFavouritesChanged() }
    }
}
