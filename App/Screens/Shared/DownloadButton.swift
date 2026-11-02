import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// An album's or playlist's download, as the page's ActionBar item (Y7): "Download" until every song is downloaded
/// with this album or playlist, then its status (D3: text plus symbol) in the same capsule, opening a menu with
/// "Remove download" ("Cancel download" while it downloads or waits). A 44 pt target; VoiceOver reads "Download" and
/// the status. Songs already on the phone for other reasons get a footnote: `DownloadNote`, under the bar.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let songs: [Song]
    var playlist: DownloadedPlaylist?
    var coverArtId: String?

    var body: some View {
        DownloadControl(status: model.downloadStatus(songs.map(\.id), reason: reason), canStart: !songs.isEmpty,
                        start: start, retry: { model.retryDownloads() },
                        remove: { Task { await model.removeDownload(reason) } })
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

/// The footnote under the action bar when some of the songs are already on the phone for other reasons.
struct DownloadNote: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let songs: [Song]
    private let themed = Themed()

    var body: some View {
        if let note = model.alreadyOnPhoneNote(songs.map(\.id), reason: reason) {
            Text(note)
                .font(.footnote)
                .foregroundStyle(themed.palette.ink2Color)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Tokens.Spacing.margin)
                .accessibilityIdentifier("download-note")
        }
    }
}

/// The Download capsule for a status: the same tinted capsule in every state, so the bar never shifts (Y7). Before a
/// download it's a button; after, its status opens the menu (Try again, Download the rest, Cancel/Remove download).
struct DownloadControl: View {
    let status: DownloadStatus
    let canStart: Bool
    let start: () -> Void
    let retry: () -> Void
    let remove: () -> Void

    var body: some View {
        control
            .accessibilityLabel("Download")
            .accessibilityValue(status.text)
            .accessibilityIdentifier("download")
    }

    @ViewBuilder private var control: some View {
        if status == .none {
            Button(action: start) { ActionCapsule("Download", symbol: "arrow.down.to.line") }
                .buttonStyle(ActionPressStyle())
                .disabled(!canStart)
        } else {
            Menu {
                if status == .failed || status == .full {
                    Button("Try again", systemImage: "arrow.clockwise", action: retry)
                }
                if case .partial = status {
                    Button("Download the rest", systemImage: "arrow.down.to.line", action: start)
                }
                Button(DownloadButton.removeTitle(status), systemImage: "trash", role: .destructive, action: remove)
            } label: {
                ActionCapsule(status.text, symbol: status.symbol, progress: Self.progress(status))
            }
            .buttonStyle(ActionPressStyle())
        }
    }

    /// The done part of the capsule while songs are on their way or partly here.
    static func progress(_ status: DownloadStatus) -> Double? {
        switch status {
        case let .downloading(done, total), let .partial(done, total):
            total > 0 ? Double(done) / Double(total) : nil
        default: nil
        }
    }
}

/// "Download" or "Remove download" in a song's context menu (glossary §9). Removing asks first (`songRemovalDialog`).
struct SongDownloadMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song
    @Binding var removing: Song?

    static let removeTitle = "Remove download"

    var body: some View {
        // The UX appraisal's menu order (§4): Add to playlist… · Favourite, then Download.
        Section { SongLibraryMenuItems(song: song) }   // R7, R8
        Section { downloadItem }
    }

    @ViewBuilder private var downloadItem: some View {
        switch model.downloadStatus([song.id]) {
        case .none:
            Button("Download", systemImage: "arrow.down.to.line") { model.download([song], reason: .song) }
        case .downloaded:
            Button(Self.removeTitle, systemImage: "trash", role: .destructive) { removing = song }
        default:   // not on the phone, but on its way, waiting, full or failed
            Button("Cancel download", systemImage: "xmark") { Task { await model.removeSongDownload(song.id) } }
        }
    }
}

extension View {
    /// The confirmation for a song's "Remove download", saying when it's kept for more than itself.
    func songRemovalDialog(_ removing: Binding<Song?>) -> some View {
        modifier(SongRemovalDialog(removing: removing))
    }
}

private struct SongRemovalDialog: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var removing: Song?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove \(removing?.title ?? "this song") from this iPhone?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible, presenting: removing
        ) { song in
            Button(SongDownloadMenuItem.removeTitle, role: .destructive) {
                Task { await model.removeSongDownload(song.id) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { song in
            Text(model.songRemovalNote(song.id) ?? "It stays on your server.")
        }
    }
}
