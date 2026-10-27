import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// After a Keep that moved the find into the library (D5): "Bring in more from <artist>?" with Albums and EPs
/// (preselected, the owner default), This album only, Everything, and a separate Follow new releases toggle. Each
/// choice says how much it is only as "about N hours of music" (A5), and says so when it brings in only the newest
/// ones (G7). "Not now" changes nothing.
struct BringInMoreSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let requestId: RequestID
    /// What Keep said ("Kept. It's in your library now.").
    let keptMessage: String

    private enum Phase: Equatable {
        case loading
        case choosing(RequestRunner.BringInOffer)
        case working(RequestRunner.BringInOffer)
        case done(String)
    }

    @State private var phase = Phase.loading
    @State private var choice = RequestRunner.BringInChoice.albumsAndEPs
    @State private var follow = false
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                    Label(keptMessage, systemImage: "checkmark.seal")
                        .font(.subheadline).foregroundStyle(themed.palette.accentInkColor)
                        .accessibilityIdentifier("bring-in-kept")
                    content
                }
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                .padding(.vertical, Tokens.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(themed.palette.bgColor)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Done" : BringInCopy.notNow) { dismiss() }
                        .accessibilityIdentifier("bring-in-close")
                }
            }
        }
        .task { await load() }
    }

    private var isDone: Bool { if case .done = phase { true } else { false } }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            HStack(spacing: Tokens.Spacing.s) {
                ProgressView()
                Text(BringInCopy.loading).font(.footnote).foregroundStyle(themed.palette.ink2Color)
            }
        case .choosing(let offer), .working(let offer):
            choosing(offer)
        case .done(let message):
            Text(message).font(.body).accessibilityIdentifier("bring-in-done")
        }
    }

    private func choosing(_ offer: RequestRunner.BringInOffer) -> some View {
        let p = themed.palette
        let working = phase == .working(offer)
        let selected = offer.options[choice]
        let canFollow = !offer.followsNewReleases
        let hasReleases = selected.map { !$0.albumIds.isEmpty } ?? false
        return VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            Text(BringInCopy.title(offer.artistName)).magpieDisplay(.title2)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(RequestRunner.BringInChoice.allCases, id: \.self) { c in
                    if let option = offer.options[c] {
                        row(c, option)
                        if c != RequestRunner.BringInChoice.allCases.last { Divider() }
                    }
                }
            }
            .background(p.surfaceColor, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let selected, let capped = BringInCopy.capped(selected) {
                Label(capped, systemImage: "info.circle").font(.footnote).foregroundStyle(p.ink2Color)
                    .accessibilityIdentifier("bring-in-capped")
            }
            VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                Toggle(BringInCopy.follow, isOn: canFollow ? $follow : .constant(true))
                    .disabled(!canFollow)
                    .accessibilityIdentifier("bring-in-follow")
                Text(canFollow ? BringInCopy.followNote : BringInCopy.followingAlready)
                    .font(.footnote).foregroundStyle(p.ink2Color)
            }
            Button { Task { await bring(offer) } } label: {
                HStack {
                    if working { ProgressView() }
                    Text(BringInCopy.bring)
                }
                .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize)
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || !(hasReleases || (follow && canFollow)))
            .accessibilityIdentifier("bring-in-start")
        }
    }

    /// One choice: its name, what it brings in, and a check when it's the one (text + symbol, D3).
    private func row(_ c: RequestRunner.BringInChoice, _ option: RequestRunner.BringInOption) -> some View {
        let p = themed.palette
        let isOn = c == choice
        return Button { choice = c } label: {
            HStack(spacing: Tokens.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(BringInCopy.choice(c)).font(.body).foregroundStyle(p.inkColor)
                    Text(BringInCopy.detail(option)).font(.footnote).foregroundStyle(p.ink2Color)
                }
                Spacer(minLength: 0)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isOn ? p.accentInkColor : p.ink2Color)
                    .accessibilityHidden(true)
            }
            .padding(Tokens.Spacing.m)
            .frame(minHeight: Tokens.minHitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isOn ? .isSelected : [])
        .accessibilityIdentifier("bring-in-\(c.rawValue)")
    }

    private func load() async {
        guard phase == .loading else { return }
        switch await model.bringInOffer(requestId) {
        case .offer(let offer): phase = .choosing(offer)
        case .message(let text): phase = .done(text)
        }
    }

    private func bring(_ offer: RequestRunner.BringInOffer) async {
        phase = .working(offer)
        let releases = offer.options[choice].map { !$0.albumIds.isEmpty } ?? false
        let message = await model.bringIn(requestId, choice: releases ? choice : nil, follow: follow,
                                          artist: offer.artistName)
        phase = .done(message)
    }
}
