import Foundation
import LidarrKit
import ListenBrainzKit
import MagpieCore
import NavidromeKit
import Requests

/// Whether Try can bring a song home right now, and if not, the calm reason (brief ruling 2). The reason talks
/// about the music and points to Settings, which names its own switches (§5, H3 I5).
enum TryAvailability: Equatable {
    case available(Tier)
    case noLidarr
    case changesOff
    case notSetUp
    case noRoot

    var message: String? {
        switch self {
        case .available: nil
        case .noLidarr: "Bringing songs home isn't set up yet. Set it up in Settings."
        case .changesOff: "Bringing songs home is switched off. Turn it on in Settings."
        case .notSetUp: "Bringing songs home needs one more step in Settings."
        case .noRoot: "Choose where new music goes in Settings to bring songs home."
        }
    }
}

/// Why Save token didn't save it (B-M8). Plain words; Settings names the service itself.
enum ListenBrainzTokenError: Error, Equatable {
    case notAccepted
    case unreachable

    var message: String {
        switch self {
        case .notAccepted: "That token wasn't accepted."
        case .unreachable: "Couldn't check the token right now. Try again in a moment."
        }
    }
}

enum TryCopy {
    /// B8: fallback mode; say plainly where the song lands.
    static let fallbackNote = "Finds aren't set up, so this goes straight into your library."
    /// Finds mode (Task 6.2a). Honest for both cases (B8, final fix 2 B-I1): only new artists become finds.
    static let findsNote = "New artists go into your Finds first, so you can try them before they join your library. Songs by artists you have go straight into your library."
    /// Finds mode was on, but the Finds folder didn't check out when the song was asked for (G2, B8).
    static let findsUnavailable = "Your Finds folder needs another look in Settings, so this went straight into your library."
    /// G7 / FL4: songs on their way and releases Bring in more is bringing in share the limit of five.
    static let tooMany = "Five songs and releases are already on their way. Try this one when one of them is home or has stopped."
    static let unavailable = "Your requests can't be read right now. Unlock your iPhone and try again."
    static let changesOff = TryAvailability.changesOff.message!
    static let notSetUp = TryAvailability.notSetUp.message!

    static func message(for error: Error) -> String {
        switch error {
        case RequestRunner.TryError.tooMany: tooMany
        case RequestRunner.TryError.changesOff: changesOff
        case RequestRunner.TryError.notSetUp: notSetUp
        case RequestRunner.TryError.unavailable: unavailable
        default: "That didn't work. Try again in a moment."
        }
    }
}

extension AppModel {
    static let countPlaysKey = "magpie.countPlays"

    // MARK: - Runner lifecycle

    /// Builds the write gate and request runner for the current session and Lidarr, or tears them down.
    /// Saved requests are loaded and resumed.
    func rebuildRunner() {
        reloadFindsSetup()   // the session or the Lidarr changed: so may the Finds setup's scope
        Task { await refreshFinds() }
        runnerTasks.forEach { $0.cancel() }
        runnerTasks = []
        pollTask?.cancel()
        pollTask = nil
        pollGeneration += 1
        let retired = runner
        runner = nil
        gate = nil
        ledger = nil
        requestStore = nil
        if let retired { Task { await retired.stop() } }
        guard session != nil, let client = lidarrClient else {
            requests = []
            return
        }
        // CRITICAL 1: one ledger view and one requests file per Lidarr server.
        let scope = client.instanceScope
        let ledger = Ledger(fileURL: Ledger.defaultURL(in: dataDirectory), instance: scope)
        // FM1: the gate confines deletes and artist edits itself, from this ledger and the owner's setup.
        let confinement = WriteConfinement(ledger: ledger, roots: { [weak self] in
            await self?.gateRoots ?? WriteConfinement.Roots(mainRoot: nil, findsRoot: nil, findTagId: nil)
        })
        let gate = LidarrWriteGate(client: client, logURL: LidarrWriteGate.defaultLogURL(in: dataDirectory),
                                   defaultsSuite: gateDefaultsSuite, confinement: confinement)
        let requestStore = RequestStore(fileURL: RequestStore.defaultURL(in: dataDirectory, instance: scope))
        self.ledger = ledger
        self.requestStore = requestStore
        let runner = RequestRunner(
            lidarr: client, gate: gate, ledger: ledger, mb: musicBrainz, library: libraryAccess(), store: requestStore,
            setup: { [weak self] in await self?.runnerSetup },
            keepSetup: { [weak self] in await self?.keepSetup },
            onReady: { [weak self] request in Task { @MainActor in self?.requestBecameReady(request) } },
            onRelinked: { [weak self] request, before, song in
                Task { @MainActor in self?.keptSongRelinked(request, before: before, song: song) }
            })
        self.gate = gate
        self.runner = runner
        runnerTasks.append(Task { [weak self] in
            for await list in await runner.updates {
                guard let self, self.runner === runner else { return }
                let wasWaiting = self.hasUnavailableWait
                self.requests = list
                // I4: a request just started waiting: re-check the connection so a rejected key is named.
                if !wasWaiting, self.hasUnavailableWait { Task { _ = await self.lidarrAudit() } }
            }
        })
        runnerTasks.append(Task { [weak self] in
            await retired?.stop()   // the old runner never saves over what this one loads
            await runner.load()
            self?.pollRequests()
        })
        if lidarrStatus == nil { Task { _ = await lidarrAudit() } }
    }

    /// FM1: what the write gate confines deletes and moves to: the main root, the confirmed Finds root and the
    /// `magpie-find` tag, as the owner set them up (the gate checks them against Lidarr's fresh root folders).
    var gateRoots: WriteConfinement.Roots {
        WriteConfinement.Roots(mainRoot: lidarrSetup?.rootFolderPath, findsRoot: findsSetup?.findsRoot,
                               findTagId: lidarrSetup?.findTagId)
    }

    /// The library as the runner sees it: plain quick scan (A12), the shared match index.
    private func libraryAccess() -> LibraryAccess {
        LibraryAccess(
            startScan: { [weak self] in
                guard let self else { return }
                try await self.request { try await $0.startScan(target: nil) }
            },
            isScanning: { [weak self] in
                guard let self else { return false }
                return try await self.request { try await $0.scanStatus() }
            },
            refreshIndex: { [weak self] in try await self?.refreshMatchIndex() },
            songId: { [weak self] recording in await self?.matchIndex?.index.librarySong(for: recording) },
            rescanMoved: { [weak self] from, to in try await self?.rescanMoved(from: from, to: to) },
            keptSong: { [weak self] recording, artistPath in try await self?.keptSong(recording, artistPath: artistPath) })
    }

    /// Polls while any request is on its way: every 5 s in the foreground, 30 s otherwise. Stops by itself
    /// when nothing is left to poll.
    func pollRequests() {
        guard pollTask == nil, let runner else { return }
        let generation = pollGeneration
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await runner.tick()
                guard await runner.needsPolling, let foreground = self?.isForeground else { break }
                try? await Task.sleep(for: RequestRunner.pollInterval(foreground: foreground))
            }
            if let self, self.pollGeneration == generation { self.pollTask = nil }
        }
    }

    // MARK: - Settings: Lidarr

    /// G1: the persisted "Allow Magpie to change Lidarr" switch of the connected Lidarr (security M3: per
    /// instance), shared with every write gate for it.
    func setChangesAllowed(_ on: Bool) async {
        guard let scope = lidarrScope else {   // no Lidarr: nothing to allow
            changesAllowed = false
            return
        }
        if let gate { await gate.setEnabled(on) } else { gateDefaults.set(on, forKey: LidarrWriteGate.enabledKey(scope: scope)) }
        changesAllowed = on
        if on { pollRequests() }
    }

    /// "Set up Magpie in Lidarr": creates Magpie's profiles and tags if they are missing (through the gate).
    @discardableResult
    func provisionLidarr() async throws -> ProvisionResult {
        guard let gate, let client = lidarrClient, var setup = lidarrSetup else { throw WriteGateError.disabled }
        let result = try await Provisioner().ensure(gate: gate, client: client)
        setup.fastStartProfileId = result.fastStartProfileId
        setup.findsMetadataProfileId = result.findsMetadataProfileId
        setup.magpieTagId = result.magpieTagId
        setup.findTagId = result.findTagId
        setup.losslessProfileId = result.losslessProfileId
        saveSetup(setup)
        _ = await lidarrAudit()
        return result
    }

    /// The owner's choice of main root folder (fallback mode adds go here).
    func chooseRoot(_ path: String) {
        guard var setup = lidarrSetup, !isFindsRoot(path) else { return }
        setup.rootFolderPath = path
        saveSetup(setup)
    }

    /// Fix 6.2a-2: a Lidarr set up before Finds mode has no `magpie-find` id saved. The audit looks the tag up
    /// by name (a read); it is only ever created by "Set up Magpie in Lidarr". A found id is never cleared here.
    func adoptFindTag(_ audit: LidarrAudit) {
        guard var setup = lidarrSetup, let id = audit.findTagId, setup.findTagId != id else { return }
        setup.findTagId = id
        saveSetup(setup)
    }

    /// Task 6.2b: a setup made before Keep has no "Magpie Lossless" id saved; the audit looks the profile up by
    /// name (a read). A found id is never cleared here.
    func adoptLosslessProfile(_ audit: LidarrAudit) {
        guard var setup = lidarrSetup, let id = audit.losslessProfileId, setup.losslessProfileId != id else { return }
        setup.losslessProfileId = id
        saveSetup(setup)
    }

    /// Exactly one root folder: that is where new music goes. Several: the owner picks; never guessed.
    func adoptOnlyRoot(_ audit: LidarrAudit) {
        guard var setup = lidarrSetup, audit.reachable else { return }
        let paths = audit.roots.map(\.path)
        if setup.rootFolderPath == nil, paths.count == 1, !isFindsRoot(paths[0]) {
            setup.rootFolderPath = paths[0]
            saveSetup(setup)
        }
    }

    private func saveSetup(_ setup: LidarrSetup) {
        lidarrSetup = setup
        setupStore.save(setup)
    }

    /// The Lidarr change log, newest first. Readable after Lidarr is disconnected too: it is the owner's undo map.
    func changeLog() async -> [ChangeLogEntry] {
        let reader = gate ?? LidarrWriteGate(
            client: LidarrClient(base: URL(string: "http://127.0.0.1")!, apiKey: "", transport: transport),
            logURL: LidarrWriteGate.defaultLogURL(in: dataDirectory), defaultsSuite: gateDefaultsSuite)
        return await reader.changeLog().reversed()
    }

    // MARK: - Settings: listening

    func setCountPlays(_ on: Bool) {
        countPlays = on
        playCounting.set(on)
        appDefaults.set(on, forKey: Self.countPlaysKey)
    }

    /// Settings' Save token (final fix 2 B-M8): the token is checked with ListenBrainz first (`validate-token`, the
    /// API host only, A9) and saved only once it is accepted. When it can't be checked, it isn't saved either.
    func saveListenBrainzToken(_ token: String) async throws {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return try setListenBrainzToken(nil) }
        do {
            _ = try await ListenBrainzClient(transport: transport, token: trimmed, limiter: listenBrainzLimiter).tokenUser()
        } catch ListenBrainzError.unauthorized {
            throw ListenBrainzTokenError.notAccepted
        } catch {
            throw ListenBrainzTokenError.unreachable
        }
        try setListenBrainzToken(trimmed)
    }

    func setListenBrainzToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { tokenStore.clear() } else { try tokenStore.save(trimmed) }
        hasListenBrainzToken = !trimmed.isEmpty
        listenBrainzTokenChanged()
    }

    // MARK: - Try

    /// D8: Standard when Tubifarry is detected, else Patient (also when Lidarr's setup hasn't been read).
    var speedTier: Tier { lidarrStatus?.tubifarry == true ? .standard : .patient }

    var tryAvailability: TryAvailability {
        guard lidarr != nil else { return .noLidarr }
        guard changesAllowed else { return .changesOff }
        guard lidarrSetup?.isProvisioned == true else { return .notSetUp }
        guard lidarrSetup?.rootFolderPath != nil else { return .noRoot }
        return .available(speedTier)
    }

    /// Final fix 2 B-M2: Home's "Finish setting up" card, while something is left: Try doesn't work yet, or Finds
    /// is on but half set up (or needs set-up run again). Finds off is a choice, not a step left.
    var showsFinishSettingUp: Bool {
        guard case .available = tryAvailability else { return true }
        return findsStatus == .notFinished || findsStatus == .needsSetUpAgain
    }

    /// I4: why waiting requests can't move, as far as the app knows: Try's availability first, then a key the last
    /// audit found rejected.
    var waitContext: RequestCopy.WaitContext {
        if let message = tryAvailability.message { return .needsSettings(message) }
        if lidarrStatus?.keyRejected == true { return .keyRejected }
        return .unknown
    }

    /// Some request is waiting because Lidarr (or MusicBrainz, or the requests file) couldn't be used.
    var hasUnavailableWait: Bool {
        requests.contains {
            if case .waiting(let reason, _) = $0.state { reason.kind == .serviceUnavailable } else { false }
        }
    }

    func tryRecording(_ recording: ExternalRecording) async throws -> RequestID {
        guard let runner else { throw RequestRunner.TryError.notSetUp }
        let id = try await runner.tryRecording(recording, tier: speedTier)
        if notifications { ReadyNotifier.shared.requestAuthorizationIfNeeded() }
        pollRequests()
        return id
    }

    func cancelRequest(_ id: RequestID) async {
        await runner?.cancel(id)
        pollRequests()
    }

    func forgetRequest(_ id: RequestID) async {
        await runner?.forget(id)
    }

    /// "Not showing up in your library yet" › Check again.
    func checkAgain(_ id: RequestID) async {
        await runner?.checkAgain(id)
        pollRequests()
    }

    func magpieRequest(_ id: RequestID) -> MagpieRequest? { requests.first { $0.id == id } }

    /// G7 / FL4: songs on their way plus releases Bring in more is still bringing in (the limit of five counts both).
    var onTheirWay: Int { requests.reduce(0) { $0 + $1.activePlaces } }

    /// The library song a Ready request became.
    func readySong(_ request: MagpieRequest) async -> Song? {
        guard let songId = request.songId else { return nil }
        return try? await self.request { try await $0.song(id: songId) }
    }

    /// D6: it lands by the one landing rule (AppModel+Landing.swift). D7: a local notification, only while the app
    /// runs.
    func requestBecameReady(_ request: MagpieRequest) {
        // FM2: a find from now on, before it can land and play (the refresh below runs next to the landing).
        if request.isFind, let songId = request.songId { findsIdentity.markLanded(songId) }
        if request.isFind { Task { await refreshFinds() } }
        if !request.isFind, findsLibraryId != nil {
            // Final fix 2 A-I1, belt and braces: a song the runner didn't call a find can still be in the Finds
            // library. Read it again before landing, so it never plays as now playing (D29).
            Task {
                await refreshFinds()
                await land(request)
            }
        } else {
            Task { await land(request) }
        }
        guard notifications else { return }
        ReadyNotifier.shared.post(id: request.id.description, title: "\(request.recording.title) is ready",
                                  body: "\(request.recording.artist) · in your \(request.isFind ? "Finds" : "library") now")
    }
}
