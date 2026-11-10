import MagpieCore
import SwiftUI

/// Settings › Home & Library › Artist top songs (round 14 A3, owner answer 6): Automatic (Aurral, then ListenBrainz,
/// then your library), Aurral, ListenBrainz or Your library. Settings may name the services. Without Aurral (or one that
/// can't give an artist's top songs) the picker offers Automatic, ListenBrainz and Your library only. Round 25 I (owner,
/// 2026-11-10; D247): with Lidarr, a switch below: "In your library only, for artists in Lidarr" (on by default).
struct ArtistTopSongsView: View {
    @Environment(AppModel.self) private var model
    static let title = "Artist top songs"

    static func hasAurral(_ model: AppModel) -> Bool { model.aurralSetUp && model.aurralCapabilities.artistPreview }

    /// Round 25 I (D247): "In your library only, for artists in Lidarr" shows only with Lidarr (no dead switches).
    static func offersLibraryOnly(_ model: AppModel) -> Bool { model.lidarr != nil }

    /// The row's value: the choice (a stored Aurral without Aurral reads as Automatic, which is what happens).
    static func summary(_ model: AppModel) -> String {
        let chosen = model.preferences.layout.artistTopSongs
        return SongActionsCopy.sourceTitle(chosen == .aurral && !hasAurral(model) ? .automatic : chosen)
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
                Text("Used for the Top songs on every artist page. If the choice has none for an artist, the next one in Automatic\u{2019}s order is used, with a note."
                     + (model.hasListenBrainzToken ? "" : " ListenBrainz needs your token in Settings \u{203A} Scrobbling."))
            }
            if Self.offersLibraryOnly(model) {   // Round 25 I (owner, 2026-11-10; D247): on by default
                Section {
                    Toggle(TopSongsInLibraryCopy.toggle, isOn: Binding(
                        get: { model.preferences.layout.topSongsInLibraryOnly },
                        set: { on in model.updatePreferences { $0.layout.topSongsInLibraryOnly = on } }))
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("artist-top-songs-library-only")
                } footer: {
                    Text(TopSongsInLibraryCopy.footer)
                }
            }
        }
        .navigationTitle(Self.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
