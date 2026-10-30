import DesignSystem
import MagpieCore
import SwiftUI

/// Downloading now (P1): what's downloading, then what waits, then what failed, each with Cancel (and Try again when
/// it failed). Pause all / Resume all and Cancel all (confirmed) on top. Reached from Settings › Downloads & Storage and
/// from the banner on Library › Downloads.
struct DownloadingNowView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmsCancelAll = false
    private let themed = Themed()

    var body: some View {
        let items = model.downloadActivity
        List {
            if model.hasActiveDownloads {
                KeepOpenBanner().listRowBackground(Color.clear)
            }
            if !items.isEmpty {
                Section {
                    ForEach(items) { row($0) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if items.isEmpty {
                ContentUnavailableView(DownloadActivityCopy.empty, systemImage: "arrow.down.circle")
                    .accessibilityIdentifier("downloading-now-empty")
            }
        }
        .navigationTitle(DownloadActivityCopy.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !items.isEmpty {
                ToolbarItemGroup(placement: .bottomBar) {
                    if model.downloads?.isPaused == true {
                        Button("Resume all", systemImage: "play.fill") { model.downloads?.resumeAll() }
                            .labelStyle(.titleAndIcon)
                            .accessibilityIdentifier("downloads-resume-all")
                    } else {
                        Button("Pause all", systemImage: "pause.fill") { model.downloads?.pauseAll() }
                            .labelStyle(.titleAndIcon)
                            .accessibilityIdentifier("downloads-pause-all")
                    }
                    Spacer()
                    Button("Cancel all", role: .destructive) { confirmsCancelAll = true }
                        .accessibilityIdentifier("downloads-cancel-all")
                }
            }
        }
        .confirmationDialog("Cancel all downloads?", isPresented: $confirmsCancelAll, titleVisibility: .visible) {
            Button("Cancel all downloads", role: .destructive) {
                Task { await model.downloads?.cancelAllActive() }
            }
            Button("Keep downloading", role: .cancel) {}
        } message: {
            Text("Songs already downloaded stay on this phone.")
        }
        .accessibilityIdentifier("downloading-now")
    }

    private func row(_ item: DownloadActivityItem) -> some View {
        let p = themed.palette
        return VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.s) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.metadata.title).font(.body).lineLimit(2)
                    Text(item.metadata.artist).font(.footnote).foregroundStyle(p.ink2Color).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if item.isFailed {
                    Button("Try again") { model.downloads?.retry(item) }
                        .buttonStyle(.borderless)
                        .frame(minHeight: Tokens.minHitSize)
                        .accessibilityIdentifier("downloading-retry")
                }
                Button {
                    Task { await model.downloads?.cancel(item) }
                } label: {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(p.ink2Color)
                        .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Cancel")
                .accessibilityIdentifier("downloading-cancel")
            }
            if case let .running(progress) = item.phase {
                if let fraction = progress?.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView(value: 0).opacity(0.5)
                }
                Text(progress.map(DownloadActivityCopy.progress) ?? "Starting…")
                    .font(.footnote.monospacedDigit()).foregroundStyle(p.ink2Color)
            } else {
                Label(item.text, systemImage: item.symbol)
                    .font(.footnote).foregroundStyle(p.ink2Color)
            }
        }
        .padding(.vertical, Tokens.Spacing.xs)
    }
}

/// "Keep Magpie open to finish downloading" (P1: downloads don't go on in the background).
struct KeepOpenBanner: View {
    private let themed = Themed()

    var body: some View {
        Label(DownloadActivityCopy.keepOpen, systemImage: "iphone")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(themed.palette.inkColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("downloads-keep-open")
    }
}

/// Library › Downloads' banner row while anything downloads: "Downloading now · 3", opening Downloading now.
struct DownloadingNowLink: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        let count = model.downloadActivity.count
        if count > 0 {
            NavigationLink { DownloadingNowView() } label: {
                VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                    Label(DownloadActivityCopy.row(count), systemImage: "arrow.down.circle.dotted")
                        .font(.body.weight(.semibold))
                    if model.hasActiveDownloads {
                        Text(DownloadActivityCopy.keepOpen).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(themed.palette.inkColor)
            .accessibilityIdentifier("downloading-now-link")
        }
    }
}
