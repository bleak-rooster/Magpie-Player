#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import Observation

// Round 12 item 2d (Y2): Now Playing's album/artist button. Fix round 1 (I1): out of CarPlayController.swift, which
// only starts `watchNowPlayingLinks` and adds the controller as the template's observer.
extension CarPlayController: CPNowPlayingTemplateObserver {
    /// The song, offline, and what's on the phone decide the button.
    func watchNowPlayingLinks() {
        let player = player, library = library
        watches.append(Task { [weak self] in
            let keys = Observations { @MainActor in "\(player.queue.current?.song.id ?? "")|\(library.isOffline)" }
            var last: String?
            for await key in keys where key != last {
                last = key
                self?.refreshNowPlayingLinks()
            }
        })
    }

    /// Works out the song's pages (offline: only those on the phone) and turns the button on when there is one.
    func refreshNowPlayingLinks() {
        linksTask?.cancel()
        let song = player.queue.current?.song
        let offline = library.isOffline
        let library = library
        linksTask = Task { [weak self] in
            var albumOnPhone = false, artistOnPhone = false
            if offline, let song {
                if let id = song.albumId { albumOnPhone = await library.downloadedAlbum(id: id) != nil }
                if let id = song.artistId { artistOnPhone = await library.downloadedArtist(id: id) != nil }
            }
            guard !Task.isCancelled, let self, self.player.queue.current?.song.id == song?.id else { return }
            self.nowPlayingLinks = CarPlayRows.nowPlayingLinks(song, offline: offline, albumOnPhone: albumOnPhone,
                                                               artistOnPhone: artistOnPhone)
            CPNowPlayingTemplate.shared.isAlbumArtistButtonEnabled = !self.nowPlayingLinks.isEmpty
        }
    }

    /// Both known: "Go to album" / "Go to artist" (modal, no push). Only one: straight there.
    public nonisolated func nowPlayingTemplateAlbumArtistButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { albumArtistTapped() }
    }

    /// Round 13 item 9 (CarPlayController+UpNext.swift).
    public nonisolated func nowPlayingTemplateUpNextButtonTapped(_ nowPlayingTemplate: CPNowPlayingTemplate) {
        MainActor.assumeIsolated { upNextTapped() }
    }

    private func albumArtistTapped() {
        let links = nowPlayingLinks
        switch (links.album, links.artist) {
        case (let album?, let artist?):
            guard interface.presentedTemplate == nil else { return }
            func choice(_ title: String, _ destination: CPDestination) -> CPAlertAction {
                CPAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.interface.dismissTemplate(animated: true) { _, _ in
                        Task { @MainActor in self?.go(to: destination) }
                    }
                }
            }
            let cancel = CPAlertAction(title: CPNowPlayingLinkCopy.cancel, style: .cancel) { [weak self] _ in
                self?.interface.dismissTemplate(animated: true, completion: nil)
            }
            interface.presentTemplate(CPActionSheetTemplate(title: nil, message: nil, actions: [
                choice(CPNowPlayingLinkCopy.album, album), choice(CPNowPlayingLinkCopy.artist, artist), cancel,
            ]), animated: true, completion: nil)
        case (let only?, nil), (nil, let only?):
            go(to: only)
        case (nil, nil):
            break
        }
    }

    /// Opens the page from the tab bar, so it has the whole depth budget (the browse stack under Now Playing goes).
    func go(to destination: CPDestination) {
        guard let tabBar else { return }
        interface.pop(to: tabBar, animated: false) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.open(destination) }
        }
    }
}
#endif
