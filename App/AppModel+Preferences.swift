import Foundation
import MagpieCore
#if os(iOS)
import UIKit
#endif

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

    /// Whether protected data (UserDefaults included) is readable: `given` in tests, otherwise UIApplication's answer.
    static func protectedDataAvailable(_ given: Bool?) -> Bool {
        if let given { return given }
        #if os(iOS)
        return UIApplication.shared.isProtectedDataAvailable
        #else
        return true
        #endif
    }

    /// After a launch before first unlock (from the car), once only: UserDefaults couldn't be read, so the app started
    /// with the defaults. Each area the app hasn't changed since takes what the owner saved; an area changed in memory
    /// meanwhile keeps that change (and is saved now). Every feature reacts as to any change.
    func reloadPreferences() {
        guard let launch = preferencesReadLocked else { return }
        preferencesReadLocked = nil
        let old = preferences
        let saved = preferencesStore.load()
        var merged = saved
        if old.layout != launch.layout { merged.layout = old.layout }
        if old.playback != launch.playback { merged.playback = old.playback }
        if old.downloads != launch.downloads { merged.downloads = old.downloads }
        if old.scrobbling != launch.scrobbling { merged.scrobbling = old.scrobbling }
        if old.genres != launch.genres { merged.genres = old.genres }
        merged = merged.normalised()
        preferencesStore.save(merged, previous: saved)
        guard merged != old else { return }
        preferences = merged
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
            if currentStreamQuality != oldQuality { cacheQualityTargetChanged() }   // round 13 item 7
        }
        if preferences.scrobbling != old.scrobbling { scrobbleSettings.set(preferences.scrobbling) }
        // Downloads: a setting may let waiting downloads go (mobile data, a bigger limit); favourites follow the toggle.
        let new = preferences.downloads, was = old.downloads
        if new.overMobileData != was.overMobileData || new.downloadsLimit != was.downloadsLimit
            || new.concurrent != was.concurrent || new.quality != was.quality { downloads?.retryWaiting() }
        // R1: mobile data off stops what may no longer use it (it resumes later); the background rule applies at once.
        if new.overMobileData != was.overMobileData || new.downloadInBackground != was.downloadInBackground {
            downloads?.downloadSettingsChanged()
        }
        if preferences.downloads.keepFavourites != old.downloads.keepFavourites { keepFavouritesChanged() }
        if new.preDownload != was.preDownload { applyEngineWindow() }
        if new.offlineMode != was.offlineMode { offlineInputsChanged() }
    }
}
