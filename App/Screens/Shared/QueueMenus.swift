import MagpieCore
import SwiftUI

/// R12 fix round 1 (I1): long-press menus lead with Play next · Add to queue (appraisal §4, group 1), on songs and on
/// album, playlist and artist rows and tiles. A collection's items ask In order or Shuffled, like its swipes.
enum QueueMenu {
    struct Item: Identifiable, Equatable {
        let title: String
        let symbol: String
        let placement: QueuePlacement
        var id: String { title }
    }

    static let items = [
        Item(title: QueueCopy.playNext, symbol: QueueCopy.symbol(.playNext), placement: .next),
        Item(title: QueueCopy.addToQueue, symbol: QueueCopy.symbol(.addToQueue), placement: .end),
    ]
}

extension AppModel {
    func perform(_ item: QueueMenu.Item, on song: Song) { place([song], item.placement) }

    func perform(_ item: QueueMenu.Item, on collection: CollectionRef) { askToQueue(collection, item.placement) }

    /// A collection's Play next or Add to queue: asks In order or Shuffled. Offline it first checks the phone has some
    /// of it (`offerQueue`).
    func askToQueue(_ collection: CollectionRef, _ placement: QueuePlacement) {
        if isOffline {
            Task { await offerQueue(collection, placement) }
        } else {
            queueActions.pendingCollection = .init(collection: collection, placement: placement)
        }
    }

    /// Offline, a collection with nothing on the phone says "Nothing downloaded" rather than asking and then doing
    /// nothing (polish).
    func offerQueue(_ collection: CollectionRef, _ placement: QueuePlacement) async {
        if isOffline, (try? await songs(of: collection))?.isEmpty ?? true {
            libraryEdits.notify(QueueCopy.nothingDownloaded, symbol: "arrow.down.circle")
            return
        }
        queueActions.pendingCollection = .init(collection: collection, placement: placement)
    }
}

/// Group 1 of a song's long-press menu.
struct SongQueueMenuItems: View {
    @Environment(AppModel.self) private var model
    let song: Song

    var body: some View {
        Section {
            ForEach(QueueMenu.items) { item in
                Button(item.title, systemImage: item.symbol) { model.perform(item, on: song) }
            }
        }
    }
}

extension View {
    /// The long-press menu of an album, playlist or artist row or tile: Play next · Add to queue, then Reload artwork
    /// (P4) when there is a cover and a connection. Replaces `reloadArtworkMenu` there.
    func collectionMenu(_ collection: CollectionRef, coverArtId: String?) -> some View {
        modifier(CollectionMenu(collection: collection, coverArtId: coverArtId))
    }
}

private struct CollectionMenu: ViewModifier {
    @Environment(AppModel.self) private var model
    let collection: CollectionRef
    let coverArtId: String?

    func body(content: Content) -> some View {
        content.contextMenu {
            Section {
                ForEach(QueueMenu.items) { item in
                    Button(item.title, systemImage: item.symbol) { model.perform(item, on: collection) }
                }
            }
            if let coverArtId, !model.isOffline {
                Section {
                    Button("Reload artwork", systemImage: "arrow.clockwise") {
                        Task { await model.reloadArtwork(coverArtId) }
                    }
                }
            }
        }
    }
}
