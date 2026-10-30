import DesignSystem
import MagpieCore
import SwiftUI

/// Add to playlist (round 11 R8): "New playlist…" at the top, then the user's own playlists A–Z (read-only ones are
/// left out). A playlist that holds any of the songs already asks "Already in X. Add again?" (duplicates are allowed).
/// The sheet closes once the songs are in; a notice confirms ("Added to X").
struct AddToPlaylistSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var flow: AddToPlaylistFlow
    @State private var naming = false
    @State private var newName = ""
    private let themed = Themed()

    init(songIds: [String]) {
        _flow = State(initialValue: AddToPlaylistFlow(songIds: songIds))
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        Label(PlaylistCopy.newPlaylist, systemImage: "plus")
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .disabled(flow.busy)
                    .accessibilityIdentifier("add-to-new-playlist")
                }
                Section {
                    LoadableView(state: flow.playlists, retry: { await flow.load(model) }) { playlists in
                        if playlists.isEmpty {
                            Text("You have no playlists of your own yet.")
                                .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                        }
                        ForEach(playlists, id: \.id) { playlist in
                            Button { Task { await flow.choose(playlist, model) } } label: { row(playlist) }
                                .disabled(flow.busy)
                                .accessibilityIdentifier("add-to-playlist-\(playlist.id)")
                        }
                    }
                }
                if let failure = flow.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.circle")
                            .foregroundStyle(themed.palette.inkColor)
                            .accessibilityIdentifier("add-to-playlist-failure")
                    }
                }
            }
            .navigationTitle(flow.songIds.count == 1 ? "Add to playlist" : "Add \(flow.songIds.count) songs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if flow.busy { ProgressView() } }
            .magpieScreen()
            .alert(PlaylistCopy.newPlaylist, isPresented: $naming) {
                TextField("Name", text: $newName)
                    .accessibilityIdentifier("new-playlist-name")
                Button("Cancel", role: .cancel) {}
                Button("Create") { Task { await flow.create(named: newName, model) } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .alert(flow.duplicate.map { PlaylistCopy.alreadyIn($0.name) } ?? "",
                   isPresented: Binding(get: { flow.duplicate != nil }, set: { if !$0 { flow.duplicate = nil } }),
                   presenting: flow.duplicate) { playlist in
                Button("Add again") { Task { await flow.addAgain(playlist, model) } }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await flow.load(model) }
        .onChange(of: flow.done) { _, done in if done { dismiss() } }
    }

    private func row(_ playlist: Playlist) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            Artwork(playlist.coverArtId, side: 44) { SleeveArt(image: $0, side: 44) }
            VStack(alignment: .leading, spacing: 1) {
                Text(playlist.name).font(.body).foregroundStyle(themed.palette.inkColor)
                Text(playlist.songCount == 1 ? "1 song" : "\(playlist.songCount) songs")
                    .font(.footnote).foregroundStyle(themed.palette.ink2Color)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: Tokens.minHitSize)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The sheet's steps, apart from the view so tests can drive them: read the user's playlists, pick one (warning when
/// it holds any of the songs already), or make a new one.
@MainActor @Observable final class AddToPlaylistFlow {
    let songIds: [String]
    private(set) var playlists: Loadable<[Playlist]> = .loading
    /// The playlist that holds some of the songs already: "Already in X. Add again?"
    var duplicate: Playlist?
    private(set) var busy = false
    private(set) var failure: String?
    /// The songs went in: the sheet closes.
    private(set) var done = false

    init(songIds: [String]) { self.songIds = songIds }

    func load(_ model: AppModel) async {
        do {
            playlists = .loaded(try await model.editablePlaylists())
        } catch {
            playlists = .failed(BrowseErrorCopy.message(for: error))
        }
    }

    /// Adds to `playlist`, unless it already holds any of the songs: then asks first (`duplicate`).
    func choose(_ playlist: Playlist, _ model: AppModel) async {
        await run {
            if try await model.songsAlreadyIn(playlist, of: songIds) > 0 {
                duplicate = playlist
            } else {
                try await model.add(songIds, to: playlist)
                done = true
            }
        }
    }

    /// "Add again": the songs go in even though some are there already.
    func addAgain(_ playlist: Playlist, _ model: AppModel) async {
        duplicate = nil
        await run {
            try await model.add(songIds, to: playlist)
            done = true
        }
    }

    func create(named name: String, _ model: AppModel) async {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        await run {
            try await model.createPlaylist(named: name, songIds: songIds)
            done = true
        }
    }

    private func run(_ step: () async throws -> Void) async {
        guard !busy else { return }
        busy = true
        failure = nil
        defer { busy = false }
        do { try await step() } catch { failure = BrowseErrorCopy.message(for: error) }
    }
}

/// Shows Add to playlist when a menu asks for it (`AppModel.askToAddToPlaylist`), and the library's notices.
struct LibraryEditsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { model.libraryEdits.addToPlaylist },
                                 set: { model.libraryEdits.addToPlaylist = $0 })) { request in
                AddToPlaylistSheet(songIds: request.songIds)
            }
            .libraryNotices()
    }
}

extension View {
    /// The Add to playlist sheet asked for from menus, and the library's notices (once, near the root).
    func libraryEditsPresenter() -> some View { modifier(LibraryEditsPresenter()) }
}
