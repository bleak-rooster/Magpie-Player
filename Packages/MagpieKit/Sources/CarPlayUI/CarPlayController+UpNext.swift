#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore

// Round 13 item 9: Now Playing's Up Next button (top right, `isUpNextButtonEnabled` while there is a queue) opens the
// queue as a list: the song playing marked, a tap jumps there. CarPlay's depth (5, Now Playing included) is kept: Up
// Next goes above Now Playing when it fits, otherwise from the tab bar (Now Playing, then Up Next).
extension CarPlayController {
    func upNextTapped() {
        guard interface.topTemplate === CPNowPlayingTemplate.shared else { return }
        if CPNavigator.upNextFits(stackDepth: interface.templates.count) {
            pushUpNext()
            return
        }
        guard let tabBar else { return }
        // Z3 review M5: each step only once the one before went through, so Now Playing is never pushed twice.
        interface.pop(to: tabBar, animated: false) { [weak self] popped, _ in
            MainActor.assumeIsolated {
                guard popped, let self, self.interface.topTemplate === tabBar else { return }
                self.interface.pushTemplate(CPNowPlayingTemplate.shared, animated: false) { [weak self] pushed, _ in
                    MainActor.assumeIsolated { if pushed { self?.pushUpNext() } }
                }
            }
        }
    }

    /// The queue as it is now; the mark follows the song playing in place (the player watch refreshes every list).
    private func pushUpNext() {
        let template = CPListTemplate(title: CarPlayRows.upNextTitle, sections: [])
        template.showsSpinnerWhileEmpty = true
        let binding = bind(template)
        interface.pushTemplate(template, animated: true, completion: nil)
        let current = player.queue.current, upcoming = player.queue.upcoming
        let maxItems = Int(CPListTemplate.maximumItemCount)
        load(binding) {
            { CarPlayRows.upNext(current: current, upcoming: upcoming, maxItems: maxItems, playingId: $0) }
        }
    }

    /// A row of Up Next: plays the queue from there (the songs before it count as played) and goes back to Now Playing.
    /// A row that is no longer upcoming (it played meanwhile) just goes back.
    func playQueueEntry(_ id: UUID) {
        if player.queue.current?.id != id { player.jump(to: id) }
        showNowPlaying()
    }
}
#endif
