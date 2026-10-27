import Foundation
import LidarrKit
import MagpieCore
import NavidromeKit
import Requests

/// Whether Try can bring a song home right now, and if not, the calm reason (brief ruling 2).
enum TryAvailability: Equatable {
    case available(Tier)
    case noLidarr
    case changesOff
    case notSetUp
    case noRoot

    var message: String? {
        switch self {
        case .available: nil
        case .noLidarr: "Connect Lidarr in Settings to bring songs home."
        case .changesOff: "Turn on 'Allow Magpie to change Lidarr' in Settings to bring songs home."
        case .notSetUp: "Tap 'Set up Magpie in Lidarr' in Settings to bring songs home."
        case .noRoot: "Choose where new music goes in Settings › Lidarr to bring songs home."
        }
    }
}

enum TryCopy {
    /// B8: fallback mode; say plainly where the song lands.
    static let fallbackNote = "Finds aren't set up, so this goes straight into your library."
    /// Finds mode (Task 6.2a).
    static let findsNote = "It goes into your Finds first, so you can try it before it joins your library."
    /// Finds mode was on, but the Finds folder didn't check out when the song was asked for (G2, B8).
    static let findsUnavailable = "Your Finds folder needs another look in Settings, so this went straight into your library."
    static let tooMany = "Five songs are already on their way. Try this one when one of them is home."
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
        let gate = LidarrWriteGate(client: client, logURL: LidarrWriteGate.defaultLogURL(in: dataDirectory),
                                   defaultsSuite: gateDefaultsSuite)
        // CRITICAL 1: one ledger view and one requests file per Lidarr server.
        let scope = client.instanceScope
        let ledger = Ledger(fileURL: Ledger.defaultURL(in: dataDirectory), instance: scope)
        let requestStore = RequestStore(fileURL: RequestStore.defaultURL(in: dataDirectory, instance: scope))
        self.ledger = ledger
        self.requestStore = requestStore
        let runner = RequestRunner(
            lidarr: client, gate: gate, ledger: ledger, mb: musicBrainz, library: libraryAccess(), store: requestStore,
            setup: { [weak self] in await self?.runnerSetup },
            onReady: { [weak self] request in Task { @MainActor in self?.requestBecameReady(request) } })
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
            songId: { [weak self] recording in await self?.matchIndex?.index.librarySong(for: recording) })
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

    func setListenBrainzToken(_ token: String?) throws {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty { tokenStore.clear() } else { try tokenStore.save(trimmed) }
        hasListenBrainzToken = !trimmed.isEmpty
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

    /// The library song a Ready request became.
    func readySong(_ request: MagpieRequest) async -> Song? {
        guard let songId = request.songId else { return nil }
        return try? await self.request { try await $0.song(id: songId) }
    }

    /// D7: a local notification, only while the app runs.
    private func requestBecameReady(_ request: MagpieRequest) {
        if request.isFind { Task { await refreshFinds() } }
        guard notifications else { return }
        ReadyNotifier.shared.post(id: request.id.description, title: "\(request.recording.title) is ready",
                                  body: "\(request.recording.artist) · in your \(request.isFind ? "Finds" : "library") now")
    }
}
