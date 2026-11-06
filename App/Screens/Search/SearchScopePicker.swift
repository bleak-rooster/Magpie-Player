import DesignSystem
import SwiftUI

/// What Search lists: everything, or one kind.
enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums"
    var id: String { rawValue }
}

/// Round 23 (owner, 2026-11-07): All / Songs / Artists / Albums, pinned under the search field whenever there's a
/// query (D201). The system scope bar (`.searchScopes`) shows only while the search is presented, so the choices went
/// with it: after closing the search, a recent search, or Search instead, the results had none. The app's own picker,
/// as Playlists' All / Yours (D179), stays with the results; the chosen one is kept.
struct SearchScopePicker: View {
    @Binding var scope: SearchScope

    var body: some View {
        Picker("Search in", selection: $scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .frame(minHeight: Tokens.minHitSize)
        .padding(.horizontal, Tokens.Spacing.l)
        .padding(.vertical, Tokens.Spacing.s)
        .background(.bar)   // the rows scroll under it
        .accessibilityLabel("Search in")
        .accessibilityIdentifier("search-scope")
    }
}
