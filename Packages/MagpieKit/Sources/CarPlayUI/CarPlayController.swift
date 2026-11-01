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
public protocol CarPlayLibrary: AnyObject, Sendable, CarPlayCustomisationLibrary {
    func albumList(_ type: AlbumListType, size: Int) async throws -> [Album]
    func album(id: String) async throws -> Album
    func artists() async throws -> [Artist]
    func artist(id: String) async throws -> (Artist, [Album])
    func playlists() async throws -> [Playlist]
    func playlist(id: String) async throws -> (Playlist, [Song])
    /// The library's songs and albums for `query`, and songs from outside it.
    func search(_ query: String) async throws -> CarPlaySearchResult
    /// The cover at least `pixelSide` pixels wide (cached in memory, never on disk), or nil.
    func artwork(coverArtId: String, pixelSide: Int) async -> UIImage?
    /// The library didn't answer at all (as opposed to answering with an error).
    func isOutOfReach(_ error: Error) -> Bool
    /// T3: whether iOS's Local Network setting explains an out-of-reach library.
    var localNetwork: CPLocalNetwork { get }
    var recentSearches: [String] { get }
    func addRecentSearch(_ query: String)
    /// The search template closed: drop what was held for its results (R15: outside art goes with the search).
    func searchClosed()

    // Finds (Task 7.1d). The reads below are observable: the controller follows them with `Observations`.

    /// The phone's Finds shelf (New finds, finds with days left); nil when no Finds library is chosen.
    var findsShelf: CPFindsShelf? { get }
    /// Reads the Finds library again.
    func refreshFinds() async
    /// The song is a find that may be kept now: the phone's Finds row offers Keep for it.
    func mayKeep(songId: String) -> Bool
    /// Keeps the find's release through the phone's Keep (no Bring in more from the car, D5).
    func keep(songId: String) async -> CPKeepResult
    /// Whether a not-yet song can be tried from the car, and how.
    var tryOffer: CPTryOffer { get }
    /// "Try it next" (D6): the phone's Try; with nothing playing, a library mix seeded by the artist starts first.
    func tryNext(_ recording: ExternalRecording) async -> CPTryResult
}

/// What the car can show right now.
public enum CarPlayAvailability: Sendable, Hashable {
    /// A session is saved but the iPhone hasn't been unlocked since it restarted.
    case locked
    case notSetUp
    /// Signed in; `account` changes when a different server or user signs in.
    case ready(account: String)
}

/// Drives the CarPlay templates: tab roots Home · Library · Finds · Search (all `CPListTemplate`, C3, D12),
/// pushed lists within the depth budget, the system search template, and Now Playing (Keep for finds).
///
/// Lists are built as value models off the main thread and applied on it. A list on screen is
/// only ever updated in place (same rows, new text/playing/artwork); a change of shape is held
/// back until the list is off screen, so browsing never jumps (Amperfy #647).
@MainActor
public final class CarPlayController: NSObject {
    private let interface: any CarPlayInterface
    let library: any CarPlayLibrary
    private let player: Player
    private var sessionConfiguration: CPSessionConfiguration?
    private var keyboardLimited = false

    private var availability: CarPlayAvailability?
    private var tabBar: CPTabBarTemplate?
    var home: ListBinding?
    var libraryRoot: ListBinding?
    var findsRoot: ListBinding?
    private var searchRoot: ListBinding?
    var bindings: [ObjectIdentifier: ListBinding] = [:]
    var watches: [Task<Void, Never>] = []
    /// Follows the owner's Home and Library layout for the tabs shown now (Task 22).
    var layoutWatch: Task<Void, Never>?

    private var searchResults = LatestResults<CPListItem>()
    private var searchTask: Task<Void, Never>?
    private var lastSearch = ""
    /// Artwork loading for the search template's current results.
    private var searchArtwork: ListBinding?
    /// Finds whose Keep (from Now Playing) is running, and finds kept from it, by song id.
    private var keeping: Set<String> = []
    private var kept: Set<String> = []
    /// The plain record shown for a not-yet row (no cover to put on its label).
    private var blankRecord: UIImage?

    /// Navidrome's largest album-list page.
    private static let albumListSize = 500
    /// Artwork requests in flight per list.
    private static let artworkConcurrency = 4

    public init(interfaceController: any CarPlayInterface, library: any CarPlayLibrary, player: Player) {
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
        watchFinds()
        watchSleepTimer()
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
        searchTask?.cancel()
        library.searchClosed()
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
        // Four tabs where the car allows four (read at runtime); otherwise Finds is the one left out.
        let findsList = CPTabBarTemplate.maximumTabCount >= 4 ? tabRoot("Finds", symbol: "record.circle") : nil
        let tabs = CPTabBarTemplate(templates: [homeList, libraryList, findsList, searchList].compactMap { $0 })
        tabs.delegate = self
        tabBar = tabs
        home = bind(homeList)
        libraryRoot = bind(libraryList)
        findsRoot = findsList.map(bind)
        searchRoot = bind(searchList)
        if let libraryRoot {
            let rows = CarPlayRows.libraryRoot(library.libraryRows, hasFindsTab: findsList != nil)
            apply(rows, to: libraryRoot, placeholder: CarPlayRows.isPlaceholder(rows))
        }
        refreshFindsRoot()
        refreshSearchRoot()
        loadHome()
        watchLayout()
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
        loadCustomHome()
    }

    /// The Finds tab shows the phone's shelf as it is now (days left are counted again on each refresh).
    private func refreshFindsRoot() {
        guard let findsRoot else { return }
        let shelf = library.findsShelf
        findsRoot.content = { CarPlayRows.finds(shelf, playingId: $0) }
        Task { await refresh(findsRoot) }
    }

    /// Follows the shelf (a find arrived, was played, kept or let go): rows update in place, and a change of shape
    /// waits until the tab is off screen (M2).
    private func watchFinds() {
        let library = library
        watches.append(Task { [weak self] in
            let shelves = Observations { @MainActor in library.findsShelf }
            var last: CPFindsShelf??
            for await shelf in shelves where shelf != last {
                last = shelf
                self?.refreshFindsRoot()
            }
        })
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
        let roots = [home, libraryRoot, findsRoot, searchRoot].compactMap { $0?.template }
        let pushed = interface.templates.filter { t in
            !(t is CPTabBarTemplate) && !(t is CPNowPlayingTemplate) && !roots.contains { $0 === t }
        }
        return 1 + pushed.count
    }

    func perform(_ action: RowAction) {
        switch action {
        case .none: break
        case .open(let destination): open(destination)
        case .play(let request): play(request)
        case .tryNext(let recording): offerTry(recording)
        case .onItsWay: showOnItsWay()
        }
    }

    /// R20: a song already on its way: "On its way" / "It goes next when it's here.", OK. Never a second Try.
    private func showOnItsWay() {
        guard interface.presentedTemplate == nil else { return }
        let ok = CPAlertAction(title: CPOnItsWay.ok, style: .cancel) { [weak self] _ in
            self?.interface.dismissTemplate(animated: true, completion: nil)
        }
        interface.presentTemplate(CPActionSheetTemplate(title: CPOnItsWay.title, message: CPOnItsWay.message, actions: [ok]),
                                  animated: true, completion: nil)
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

    typealias Content = @Sendable (String?) -> [CPSectionModel]

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
                let offer = library.tryOffer
                return { CarPlayRows.searchResults(r.library, notYet: r.notYet, offer: offer, onTheirWay: r.onTheirWay,
                                                   playingId: $0) }
            }
        case .search:
            return { { _ in [] } }
        default:
            return customFetcher(for: destination)
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
        default:
            playCustom(request)
        }
    }

    func start(_ songs: [Song], at index: Int, shuffled: Bool) {
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

    func showUnavailable(_ error: Error) {
        let state = CarPlayState.unavailable(outOfReach: library.isOutOfReach(error), localNetwork: library.localNetwork,
                                             offline: library.isOffline)
        showMessage(CarPlayRows.state(state).flatMap(\.rows).first?.title ?? "Your library didn't send this")
    }

    /// Only in direct response to a tap (critique M3). Describes; never instructs.
    func showMessage(_ title: String) {
        guard interface.presentedTemplate == nil else { return }
        let ok = CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
            self?.interface.dismissTemplate(animated: true, completion: nil)
        }
        interface.presentTemplate(CPAlertTemplate(titleVariants: [title], actions: [ok]), animated: true, completion: nil)
    }

    // MARK: - Try it next

    /// A not-yet row: "Try it next" / "Cancel" (modal, no push; CarPlay H3).
    private func offerTry(_ recording: ExternalRecording) {
        guard interface.presentedTemplate == nil,
              let sheet = CarPlayRows.trySheet(recording, offer: library.tryOffer,
                                                queueEmpty: player.queue.current == nil) else { return }
        let confirm = CPAlertAction(title: sheet.confirm, style: .default) { [weak self] _ in
            self?.interface.dismissTemplate(animated: true) { _, _ in
                Task { @MainActor in self?.confirmTry(recording) }
            }
        }
        let cancel = CPAlertAction(title: CPTrySheet.cancel, style: .cancel) { [weak self] _ in
            self?.interface.dismissTemplate(animated: true, completion: nil)
        }
        interface.presentTemplate(CPActionSheetTemplate(title: sheet.title, message: sheet.message, actions: [confirm, cancel]),
                                  animated: true, completion: nil)
    }

    /// Now Playing opens only once real audio starts (the bridge); otherwise nothing more is shown unless Try failed.
    private func confirmTry(_ recording: ExternalRecording) {
        Task {
            switch await library.tryNext(recording) {
            case .bridging: showNowPlaying()
            case .noMix: showMessage(CPTryResult.noMixMessage)
            case .failed(let problem): showMessage(problem.message)
            case .asked, .queued: break
            }
        }
    }

    // MARK: - Now Playing

    /// Now Playing shows the system's view of `MPNowPlayingInfoCenter` (the real square cover,
    /// H4). Our buttons: Keep (the system add-to-library button, for a find that may be kept; D12, M1), shuffle,
    /// repeat and the sleep timer (T23).
    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.allowsMiniPlayer = true
        updateNowPlayingButtons()
    }

    /// Same Player calls as the lock screen's shuffle/repeat commands (`NowPlayingBridge`),
    /// which also keeps the commands' current types (the glyphs) in sync.
    func updateNowPlayingButtons() {
        var buttons: [CPNowPlayingButton] = []
        let keep = keepButton
        if keep.isShown {
            let add = CPNowPlayingAddToLibraryButton { [weak self] _ in self?.keepCurrent() }
            add.isEnabled = keep.isEnabled
            add.isSelected = keep.isSelected
            buttons.append(add)
        }
        let shuffle = CPNowPlayingShuffleButton { [weak self] _ in
            guard let player = self?.player else { return }
            NowPlayingBridge.applyShuffle(player.isShuffled ? .off : .items, to: player)
        }
        shuffle.isSelected = player.isShuffled
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            guard let player = self?.player else { return }
            NowPlayingBridge.applyRepeat(NowPlayingBridge.repeatType(player.repeatMode.next), to: player)
        }
        repeatButton.isSelected = player.repeatMode != .off
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons + [shuffle, repeatButton, sleepButton()])
    }

    private var keepButton: CPKeepButton {
        let id = player.queue.current?.song.id
        return CPKeepButton.state(songId: id, mayKeep: id.map { library.mayKeep(songId: $0) } ?? false,
                                  keeping: keeping, kept: kept)
    }

    /// Keep from the car: the find's release only, through the phone's Keep; says how it went.
    private func keepCurrent() {
        guard keepButton == .offered, let id = player.queue.current?.song.id else { return }
        keeping.insert(id)
        updateNowPlayingButtons()
        Task {
            let result = await library.keep(songId: id)
            keeping.remove(id)
            if result.isKept { kept.insert(id) }
            updateNowPlayingButtons()
            showMessage(result.message)
        }
    }

    private struct PlayerModes: Equatable, Sendable {
        var shuffled: Bool
        var repeatMode: RepeatMode
        /// The song playing, and whether it is a find that may be kept (the Keep button).
        var songId: String?
        var mayKeep: Bool
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
        let library = library
        watches.append(Task { [weak self] in
            let modes = Observations { @MainActor in
                let id = player.queue.current?.song.id
                return PlayerModes(shuffled: player.isShuffled, repeatMode: player.repeatMode, songId: id,
                                   mayKeep: id.map { library.mayKeep(songId: $0) } ?? false)
            }
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
        findsRoot = nil
        searchRoot = nil
    }

    /// Fetches on the caller's behalf, then builds the rows off the main thread. A failure shows a
    /// state row only when the list has nothing real yet; otherwise what's shown stays.
    func load(_ binding: ListBinding, _ fetch: @escaping @MainActor () async throws -> Content) {
        binding.loadTask?.cancel()
        binding.loadTask = Task { [weak self] in
            do {
                let content = try await fetch()
                guard !Task.isCancelled, let self else { return }
                binding.content = content
                await self.refresh(binding)
            } catch {
                guard !Task.isCancelled, let self, binding.isPlaceholder else { return }
                let state = CarPlayState.unavailable(outOfReach: self.library.isOutOfReach(error),
                                                     localNetwork: self.library.localNetwork, offline: self.library.isOffline)
                self.apply(CarPlayRows.state(state), to: binding, placeholder: true)
            }
        }
    }

    /// Rebuilds the binding's rows (off main) for the song playing now and applies them. A build that finishes after
    /// a newer one started is dropped. Rows that only describe a state stay placeholders, so real rows replace them.
    func refresh(_ binding: ListBinding) async {
        guard let content = binding.content else { return }
        binding.generation += 1
        let generation = binding.generation
        let playing = player.queue.current?.song.id
        let sections = await Task.detached(priority: .userInitiated) { content(playing) }.value
        guard bindings[ObjectIdentifier(binding.template)] === binding, binding.generation == generation else { return }
        apply(sections, to: binding, placeholder: CarPlayRows.isPlaceholder(sections))
    }

    func apply(_ sections: [CPSectionModel], to binding: ListBinding, placeholder: Bool) {
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
                if row.statusSymbol != nil { setStatusSymbol(item, row) }
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
        let before = Dictionary(binding.shown.flatMap(\.rows).map { ($0.id, $0.statusSymbol) }, uniquingKeysWith: { a, _ in a })
        for row in sections.flatMap(\.rows) {
            guard let item = binding.items[row.id] else { continue }
            if item.text != row.title { item.setText(row.title) }
            if item.detailText != row.detail { item.setDetailText(row.detail) }
            configure(item, row)   // sets the accessory type: the status symbol goes on after it
            if row.statusSymbol != nil || before[row.id] != nil { setStatusSymbol(item, row) }
        }
        binding.shown = sections
        loadArtwork(binding)
    }

    /// The status symbol beside a find or not-yet row's text (D3).
    private func setStatusSymbol(_ item: CPListItem, _ row: CPRowModel) {
        item.setAccessoryImage(row.statusSymbol.flatMap { UIImage(systemName: $0) })
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

    private static let blankRecordTag = "record"

    /// Loads cover art for rows whose artwork changed, a few at a time, sized and (for not-yet
    /// rows) drawn as records off the main thread.
    private func loadArtwork(_ binding: ListBinding) {
        var wanted: [(rowId: String, key: String, round: Bool)] = []
        let side = CPListItem.maximumImageSize
        let traitScale = interface.carTraitCollection.displayScale
        let scale = traitScale > 0 ? traitScale : 2
        for row in binding.shown.flatMap(\.rows) {
            guard let key = row.artworkKey else {
                // A not-yet song has no cover here: a plain record (D3), drawn once.
                guard row.round, binding.artworkKeys[row.id] != Self.blankRecordTag else { continue }
                binding.artworkKeys[row.id] = Self.blankRecordTag
                let record = blankRecord ?? CarPlayArtwork.blankRecord(size: side, scale: scale)
                blankRecord = record
                binding.items[row.id]?.setImage(record)
                continue
            }
            let tag = "\(key)|\(row.round)"
            guard binding.artworkKeys[row.id] != tag else { continue }
            binding.artworkKeys[row.id] = tag
            if row.round, OutsideArtKey(token: key) != nil {   // R15: the plain record until (or unless) its cover comes
                let record = blankRecord ?? CarPlayArtwork.blankRecord(size: side, scale: scale)
                blankRecord = record
                binding.items[row.id]?.setImage(record)
            }
            wanted.append((row.id, key, row.round))
        }
        guard !wanted.isEmpty else { return }
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
        if aTemplate is CPSearchTemplate, !interface.templates.contains(where: { $0 === aTemplate }) {
            searchTask?.cancel()
            searchArtwork?.cancel()
            searchArtwork = nil
            library.searchClosed()   // R15: the search closed, so its outside art goes
            return
        }
        let id = ObjectIdentifier(aTemplate)
        guard let binding = bindings[id] else { return }
        let isTabRoot = [home, libraryRoot, findsRoot, searchRoot].contains { $0 === binding }
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
        for binding in [home, libraryRoot, findsRoot, searchRoot] where binding?.template !== selectedTemplate {
            flushPending(binding)
        }
        if selectedTemplate === home?.template {
            loadHome()
        } else if selectedTemplate === findsRoot?.template {
            refreshFindsRoot()
            let library = library
            Task { await library.refreshFinds() }   // the shelf watch shows what it reads
        } else if selectedTemplate === searchRoot?.template {
            refreshSearchRoot()
        }
    }
}

extension CarPlayController: CPSearchTemplateDelegate {
    public func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                               completionHandler: @escaping ([CPListItem]) -> Void) {
        searchTask?.cancel()   // the older query completes with what's showing (below)
        let ticket = searchResults.begin()
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            completionHandler(searchResults.complete(ticket, with: []))
            return
        }
        searchTask = Task {
            // Stale or cancelled: never hand back [] (it could blank newer results).
            @MainActor func finish(_ items: [CPListItem]) { completionHandler(searchResults.complete(ticket, with: items)) }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, searchResults.isCurrent(ticket) else { return completionHandler(searchResults.stale()) }
            do {
                let result = try await library.search(query)
                guard !Task.isCancelled, searchResults.isCurrent(ticket) else {
                    return completionHandler(searchResults.stale())
                }
                lastSearch = query
                let offer = library.tryOffer
                let rows = await Task.detached(priority: .userInitiated) {
                    CarPlayRows.searchItems(result.library, notYet: result.notYet, offer: offer,
                                            onTheirWay: result.onTheirWay)
                }.value
                let fitted = CarPlayRows.fitSearchItems(rows, maxItems: Int(CPListTemplate.maximumItemCount))
                let binding = ListBinding(template: CPListTemplate(title: nil, sections: []))
                var items: [String: CPListItem] = [:]
                let list = fitted.map { row in
                    let item = CPListItem(text: row.title, detailText: row.detail)
                    item.userInfo = row.action
                    if row.statusSymbol != nil { setStatusSymbol(item, row) }
                    items[row.id] = item
                    return item
                }
                finish(list)
                guard searchResults.isCurrent(ticket) else { return }
                // Artwork arrives after the results are shown.
                searchArtwork?.cancel()
                searchArtwork = binding
                binding.items = items
                binding.shown = [CPSectionModel(header: nil, rows: fitted)]
                loadArtwork(binding)
            } catch {
                guard !Task.isCancelled, searchResults.isCurrent(ticket) else {
                    return completionHandler(searchResults.stale())
                }
                let state = CarPlayState.unavailable(outOfReach: library.isOutOfReach(error), localNetwork: library.localNetwork,
                                                     offline: library.isOffline)
                finish(CarPlayRows.state(state).flatMap(\.rows).map {
                    CPListItem(text: $0.title, detailText: $0.detail, image: nil,
                               accessoryImage: $0.statusSymbol.flatMap { UIImage(systemName: $0) }, accessoryType: .none)
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
    /// Counts refreshes; only the newest one's rows are applied.
    var generation = 0
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
    /// A record with a plain label, for a not-yet row without a cover.
    nonisolated static func blankRecord(size: CGSize, scale: CGFloat) -> UIImage {
        let label = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { ctx in
            UIColor(white: 0.55, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return RoundArt.render(label, size: size, scale: scale)
    }

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

public extension CarPlayLibrary {
    func searchClosed() {}
}
#endif
