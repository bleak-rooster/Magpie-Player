import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// An album's or playlist's download: "Download" until every song is downloaded with this album or playlist, then
/// its status (D3: text plus symbol) with "Remove download" ("Cancel download" while it downloads or waits). Songs
/// already on the phone for other reasons get a footnote. A 44 pt target; VoiceOver reads "Download" and the status.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let songs: [Song]
    var playlist: DownloadedPlaylist?
    var coverArtId: String?
    private let themed = Themed()

    var body: some View {
        let ids = songs.map(\.id)
        let status = model.downloadStatus(ids, reason: reason)
        VStack(spacing: Tokens.Spacing.xs) {
            control(status)
                .accessibilityLabel("Download")
                .accessibilityValue(status.text)
                .accessibilityIdentifier("download")
            if let note = model.alreadyOnPhoneNote(ids, reason: reason) {
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(themed.palette.ink2Color)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("download-note")
            }
        }
    }

    @ViewBuilder private func control(_ status: DownloadStatus) -> some View {
        if status == .none {
            CapsuleButton("Download", symbol: "arrow.down.to.line") { start() }
                .disabled(songs.isEmpty)
        } else {
            Menu {
                if status == .failed || status == .full {
                    Button("Try again", systemImage: "arrow.clockwise") { model.retryDownloads() }
                }
                if case .partial = status {
                    Button("Download the rest", systemImage: "arrow.down.to.line") { start() }
                }
                Button(Self.removeTitle(status), systemImage: "trash", role: .destructive) {
                    Task { await model.removeDownload(reason) }
                }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: status.symbol)
                    Text(status.text).lineLimit(2)
                }
                .font(.footnote.weight(.semibold))
                .foregroundStyle(themed.palette.accentInkColor)
                .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                .contentShape(Rectangle())
            }
        }
    }

    /// "Cancel download" while songs are still on their way; "Remove download" otherwise.
    static func removeTitle(_ status: DownloadStatus) -> String {
        switch status {
        case .downloading, .waitingForWiFi, .waitingForConnection: "Cancel download"
        default: "Remove download"
        }
    }

    private func start() {
        var snapshot = playlist
        snapshot?.savedAt = .now
        model.download(songs, reason: reason, playlist: snapshot, coverArtId: coverArtId)
    }
}

/// "Download" or "Remove from this phone" in a song's context menu. Removing asks first (`songRemovalDialog`).
struct SongDownloadMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song
    @Binding var removing: Song?

    var body: some View {
        switch model.downloadStatus([song.id]) {
        case .none:
            Button("Download", systemImage: "arrow.down.to.line") { model.download([song], reason: .song) }
        case .downloaded:
            Button("Remove from this phone", systemImage: "trash", role: .destructive) { removing = song }
        default:   // not on the phone, but on its way, waiting, full or failed
            Button("Cancel download", systemImage: "xmark") { Task { await model.removeSongDownload(song.id) } }
        }
    }
}

extension View {
    /// The confirmation for a song's "Remove from this phone", saying when it's kept for more than itself.
    func songRemovalDialog(_ removing: Binding<Song?>) -> some View {
        modifier(SongRemovalDialog(removing: removing))
    }
}

private struct SongRemovalDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var removing: Song?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(removing?.title ?? "this song") from this phone?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { song in
            Button("Remove from this phone", role: .destructive) {
                Task { await model.removeSongDownload(song.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { song in
            Text(model.songRemovalNote(song.id) ?? "It stays on your server.")
        }
    }
}
