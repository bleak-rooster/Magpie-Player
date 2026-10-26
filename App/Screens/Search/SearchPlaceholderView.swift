import SwiftUI

/// Placeholder until library search lands (Task 2.1).
struct SearchPlaceholderView: View {
    var body: some View {
        ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                               description: Text("Songs, albums and artists. Coming soon."))
            .navigationTitle("Search")
            .magpieScreen()
    }
}
