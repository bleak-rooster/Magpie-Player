#if os(iOS) && canImport(CarPlay)
import CarPlay
import MagpieCore
import Observation

/// Home and Library from the owner's layout (spec §3, Task 22): the phone's order and switches, minus what the car
/// can't show. A change on the phone (or going offline) reloads Home and redraws the Library tab; a list being browsed
/// keeps its shape until it is off screen (`apply`).
extension CarPlayController {
    /// Home: the shelves of the sections shown, sized so they fit the car's list together.
    func loadCustomHome() {
        guard let home else { return }
        let library = library
        let sections = library.homeSections
        let size = CarPlayRows.homeShelfSize(sectionCount: sections.count)
        load(home) {
            let shelves = try await library.homeShelves(sections, size: size)
            return { _ in CarPlayRows.home(shelves) }
        }
    }

    /// Follows `homeSections` and `libraryRows`. Started with the tabs; a newer start replaces the older one.
    func watchLayout() {
        layoutWatch?.cancel()
        let library = library
        let task = Task { [weak self] in
            let layouts = Observations { @MainActor in CarLayout(home: library.homeSections, library: library.libraryRows) }
            var last = CarLayout(home: library.homeSections, library: library.libraryRows)   // what the tabs show now
            for await layout in layouts where layout != last {
                guard let self, !Task.isCancelled else { return }
                if layout.home != last.home { self.loadCustomHome() }
                if layout.library != last.library, let libraryRoot = self.libraryRoot {
                    self.apply(CarPlayRows.libraryRoot(layout.library, hasFindsTab: self.findsRoot != nil),
                               to: libraryRoot, placeholder: false)
                }
                last = layout
            }
        }
        layoutWatch = task
        watches.append(task)
    }

    /// The screens of the destinations added for the layout. Finds (a Library row when the car has no Finds tab)
    /// shows the phone's shelf; the others are filled in by Task 23.
    func customFetcher(for destination: CPDestination) -> @MainActor () async throws -> Content {
        let library = library
        switch destination {
        case .finds:
            return { let shelf = library.findsShelf; return { CarPlayRows.finds(shelf, playingId: $0) } }
        default:
            return { { _ in CarPlayRows.state(.empty) } }
        }
    }

    /// Genre requests (Task 23).
    func playCustom(_ request: CPPlayRequest) {}
}

/// The layout the car follows.
private struct CarLayout: Equatable, Sendable {
    var home: [HomeSection]
    var library: [LibraryRow]
}
#endif
