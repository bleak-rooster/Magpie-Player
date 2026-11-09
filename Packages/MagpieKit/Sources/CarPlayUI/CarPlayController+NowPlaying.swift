#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import Playback

// Round 24 G (owner item 11, D234): Now Playing's own buttons, moved out of CarPlayController.swift unchanged in
// behaviour. The car's next and previous are not here: they are the system's remote commands (`NowPlayingBridge`).
extension CarPlayController {
    /// Now Playing shows the system's view of `MPNowPlayingInfoCenter` (the real square cover,
    /// H4). Our buttons: Keep (the system add-to-library button, for a find that may be kept; D12, M1), shuffle,
    /// repeat and Favourite (round 12 item 2b: the star replaced the sleep timer, which stays on the phone).
    func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isUpNextButtonEnabled = false   // round 13: on while there is a queue (`updateNowPlayingButtons`)
        nowPlaying.upNextTitle = CarPlayRows.upNextTitle
        nowPlaying.isAlbumArtistButtonEnabled = false   // on once the song playing has a page to go to (2d)
        nowPlaying.add(self)
        // R21 (D166): the car's mini player is new in iOS 27; on iOS 26 CarPlay keeps its own Now Playing button.
        if #available(iOS 27, *) { nowPlaying.allowsMiniPlayer = true }
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
        let selection = Self.modeSelection(of: player)
        shuffle.isSelected = selection.shuffle
        let repeatButton = CPNowPlayingRepeatButton { [weak self] _ in
            guard let player = self?.player else { return }
            NowPlayingBridge.applyRepeat(NowPlayingBridge.repeatType(player.repeatMode.next), to: player)
        }
        repeatButton.isSelected = selection.repeating
        CPNowPlayingTemplate.shared.updateNowPlayingButtons(buttons + [shuffle, repeatButton, favouriteButton()])
        CPNowPlayingTemplate.shared.isUpNextButtonEnabled = player.queue.current != nil
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
}
#endif
