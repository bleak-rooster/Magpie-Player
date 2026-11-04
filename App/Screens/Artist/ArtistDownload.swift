import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// The copy and size estimate for an artist's download (R4, as ruled by R20: the appraisal's ⋯ → "Download to this
/// iPhone…", which says where the songs go; §5 voice and the glossary's "Download" / "Remove download").
enum ArtistDownloadCopy {
    static let action = "Download to this iPhone\u{2026}"
    static let confirm = "Download"
    static let remove = "Remove download"

    /// "Download 143 songs to this iPhone?"
    static func title(count: Int) -> String {
        "Download \(count) \(count == 1 ? "song" : "songs") to this iPhone?"
    }

    /// "About 1.2 GB."; nil when the size isn't known.
    static func message(bytes: Int64?) -> String? {
        guard let bytes, bytes > 0 else { return nil }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "About \(formatter.string(fromByteCount: bytes))."
    }

    /// The ⋯ item: download, or remove once there's anything (removing one still on its way stops it too).
    static func menuTitle(_ status: DownloadStatus) -> String { status == .none ? action : remove }

    /// Bit rate × duration, summed: the song's own rate for Original, the format's when converting. Nil when any song's
    /// rate isn't known (an estimate that leaves songs out would mislead).
    static func estimate(_ songs: [Song], quality: StreamQuality) -> Int64? {
        var total: Int64 = 0
        for song in songs {
            guard let kbps = quality.maxBitRate ?? song.bitRate, kbps > 0 else { return nil }
            total += Int64(Double(kbps) * 1000 / 8 * song.duration)
        }
        return songs.isEmpty ? nil : total
    }
}

extension View {
    /// R4: the artist download's confirmation, and a status line while it is on its way or stuck. Its ⋯ items
    /// (`ArtistDownloadMenuItems`) live in the page's one ⋯ (`PageMoreMenu`).
    func artistDownload(_ state: ArtistDownloadState, artist: Artist) -> some View {
        modifier(ArtistDownload(state: state, artist: artist))
    }
}

/// An artist's download (R4): every album of theirs, fetched at the tap and confirmed with the count and the size when
/// known, downloaded with `.artist(id)` so the artist's mark shows it and "Remove download" takes it off as a group.
/// Albums added later aren't included. Storage limit and Wi-Fi rules apply as to any download.
@MainActor @Observable final class ArtistDownloadState {
    var gathering = false
    var plan: Plan?
    var error: String?

    /// What the confirmation offers: each album's songs.
    struct Plan: Identifiable {
        let id = UUID()
        var albums: [(album: Album, songs: [Song])]
        var count: Int { albums.reduce(0) { $0 + $1.songs.count } }
    }

    /// Every album's songs (in parallel), then the confirmation.
    func gather(_ model: AppModel, albums list: [Album]) async {
        gathering = true
        error = nil
        defer { gathering = false }
        do {
            let songs = try await model.request { client in
                // B1 fix round (D120): answers by album id, never by position.
                let byId = try await KeyedGather.values(list.map(\.id)) { id in try await client.album(id: id).songs ?? [] }
                return list.map { byId[$0.id] ?? [] }
            }
            let albums = zip(list, songs).map { (album: $0, songs: $1) }.filter { !$0.songs.isEmpty }
            guard !albums.isEmpty else { return }
            plan = Plan(albums: albums)
        } catch {
            self.error = BrowseErrorCopy.message(for: error)
            AccessibilityNotification.Announcement(self.error ?? "").post()
        }
    }

    func start(_ plan: Plan, artistId: String, model: AppModel) {
        for entry in plan.albums {
            model.download(entry.songs, reason: .artist(artistId), coverArtId: entry.album.coverArtId)
        }
    }
}

/// The artist's ⋯ items (R4 as ruled by R20): "Download to this iPhone…", or "Remove download" once there's anything
/// (removing one still on its way stops it too). Nothing to offer offline before a download.
struct ArtistDownloadMenuItems: View {
    @Environment(AppModel.self) private var model
    let state: ArtistDownloadState
    let artist: Artist
    let albums: [Album]

    var body: some View {
        let status = model.downloads?.artistStatus(artist.id) ?? .none
        if status == .none {
            if !model.isOffline {
                Button(ArtistDownloadCopy.action, systemImage: "arrow.down.circle") {
                    Task { await state.gather(model, albums: albums) }
                }
                .disabled(albums.isEmpty || state.gathering)
                .accessibilityIdentifier("artist-download-all")
            }
        } else {
            Button(ArtistDownloadCopy.remove, systemImage: "trash", role: .destructive) {
                Task { await model.removeDownload(.artist(artist.id)) }
            }
            .accessibilityIdentifier("artist-remove-download")
        }
    }
}

struct ArtistDownload: ViewModifier {
    @Environment(AppModel.self) private var model
    @Bindable var state: ArtistDownloadState
    let artist: Artist
    private let themed = Themed()

    func body(content: Content) -> some View {
        let status = model.downloads?.artistStatus(artist.id) ?? .none
        VStack(spacing: Tokens.Spacing.xs) {
            content
            statusLine(status)
        }
        .confirmationDialog(state.plan.map { ArtistDownloadCopy.title(count: $0.count) } ?? "",
                            isPresented: Binding(get: { state.plan != nil }, set: { if !$0 { state.plan = nil } }),
                            titleVisibility: .visible, presenting: state.plan) { plan in
            Button(ArtistDownloadCopy.confirm) { state.start(plan, artistId: artist.id, model: model) }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            if let message = ArtistDownloadCopy.message(bytes: ArtistDownloadCopy.estimate(
                plan.albums.flatMap(\.songs), quality: model.preferences.downloads.quality)) {
                Text(message)
            }
        }
    }

    /// While on its way, waiting or stuck (the artist's mark already says Downloaded / Partly downloaded).
    @ViewBuilder private func statusLine(_ status: DownloadStatus) -> some View {
        let p = themed.palette
        if state.gathering {
            Label("Loading\u{2026}", systemImage: "arrow.down.circle.dotted")
                .font(.footnote).foregroundStyle(p.ink2Color)
        } else if let error = state.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(p.ink2Color)
        } else if status != .none, status != .downloaded {
            HStack(spacing: Tokens.Spacing.s) {
                Label(status.text, systemImage: status.symbol)
                    .font(.footnote).foregroundStyle(p.ink2Color)
                if status == .failed || status == .full {
                    Button("Try again") { model.retryDownloads() }
                        .font(.footnote.weight(.semibold))
                        .frame(minHeight: Tokens.minHitSize)
                }
            }
            .accessibilityIdentifier("artist-download-status")
        }
    }
}
