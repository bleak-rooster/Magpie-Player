import DesignSystem
import MagpieCore
import Search
import SwiftUI

/// Library › Genres (spec §4, Task 19): Grouped (each group opens to its subgenres) or All genres (A–Z), the choice
/// kept in Preferences. A group's title opens the group page, a subgenre its genre page. Edit renames and hides groups.
/// Offline it lists the genres of the songs on the phone.
struct GenresView: View {
    @Environment(AppModel.self) private var model
    @State private var sections: Loadable<[GenreGroupSection]> = .loading
    @State private var genres: Loadable<[Genre]> = .loading
    /// Edit lists every group with genres, hidden ones too.
    @State private var everyGroup: [GenreGroupSection] = []
    @State private var editing = false
    @State private var renaming: GenreGroup?
    @State private var newName = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    private let themed = Themed()

    var body: some View {
        let indexSections = indexSections, indexIds = indexIds   // once per update
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.l) {
                Picker("Show", selection: mode) {
                    Text("Grouped").tag(GenreViewMode.grouped)
                    Text("All genres").tag(GenreViewMode.all)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                .accessibilityIdentifier("genres-mode")
                if model.isOffline {
                    OfflineNotice().padding(.horizontal, Tokens.Spacing.largeTitleMargin)
                }
                if editing {
                    editList
                } else if model.preferences.genres.mode == .grouped {
                    LoadableView(state: sections, retry: load) { sections in
                        if sections.isEmpty { empty } else { GenreGroupRows(sections: sections) }
                    }
                } else {
                    LoadableView(state: genres, retry: load) { genres in
                        if genres.isEmpty { empty } else { allList(genres) }
                    }
                }
            }
            .padding(.vertical, Tokens.Spacing.l)
        }
        // P2: over All genres, or the groups list; not while editing.
        .letterIndex(available: Set(indexSections.map(\.key)), hidden: editing || indexSections.isEmpty) { letter in
            guard let target = LetterIndex.target(letter, in: indexSections) else { return }
            withAnimation(nil) { proxy.scrollTo(indexIds[target.range.lowerBound], anchor: .top) }
        }
        }
        .refreshable {
            await RefreshSafety.run {   // Round 13 Z2
                if model.isOffline { await model.checkReachability() }
                await load()
            }
        }
        .navigationTitle("Genres")
        .magpieScreen()
        .toolbar {
            if model.preferences.genres.mode == .grouped {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(editing ? "Done" : "Edit") { editing.toggle() }
                        .accessibilityIdentifier("genres-edit")
                }
            }
        }
        .alert("Rename group", isPresented: isRenaming, presenting: renaming) { group in
            TextField("Name", text: $newName)
            Button("Rename") { model.renameGroup(group.id, to: newName) }
            Button("Cancel", role: .cancel) {}
        } message: { group in
            if let original = GenreGroups.builtIn.first(where: { $0.id == group.id }) {
                Text("Leave it empty to call it \(original.name) again.")
            }
        }
        // Again when offline mode changes, the songs on the phone change, or an override changes the groups.
        .task(id: LoadKey(page: model.offlinePageKey, genres: model.preferences.genres)) { await load() }
    }

    /// The names the letter index runs over (group names in their own order, or genres A–Z) and their row ids.
    private var indexNames: [String] {
        model.preferences.genres.mode == .grouped ? (sections.value ?? []).map(\.group.name) : (genres.value ?? []).map(\.name)
    }
    private var indexIds: [String] {
        model.preferences.genres.mode == .grouped ? (sections.value ?? []).map(\.group.id) : (genres.value ?? []).map(\.name)
    }
    private var indexSections: [LetterIndex.Section] { LetterIndex.sections(indexNames) { $0 } }

    private struct LoadKey: Hashable {
        let page: String
        let genres: GenrePreferences
    }

    private var mode: Binding<GenreViewMode> {
        Binding(get: { model.preferences.genres.mode },
                set: { new in
                    editing = false
                    model.updatePreferences { $0.genres.mode = new }
                })
    }

    private var isRenaming: Binding<Bool> {
        Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })
    }

    private var empty: some View {
        ContentUnavailableView("No genres yet", systemImage: "guitars",
                               description: Text(model.isOffline ? "Genres of the songs on this phone show here."
                                                                 : "Genres show here once your music is tagged with them."))
            .accessibilityIdentifier("genres-empty")
    }

    private func allList(_ genres: [Genre]) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(genres, id: \.name) { genre in
                GenreRow(genre: genre).id(genre.name)
                Divider().overlay(themed.palette.sepColor).padding(.leading, Tokens.Spacing.margin)
            }
        }
    }

    /// Every group with genres: Rename, and Hide or Show.
    private var editList: some View {
        let p = themed.palette
        let hidden = model.preferences.genres.hidden
        return LazyVStack(spacing: 0) {
            ForEach(everyGroup, id: \.group.id) { section in
                let isHidden = hidden.contains(section.group.id)
                // Stacked at accessibility sizes so the name and both buttons keep their full width (D15).
                let layout = typeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Tokens.Spacing.s))
                    : AnyLayout(HStackLayout(spacing: Tokens.Spacing.m))
                layout {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(section.group.name).font(.body)
                            .foregroundStyle(isHidden ? p.ink2Color : p.inkColor)
                        if isHidden {
                            Label("Hidden", systemImage: "eye.slash").font(.footnote).foregroundStyle(p.ink2Color)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    if !typeSize.isAccessibilitySize { Spacer() }
                    HStack(spacing: Tokens.Spacing.m) {
                        Button("Rename") {
                            newName = section.group.name
                            renaming = section.group
                        }
                        .frame(minHeight: Tokens.minHitSize)
                        .accessibilityLabel("Rename \(section.group.name)")
                        Button(isHidden ? "Show" : "Hide") { model.setGroupHidden(section.group.id, !isHidden) }
                            .frame(minWidth: Tokens.minHitSize, minHeight: Tokens.minHitSize)
                            .accessibilityLabel("\(isHidden ? "Show" : "Hide") \(section.group.name)")
                            .accessibilityIdentifier("genre-hide-\(section.group.id)")
                    }
                }
                .buttonStyle(.borderless)
                .tint(p.accentInkColor)
                .padding(.horizontal, Tokens.Spacing.margin)
                .frame(minHeight: 52)
                Divider().overlay(p.sepColor).padding(.leading, Tokens.Spacing.margin)
            }
        }
    }

    private func load() async {
        do {
            if editing || model.preferences.genres.mode == .grouped {
                let all = try await model.genreSectionsIncludingHidden()
                everyGroup = all
                let hidden = model.preferences.genres.hidden
                sections = .loaded(all.filter { !hidden.contains($0.group.id) })
            } else {
                genres = .loaded(try await model.allGenres())
            }
        } catch {
            sections = sections.failing(error)   // Round 13 Z2: also never for a load cut short
            genres = genres.failing(error)
        }
    }
}

/// Groups that open to their subgenres. The group's title opens the group page; each subgenre opens its genre page.
struct GenreGroupRows: View {
    let sections: [GenreGroupSection]
    @State private var expanded: Set<String> = []
    private let themed = Themed()

    var body: some View {
        let p = themed.palette
        LazyVStack(spacing: 0) {
            ForEach(sections, id: \.group.id) { section in
                DisclosureGroup(isExpanded: isExpanded(section.group.id)) {
                    ForEach(section.genres, id: \.name) { genre in
                        GenreRow(genre: genre).padding(.leading, Tokens.Spacing.l)
                    }
                } label: {
                    NavigationLink(value: Route.genreGroup(id: section.group.id)) {
                        GenreLabel(name: section.group.name, albums: section.albumCount, songs: section.songCount,
                                   font: .title3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("genre-group-\(section.group.id)")
                }
                .tint(p.ink2Color)
                .padding(.horizontal, Tokens.Spacing.margin)
                .id(section.group.id)   // the letter index's target (P2)
                Divider().overlay(p.sepColor).padding(.leading, Tokens.Spacing.margin)
            }
        }
        .foregroundStyle(p.inkColor)
    }

    private func isExpanded(_ id: String) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) },
                set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }
}

/// A genre that opens its genre page.
struct GenreRow: View {
    let genre: Genre
    private let themed = Themed()

    var body: some View {
        NavigationLink(value: Route.genre(name: genre.name)) {
            GenreLabel(name: genre.name, albums: genre.albumCount, songs: genre.songCount, font: .body,
                       countsKnown: genre.countsKnown)
                .padding(.horizontal, Tokens.Spacing.margin)
        }
        .buttonStyle(.plain)
        .foregroundStyle(themed.palette.inkColor)
        .accessibilityIdentifier("genre-\(genre.name)")
    }
}

/// A name with its album and song counts (in the rounded number face), and a chevron.
struct GenreLabel: View {
    let name: String
    let albums: Int
    let songs: Int
    let font: Font
    /// False when the server gave no counts: none are shown.
    var countsKnown = true
    @Environment(\.magpieTheme) private var theme
    private let themed = Themed()

    var body: some View {
        HStack(spacing: Tokens.Spacing.m) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(font).lineLimit(2)
                if countsKnown {
                    Text(GenreLabel.counts(albums: albums, songs: songs))
                        .font(theme.numberFont(.footnote)).foregroundStyle(themed.palette.ink2Color)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold))
                .foregroundStyle(themed.palette.ink2Color).accessibilityHidden(true)
        }
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    /// "1 album, 12 songs".
    static func counts(albums: Int, songs: Int) -> String {
        "\(albums) \(albums == 1 ? "album" : "albums"), \(songs) \(songs == 1 ? "song" : "songs")"
    }
}
