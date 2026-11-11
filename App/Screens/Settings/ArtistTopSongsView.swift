import MagpieCore
import SwiftUI

/// Settings › Home & Library › Artist top songs (round 14 A3, owner answer 6): Automatic (Aurral, then ListenBrainz,
/// then your library), Aurral, ListenBrainz or Your library. Settings may name the services. Without Aurral (or one that
/// can't give an artist's top songs) the picker offers Automatic, ListenBrainz and Your library only.
struct ArtistTopSongsView: View {
    @Environment(AppModel.self) private var model
    static let title = "Artist top songs"

    static func hasAurral(_ model: AppModel) -> Bool { model.aurralSetUp && model.aurralCapabilities.artistPreview }

    /// The row's value: the choice (a stored Aurral without Aurral reads as Automatic, which is what happens).
    static func summary(_ model: AppModel) -> String {
        let chosen = model.preferences.layout.artistTopSongs
        return SongActionsCopy.sourceTitle(chosen == .aurral && !hasAurral(model) ? .automatic : chosen)
    }

    /// The footer. Round 26 K2 (D266, amends D104): with Lidarr set up, the choice is for artists Lidarr doesn't look
    /// after, and the last sentence says what the others get, naming only the sources set up (Aurral with its artist
    /// previews, ListenBrainz with a token). Without Lidarr, exactly as before.
    static func footer(_ model: AppModel) -> String {
        let token = model.hasListenBrainzToken ? "" : " ListenBrainz needs your token in Settings \u{203A} Scrobbling."
        let rest = " If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note."
            + token
        guard model.lidarr != nil else { return "Used for the Top songs on every artist page." + rest }
        let sources = model.lidarrTopSongsSourceNames
        let picked = sources.count == 1 ? "picked from \(sources[0])."
            : "picked from \(sources.joined(separator: ", then ")), in that order."
        return "Used for the Top songs of artists Lidarr doesn\u{2019}t look after." + rest
            + " For artists Lidarr looks after, Top songs are up to five songs you already have, " + picked
    }

    var body: some View {
        let aurral = Self.hasAurral(model)
        let stored = model.preferences.layout.artistTopSongs
        let selected = stored == .aurral && !aurral ? .automatic : stored
        List {
            Section {
                ForEach(ArtistTopSongsSource.choices(aurral: aurral), id: \.self) { source in
                    Button {
                        model.updatePreferences { $0.layout.artistTopSongs = source }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(SongActionsCopy.sourceTitle(source))
                                Text(SongActionsCopy.sourceNote(source, aurral: aurral)).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if source == selected { Image(systemName: "checkmark").accessibilityHidden(true) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(source == selected ? .isSelected : [])
                    .accessibilityIdentifier("artist-top-songs-\(source.rawValue)")
                }
            } footer: {
                Text(Self.footer(model))
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
