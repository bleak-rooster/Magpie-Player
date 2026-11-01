import MagpieCore
import Playback
import SwiftUI

/// Settings › Downloads & Storage (spec §6): every download preference in the spec's order, "Keep favourites
/// downloaded", the storage used, re-download at the new quality, and remove or clear (each confirmed first).
struct DownloadsSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var usage: AudioUsage?
    @State private var artworkBytes: Int64?
    @State private var confirmsClearArtwork = false
    @State private var confirmsRemoveAll = false
    @State private var confirmsClearCache = false
    @State private var redownloading = false

    static let originalTitle = "Original file (no conversion)"
    static let formatFooter = "Original saves each song exactly as it is on your server. The other choices convert it on your server first, which uses less space."

    private func binding<V>(_ keyPath: WritableKeyPath<DownloadPreferences, V>) -> Binding<V> {
        Binding(get: { model.preferences.downloads[keyPath: keyPath] },
                set: { value in model.updatePreferences { $0.downloads[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            // P1: hidden when nothing is downloading.
            let active = model.downloadActivityCount
            if active > 0 {
                Section {
                    NavigationLink { DownloadingNowView() } label: {
                        Label(DownloadActivityCopy.row(active), systemImage: "arrow.down.circle.dotted")
                    }
                    .accessibilityIdentifier("settings-downloading-now")
                }
            }
            Section {
                StreamQualityPicker(title: "Download format", selection: binding(\.quality), originalTitle: Self.originalTitle)
            } footer: {
                Text(Self.formatFooter)
            }
            Section {
                Toggle("Download on mobile data", isOn: binding(\.overMobileData))
                Picker("Downloads at the same time", selection: binding(\.concurrent)) {
                    ForEach(DownloadPreferences.concurrentRange, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Pre-download upcoming songs", selection: binding(\.preDownload)) {
                    ForEach(0...10, id: \.self) { Text(Self.aheadTitle($0)).tag($0) }
                }
                Toggle(Self.backgroundTitle, isOn: binding(\.downloadInBackground))
                    .accessibilityIdentifier("download-in-background")
                Toggle("Keep screen on while downloading", isOn: binding(\.keepScreenOn))
                    .accessibilityIdentifier("keep-screen-on")
                Toggle("Keep recently played songs", isOn: binding(\.keepRecentlyPlayed))
                Picker("Cache limit", selection: binding(\.cacheLimit)) {
                    ForEach(CacheLimit.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
                Picker("Downloads limit", selection: binding(\.downloadsLimit)) {
                    ForEach(DownloadsLimit.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
                Picker("Offline mode", selection: binding(\.offlineMode)) {
                    ForEach(OfflineMode.allCases, id: \.self) { Text(Self.title($0)).tag($0) }
                }
            } footer: {
                Text(Self.footer(inBackground: model.preferences.downloads.downloadInBackground))
            }
            Section {
                Toggle("Keep favourites downloaded", isOn: binding(\.keepFavourites))
            }
            Section("Storage") {
                LabeledContent("Used", value: usage.map(Self.usageText) ?? "…")
                    .accessibilityIdentifier("storage-used")
                Button(redownloading ? "Re-downloading…" : "Re-download in this format") {
                    redownloading = true
                    Task {
                        await model.redownloadAtCurrentQuality()
                        await model.downloads?.settled()
                        await readUsage()
                        redownloading = false
                    }
                }
                .disabled(redownloading)
                Button("Remove all downloads", role: .destructive) { confirmsRemoveAll = true }
                    .confirmationDialog("Remove all downloads?", isPresented: $confirmsRemoveAll, titleVisibility: .visible) {
                        Button("Remove all downloads", role: .destructive) {
                            Task { await model.removeAllDownloads(); await readUsage() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Downloaded songs leave this phone, and Keep favourites downloaded turns off. They stay on your server.")
                    }
                Button("Clear cache", role: .destructive) { confirmsClearCache = true }
                    .confirmationDialog("Clear cache?", isPresented: $confirmsClearCache, titleVisibility: .visible) {
                        Button("Clear cache", role: .destructive) {
                            Task { await model.clearCache(); await readUsage() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Pre-downloaded and recently played songs leave this phone. Downloads stay.")
                    }
            }
            Section {
                Text(artworkBytes.map(Self.artworkText) ?? "Artwork \u{00B7} …")
                    .accessibilityIdentifier("artwork-used")
                Button("Clear artwork cache", role: .destructive) { confirmsClearArtwork = true }
                    .accessibilityIdentifier("clear-artwork")
                    .confirmationDialog("Clear artwork cache?", isPresented: $confirmsClearArtwork, titleVisibility: .visible) {
                        Button("Clear artwork cache", role: .destructive) {
                            Task { await model.clearArtworkCache(); await readUsage() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text(Self.clearArtworkMessage)
                    }
            } footer: {
                Text("Covers and artist pictures stay on this phone until you clear them.")
            }
        }
        .navigationTitle("Downloads & Storage")
        .navigationBarTitleDisplayMode(.inline)
        .task { await readUsage() }
    }

    private func readUsage() async {
        usage = await model.storageUsage
        artworkBytes = await model.artworkUsage
    }

    static let backgroundTitle = "Download in the background"

    /// The settings footer: the Wi-Fi rule, then whether downloads go on with Magpie closed (R1).
    static func footer(inBackground: Bool) -> String {
        "Without mobile data, downloads wait for Wi-Fi. Upcoming songs are saved ahead on any network. "
            + (inBackground ? "Downloads go on when Magpie is closed or your phone is locked, and pick up where they stopped."
                            : "Downloads only go on while Magpie is open.")
    }

    static let clearArtworkMessage = "Covers load again from your server when you next see them. Covers of downloaded albums stay."

    // MARK: - Copy

    /// The one-line summary on the Settings row, e.g. "Original · 2 GB cache · 3 ahead".
    static func summary(_ prefs: DownloadPreferences) -> String {
        "\(formatTitle(prefs.quality)) · \(title(prefs.cacheLimit)) cache · \(prefs.preDownload == 0 ? "none" : String(prefs.preDownload)) ahead"
    }

    /// "Original", or the codec and bitrate ("AAC 256 kbps").
    static func formatTitle(_ quality: StreamQuality) -> String { quality.shortTitle }

    /// "Downloads 1.2 GB · Cache 340 MB".
    static func usageText(_ usage: AudioUsage) -> String {
        "Downloads \(bytes(usage.downloadBytes)) · Cache \(bytes(usage.cacheBytes))"
    }

    /// "Artwork · 84 MB".
    static func artworkText(_ count: Int64) -> String { "Artwork \u{00B7} \(bytes(count))" }

    static func bytes(_ count: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: count)
    }

    static func aheadTitle(_ count: Int) -> String { count == 0 ? "None" : "\(count)" }

    static func title(_ limit: CacheLimit) -> String {
        switch limit {
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        case .gb2: "2 GB"
        case .gb5: "5 GB"
        case .gb10: "10 GB"
        }
    }

    static func title(_ limit: DownloadsLimit) -> String {
        switch limit {
        case .none: "None"
        case .gb5: "5 GB"
        case .gb10: "10 GB"
        case .gb20: "20 GB"
        case .gb50: "50 GB"
        }
    }

    static func title(_ mode: OfflineMode) -> String {
        switch mode {
        case .automatic: "Automatic"
        case .on: "On"
        case .off: "Off"
        }
    }
}
