import Foundation
import MagpieCore
import Testing
@testable import AurralKit

/// Round 26 L (owner, 2026-11-11): same-named Aurral items that Navidrome has no playlist (or only an empty one) for
/// (D271, D272). `DiscoverRules.itemRows` decides which items are rows of their own, by Aurral id, and which of
/// Aurral's Navidrome playlists are never rows.
@Suite struct R26LItemRowsTests {
    private func list(_ id: String, _ name: String) -> Playlist {
        Playlist(id: id, name: name, songCount: 0, duration: 0, owner: "admin")
    }

    let jordans = AurralFlow(id: "sp-j", name: "Chill", ownerUserId: 3, ownerUsername: "jordan")
    let sams = AurralFlow(id: "sp-s", name: "Chill", ownerUserId: 2, ownerUsername: "sam")

    @Test func noPlaylistAtAll_eachItemItsOwnRow() {
        let rows = DiscoverRules.itemRows(items: [jordans, sams], linked: [], unclaimed: [], empty: [])
        #expect(rows.items == ["sp-j", "sp-s"])
        #expect(rows.hidden.isEmpty)
    }

    /// Build 27's case: two empty "Chill" playlists no item could claim. Neither is a row (nothing to play, no owner
    /// known); each item is, by its id.
    @Test func twoEmptyUnclaimed_hidden_itemsAreRows() {
        let rows = DiscoverRules.itemRows(items: [jordans, sams], linked: [],
                                          unclaimed: [list("pl-e1", "Chill"), list("pl-e2", "Chill")], empty: ["pl-e1", "pl-e2"])
        #expect(rows.items == ["sp-j", "sp-s"])
        #expect(rows.hidden == ["pl-e1", "pl-e2"])
    }

    /// An item whose playlist is known (claimed, or kept with it) is that playlist's row, never a second one.
    @Test func linkedItem_noRowOfItsOwn() {
        let rows = DiscoverRules.itemRows(items: [jordans, sams], linked: ["sp-j"], unclaimed: [list("pl-e2", "Chill")],
                                          empty: ["pl-e2"])
        #expect(rows.items == ["sp-s"])
        #expect(rows.hidden == ["pl-e2"])
    }

    /// D202's Q1 stays: an unclaimed playlist with songs may be the item's (never guessed whose), so it stays a row and
    /// the item gets none of its own (never two rows for one item).
    @Test func unclaimedWithSongs_standsForTheItem() {
        let rows = DiscoverRules.itemRows(items: [jordans, sams], linked: ["sp-j"], unclaimed: [list("pl-c2", "Chill")], empty: [])
        #expect(rows.items.isEmpty)
        #expect(rows.hidden.isEmpty)
    }

    /// Every name Aurral gives an item's playlist counts (D181): the owner's prefix, the older forms, a copy number.
    @Test(arguments: ["sam - Chill", "[AS] Chill", "Aurral Shared chill", "Chill (2)", "  CHILL "])
    func unclaimedWithSongs_anyAurralName(_ name: String) {
        let rows = DiscoverRules.itemRows(items: [sams], linked: [], unclaimed: [list("pl-x", name)], empty: [])
        #expect(rows.items.isEmpty, "\(name)")
    }

    /// A playlist named as another item only doesn't stand for this one.
    @Test func unclaimedOfAnotherName_doesNotStand() {
        let late = AurralFlow(id: "sp-l", name: "Late", ownerUserId: 2, ownerUsername: "sam")
        let rows = DiscoverRules.itemRows(items: [jordans, late], linked: [], unclaimed: [list("pl-l", "Late")], empty: [])
        #expect(rows.items == ["sp-j"])
    }

    /// An item listed twice is one row; an item with no id is none.
    @Test func duplicatesAndBlankIds() {
        let blank = AurralFlow(id: "", name: "Chill")
        let rows = DiscoverRules.itemRows(items: [jordans, jordans, blank, sams], linked: [], unclaimed: [], empty: [])
        #expect(rows.items == ["sp-j", "sp-s"])
    }
}
