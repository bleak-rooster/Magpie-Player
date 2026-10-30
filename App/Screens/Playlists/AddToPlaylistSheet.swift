import DesignSystem
import MagpieCore
import SwiftUI

/// Add to playlist (round 11 R8, in the UX appraisal's words): "New playlist…" at the top, then the user's own
/// playlists, the most recently changed first (read-only ones are left out). A playlist that holds the song already
/// asks "Already in X" / "Add <song> again?"; for several songs only the ones already there are asked about ("3 of
/// these are already in X.": Add all, Skip those). Duplicates are allowed. The sheet closes once the songs are in; a
/// notice confirms ("Added to X").
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
            .navigationTitle("Add to playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .overlay { if flow.busy { ProgressView() } }
            .magpieScreen()
            .alert(PlaylistCopy.newPlaylistTitle, isPresented: $naming) {
                TextField("Name", text: $newName)
                    .accessibilityIdentifier("new-playlist-name")
                Button("Create") { Task { await flow.create(named: newName, model) } }
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", role: .cancel) {}
            }
            .alert(flow.duplicate.map { PlaylistCopy.alreadyIn($0.playlist.name) } ?? "",
                   isPresented: Binding(get: { flow.duplicate != nil }, set: { if !$0 { flow.duplicate = nil } }),
                   presenting: flow.duplicate) { duplicate in
                if flow.songIds.count == 1 {
                    Button("Add again") { Task { await flow.addAll(duplicate, model) } }
                } else {
                    Button("Add all") { Task { await flow.addAll(duplicate, model) } }
                    if duplicate.ids.count < Set(flow.songIds).count {
                        Button("Skip those") { Task { await flow.skipThose(duplicate, model) } }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: { duplicate in
                Text(flow.songIds.count == 1 ? PlaylistCopy.addAgain(duplicate.title ?? "it")
                                             : PlaylistCopy.someAlreadyIn(duplicate.count(in: flow.songIds),
                                                                          duplicate.playlist.name))
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
    /// The playlist that holds some of the songs already, waiting for the user's answer.
    var duplicate: Duplicate?
    private(set) var busy = false
    private(set) var failure: String?
    /// The songs went in: the sheet closes.
    private(set) var done = false

    /// A playlist holding `ids` of the songs already (`title`: the first one's, for a single song's question).
    struct Duplicate: Identifiable {
        let playlist: Playlist
        let ids: Set<String>
        let title: String?
        var id: String { playlist.id }

        /// How many of `songIds` (repeats counted) are there already.
        func count(in songIds: [String]) -> Int { songIds.filter(ids.contains).count }
    }

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
            let there = try await model.songsAlreadyIn(playlist, of: songIds)
            if there.ids.isEmpty {
                try await model.add(songIds, to: playlist)
                done = true
            } else {
                duplicate = Duplicate(playlist: playlist, ids: there.ids, title: there.title)
            }
        }
    }

    /// "Add again" / "Add all": every song goes in, the ones already there too.
    func addAll(_ duplicate: Duplicate, _ model: AppModel) async {
        self.duplicate = nil
        await run {
            try await model.add(songIds, to: duplicate.playlist)
            done = true
        }
    }

    /// "Skip those": only the songs not there yet go in.
    func skipThose(_ duplicate: Duplicate, _ model: AppModel) async {
        self.duplicate = nil
        let rest = songIds.filter { !duplicate.ids.contains($0) }
        await run {
            if !rest.isEmpty { try await model.add(rest, to: duplicate.playlist) }
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
