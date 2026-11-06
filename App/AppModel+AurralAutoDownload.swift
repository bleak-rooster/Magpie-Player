import AurralKit
import Foundation
import MagpieCore

/// Round 22 R22A (owner, 2026-11-06): "when a new aurral flow or playlist is added, it should automatically start
/// downloading the songs in the background" (D186), and "there should be a toggle that is default off to exclude them,
/// otherwise to include them in Playlists" (D188).
///
/// Auto-download (supersedes D82's "only on the owner's tap" for this one case):
/// - Per account, the flows and playlists already handled are saved. The first read after connecting (or after this
///   update) only records what exists and starts nothing, so the flows already there aren't all started at once.
/// - A new one is handled once: a flow Aurral doesn't download by itself (`autoDownload` false: what "Download songs"
///   is for, D94) gets Aurral's one "Download songs" write, in the background; everything else (a flow that downloads
///   by itself, an Aurral playlist, whose songs Aurral queues as it makes it: there is no allow-listed route to ask for
///   them) is only recorded.
/// - Only with Aurral connected and its user allowed (accessFlow), the capability on (`flowDownload`: flows +
///   flowAutoDownload), a downloader not known to be missing, the switch on, online, and never while a run is under
///   way (D61's `isFlowRunActive`: the flow is looked at again on the next read).
/// - "Handled" is saved before the write is sent (M6), so it is never sent twice; a lost answer isn't sent again.
/// - No downloader (409) or not allowed (403): handled, quietly, with a note on the flow's page.
extension AppModel {
    /// Why a new flow's songs didn't start by themselves (shown on its page).
    enum AutoDownloadNote: String, Sendable {
        case noDownloader, notAllowed
    }

    nonisolated static let autoDownloadKeyPrefix = "magpie.aurralAutoDownload."
    nonisolated static let handledFlowsKeyPrefix = "magpie.aurralHandledFlows."
    nonisolated static let autoDownloadNotesKeyPrefix = "magpie.aurralAutoDownloadNotes."
    nonisolated static let showDiscoverInPlaylistsKeyPrefix = "magpie.showDiscoverInPlaylists."

    /// Settings › Aurral › "Get songs for new flows automatically": on by default, per account.
    var autoDownloadNewFlows: Bool {
        get {
            guard let scope = navidromeScope else { return true }
            return appDefaults.object(forKey: Self.autoDownloadKeyPrefix + scope) as? Bool ?? true
        }
        set {
            guard let scope = navidromeScope else { return }
            appDefaults.set(newValue, forKey: Self.autoDownloadKeyPrefix + scope)
        }
    }

    /// D188: Settings › Aurral › "Show Discover playlists in Playlists": off by default, per account.
    var showDiscoverInPlaylists: Bool {
        get {
            guard let scope = navidromeScope else { return false }
            return appDefaults.object(forKey: Self.showDiscoverInPlaylistsKeyPrefix + scope) as? Bool ?? false
        }
        set {
            guard let scope = navidromeScope else { return }
            appDefaults.set(newValue, forKey: Self.showDiscoverInPlaylistsKeyPrefix + scope)
            libraryEdits.playlistsRevision += 1   // Library › Playlists reads again
        }
    }

    /// D188: whether Library › Playlists and the car's Playlists leave `playlist` out: Discover's, unless the switch
    /// shows them there too.
    func leavesOutOfPlaylists(_ playlist: Playlist) -> Bool { !showDiscoverInPlaylists && isDiscoverPlaylist(playlist) }

    /// The note on a flow's page when its songs couldn't start by themselves.
    func autoDownloadNote(flowId: String) -> AutoDownloadNote? {
        guard let scope = navidromeScope,
              let notes = appDefaults.dictionary(forKey: Self.autoDownloadNotesKeyPrefix + scope) as? [String: String]
        else { return nil }
        return notes[flowId].flatMap(AutoDownloadNote.init)
    }

    /// The flows and playlists already handled for this account; nil before the first read recorded them.
    var handledAurralFlows: Set<String>? {
        guard let scope = navidromeScope,
              let saved = appDefaults.stringArray(forKey: Self.handledFlowsKeyPrefix + scope) else { return nil }
        return Set(saved)
    }

    /// Hook from each read of Aurral (`performDiscoverRead`): records the user's flows and playlists, and starts the
    /// songs of each new flow that Aurral won't download by itself. Returns the background send, if one was started.
    @discardableResult
    func autoDownloadNewFlows(_ status: AurralStatus) -> Task<Void, Never>? {
        guard let scope = navidromeScope else { return nil }
        let key = Self.handledFlowsKeyPrefix + scope
        let all = status.flows + status.sharedPlaylists
        guard var handled = handledAurralFlows else {
            appDefaults.set(all.map(\.id).sorted(), forKey: key)   // the first read: record only
            return nil
        }
        let new = all.filter { !handled.contains($0.id) }
        guard !new.isEmpty else { return nil }
        let shared = Set(status.sharedPlaylists.map(\.id))
        var toSend: [String] = []
        for flow in new {
            if !shared.contains(flow.id), flow.autoDownload == false, isFlowRunActive(flow.id) { continue }   // later
            handled.insert(flow.id)
            guard !shared.contains(flow.id), flow.autoDownload == false, mayAutoDownload else { continue }
            toSend.append(flow.id)
        }
        appDefaults.set(handled.sorted(), forKey: key)   // M6: saved before anything is sent
        guard !toSend.isEmpty, let client = aurralClient else { return nil }
        let account = discover.connection?.account
        return Task { [weak self] in
            for flowId in toSend {
                do {
                    _ = try await client.downloadFlow(flowId)
                } catch AurralError.noDownloader {
                    self?.noteAutoDownload(.noDownloader, flowId: flowId, scope: scope, account: account)
                } catch AurralError.notPermitted, AurralError.unauthorized {
                    self?.noteAutoDownload(.notAllowed, flowId: flowId, scope: scope, account: account)
                } catch {
                    // A lost answer or another failure: never sent again (it may have gone through).
                }
            }
        }
    }

    /// Everything that lets a new flow's songs start by themselves, but the flow's own state.
    private var mayAutoDownload: Bool {
        autoDownloadNewFlows && !isOffline && aurralCapabilities.flowDownload && aurralHasDownloader != false
            && discover.bootstrap?.user?.canAddFlow == true
    }

    private func noteAutoDownload(_ note: AutoDownloadNote, flowId: String, scope: String,
                                  account: AurralConnection.Account?) {
        guard navidromeScope == scope, discover.connection?.account == account else { return }
        let key = Self.autoDownloadNotesKeyPrefix + scope
        var notes = appDefaults.dictionary(forKey: key) as? [String: String] ?? [:]
        notes[flowId] = note.rawValue
        appDefaults.set(notes, forKey: key)
    }

    /// Sign-out or another Aurral: this account's records go (the switches stay, as the owner's choices).
    func forgetAutoDownloadRecords(scope: String) {
        appDefaults.removeObject(forKey: Self.handledFlowsKeyPrefix + scope)
        appDefaults.removeObject(forKey: Self.autoDownloadNotesKeyPrefix + scope)
    }
}

/// The words for D186 and D188 (§5 voice: about music; Settings › Aurral may name the connection, these don't).
enum AurralAutoDownloadCopy {
    static let autoDownload = "Get songs for new flows automatically"
    static let autoDownloadFooter = "When a new flow appears, its songs start downloading on your server by themselves."
    static let showInPlaylists = "Show Discover playlists in Playlists"
    static let showInPlaylistsFooter = "Discover’s playlists also appear in Library › Playlists and in the car. They can’t be changed there."
    static func note(_ note: AppModel.AutoDownloadNote) -> String {
        switch note {
        case .noDownloader: "Its songs didn’t start by themselves: no downloader is set up on your server."
        case .notAllowed: "Its songs didn’t start by themselves: your account can’t download songs for flows."
        }
    }
}
