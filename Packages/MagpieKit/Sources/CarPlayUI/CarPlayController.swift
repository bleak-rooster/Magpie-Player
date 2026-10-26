#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import MediaPlayer
import Observation
import Playback
import UIKit

/// What the CarPlay screens read from the app. The app implements it over its session (with
/// address failover) and its in-memory artwork cache.
@MainActor
public protocol CarPlayLibrary: AnyObject, Sendable {
    func albumList(_ type: AlbumListType, size: Int) async throws -> [Album]
    func album(id: String) async throws -> Album
    func artists() async throws -> [Artist]
    func artist(id: String) async throws -> (Artist, [Album])
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> (Playlist, [Song])
    func search(_ query: String) async throws -> LibrarySearchResult
    /// The cover at least `pixelSide` pixels wide (cached in memory, never on disk), or nil.
    func artwork(coverArtId: String, pixelSide: Int) async -> UIImage?
    /// The library didn't answer at all (as opposed to answering with an error).
    func isOutOfReach(_ error: Error) -> Bool
    var recentSearches: [String] { get }
    func addRecentSearch(_ query: String)
}

/// What the car can show right now.
public enum CarPlayAvailability: Sendable, Hashable {
    /// A session is saved but the iPhone hasn't been unlocked since it restarted.
    case locked
    case notSetUp
    /// Signed in; `account` changes when a different server or user signs in.
    case ready(account: String)
}

/// Drives the CarPlay templates: tab roots Home · Library · Search (all `CPListTemplate`, C3),
/// pushed lists within the depth budget, the system search template, and Now Playing.
///
/// Lists are built as value models off the main thread and applied on it. A list on screen is
/// only ever updated in place (same rows, new text/playing/artwork); a change of shape is held
/// back until the list is off screen, so browsing never jumps (Amperfy #647).
@MainActor
public final class CarPlayController: NSObject {
    private let interface: CPInterfaceController
    private let library: any CarPlayLibrary
    private let player: Player
    private var sessionConfiguration: CPSessionConfiguration?
    private var keyboardLimited = false

    private var availability: CarPlayAvailability?
    private var tabBar: CPTabBarTemplate?
    private var home: ListBinding?
    private var libraryRoot: ListBinding?
    private var searchRoot: ListBinding?
    private var bindings: [ObjectIdentifier: ListBinding] = [:]
    private var watches: [Task<Void, Never>] = []

    private var searchGeneration = 0
    private var lastSearch = ""
    /// Artwork loading for the search template's current results.
    private var searchArtwork: ListBinding?

    /// Home shelves ask for this many albums each (the rows are capped by `CarPlayRows`).
    private static let homeFetchSize = CarPlayRows.homeShelfSize
    /// Navidrome's largest album-list page.
    private static let albumListSize = 500
    /// Artwork requests in flight per list.
    private static let artworkConcurrency = 4

    public init(interfaceController: CPInterfaceController, library: any CarPlayLibrary, player: Player) {
        self.interface = interfaceController
        self.library = library
        self.player = player
        super.init()
        interface.delegate = self
        let configuration = CPSessionConfiguration(delegate: self)
        sessionConfiguration = configuration
        keyboardLimited = configuration.limitedUserInterfaces.contains(.keyboard)
        configureNowPlaying()
        watchPlayer()
    }

    /// Shows the tabs when ready, otherwise a list that describes why not. Rebuilds only when the
    /// availability (or the signed-in account) changes.
    public func setAvailability(_ new: CarPlayAvailability) {
        guard new != availability else { return }
        availability = new
        resetBindings()
        switch new {
        case .locked: showStateRoot(.locked)
        case .notSetUp: showStateRoot(.notSetUp)
        case .ready: showTabs()
        }
    }

    /// The car disconnected: stop all work.
    public func disconnect() {
        watches.forEach { $0.cancel() }
        watches = []
        resetBindings()
        searchArtwork?.cancel()
        searchArtwork = nil
        interface.delegate = nil
        sessionConfiguration = nil
    }

    // MARK: - Roots

    private func showStateRoot(_ state: CarPlayState) {
        let template = CPListTemplate(title: "Magpie", sections: [])
        let binding = bind(template)
        apply(CarPlayRows.state(state), to: binding, placeholder: true)
        interface.setRootTemplate(template, animated: false, completion: nil)
    }

    private func showTabs() {
        let homeList = tabRoot("Home", symbol: "house.fill")
        let libraryList = tabRoot("Library", symbol: "square.stack.fill")
        let searchList = tabRoot("Search", symbol: "magnifyingglass")
        let tabs = CPTabBarTemplate(templates: [homeList, libraryList, searchList])
        tabs.delegate = self
        tabBar = tabs
        home = bind(homeList)
        libraryRoot = bind(libraryList)
        searchRoot = bind(searchList)
        if let libraryRoot { apply(CarPlayRows.libraryRoot(), to: libraryRoot, placeholder: false) }
        refreshSearchRoot()
        loadHome()
        interface.setRootTemplate(tabs, animated: false, completion: nil)
    }

    private func tabRoot(_ title: String, symbol: String) -> CPListTemplate {
        let template = CPListTemplate(title: title, sections: [])
        template.tabTitle = title
        template.tabImage = UIImage(systemName: symbol)
        template.showsSpinnerWhileEmpty = true
        return template
    }

    private func loadHome() {
        guard let home else { return }
        let library = library
        let size = Self.homeFetchSize
        load(home) {
            async let recent = library.albumList(.recent, size: size)
            async let newest = library.albumList(.newest, size: size)
            async let frequent = library.albumList(.frequent, size: size)
            let (r, n, f) = try await (recent, newest, frequent)
            return { _ in CarPlayRows.home(recent: r, newest: n, frequent: f) }
        }
    }

    private func refreshSearchRoot() {
        guard let searchRoot else { return }
        let recents = library.recentSearches
        let limited = keyboardLimited
        searchRoot.content = { _ in CarPlayRows.searchRoot(recents: recents, keyboardLimited: limited) }
        Task { await refresh(searchRoot) }
    }

    // MARK: - Navigation

    /// Browse depth counting the tab root as 1, whichever way the system reports the tab bar.
    private var browseDepth: Int {
        let roots = [home, libraryRoot, searchRoot].compactMap { $0?.template }
        let pushed = interface.templates.filter { t in
            !(t is CPTabBarTemplate) && !(t is CPNowPlayingTemplate) && !roots.contains { $0 === t }
        }
        return 1 + pushed.count
    }

    private func perform(_ action: RowAction) {
        switch action {
        case .none: break
        case .open(let destination): open(destination)
        case .play(let request): play(request)
        }
    }

    private func open(_ destination: CPDestination) {
        guard CPNavigator.allowsPush(atDepth: browseDepth) else {
            Log.logger("carplay").error("refused a push past the depth budget")
            return
        }
        if destination == .search {
            let search = CPSearchTemplate()
            search.delegate = self
            interface.pushTemplate(search, animated: true, completion: nil)
            return
        }
        let template = CPListTemplate(title: destination.title, sections: [])
        template.showsSpinnerWhileEmpty = true
        let binding = bind(template)
        interface.pushTemplate(template, animated: true, completion: nil)
        load(binding, fetcher(for: destination))
    }

    private typealias Content = @Sendable (String?) -> [CPSectionModel]

    private func fetcher(for destination: CPDestination) -> @MainActor () async throws -> Content {
        let library = library
        switch destination {
        case .playlists:
            return { let p = try await library.playlists(); return { _ in CarPlayRows.playlists(p) } }
        case .artists:
            return { let a = try await library.artists(); return { _ in CarPlayRows.artists(a) } }
        case .albums:
            let size = Self.albumListSize
            return {
                let a = try await library.albumList(.alphabeticalByName, size: size)
                return { _ in CarPlayRows.albums(a) }
            }
        case .album(let id, _):
            return { let a = try await library.album(id: id); return { CarPlayRows.album(a, playingId: $0) } }
        case .playlist(let id, _):
            return {
                let (p, songs) = try await library.playlist(id: id)
                return { CarPlayRows.playlist(p, songs: songs, playingId: $0) }
            }
        case .artist(let id, _):
            return {
                let (a, albums) = try await library.artist(id: id)
                return { _ in CarPlayRows.artist(a, albums: albums) }
            }
        case .searchResults(let query):
            return {
                let r = try await library.search(query)
                return { CarPlayRows.searchResults(r, playingId: $0) }
            }
        case .search:
            return { { _ in [] } }
        }
    }

    // MARK: - Playback

    private func play(_ request: CPPlayRequest) {
        switch request {
        case .songs(let songs, let index):
            start(songs, at: index, shuffled: false)
        case .album(let id, let shuffled):
            Task {
                do {
                    let album = try await library.album(id: id)
                    start(album.songs ?? [], at: 0, shuffled: shuffled)
                } catch {
                    showUnavailable(error)
                }
            }
        case .artistShuffle(let id):
            Task {
                do {
                    let library = library
                    let (_, albums) = try await library.artist(id: id)
                    let songs = try await withThrowingTaskGroup(of: [Song].self) { group in
                        for album in albums { group.addTask { try await library.album(id: album.id).songs ?? [] } }
                        var all: [Song] = []
                        for try await songs in group { all += songs }
                        return all
                    }
                    start(songs, at: 0, shuffled: true)
                } catch {
                    showUnavailable(error)
                }
            }
        }
    }

    private func start(_ songs: [Song], at index: Int, shuffled: Bool) {
        guard !songs.isEmpty else { return }
        if shuffled {
            player.play(songs, startAt: Int.random(in: songs.indices))
            player.setShuffled(true)
        } else {
            player.play(songs, startAt: min(max(index, 0), songs.count - 1))
        }
        showNowPlaying()
    }

    private func showNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        if interface.topTemplate === nowPlaying { return }
        if interface.templates.contains(where: { $0 === nowPlaying }) {
            interface.pop(to: nowPlaying, animated: true, completion: nil)
        } else {
            interface.pushTemplate(nowPlaying, animated: true, completion: nil)
        }
    }

    /// Only in direct response to a tap (critique M3). Describes; never instructs.
    private func showUnavailable(_ error: Error) {
        guard interface.presentedTemplate == nil else { return }
        let title = library.isOutOfReach(error) ? "Your library is out of reach" : "Your library didn't send this"
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interface.dismissTemplate(animated: true, completion: nil)
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [title], actions: [ok]), animated: true, completion: nil)
    }

    /// Now Playing shows the system's view of `MPNowPlayingInfoCenter` (the real square cover,
    /// H4). Our buttons: shuffle and repeat.
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.allowsMiniPlayer = true
        updateNowPlayingButtons()
    }

    private func updateNowPlayingButtons() {
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            guard let player = self?.player else { return }
            player.setShuffled(!player.isShuffled)
        }
        shuffle.isSelected = player.isShuffled
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            guard let player = self?.player else { return }
            player.repeatMode = player.repeatMode.next
        }
        repeatButton.isSelected = player.repeatMode != .off
        CPNowPlayingTemplate.shared.updateNowPlayingButtons([shuffle, repeatButton])

        // The system draws the shuffle/repeat glyphs from these.
        let commands = MPRemoteCommandCenter.shared()
        commands.changeShuffleModeCommand.currentShuffleType = player.isShuffled ? .items : .off
        commands.changeRepeatModeCommand.currentRepeatType = switch player.repeatMode {
        case .off: .off
        case .all: .all
        case .one: .one
        }
    }

    private struct PlayerModes: Equatable, Sendable {
        var shuffled: Bool
        var repeatMode: RepeatMode
    }

    private func watchPlayer() {
        let player = player
        watches.append(Task { [weak self] in
            let current = Observations { @MainActor in player.queue.current?.song.id }
            var last: String??
            for await id in current where id != last {
                last = id
                guard let self else { return }
                for binding in self.bindings.values where binding.content != nil {
                    await self.refresh(binding)
                }
            }
        })
        watches.append(Task { [weak self] in
            let modes = Observations { @MainActor in PlayerModes(shuffled: player.isShuffled, repeatMode: player.repeatMode) }
            var last: PlayerModes?
            for await m in modes where m != last {
                last = m
                self?.updateNowPlayingButtons()
            }
        })
    }

    // MARK: - Lists

    private func bind(_ template: CPListTemplate) -> ListBinding {
        let binding = ListBinding(template: template)
        bindings[ObjectIdentifier(template)] = binding
        return binding
    }

    private func resetBindings() {
        for binding in bindings.values { binding.cancel() }
        bindings = [:]
        tabBar = nil
        home = nil
        libraryRoot = nil
        searchRoot = nil
    }

    /// Fetches on the caller's behalf, then builds the rows off the main thread. A failure shows a
    /// state row only when the list has nothing real yet; otherwise what's shown stays.
    private func load(_ binding: ListBinding, _ fetch: @escaping @MainActor () async throws -> Content) {
        binding.loadTask?.cancel()
        binding.loadTask = Task { [weak self] in
            do {
                let content = try await fetch()
                guard !Task.isCancelled, let self else { return }
                binding.content = content
                await self.refresh(binding)
            } catch {
                guard !Task.isCancelled, let self, binding.isPlaceholder else { return }
                let state: CarPlayState = self.library.isOutOfReach(error) ? .outOfReach : .failed
                self.apply(CarPlayRows.state(state), to: binding, placeholder: true)
            }
        }
    }

    /// Rebuilds the binding's rows (off main) for the song playing now and applies them.
    private func refresh(_ binding: ListBinding) async {
        guard let content = binding.content else { return }
        let playing = player.queue.current?.song.id
        let sections = await Task.detached(priority: .userInitiated) { content(playing) }.value
        guard bindings[ObjectIdentifier(binding.template)] === binding else { return }
        apply(sections, to: binding, placeholder: false)
    }

    private func apply(_ sections: [CPSectionModel], to binding: ListBinding, placeholder: Bool) {
        let fitted = clamp(sections, maxItems: Int(CPListTemplate.maximumItemCount),
                           maxSections: Int(CPListTemplate.maximumSectionCount))
        if !binding.shown.isEmpty, !needsRebuild(old: binding.shown, new: fitted) {
            updateInPlace(binding, fitted)
            binding.isPlaceholder = placeholder
            return
        }
        if !binding.isPlaceholder, isVisible(binding.template) {
            binding.pending = (fitted, placeholder)   // never reshape a list being browsed
            return
        }
        rebuild(binding, fitted, placeholder: placeholder)
    }

    private func rebuild(_ binding: ListBinding, _ sections: [CPSectionModel], placeholder: Bool) {
        var items: [String: CPListItem] = [:]
        let cpSections = sections.map { section in
            let sectionItems = section.rows.map { row in
                let item = CPListItem(text: row.title, detailText: row.detail)
                configure(item, row)
                items[row.id] = item
                return item
            }
            return CPListSection(items: sectionItems, header: section.header, sectionIndexTitle: nil)
        }
        binding.items = items
        binding.shown = sections
        binding.isPlaceholder = placeholder
        binding.pending = nil
        binding.artworkKeys = [:]
        binding.template.updateSections(cpSections)
        loadArtwork(binding)
    }

    private func updateInPlace(_ binding: ListBinding, _ sections: [CPSectionModel]) {
        for row in sections.flatMap(\.rows) {
            guard let item = binding.items[row.id] else { continue }
            if item.text != row.title { item.setText(row.title) }
            if item.detailText != row.detail { item.setDetailText(row.detail) }
            configure(item, row)
        }
        binding.shown = sections
        loadArtwork(binding)
    }

    private func configure(_ item: CPListItem, _ row: CPRowModel) {
        let action = row.action
        item.isEnabled = action != .none
        if item.isPlaying != row.playing { item.isPlaying = row.playing }
        if case .open = action { item.accessoryType = .disclosureIndicator } else { item.accessoryType = .none }
        item.handler = action == .none ? nil : { [weak self] _, completion in
            self?.perform(action)
            completion()
        }
    }

    /// A list counts as on screen when it is the top template, or the selected tab of the tab
    /// bar at the top.
    private func isVisible(_ template: CPTemplate) -> Bool {
        let top = interface.topTemplate
        if top === template { return true }
        if let tabBar, top == nil || top === tabBar, tabBar.selectedTemplate === template { return true }
        return false
    }

    /// Applies a held-back rebuild once its list is off screen (or about to come back).
    private func flushPending(_ binding: ListBinding?, force: Bool = false) {
        guard let binding, let pending = binding.pending else { return }
        guard force || !isVisible(binding.template) else { return }
        rebuild(binding, pending.sections, placeholder: pending.placeholder)
    }

    // MARK: - Artwork

    /// Loads cover art for rows whose artwork changed, a few at a time, sized and (for not-yet
    /// rows) drawn as records off the main thread.
    private func loadArtwork(_ binding: ListBinding) {
        var wanted: [(rowId: String, key: String, round: Bool)] = []
        for row in binding.shown.flatMap(\.rows) {
            guard let key = row.artworkKey else { continue }
            let tag = "\(key)|\(row.round)"
            guard binding.artworkKeys[row.id] != tag else { continue }
            binding.artworkKeys[row.id] = tag
            wanted.append((row.id, key, row.round))
        }
        guard !wanted.isEmpty else { return }
        let side = CPListItem.maximumImageSize
        let traitScale = interface.carTraitCollection.displayScale
        let scale = traitScale > 0 ? traitScale : 2
        let pixelSide = Int((max(side.width, side.height) * scale).rounded(.up))
        let library = library
        let task = Task { [weak binding] in
            await withTaskGroup(of: (String, String, UIImage?).self) { group in
                var next = wanted.makeIterator()
                func enqueue() {
                    guard let w = next.next() else { return }
                    group.addTask {
                        guard let raw = await library.artwork(coverArtId: w.key, pixelSide: pixelSide) else {
                            return (w.rowId, w.key, nil)
                        }
                        return (w.rowId, "\(w.key)|\(w.round)",
                                CarPlayArtwork.prepare(raw, size: side, scale: scale, round: w.round))
                    }
                }
                for _ in 0..<Self.artworkConcurrency { enqueue() }
                for await (rowId, tag, image) in group {
                    enqueue()
                    guard let binding, let image, binding.artworkKeys[rowId] == tag,
                          let item = binding.items[rowId] else { continue }
                    item.setImage(image)
                }
            }
        }
        binding.artworkTasks.append(task)
    }
}

// MARK: - Delegates

extension CarPlayController: CPInterfaceControllerDelegate {
    public func templateWillAppear(_ aTemplate: CPTemplate, animated: Bool) {
        if aTemplate === tabBar {
            flushPending(tabBar.flatMap { bindings[ObjectIdentifier($0.selectedTemplate ?? $0)] }, force: true)
        } else {
            flushPending(bindings[ObjectIdentifier(aTemplate)], force: true)
        }
    }

    public func templateDidAppear(_ aTemplate: CPTemplate, animated: Bool) {}

    public func templateWillDisappear(_ aTemplate: CPTemplate, animated: Bool) {}

    public func templateDidDisappear(_ aTemplate: CPTemplate, animated: Bool) {
        let id = ObjectIdentifier(aTemplate)
        guard let binding = bindings[id] else { return }
        let isTabRoot = [home, libraryRoot, searchRoot].contains { $0 === binding }
        if !isTabRoot, !interface.templates.contains(where: { $0 === aTemplate }) {
            binding.cancel()   // popped
            bindings[id] = nil
            return
        }
        flushPending(binding)
    }
}

extension CarPlayController: CPTabBarTemplateDelegate {
    public func tabBarTemplate(_ tabBarTemplate: CPTabBarTemplate, didSelect selectedTemplate: CPTemplate) {
        for binding in [home, libraryRoot, searchRoot] where binding?.template !== selectedTemplate {
            flushPending(binding)
        }
        if selectedTemplate === home?.template {
            loadHome()
        } else if selectedTemplate === searchRoot?.template {
            refreshSearchRoot()
        }
    }
}

extension CarPlayController: CPSearchTemplateDelegate {
    public func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                               completionHandler: @escaping ([CPListItem]) -> Void) {
        searchGeneration += 1
        let generation = searchGeneration
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completionHandler([])
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard generation == searchGeneration else { return completionHandler([]) }
            do {
                let result = try await library.search(query)
                guard generation == searchGeneration else { return completionHandler([]) }
                lastSearch = query
                let rows = await Task.detached(priority: .userInitiated) { CarPlayRows.searchItems(result) }.value
                let fitted = Array(rows.prefix(Int(CPListTemplate.maximumItemCount)))
                let binding = ListBinding(template: CPListTemplate(title: nil, sections: []))
                var items: [String: CPListItem] = [:]
                let list = fitted.map { row in
                    let item = CPListItem(text: row.title, detailText: row.detail)
                    item.userInfo = row.action
                    items[row.id] = item
                    return item
                }
                completionHandler(list)
                // Artwork arrives after the results are shown.
                searchArtwork?.cancel()
                searchArtwork = binding
                binding.items = items
                binding.shown = [CPSectionModel(header: nil, rows: fitted)]
                loadArtwork(binding)
            } catch {
                let state: CarPlayState = library.isOutOfReach(error) ? .outOfReach : .failed
                completionHandler(CarPlayRows.state(state).flatMap(\.rows).map {
                    CPListItem(text: $0.title, detailText: $0.detail)
                })
            }
        }
    }

    public func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                               completionHandler: @escaping () -> Void) {
        if let action = item.userInfo as? RowAction, action != .none {
            rememberSearch()
            perform(action)
        }
        completionHandler()
    }

    public func searchTemplateSearchButtonPressed(_ searchTemplate: CPSearchTemplate) {
        rememberSearch()
    }

    private func rememberSearch() {
        guard !lastSearch.isEmpty else { return }
        library.addRecentSearch(lastSearch)
        refreshSearchRoot()
    }
}

extension CarPlayController: CPSessionConfigurationDelegate {
    public nonisolated func sessionConfiguration(_ sessionConfiguration: CPSessionConfiguration,
                                                 limitedUserInterfacesChanged limitedUserInterfaces: CPLimitableUserInterface) {
        let limited = limitedUserInterfaces.contains(.keyboard)
        Task { @MainActor in
            guard limited != self.keyboardLimited else { return }
            self.keyboardLimited = limited
            self.refreshSearchRoot()   // same rows: updated in place
        }
    }
}

// MARK: - Support

/// One `CPListTemplate` and what it shows.
@MainActor
final class ListBinding {
    let template: CPListTemplate
    /// The models currently on screen (after clamping).
    var shown: [CPSectionModel] = []
    /// Showing loading or a state row, not real content: may be replaced even while on screen.
    var isPlaceholder = true
    /// A rebuild held back while the list is on screen.
    var pending: (sections: [CPSectionModel], placeholder: Bool)?
    var items: [String: CPListItem] = [:]
    /// Row id → artwork tag requested for it.
    var artworkKeys: [String: String] = [:]
    /// Rebuilds the rows for the song playing now (nil when nothing has loaded).
    var content: (@Sendable (String?) -> [CPSectionModel])?
    var loadTask: Task<Void, Never>?
    var artworkTasks: [Task<Void, Never>] = []

    init(template: CPListTemplate) { self.template = template }

    func cancel() {
        loadTask?.cancel()
        artworkTasks.forEach { $0.cancel() }
        artworkTasks = []
    }
}

enum CarPlayArtwork {
    /// Square cover (aspect-filled) or record, at the list's image size and the car's scale.
    nonisolated static func prepare(_ image: UIImage, size: CGSize, scale: CGFloat, round: Bool) -> UIImage {
        if round { return RoundArt.render(image, size: size, scale: scale) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let aspect = image.size.height > 0 ? image.size.width / image.size.height : 1
            var rect = CGRect(origin: .zero, size: size)
            if aspect > 1 { rect.size.width = size.height * aspect } else { rect.size.height = size.width / aspect }
            rect.origin = CGPoint(x: (size.width - rect.width) / 2, y: (size.height - rect.height) / 2)
            image.draw(in: rect)
        }
    }
}
#endif
