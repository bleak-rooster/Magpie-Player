import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library › Finds (Task 6.2a): New finds (here, not played yet), the other finds with their days left, and
/// finds still on their way. Every find is a round record with a text status, a symbol (D3) and the "Sample"
/// hallmark. Tapping a find plays it; finds are never scrobbled (D29). Keep and Not for me come later.
struct FindsView: View {
    @Environment(AppModel.self) private var model
    private let themed = Themed()

    var body: some View {
        let shelf = model.findsShelf()
        List {
            if shelf.isEmpty {
                ContentUnavailableView("No finds yet", systemImage: "record.circle",
                                       description: Text("Songs you try land here first, so you can get to know them."))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("finds-empty")
            }
            section("New finds", shelf.newFinds, all: shelf)
            section("Finds", shelf.finds, all: shelf)
            if !shelf.onTheirWay.isEmpty {
                Section {
                    ForEach(shelf.onTheirWay.reversed()) { request in
                        NavigationLink(value: Route.request(request.id)) {
                            RequestRow(request: request, context: model.waitContext)
                        }
                        .listRowBackground(Color.clear)
                    }
                } header: {
                    header("On their way")
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle("Finds")
        .magpieScreen()
        .refreshable { await model.refreshFinds() }
        .task { await model.refreshFinds() }
    }

    @ViewBuilder private func section(_ title: String, _ items: [FindsShelf.Item], all: FindsShelf) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    Button { play(item, in: all) } label: {
                        Artwork(item.song.coverArtId, side: 48) {
                            SongRow(song: item.song, state: item.state, artwork: $0, quality: item.quality)
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("find-\(item.song.title)")
                }
            } header: {
                header(title)
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title).magpieDisplay(.title3).foregroundStyle(themed.palette.inkColor)
            .textCase(nil).accessibilityAddTraits(.isHeader)
    }

    /// Plays the shelf from this find: new finds first, then the rest.
    private func play(_ item: FindsShelf.Item, in shelf: FindsShelf) {
        let songs = (shelf.newFinds + shelf.finds).map(\.song)
        guard let index = songs.firstIndex(of: item.song) else { return }
        model.play(songs, startAt: index)
    }
}
