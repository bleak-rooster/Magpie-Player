import DesignSystem
import MagpieCore
import Playback
import SwiftUI

/// An album's or playlist's download: "Download" while nothing is on the phone, then its status (D3: text plus
/// symbol) with "Remove download". A 44 pt target; VoiceOver reads "Download" and the status.
struct DownloadButton: View {
    @Environment(AppModel.self) private var model
    let reason: DownloadReason
    let songs: [Song]
    var playlist: DownloadedPlaylist?
    var coverArtId: String?
    private let themed = Themed()

    var body: some View {
        let status = model.downloadStatus(songs.map(\.id))
        Group {
            if status == .none {
                CapsuleButton("Download", symbol: "arrow.down.to.line") { start() }
                    .disabled(songs.isEmpty)
            } else {
                Menu {
                    if status == .failed || status == .full {
                        Button("Try again", systemImage: "arrow.clockwise") { model.retryDownloads() }
                    }
                    Button("Remove download", systemImage: "trash", role: .destructive) {
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
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Download")
        .accessibilityValue(status.text)
        .accessibilityIdentifier("download")
    }

    private func start() {
        var snapshot = playlist
        snapshot?.savedAt = .now
        model.download(songs, reason: reason, playlist: snapshot, coverArtId: coverArtId)
    }
}

/// "Download" or "Remove download" in a song's context menu.
struct SongDownloadMenuItem: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        if model.downloadStatus([song.id]) == .none {
            Button("Download", systemImage: "arrow.down.to.line") { model.download([song], reason: .song) }
        } else {
            Button("Remove download", systemImage: "trash", role: .destructive) {
                Task { await model.removeSongDownload(song.id) }
            }
        }
    }
}
