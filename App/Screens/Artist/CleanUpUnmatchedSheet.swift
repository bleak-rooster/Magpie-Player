import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Round 24 (owner, 2026-11-08, D242): "Clean up unmatched songs". The songs kept when the artist's monitoring was
/// reduced whose album is still not monitored, read fresh; the ones the owner favourited, saved to a playlist or keeps on
/// the phone are listed as kept and never removed. A final confirmation names the count; only the listed songs go.
struct CleanUpUnmatchedSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let lidarrId: Int
    let artistName: String
    var onFinished: () -> Void

    @State private var preview: CleanupPreview?
    @State private var favourites = MonitoringKeepList()
    @State private var loadError: String?
    @State private var working = false
    @State private var confirms = false
    @State private var result: (text: String, symbol: String)?
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            List {
                if let preview {
                    Section {
                        Text(preview.files.isEmpty ? MonitoringCopy.nothingToCleanUp
                             : MonitoringCopy.cleanUpMessage(count: preview.files.count, artist: artistName))
                            .accessibilityIdentifier("clean-up-message")
                    }
                    if !preview.rows.isEmpty {
                        Section {
                            ForEach(preview.rows) { row in rowView(row) }
                        }
                    }
                } else if let loadError {
                    Section { Label(loadError, systemImage: "exclamationmark.circle") }
                } else {
                    Section { ProgressView() }
                }
                if let result {
                    Section {
                        Label(result.text, systemImage: result.symbol)
                            .foregroundStyle(themed.palette.inkColor)
                            .accessibilityIdentifier("clean-up-result")
                    }
                }
            }
            .navigationTitle(MonitoringCopy.cleanUp)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(result == nil ? "Cancel" : "Done") { dismiss() } }
                ToolbarItem(placement: .destructiveAction) {
                    Button(MonitoringCopy.removeSongs(preview?.files.count ?? 0), role: .destructive) { confirms = true }
                        .disabled(working || result != nil || (preview?.files.isEmpty ?? true))
                        .accessibilityIdentifier("clean-up-remove")
                }
            }
            .overlay { if working { ProgressView() } }
            .magpieScreen()
            .task { await load() }
            .alert(MonitoringCopy.confirmCleanUp(preview?.files.count ?? 0), isPresented: $confirms, presenting: preview) { p in
                Button(MonitoringCopy.removeSongs(p.files.count), role: .destructive) { Task { await cleanUp(p) } }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(MonitoringCopy.forGood)
            }
        }
    }

    /// A song, its album, and (kept ones) why it stays: text plus a symbol (D3).
    private func rowView(_ row: CleanupPreview.Row) -> some View {
        let p = themed.palette
        let why = favourites.keeps(recording: row.recording, title: row.title, album: row.album)
            ? MonitoringCopy.keptFavourite : MonitoringCopy.keptSaved
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Label(row.title, systemImage: row.kept ? "heart" : "trash")
            Text(row.album).font(.footnote).foregroundStyle(p.ink2Color)
            if row.kept { Text(why).font(.footnote).foregroundStyle(p.ink2Color) }
        }
        .frame(minHeight: Tokens.minHitSize, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("clean-up-row-\(row.id)")
    }

    private func load() async {
        guard let changer = model.monitoringChanger else { loadError = MonitoringCopy.unavailable; return }
        do {
            let keep = try await model.monitoringKeepLists(artist: artistName)
            favourites = keep.favourites
            preview = try await changer.cleanupPreview(artistId: lidarrId, keep: keep.all)
        } catch {
            loadError = MonitoringCopy.message(for: error)
        }
    }

    private func cleanUp(_ p: CleanupPreview) async {
        guard let changer = model.monitoringChanger else { return }
        working = true
        defer { working = false }
        do {
            result = MonitoringCopy.outcome(try await changer.cleanUp(p))
            onFinished()
        } catch {
            result = (MonitoringCopy.message(for: error), "exclamationmark.circle")
        }
        AccessibilityNotification.Announcement(result?.text ?? "").post()
    }
}
