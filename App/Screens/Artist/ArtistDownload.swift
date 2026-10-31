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
    static let more = "More"

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
    /// R4: the artist's ⋯ (toolbar) with "Download to this iPhone…" / "Remove download", its confirmation, and a
    /// status line while the download is on its way or stuck.
    func artistDownload(artist: Artist, albums: [Album]) -> some View {
        modifier(ArtistDownload(artist: artist, albums: albums))
    }
}

/// An artist's download (R4): every album of theirs, fetched at the tap and confirmed with the count and the size when
/// known, downloaded with `.artist(id)` so the artist's mark shows it and "Remove download" takes it off as a group.
/// Albums added later aren't included. Storage limit and Wi-Fi rules apply as to any download.
struct ArtistDownload: ViewModifier {
    @Environment(AppModel.self) private var model
    let artist: Artist
    let albums: [Album]
    @State private var gathering = false
    @State private var plan: Plan?
    @State private var error: String?
    private let themed = Themed()

    /// What the confirmation offers: each album's songs.
    struct Plan: Identifiable {
        let id = UUID()
        var albums: [(album: Album, songs: [Song])]
        var count: Int { albums.reduce(0) { $0 + $1.songs.count } }
    }

    func body(content: Content) -> some View {
        let status = model.downloads?.artistStatus(artist.id) ?? .none
        VStack(spacing: Tokens.Spacing.xs) {
            content
            statusLine(status)
        }
        .toolbar {
            // No ⋯ when it would open empty (offline with nothing downloaded): no dead taps (§10).
            if status != .none || !model.isOffline {
                ToolbarItem(placement: .topBarTrailing) { menu(status) }
            }
        }
        .confirmationDialog(plan.map { ArtistDownloadCopy.title(count: $0.count) } ?? "",
                            isPresented: Binding(get: { plan != nil }, set: { if !$0 { plan = nil } }),
                            titleVisibility: .visible, presenting: plan) { plan in
            Button(ArtistDownloadCopy.confirm) { start(plan) }
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
        if gathering {
            Label("Loading\u{2026}", systemImage: "arrow.down.circle.dotted")
                .font(.footnote).foregroundStyle(p.ink2Color)
        } else if let error {
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

    private func menu(_ status: DownloadStatus) -> some View {
        Menu {
            if status == .none {
                Button(ArtistDownloadCopy.action, systemImage: "arrow.down.circle") { Task { await gather() } }
                    .disabled(albums.isEmpty || gathering)
                    .accessibilityIdentifier("artist-download-all")
            } else {
                Button(ArtistDownloadCopy.remove, systemImage: "trash", role: .destructive) {
                    Task { await model.removeDownload(.artist(artist.id)) }
                }
                .accessibilityIdentifier("artist-remove-download")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel(ArtistDownloadCopy.more)
        }
        .accessibilityIdentifier("artist-more")
    }

    /// Every album's songs (in parallel), then the confirmation.
    private func gather() async {
        gathering = true
        error = nil
        defer { gathering = false }
        let list = albums
        do {
            let songs = try await model.request { client in
                try await withThrowingTaskGroup(of: (Int, [Song]).self) { group in
                    for (i, album) in list.enumerated() {
                        group.addTask { (i, try await client.album(id: album.id).songs ?? []) }
                    }
                    var byIndex: [Int: [Song]] = [:]
                    for try await (i, songs) in group { byIndex[i] = songs }
                    return list.indices.map { byIndex[$0] ?? [] }
                }
            }
            let albums = zip(list, songs).map { (album: $0, songs: $1) }.filter { !$0.songs.isEmpty }
            guard !albums.isEmpty else { return }
            plan = Plan(albums: albums)
        } catch {
            self.error = BrowseErrorCopy.message(for: error)
            AccessibilityNotification.Announcement(self.error ?? "").post()
        }
    }

    private func start(_ plan: Plan) {
        for entry in plan.albums {
            model.download(entry.songs, reason: .artist(artist.id), coverArtId: entry.album.coverArtId)
        }
    }
}
