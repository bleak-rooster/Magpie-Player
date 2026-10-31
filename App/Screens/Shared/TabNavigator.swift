import Observation
import SwiftUI

enum AppTab: Hashable { case home, library, search }

/// Each tab's navigation stack, so a link from a sheet (Now Playing's artist and album, R10) pushes onto the tab the
/// user is on rather than switching tabs (appraisal §10.5).
@MainActor @Observable final class TabNavigator {
    var tab: AppTab = .home
    var home = NavigationPath()
    var library = NavigationPath()
    var search = NavigationPath()

    /// Pushes `route` onto the current tab's stack.
    func push(_ route: Route) {
        switch tab {
        case .home: home.append(route)
        case .library: library.append(route)
        case .search: search.append(route)
        }
    }

    /// The current tab's stack depth (tests).
    var depth: Int {
        switch tab {
        case .home: home.count
        case .library: library.count
        case .search: search.count
        }
    }
}
