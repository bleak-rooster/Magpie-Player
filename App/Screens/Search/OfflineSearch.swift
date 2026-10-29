import MagpieCore
import Playback
import Search

/// Search while offline (spec §6): the downloads' snapshot, shown under "Downloads", then the cached songs that have
/// played, under "Recently played on this phone". Nothing is asked of the server or any outside source.
struct OfflineSearch {
    let catalog: OfflineCatalog

    func sections(_ query: String) -> SearchSections {
        var sections = SearchSections.library(catalog.search(query), query: query)
        sections.recentlyPlayed = catalog.recentlyPlayed(matching: query)
        return sections
    }
}
