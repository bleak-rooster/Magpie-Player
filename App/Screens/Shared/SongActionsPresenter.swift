import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Round 14 A3: presents what an outside song's ⋯ menu asks for, once, inside the tabs: the Try sheet (Listen to the
/// full song), the Add (Add artist; Whole artist), the Just this song / Whole artist question, the playlist picker, and
/// "Couldn't match this song" with Search instead.
struct SongActionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let navigator: TabNavigator?

    func body(content: Content) -> some View {
        @Bindable var actions = model.songActions
        @Bindable var adder = model.songActions.adder
        content
            .sheet(item: $actions.trying) { TrySheet(target: $0) }
            // Fix round 1: Whole artist's Add is presented once the picker has finished closing.
            .sheet(item: $actions.picking, onDismiss: { actions.presentQueuedAdd() }) { SaveToPlaylistSheet(pick: $0) }
            .addFlow($adder.addFlow) { adder.finished($0); notify($0) }
            .addFlow($actions.wholeArtistAdd) { notify($0) }
            .onChange(of: adder.message) {
                if let text = adder.message {
                    model.libraryEdits.notify(text, symbol: "info.circle")
                    adder.message = nil
                }
            }
            .confirmationDialog(SongActionsCopy.choiceTitle,
                                isPresented: Binding(get: { actions.choosing != nil }, set: { if !$0 { actions.choosing = nil } }),
                                titleVisibility: .visible, presenting: actions.choosing) { song in
                if model.justThisSongAvailable {
                    Button(SongActionsCopy.justThisSong) { model.choose(.justThisSong, for: song) }
                        .accessibilityIdentifier("save-just-this-song")
                }
                Button(SongActionsCopy.wholeArtist) { model.choose(.wholeArtist, for: song) }
                    .accessibilityIdentifier("save-whole-artist")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(model.justThisSongAvailable ? SongActionsCopy.choiceMessage
                                                 : SongActionsCopy.choiceMessage + " " + SongActionsCopy.noJustThisSong)
            }
            .alert(SongActionsCopy.unmatchedTitle,
                   isPresented: Binding(get: { actions.unmatched != nil }, set: { if !$0 { actions.unmatched = nil } }),
                   presenting: actions.unmatched) { song in
                Button(SongActionsCopy.searchInstead) {
                    actions.searchQuery = "\(song.artist) \(song.title)"
                    navigator?.tab = .search
                }
                .accessibilityIdentifier("unmatched-search-instead")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(SongActionsCopy.unmatchedMessage)
            }
    }

    private func notify(_ outcome: AddOutcome) {
        model.libraryEdits.notify(outcome.message, symbol: outcome.succeeded ? "checkmark.circle" : "exclamationmark.circle")
    }
}

extension View {
    func songActionsPresenter(navigator: TabNavigator?) -> some View { modifier(SongActionsPresenter(navigator: navigator)) }
}

/// Save to playlist's picker for a song the library doesn't have yet: "New playlist…", then the owner's own playlists.
/// Picking one saves a pending add (Just this song: the Find starts; Whole artist: the Add asks next).
struct SaveToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pick: SavePick
    @State private var playlists: Loadable<[Playlist]> = .loading
    @State private var busy = false
    @State private var failure: String?
    @State private var naming = false
    @State private var newName = ""
    private let themed = Themed()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(pick.choice == .justThisSong ? "\(pick.song.title) \u{00B7} \(pick.song.artist)"
                                                      : "\(pick.song.title), with all of \(pick.song.artist)")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        Label(PlaylistCopy.newPlaylist, systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("save-new-playlist")
                }
                Section {
                    LoadableView(state: playlists, retry: load) { list in
                        if list.isEmpty {
                            Text("You have no playlists of your own yet.").font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        }
                        ForEach(list, id: \.id) { playlist in
                            Button { Task { await save(to: playlist) } } label: {
                                Text(playlist.name).frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .disabled(busy)
                            .accessibilityIdentifier("save-to-playlist-\(playlist.id)")
                        }
                    }
                }
                if let failure {
                    Section { Label(failure, systemImage: "exclamationmark.circle").accessibilityIdentifier("save-failure") }
                }
            }
            .navigationTitle(SongActionsCopy.saveToPlaylist)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .overlay { if busy { ProgressView() } }
            .magpieScreen()
            .alert(PlaylistCopy.newPlaylistTitle, isPresented: $naming) {
                TextField("Name", text: $newName)
                Button("Create") { Task { await create() } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await load() }
    }

    private func load() async {
        do { playlists = .loaded(try await model.editablePlaylists()) } catch {
            playlists = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    private func save(to playlist: Playlist) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        failure = await model.save(pick.song, choice: pick.choice, to: playlist)
        if failure == nil || model.songActions.unmatched != nil { dismiss() }
    }

    /// New playlist…: made empty, then the song waits for it like any other.
    private func create() async {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !busy else { return }
        busy = true
        do {
            // Fix round 1 (M2): by the id the new playlist got, never by its name (an older one may share it).
            let id = try await model.createPlaylist(named: name, songIds: [])
            var made: Playlist?
            if let id { made = try await model.editablePlaylists().first { $0.id == id } }
            busy = false
            if let made { await save(to: made) } else { failure = SongActionsCopy.couldntSave }
        } catch {
            busy = false
            failure = PlaylistEditError.message(for: error)
        }
    }
}
