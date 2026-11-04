import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Round 14 A3 (Decision 5, D101): the songs saved to this playlist that aren't in the library yet, greyed, with what
/// they're doing ("Coming"); a stopped one says so, with Retry and Remove. Each turns into a normal row when it lands
/// (the playlist reads again then).
struct ComingRows: View {
    @Environment(AppModel.self) private var model
    let playlistId: String
    private let themed = Themed()

    var body: some View {
        let rows = model.pendingAdds(for: playlistId)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text(SongActionsCopy.coming).font(.subheadline.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Tokens.Spacing.margin)
                    .padding(.top, Tokens.Spacing.s)
                ForEach(Array(rows.enumerated()), id: \.element.add.id) { index, row in
                    ComingRow(add: row.add, step: row.step)
                        .accessibilityIdentifier("coming-\(index)")
                }
            }
            .task(id: rows.map(\.add.id)) { await model.evaluatePendingAdds() }
        }
    }
}

private struct ComingRow: View {
    @Environment(AppModel.self) private var model
    let add: PendingPlaylistAdd
    let step: PendingAddStep
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        let failed = step == .failed || step == .requestGone   // requestGone only once the list is in (pendingStep)
        let status = SongActionsCopy.status(step, playlistGone: add.playlistGone == true)
        HStack(spacing: Tokens.Spacing.m) {
            SleeveArt(image: nil, side: 48).opacity(0.5).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(add.recording.title).font(.callout).lineLimit(1)
                Text(add.recording.artist).font(.footnote).lineLimit(1)
                HStack(spacing: Tokens.Spacing.xs) {
                    if case .waiting(.downloading(let progress)?) = step {
                        ProgressView(value: progress).frame(width: 60).accessibilityHidden(true)
                    }
                    Label(status, systemImage: failed ? "exclamationmark.circle" : "clock")
                        .font(.caption)
                }
            }
            .foregroundStyle(failed ? p.inkColor : p.ink2Color)
            .frame(maxWidth: .infinity, alignment: .leading)
            if failed {
                if add.playlistGone != true {
                    Button("Retry") { Task { await model.retryPending(add.id) } }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("coming-retry")
                }
                Button("Remove", role: .destructive) { Task { await model.removePending(add.id) } }
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("coming-remove")
            }
        }
        .padding(.horizontal, Tokens.Spacing.margin)
        .frame(minHeight: 60)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(add.recording.title), \(add.recording.artist)")
        .accessibilityValue(status)
        .contextMenu {
            Button("Remove", systemImage: "minus.circle", role: .destructive) { Task { await model.removePending(add.id) } }
        }
    }
}
