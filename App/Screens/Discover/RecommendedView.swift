import AurralKit
import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 14 A4 (plan "Screens", D92): Recommended. Top pick, New this week, Because you like X (up to 3), Close to
/// home, Further out, then All (sortable by rank, name or first seen). An artist opens the outside artist page; Not for
/// me (a long press) hides it here at once and tells the server.
struct RecommendedView: View {
    @Environment(AppModel.self) private var model
    @State private var sort = RecommendedRails.Sort.rank
    private let themed = Themed()

    private var feeds: AurralFeeds { model.aurralFeeds }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xxl) {
                if let snapshot = feeds.recommended {
                    if feeds.failed.contains(.recommended) {
                        Text(DiscoverPagesCopy.couldntUpdate).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            .padding(.horizontal, Tokens.Spacing.margin)
                    }
                    content(snapshot.rails(now: Date(), hidden: feeds.hidden))
                } else {
                    UpdatingCard()
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        .refreshable { await RefreshSafety.run { await feeds.refresh(.recommended, force: true) } }
        .navigationTitle(DiscoverPagesCopy.recommended)
        .navigationBarTitleDisplayMode(.inline)
        .magpieScreen()
        .task { await feeds.refresh(.recommended) }
    }

    @ViewBuilder private func content(_ rails: RecommendedRails) -> some View {
        if let top = rails.topPick {
            VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
                PageSectionTitle(title: DiscoverPagesCopy.topPick)
                NavigationLink(value: route(top)) {
                    HStack(spacing: Tokens.Spacing.m) {
                        AurralArt(image: top.image, side: 96, circle: true)
                        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                            Text(top.name).magpieDisplay(.title3)
                            if let line = RecommendedRails.subtitle(top) {
                                Text(line).font(.subheadline).foregroundStyle(themed.palette.ink2Color)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Tokens.Spacing.margin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { notForMe(top) }
                .accessibilityIdentifier("recommended-top-pick")
            }
        }
        shelf(DiscoverPagesCopy.newThisWeek, rails.newThisWeek)
        ForEach(rails.becauseYouLike, id: \.seed) { rail in
            shelf(DiscoverPagesCopy.becauseYouLike(rail.seed), rail.artists)
        }
        shelf(DiscoverPagesCopy.closeToHome, rails.closeToHome)
        shelf(DiscoverPagesCopy.furtherOut, rails.furtherOut)
        all(rails)
    }

    @ViewBuilder private func shelf(_ title: String, _ artists: [AurralRecommendedArtist]) -> some View {
        if !artists.isEmpty {
            ShelfSection(title) {
                ForEach(Array(artists.enumerated()), id: \.offset) { _, artist in
                    NavigationLink(value: route(artist)) {
                        VStack(spacing: Tokens.Spacing.xs) {
                            AurralArt(image: artist.image, side: 110, circle: true)
                            Text(artist.name).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
                            if let line = RecommendedRails.subtitle(artist) {
                                Text(line).font(.caption).foregroundStyle(themed.palette.ink2Color).lineLimit(2)
                                    .multilineTextAlignment(.center)
                            }
                        }
                        .frame(width: 120)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { notForMe(artist) }
                }
            }
        }
    }

    @ViewBuilder private func all(_ rails: RecommendedRails) -> some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.m) {
            PageSectionTitle(title: DiscoverPagesCopy.all)
            Picker(DiscoverPagesCopy.all, selection: $sort) {
                Text(DiscoverPagesCopy.sortRank).tag(RecommendedRails.Sort.rank)
                Text(DiscoverPagesCopy.sortName).tag(RecommendedRails.Sort.name)
                Text(DiscoverPagesCopy.sortFirstSeen).tag(RecommendedRails.Sort.firstSeen)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Tokens.Spacing.margin)
            .accessibilityIdentifier("recommended-sort")
            ForEach(Array(rails.sorted(sort).enumerated()), id: \.offset) { index, artist in
                NavigationLink(value: route(artist)) {
                    HStack(spacing: Tokens.Spacing.m) {
                        AurralArt(image: artist.image, side: 48, circle: true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(artist.name).font(.body)
                            if let line = RecommendedRails.subtitle(artist) {
                                Text(line).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            }
                        }
                        Spacer(minLength: 0)
                        if let match = artist.matchPercent {
                            Text("\(match)%").font(.footnote.monospacedDigit()).foregroundStyle(themed.palette.ink2Color)
                        }
                    }
                    .padding(.horizontal, Tokens.Spacing.margin)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu { notForMe(artist) }
                .accessibilityIdentifier("recommended-all-\(index)")
            }
        }
    }

    private func route(_ artist: AurralRecommendedArtist) -> Route {
        .outsideArtist(NotYetArtist(name: artist.name, mbid: artist.mbid))
    }

    /// Not for me: hidden here at once; the server is told too.
    @ViewBuilder private func notForMe(_ artist: AurralRecommendedArtist) -> some View {
        Button(role: .destructive) {
            Task { await feeds.notForMe(artist) }
        } label: {
            Label(DiscoverPagesCopy.notForMe, systemImage: "hand.thumbsdown")
        }
    }
}
