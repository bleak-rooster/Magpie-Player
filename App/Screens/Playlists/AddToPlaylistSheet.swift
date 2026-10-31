import SwiftUI

// X2 stub of X3's shared interface (round11-common.md): same name, initialiser and path, so the merge with X3
// replaces this file.
struct AddToPlaylistSheet: View {
    let songIds: [String]

    init(songIds: [String]) { self.songIds = songIds }

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Add to playlist…", systemImage: "text.badge.plus")
                .navigationTitle("Add to playlist")
        }
    }
}
