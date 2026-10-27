import DesignSystem
import MagpieCore
import Requests
import Search
import SwiftUI

/// Search tab: type to search. Recent searches when the field is empty; otherwise the library's Top
/// result, Songs, Artists and Albums, then a "Not in your library" band (D4: library first).
struct SearchView: View {
    @Environment(AppModel.self) private var app
    @State private var model: SearchModel?
    @State private var scope = SearchScope.all

    var body: some View {
        NavigationStack {
            Group {
                if let model {
                    SearchContent(model: model, scope: scope)
                } else {
                    Color.clear
                }
            }
            .magpieRoutes()
        }
        // On the stack itself, which is where a Search-role tab looks for its field.
        .searchable(text: Binding(get: { model?.query ?? "" }, set: { model?.update(query: $0) }),
                    placement: .navigationBarDrawer(displayMode: .always), prompt: "Songs, artists and albums")
        .searchScopes($scope) {
            ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
        }
        .onSubmit(of: .search) { if let model { RecentSearches().add(model.query) } }
        .task {
            guard model == nil else { return }
            let app = app
            model = SearchModel(search: { q, early in
                                    try await app.mergedSearch().runReportingLibraryFailure(q, libraryFirst: early)
                                },
                                errorMessage: BrowseErrorCopy.message(for:))
        }
    }
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all = "All", songs = "Songs", artists = "Artists", albums = "Albums"
    var id: String { rawValue }
}

private struct SearchContent: View {
    @Environment(AppModel.self) private var app
    let model: SearchModel
    let scope: SearchScope
    @State private var recents = RecentSearches().items
    @State private var trying: TryTarget?
    private let themed = Themed()

    var body: some View {
        let sections = model.results
        List {
            switch model.phase {
            case .idle:
                recentSection
            case .searching where sections.isEmpty:
                ProgressView().frame(maxWidth: .infinity, minHeight: 160).listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't search", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") { model.update(query: model.query) }
                }
                .listRowBackground(Color.clear)
            case .done where sections.isEmpty:
                ContentUnavailableView("Nothing in your library for \u{201C}\(model.query)\u{201D}",
                                       systemImage: "magnifyingglass",
                                       description: Text("Check the spelling, or try an artist or album."))
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("search-empty")
            default:
                results(sections)
            }
        }
        .listStyle(.plain)
        .listRowSeparatorTint(themed.palette.sepColor)
        .navigationTitle("Search")
        .magpieScreen()
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $trying) { TrySheet(recording: $0.recording) }
    }

    // MARK: - Start

    @ViewBuilder private var recentSection: some View {
        if recents.isEmpty {
            ContentUnavailableView("Search your library", systemImage: "magnifyingglass",
                                   description: Text("Find songs, artists and albums by name, in your library and beyond."))
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(recents, id: \.self) { q in
                    Button { model.update(query: q) } label: {
                        Label(q, systemImage: "clock.arrow.circlepath")
                            .frame(maxWidth: .infinity, minHeight: Tokens.minHitSize, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
            } header: {
                HStack {
                    Text("Recent").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    Button("Clear") {
                        RecentSearches().clear()
                        recents = []
                    }
                    .font(.subheadline)
                    .accessibilityLabel("Clear recent searches")
                }
                .textCase(nil)
            }
        }
    }

    // MARK: - Results

    @ViewBuilder private func results(_ sections: SearchSections) -> some View {
        if scope == .all, let top = sections.top {
            Section { topRow(top, in: sections) } header: { header("Top result") }
        }
        if scope == .all || scope == .songs, !sections.songs.isEmpty {
            Section {
                ForEach(Array(sections.songs.enumerated()), id: \.element.id) { index, song in
                    songRow(song, index: index, in: sections.songs)
                }
            } header: { header("Songs") }
        }
        if scope == .all || scope == .artists, !sections.artists.isEmpty {
            Section {
                ForEach(sections.artists, id: \.id) { artistRow($0) }
            } header: { header("Artists") }
        }
        if scope == .all || scope == .albums, !sections.albums.isEmpty {
            Section {
                ForEach(sections.albums, id: \.id) { albumRow($0) }
            } header: { header("Albums") }
        }
        notYetBand(sections.notYet)
    }

    // MARK: - Not in your library

    /// Below every library row, never interleaved (D4). Each row says "Not in your library" in text
    /// with a symbol, not by its round art alone (D3).
    @ViewBuilder private func notYetBand(_ band: NotYetSections) -> some View {
        let songs = scope == .all || scope == .songs ? band.songs : []
        let artists = scope == .all || scope == .artists ? band.artists : []
        let albums = scope == .all || scope == .albums ? band.albums : []
        let kinds = [songs.isEmpty, artists.isEmpty, albums.isEmpty].filter { !$0 }.count
        if kinds > 0 {
            Section {
                if !songs.isEmpty {
                    if kinds > 1 { subheader("Songs") }
                    ForEach(Array(songs.enumerated()), id: \.offset) { index, recording in
                        notYetSongRow(recording, index: index)
                    }
                }
                if !artists.isEmpty {
                    if kinds > 1 { subheader("Artists") }
                    ForEach(Array(artists.enumerated()), id: \.offset) { index, artist in
                        notYetArtistRow(artist).accessibilityIdentifier("search-notyet-artist-\(index)")
                    }
                }
                if !albums.isEmpty {
                    if kinds > 1 { subheader("Albums") }
                    ForEach(Array(albums.enumerated()), id: \.offset) { index, album in
                        notYetAlbumRow(album).accessibilityIdentifier("search-notyet-album-\(index)")
                    }
                }
            } header: {
                header("Not in your library").accessibilityIdentifier("search-notyet-header")
            }
        }
    }

    private func subheader(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(themed.palette.ink2Color)
            .accessibilityAddTraits(.isHeader)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func notYetSongRow(_ recording: ExternalRecording, index: Int) -> some View {
        let song = Song(id: "notyet-\(index)", title: recording.title, artist: recording.artist,
                        album: recording.releaseTitle ?? "", duration: recording.duration ?? 0)
        return SongRow(song: song, state: RequestCopy.rowState(for: recording, in: app.requests),
                       onTry: { trying = TryTarget(recording: recording) })
            .accessibilityIdentifier("search-notyet-song-\(index)")
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)
    }

    private func notYetArtistRow(_ artist: NotYetArtist) -> some View {
        HStack(spacing: Tokens.Spacing.m) {
            // A plain circle: the groove ring is invisible at this size (review of D3).
            Circle().fill(themed.palette.surfaceColor).frame(width: 48, height: 48)
                .overlay { Image(systemName: "person.fill").foregroundStyle(themed.palette.ink2Color) }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(artist.name).font(.body)
                StatusLine(.notYet)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(artist.name), artist")
        .accessibilityValue(RowState.notYet.voiceOverValue ?? "")
        .listRowBackground(Color.clear)
    }

    private func notYetAlbumRow(_ album: NotYetAlbum) -> some View {
        NotYetAlbumRow(title: album.title, detail: [album.kind ?? "Album", album.artist].joined(separator: " \u{00B7} "),
                       label: "\(album.title), \(album.kind ?? "Album") by \(album.artist)")
            .listRowBackground(Color.clear)
    }

    private func header(_ title: String) -> some View {
        Text(title).magpieDisplay(.title3).foregroundStyle(themed.palette.inkColor)
            .textCase(nil).accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func topRow(_ item: SearchItem, in sections: SearchSections) -> some View {
        switch item {
        case .song(let song):
            songRow(song, index: sections.songs.firstIndex(of: song) ?? 0, in: sections.songs, id: "search-top")
        case .artist(let artist):
            artistRow(artist).accessibilityIdentifier("search-top")
        case .album(let album):
            albumRow(album).accessibilityIdentifier("search-top")
        }
    }

    private func songRow(_ song: Song, index: Int, in songs: [Song], id: String? = nil) -> some View {
        Button {
            remember(model.query)
            app.play(songs, startAt: index)
        } label: {
            Artwork(song.coverArtId, side: 48) { SongRow(song: song, state: .library, artwork: $0) }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier(id ?? "search-song-\(index)")
        .contextMenu {
            Button("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") { app.player.playNext([song]) }
            Button("Add to Queue", systemImage: "text.line.last.and.arrowtriangle.forward") { app.player.addToEnd([song]) }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
    }

    private func artistRow(_ artist: Artist) -> some View {
        NavigationLink(value: Route.artist(id: artist.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(artist.coverArtId, side: 48) { SleeveArt(image: $0, side: 48).clipShape(Circle()) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(artist.name).font(.body)
                    Text(artist.albumCount == 1 ? "Artist \u{00B7} 1 album" : "Artist \u{00B7} \(artist.albumCount) albums")
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .simultaneousGesture(TapGesture().onEnded { remember(model.query) })
        .listRowBackground(Color.clear)
    }

    private func albumRow(_ album: Album) -> some View {
        NavigationLink(value: Route.album(id: album.id)) {
            HStack(spacing: Tokens.Spacing.m) {
                Artwork(album.coverArtId, side: 48) { SleeveArt(image: $0, side: 48) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(album.name).font(.body).lineLimit(2)
                    Text(["Album", album.artist].joined(separator: " \u{00B7} "))
                        .font(.footnote).foregroundStyle(themed.palette.ink2Color).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
        }
        .simultaneousGesture(TapGesture().onEnded { remember(model.query) })
        .listRowBackground(Color.clear)
    }

    private func remember(_ query: String) {
        RecentSearches().add(query)
        recents = RecentSearches().items
    }
}

/// The not-yet song a Try sheet is open for.
struct TryTarget: Identifiable {
    let id = UUID()
    let recording: ExternalRecording
}
