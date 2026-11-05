import DesignSystem
import MagpieCore
import Requests
import SwiftUI

/// Library › Finds (Task 6.2a): New finds (here, not played yet), the other finds with their days left, and
/// finds still on their way. Every find is a round record with a text status, a symbol (D3) and the "Sample"
/// hallmark. Tapping a find plays it; finds are never scrobbled (D29). Keep (Task 6.2b) moves it into the
/// library and says how it went; after a move, "Kept. Add more from <artist>?" follows (D5, R20: the Add sheet). Not for me (Task 6.2c, a
/// swipe, the context menu or the VoiceOver action) asks first, saying whether the files can come back, then lets
/// the find's release go.
struct FindsView: View {
    @Environment(AppModel.self) private var model
    /// Finds a Keep is running for: their row offers no second Keep meanwhile.
    @State private var keeping: Set<RequestID> = []
    @State private var keepMessage: String?
    /// D5 + R20: a Keep moved the find into the library; "Kept. Add more from <artist>?" follows (the Add sheet).
    @State private var addingMore: AddFlowRequest?
    /// Finds a Not for me is asking about or running for: their row offers no second one meanwhile.
    @State private var lettingGo: Set<RequestID> = []
    @State private var asking: NotForMeConfirm?
    private let themed = Themed()

    var body: some View {
        let shelf = model.findsShelf()
        List {
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
            // Round 15 C3 (D138): what Not for me took out of your playlists, the latest few.
            let letGo = model.letGo.history.prefix(5)
            if !letGo.isEmpty {
                Section {
                    ForEach(Array(letGo)) { job in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(job.title).font(.body).foregroundStyle(themed.palette.inkColor)
                            Text(FindCleanupCopy.historyLine(job)).font(.footnote).foregroundStyle(themed.palette.ink2Color)
                            if let at = job.finishedAt {
                                Text(at, format: .relative(presentation: .named)).font(.caption).foregroundStyle(themed.palette.ink2Color)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .listRowBackground(Color.clear)
                        .accessibilityIdentifier("finds-let-go-\(job.title)")
                    }
                } header: {
                    header(FindCleanupCopy.recentlyLetGo)
                }
            }
        }
        .listStyle(.plain)
        // Over the list, not a row in it, so no separators frame it (final fix 2 B-M10, as Requests).
        .overlay {
            if shelf.isEmpty, model.letGo.history.isEmpty {
                ContentUnavailableView("No finds yet", systemImage: "record.circle",
                                       description: Text("New artists you try land here first, so you can try them before they join your library. Songs by artists you have go straight into your library."))
                    .accessibilityIdentifier("finds-empty")
            }
        }
        .navigationTitle("Finds")
        .magpieScreen()
        .refreshable { await model.refreshFinds() }
        .task { await model.refreshFinds() }
        .addFlow($addingMore) { keepMessage = $0.message }
        .alert(keepMessage ?? "", isPresented: Binding(get: { keepMessage != nil }, set: { if !$0 { keepMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .confirmationDialog(NotForMeCopy.confirmTitle, isPresented: Binding(get: { asking != nil }, set: { shown in
            if !shown, let confirm = asking {
                asking = nil
                lettingGo.remove(confirm.request)
            }
        }), titleVisibility: .visible, presenting: asking) { confirm in
            Button(NotForMeCopy.action, role: .destructive) { letGo(confirm) }
            Button("Cancel", role: .cancel) {}
        } message: { confirm in
            Text(confirm.message)
        }
    }

    @ViewBuilder private func section(_ title: String, _ items: [FindsShelf.Item], all: FindsShelf) -> some View {
        if !items.isEmpty {
            Section {
                ForEach(items) { item in
                    // Not a Button: the row's own Keep button must take its taps. Tap (or VoiceOver's default
                    // action) plays; Keep is the row's named action.
                    Artwork(item.song.coverArtId, side: 48) {
                        SongRow(song: item.song, state: item.state, artwork: $0, quality: item.quality,
                                onKeep: keepAction(item))
                    }
                    .onTapGesture { play(item, in: all) }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { play(item, in: all) }
                    .modifier(NotForMeActions(song: item.song, action: notForMeAction(item)))
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

    /// Keep, when the find has a ready request and no Keep is running for it (else the row offers none).
    private func keepAction(_ item: FindsShelf.Item) -> (() -> Void)? {
        guard let id = item.keepRequest, !keeping.contains(id), !lettingGo.contains(id),
              !model.newMusic.keepsRunning.contains(id) else { return nil }
        return {
            keeping.insert(id)
            Task {
                let reply = await model.keep(id)
                if reply.bringsInMore {
                    addingMore = model.afterKeepRequest(id, artist: item.song.artist, kept: reply.message)
                } else {
                    keepMessage = reply.message
                }
                keeping.remove(id)
            }
        }
    }

    /// Not for me, when the find has a ready request it can go through and nothing is running for it. Asks the
    /// runner first (a fresh read, nothing written) so the sheet can say whether the files can come back.
    private func notForMeAction(_ item: FindsShelf.Item) -> (() -> Void)? {
        guard let id = item.notForMeRequest, !lettingGo.contains(id), !keeping.contains(id) else { return nil }
        return {
            lettingGo.insert(id)
            Task {
                switch await model.notForMeAsk(id) {
                case .confirm(let confirm): asking = confirm
                case .message(let text):
                    keepMessage = text
                    lettingGo.remove(id)
                }
            }
        }
    }

    private func letGo(_ confirm: NotForMeConfirm) {
        asking = nil
        lettingGo.insert(confirm.request)   // however the dialog's dismissal was ordered
        Task {
            keepMessage = await model.notForMe(confirm)
            lettingGo.remove(confirm.request)
        }
    }

    /// Plays the shelf from this find: new finds first, then the rest.
    private func play(_ item: FindsShelf.Item, in shelf: FindsShelf) {
        let songs = (shelf.newFinds + shelf.finds).map(\.song)
        guard let index = songs.firstIndex(of: item.song) else { return }
        model.play(songs, startAt: index)
    }
}

/// Not for me on a find row: a trailing swipe, the context menu and a named VoiceOver action (no extra swipe stop).
/// R12: the row's swipe actions come with it; Not for me keeps the trailing edge's outer place, never on a full swipe.
private struct NotForMeActions: ViewModifier {
    let song: Song
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content
                .songSwipeActions(song, in: .list,
                                  destructive: RowDestructiveAction(title: NotForMeCopy.action, symbol: "hand.thumbsdown", action: action))
                .contextMenu {
                    Button(NotForMeCopy.action, systemImage: "hand.thumbsdown", role: .destructive, action: action)
                }
                .accessibilityAction(named: NotForMeCopy.action, action)
        } else {
            content.songSwipeActions(song, in: .list)
        }
    }
}
