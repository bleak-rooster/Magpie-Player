import MagpieCore
import Playback
import Search

/// Search while offline (spec §6): the downloads' snapshot, shown under "Downloads". Nothing is asked of the server or
/// any outside source. Round 28 S (owner Q2, 2026-11-15): downloads only; cached songs that have played ("Recently
/// played on this phone") are no longer listed, though one already in the queue still plays (D339).
struct OfflineSearch {
    let catalog: OfflineCatalog

    func sections(_ query: String) -> SearchSections {
        SearchSections.library(catalog.search(query), query: query)
    }
}
