import Foundation
import MagpieCore
import Playback

/// R1: who a download is across relaunches, so a stopped one can resume and a finished one finds its job.
struct FetchJob: Sendable, Equatable {
    /// The store's scope (the app's own hex id, never a server string).
    var scope: String
    /// `PartialDownloads.key(songId:quality:)`.
    var key: String
    /// Original streams are byte-resumed; a transcoded one restarts from zero.
    var isOriginal: Bool

    /// `<scope>/<key>`: the task's description, the one thing the system keeps about it besides the request.
    var id: String { "\(scope)/\(key)" }

    init(scope: String, key: String, isOriginal: Bool) {
        self.scope = scope; self.key = key; self.isOriginal = isOriginal
    }

    init?(id: String?) {
        guard let parts = id?.split(separator: "/", omittingEmptySubsequences: false), parts.count == 2,
              String(parts[0]).wholeMatch(of: /[A-Za-z0-9_-]{1,64}/) != nil, PartialDownloads.isKey(String(parts[1]))
        else { return nil }
        self.init(scope: String(parts[0]), key: String(parts[1]), isOriginal: false)
    }
}

/// A fetcher whose downloads go on with Magpie closed, and resume part-way (R1).
protocol ResumableAudioFetching: AudioFetching {
    func fetch(_ url: URL, job: FetchJob, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> (file: URL, mimeType: String?)
    /// Relaunch reconciliation: takes up the tasks the system kept, then `retain`s.
    func reconcile(_ keys: Set<String>, scope: String, partials: URL) async
    /// Every task of `scope` whose key isn't in `keys` is cancelled, and its partials removed (cancel, remove).
    func retain(_ keys: Set<String>, scope: String, partials: URL)
    /// Sign-out: every task is cancelled and the session invalidated; the next fetch makes a new one.
    func invalidate()
}

/// The URLSession download task, as far as the fetcher uses it (tests drive a stub).
protocol DownloadTasking: AnyObject, Sendable {
    var taskIdentifier: Int { get }
    var taskDescription: String? { get set }
    var countOfBytesReceived: Int64 { get }
    var countOfBytesExpectedToReceive: Int64 { get }
    var response: URLResponse? { get }
    func resume()
    func cancel()
    func cancelProducingResumeData(_ done: @escaping @Sendable (Data?) -> Void)
}

/// The background URLSession, as far as the fetcher uses it.
protocol DownloadSessioning: AnyObject, Sendable {
    func makeTask(_ request: URLRequest) -> any DownloadTasking
    func makeTask(resumeData: Data) -> any DownloadTasking
    func downloadTasks() async -> [any DownloadTasking]
    func invalidateAndCancel()
}

extension URLSessionDownloadTask: DownloadTasking {
    func cancelProducingResumeData(_ done: @escaping @Sendable (Data?) -> Void) {
        cancel(byProducingResumeData: { done($0) })
    }
}

extension URLSession: DownloadSessioning {
    func makeTask(_ request: URLRequest) -> any DownloadTasking { downloadTask(with: request) }
    func makeTask(resumeData: Data) -> any DownloadTasking { downloadTask(withResumeData: resumeData) }
    func downloadTasks() async -> [any DownloadTasking] { await allTasks.compactMap { $0 as? URLSessionDownloadTask } }
}

/// Downloads and pre-downloads on a background `URLSession` (R1): they go on when Magpie is closed or the phone locks.
///
/// - A task is named `<scope>/<key>` (`FetchJob.id`); nothing else about it is kept by Magpie. Its URL carries the
///   Subsonic token, as streaming does: the system daemon stores the request (accepted, decisions.md). URLs are never
///   logged.
/// - A finished file is moved into the scope's `partials` folder on the delegate callback, then handed to the waiting
///   fetch. With nobody waiting (Magpie was relaunched for it) it is parked as `<key>.done`, and the job's next fetch
///   takes it without the network.
/// - Stopped part-way (Pause all, a network flip, an error), an Original keeps URLSession's resume data; one with none
///   but bytes held and a server that takes ranges continues with an HTTP Range request; a transcoded one restarts.
/// - A file is checked against the size the server announced; a short Original is continued with a Range request.
final class BackgroundAudioFetcher: NSObject, ResumableAudioFetching, URLSessionDownloadDelegate, @unchecked Sendable {
    static let identifier = "com.bleak-rooster.magpie.downloads"
    /// How many downloads the session runs at once in the background (P1's 1–6 cap applies while Magpie is open).
    static let maxConnections = 4
    /// Range continuations of one short file before it counts as a dropped connection.
    static let maxContinuations = 3

    typealias SessionFactory = @Sendable (_ delegate: any URLSessionDelegate) -> any DownloadSessioning

    /// The app's one fetcher: the app delegate hands it the system's completion handler.
    static let shared = BackgroundAudioFetcher(
        audioRoot: URL.applicationSupportDirectory.appending(path: "Magpie/Audio", directoryHint: .isDirectory))

    enum FetchError: Error, Equatable { case status(Int) }

    /// How a run ended: a whole file, or bytes kept for a Range continuation.
    enum Outcome { case file(URL, String?), incomplete }

    private struct Running {
        var job: FetchJob
        var token: Int
        var allowsCellular: Bool
        /// Bytes already held when the task started (a Range request): progress counts from there.
        var offset: Int64
        let task: any DownloadTasking
        var landed: Landed?
    }

    /// What `didFinishDownloadingTo` moved in and what the response said.
    private struct Landed {
        var file: URL
        var status: Int
        var mimeType: String?
        var contentLength: Int64?
        var contentRange: String?
        var acceptsRanges: Bool
        var validator: String?
    }

    private struct Waiter {
        let token: Int
        let continuation: CheckedContinuation<Outcome, Error>
        let progress: FetchProgress
        var lastReport: ContinuousClock.Instant?
    }

    private let audioRoot: URL
    private let makeSession: SessionFactory
    private let lock = NSLock()
    private var session: (any DownloadSessioning)?
    private var adopted = false
    private var running: [Int: Running] = [:]
    /// The current token per job id; a callback from an older task (or after `retain` dropped the job) is ignored.
    private var tokens: [String: Int] = [:]
    private var nextToken = 0
    private var waiters: [String: Waiter] = [:]
    private var eventsHandler: (@Sendable () -> Void)?
    /// Runs when the system has delivered every event of a background launch, before its completion handler: the app
    /// stores what arrived first.
    var onEventsFinished: (@Sendable () async -> Void)? {
        get { lock.withLock { _onEventsFinished } }
        set { lock.withLock { _onEventsFinished = newValue } }
    }
    private var _onEventsFinished: (@Sendable () async -> Void)?

    init(audioRoot: URL, makeSession: SessionFactory? = nil) {
        self.audioRoot = audioRoot
        self.makeSession = makeSession ?? Self.backgroundSession
        super.init()
    }

    /// `URLSessionConfiguration.background`: launch events on, not discretionary, no cache or cookies.
    static let backgroundSession: SessionFactory = { delegate in
        let configuration = URLSessionConfiguration.background(withIdentifier: BackgroundAudioFetcher.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.urlCache = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpMaximumConnectionsPerHost = BackgroundAudioFetcher.maxConnections
        return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    private func currentSession() -> any DownloadSessioning {
        lock.withLock {
            if let session { return session }
            let made = makeSession(self)
            session = made
            return made
        }
    }

    func partials(_ scope: String) -> PartialDownloads {
        PartialDownloads(directory: audioRoot.appending(path: scope, directoryHint: .isDirectory)
            .appending(path: "partials", directoryHint: .isDirectory))
    }

    // MARK: - Fetching

    /// Without a job (covers, tests) there's nothing to resume: a plain fetch is refused here, the manager uses its
    /// foreground fetcher for those.
    func fetch(_ url: URL, allowsCellular: Bool) async throws -> (file: URL, mimeType: String?) {
        throw URLError(.unsupportedURL)
    }

    func fetch(_ url: URL, job: FetchJob, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> (file: URL, mimeType: String?) {
        await adoptTasks()
        if let parked = takeParked(job) { return parked }
        for _ in 0...Self.maxContinuations {
            switch try await run(url, job: job, allowsCellular: allowsCellular, progress: progress) {
            case let .file(file, mime): return (file, mime)
            case .incomplete: continue   // bytes kept: the next run asks for the rest
            }
        }
        throw URLError(.networkConnectionLost)
    }

    /// A file that finished while nobody waited (a relaunch): handed over without the network.
    private func takeParked(_ job: FetchJob) -> (file: URL, mimeType: String?)? {
        lock.withLock {
            let partials = partials(job.scope), done = partials.url(job.key, "done")
            guard FileManager.default.fileExists(atPath: done.path) else { return nil }
            let mime = partials.info(job.key)?.mimeType
            let file = FileManager.default.temporaryDirectory.appending(path: "magpie-audio-\(UUID().uuidString).tmp")
            guard (try? FileManager.default.moveItem(at: done, to: file)) != nil else { return nil }
            partials.remove(job.key)
            return (file, mime)
        }
    }

    private func run(_ url: URL, job: FetchJob, allowsCellular: Bool, progress: @escaping FetchProgress) async throws
        -> Outcome {
        try Task.checkCancellation()
        let session = currentSession()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let token = lock.withLock { () -> Int in
                    nextToken += 1
                    let token = nextToken
                    tokens[job.id] = token
                    waiters[job.id]?.continuation.resume(throwing: CancellationError())
                    waiters[job.id] = Waiter(token: token, continuation: continuation, progress: progress)
                    // A task the system kept from before a relaunch: wait for it instead of starting another.
                    if let id = running.first(where: { $0.value.job.id == job.id })?.key {
                        running[id]?.token = token
                        return token
                    }
                    let started = start(url, job: job, allowsCellular: allowsCellular, session: session)
                    running[started.task.taskIdentifier] = Running(job: job, token: token, allowsCellular: allowsCellular,
                                                                   offset: started.offset, task: started.task)
                    started.task.resume()
                    return token
                }
                if Task.isCancelled { pause(job.id, token: token) }
            }
        } onCancel: {
            pause(job.id, token: nil)
        }
    }

    /// Chooses how the task starts (with the lock held): resume data, a Range continuation, or from zero.
    private func start(_ url: URL, job: FetchJob, allowsCellular: Bool, session: any DownloadSessioning)
        -> (task: any DownloadTasking, offset: Int64) {
        let partials = partials(job.scope)
        var info = partials.info(job.key)
        let task: any DownloadTasking
        var offset: Int64 = 0
        if !job.isOriginal {
            partials.remove(job.key)   // a new conversion needn't give the same bytes: start from zero
            info = nil
            task = session.makeTask(Self.request(url, allowsCellular: allowsCellular))
        } else if let data = partials.resumeData(job.key), info?.allowsCellular == allowsCellular {
            // Resume data replays its request as it was; one made under the other mobile-data rule isn't used.
            try? FileManager.default.removeItem(at: partials.url(job.key, "resume"))   // spent: a new one comes on stop
            task = session.makeTask(resumeData: data)
        } else if let range = partials.rangeRequest(job.key) {
            var request = Self.request(url, allowsCellular: allowsCellular)
            request.setValue(range.range, forHTTPHeaderField: "Range")
            request.setValue(range.ifRange, forHTTPHeaderField: "If-Range")
            offset = partials.partSize(job.key)
            task = session.makeTask(request)
        } else {
            partials.remove(job.key)
            info = nil
            task = session.makeTask(Self.request(url, allowsCellular: allowsCellular))
        }
        var saved = info ?? PartialDownloads.Info(received: 0, expected: nil, isOriginal: job.isOriginal,
                                                  allowsCellular: allowsCellular, validator: nil, acceptsRanges: false,
                                                  mimeType: nil)
        saved.isOriginal = job.isOriginal
        saved.allowsCellular = allowsCellular
        try? partials.saveInfo(saved, key: job.key)
        task.taskDescription = job.id
        return (task, offset)
    }

    static func request(_ url: URL, allowsCellular: Bool) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.allowsCellularAccess = allowsCellular
        return request
    }

    /// Stops the job's task keeping what it can (Pause all, a network flip, Magpie held in the background).
    private func pause(_ id: String, token: Int?) {
        let entry: Running? = lock.withLock {
            guard let current = tokens[id], token == nil || token == current else { return nil }
            return running.values.first { $0.job.id == id && $0.token == current }
        }
        guard let entry else { return }
        entry.task.cancelProducingResumeData { [weak self] data in
            guard let self, let data else { return }
            self.lock.withLock {
                // Not if the job was dropped (`retain`) or has started again since.
                guard self.tokens[entry.job.id] == entry.token else { return }
                self.saveResume(data, job: entry.job, task: entry.task, offset: entry.offset,
                                allowsCellular: entry.allowsCellular)
            }
        }
    }

    // MARK: - Reconciling

    /// Once per session: the tasks the system kept from before a relaunch are taken up by their description.
    private func adoptTasks() async {
        let session = currentSession()
        guard lock.withLock({ !adopted }) else { return }
        let tasks = await session.downloadTasks()
        lock.withLock {
            guard !adopted else { return }
            adopted = true
            for task in tasks where running[task.taskIdentifier] == nil {
                guard var job = FetchJob(id: task.taskDescription) else { task.cancel(); continue }
                let partials = partials(job.scope)
                let info = partials.info(job.key)
                job.isOriginal = info?.isOriginal ?? false
                nextToken += 1
                tokens[job.id] = nextToken
                running[task.taskIdentifier] = Running(job: job, token: nextToken, allowsCellular: info?.allowsCellular ?? false,
                                                       offset: partials.partSize(job.key), task: task)
            }
        }
    }

    func reconcile(_ keys: Set<String>, scope: String, partials: URL) async {
        await adoptTasks()
        retain(keys, scope: scope, partials: partials)
    }

    func retain(_ keys: Set<String>, scope: String, partials directory: URL) {
        let cancelled: [any DownloadTasking] = lock.withLock {
            var cancelled: [any DownloadTasking] = []
            for (id, entry) in running where entry.job.scope == scope && !keys.contains(entry.job.key) {
                running[id] = nil
                cancelled.append(entry.task)
            }
            for id in tokens.keys where id.hasPrefix(scope + "/") {
                guard let job = FetchJob(id: id), !keys.contains(job.key) else { continue }
                tokens[id] = nil
                waiters.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
            }
            PartialDownloads(directory: directory).retain(only: keys)   // under the lock: no late write lands after
            return cancelled
        }
        for task in cancelled { task.cancel() }
    }

    func invalidate() {
        let old: (any DownloadSessioning)? = lock.withLock {
            for waiter in waiters.values { waiter.continuation.resume(throwing: CancellationError()) }
            waiters = [:]
            running = [:]
            tokens = [:]
            adopted = false
            defer { session = nil }
            return session
        }
        old?.invalidateAndCancel()
    }

    // MARK: - Background launch

    /// The app delegate's `handleEventsForBackgroundURLSession`: the session is made again so its events arrive; the
    /// handler runs once they have, after the app has stored what came.
    func handleEvents(_ completion: @escaping @Sendable () -> Void) {
        lock.withLock { eventsHandler = completion }
        _ = currentSession()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let (handler, finished) = lock.withLock { () -> ((@Sendable () -> Void)?, (@Sendable () async -> Void)?) in
            defer { eventsHandler = nil }
            return (eventsHandler, _onEventsFinished)
        }
        Task {
            await finished?()
            await MainActor.run { handler?() }
        }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: (any Error)?) {
        lock.withLock {
            if self.session === session { self.session = nil; adopted = false }
        }
    }

    // MARK: - Delegate (forwarded to the handlers tests call)

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        handleFinished(downloadTask, location: location)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        handleProgress(downloadTask, written: totalBytesWritten, expected: totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let task = task as? URLSessionDownloadTask else { return }
        handleCompleted(task, error: error)
    }

    /// Security M1: redirects stay within the origin.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        await SameOriginRedirects.shared.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                                    newRequest: request)
    }

    // MARK: - Handlers

    /// The entry for `task`, taking up one the system kept that `adoptTasks` hasn't met yet (lock held).
    private func entry(for task: any DownloadTasking) -> Running? {
        if let entry = running[task.taskIdentifier] { return entry }
        guard !adopted, var job = FetchJob(id: task.taskDescription) else { return nil }
        let partials = partials(job.scope)
        let info = partials.info(job.key)
        job.isOriginal = info?.isOriginal ?? false
        nextToken += 1
        tokens[job.id] = nextToken
        let entry = Running(job: job, token: nextToken, allowsCellular: info?.allowsCellular ?? false,
                            offset: partials.partSize(job.key), task: task)
        running[task.taskIdentifier] = entry
        return entry
    }

    func handleProgress(_ task: any DownloadTasking, written: Int64, expected: Int64) {
        let report: (FetchProgress, Int64, Int64)? = lock.withLock {
            guard let entry = running[task.taskIdentifier], var waiter = waiters[entry.job.id],
                  waiter.token == entry.token else { return nil }
            let now = ContinuousClock.now
            if let last = waiter.lastReport, now - last < URLSessionAudioFetcher.progressInterval { return nil }
            waiter.lastReport = now
            waiters[entry.job.id] = waiter
            return (waiter.progress, entry.offset + written, expected > 0 ? entry.offset + expected : -1)
        }
        if let (progress, received, total) = report { progress(received, total) }
    }

    /// The file must be moved before this returns: it goes to `<key>.landing` with what the response said.
    func handleFinished(_ task: any DownloadTasking, location: URL) {
        lock.withLock {
            guard let entry = entry(for: task), tokens[entry.job.id] == entry.token else { return }
            let http = task.response as? HTTPURLResponse
            guard let landing = try? partials(entry.job.scope).adopt(location, key: entry.job.key, as: "landing") else { return }
            func header(_ name: String) -> String? { http?.value(forHTTPHeaderField: name) }
            let length = Int64(header("Content-Length") ?? "") ?? http?.expectedContentLength
            running[task.taskIdentifier]?.landed = Landed(
                file: landing, status: http?.statusCode ?? 0, mimeType: http?.mimeType,
                contentLength: length.flatMap { $0 > 0 ? $0 : nil }, contentRange: header("Content-Range"),
                acceptsRanges: header("Accept-Ranges")?.lowercased().contains("bytes") == true,
                validator: header("ETag") ?? header("Last-Modified"))
        }
    }

    func handleCompleted(_ task: any DownloadTasking, error: (any Error)?) {
        let delivery: (CheckedContinuation<Outcome, Error>, Result<Outcome, Error>)? = lock.withLock {
            guard let entry = entry(for: task) else { return nil }
            running[task.taskIdentifier] = nil
            guard tokens[entry.job.id] == entry.token else {   // dropped (`retain`) or superseded
                if let landed = entry.landed { try? FileManager.default.removeItem(at: landed.file) }
                return nil
            }
            let result = finish(entry, error: error)
            guard let waiter = waiters[entry.job.id], waiter.token == entry.token else {
                park(entry, result)   // nobody waits: Magpie was relaunched for this
                return nil
            }
            waiters[entry.job.id] = nil
            return (waiter.continuation, result)
        }
        if let (continuation, result) = delivery { continuation.resume(with: result) }
    }

    /// Turns a finished task into a whole file, kept bytes, or an error (lock held).
    private func finish(_ entry: Running, error: (any Error)?) -> Result<Outcome, Error> {
        let partials = partials(entry.job.scope), key = entry.job.key
        if let error {
            if let landed = entry.landed { try? FileManager.default.removeItem(at: landed.file) }
            let data = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
            if entry.job.isOriginal, let data {
                saveResume(data, job: entry.job, task: entry.task, offset: entry.offset, allowsCellular: entry.allowsCellular)
            } else if entry.job.isOriginal {
                noteReceived(entry)   // the counts, for "Paused · 2.1 of 8.4 MB" (resume data may follow)
            } else {
                partials.remove(key)   // transcoded: nothing to resume
            }
            if (error as? URLError)?.code == .cancelled { return .failure(CancellationError()) }
            Log.logger("downloads").error("background download stopped: \(Log.category(of: error), privacy: .public)")
            return .failure(error)
        }
        guard let landed = entry.landed else {
            partials.remove(key)
            return .failure(URLError(.cannotOpenFile))
        }
        if landed.status == 206 {
            // A Range continuation: appended to the bytes held, then the total checked.
            do {
                switch try partials.appendRange(landed.file, status: 206, contentRange: landed.contentRange, key: key) {
                case let .complete(file): return .success(.file(file, landed.mimeType ?? partials.info(key)?.mimeType))
                case .incomplete, .restart: return .success(.incomplete)
                }
            } catch {
                return .failure(error)
            }
        }
        guard (200..<300).contains(landed.status) else {
            try? FileManager.default.removeItem(at: landed.file)
            partials.remove(key)
            return .failure(FetchError.status(landed.status))
        }
        let size = PartialDownloads.size(of: landed.file)
        if PartialDownloads.isWhole(size: size, expected: landed.contentLength) {
            let file = FileManager.default.temporaryDirectory.appending(path: "magpie-audio-\(UUID().uuidString).tmp")
            do {
                try FileManager.default.moveItem(at: landed.file, to: file)
            } catch {
                return .failure(error)
            }
            partials.remove(key)
            return .success(.file(file, landed.mimeType))
        }
        // Short of its Content-Length: an Original from a server that takes ranges keeps the bytes and asks for the
        // rest; anything else is a dropped connection, tried again from zero.
        if entry.job.isOriginal, landed.acceptsRanges, landed.validator != nil, size > 0 {
            let info = PartialDownloads.Info(received: size, expected: landed.contentLength, isOriginal: true,
                                             allowsCellular: entry.allowsCellular, validator: landed.validator,
                                             acceptsRanges: true, mimeType: landed.mimeType)
            if (try? partials.adoptPart(landed.file, info: info, key: key)) != nil { return .success(.incomplete) }
        }
        try? FileManager.default.removeItem(at: landed.file)
        partials.remove(key)
        return .failure(URLError(.networkConnectionLost))
    }

    /// Nobody waits for this job (lock held): a whole file is parked as `<key>.done` for the job's next fetch.
    private func park(_ entry: Running, _ result: Result<Outcome, Error>) {
        guard case let .success(.file(file, mime)) = result else { return }
        let partials = partials(entry.job.scope)
        do {
            try partials.adopt(file, key: entry.job.key, as: "done")
            var info = partials.info(entry.job.key)
                ?? PartialDownloads.Info(received: 0, expected: nil, isOriginal: entry.job.isOriginal,
                                         allowsCellular: entry.allowsCellular, validator: nil, acceptsRanges: false,
                                         mimeType: nil)
            info.mimeType = mime
            try partials.saveInfo(info, key: entry.job.key)
        } catch {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Lock held.
    private func saveResume(_ data: Data, job: FetchJob, task: any DownloadTasking, offset: Int64, allowsCellular: Bool) {
        guard job.isOriginal else { return }
        let partials = partials(job.scope)
        do {
            try partials.saveResumeData(data, key: job.key)
        } catch {
            return
        }
        noteReceived(job: job, task: task, offset: offset, allowsCellular: allowsCellular)
    }

    private func noteReceived(_ entry: Running) {
        noteReceived(job: entry.job, task: entry.task, offset: entry.offset, allowsCellular: entry.allowsCellular)
    }

    /// The bytes so far and expected, from the task's own counts (lock held).
    private func noteReceived(job: FetchJob, task: any DownloadTasking, offset: Int64, allowsCellular: Bool) {
        let partials = partials(job.scope)
        var info = partials.info(job.key)
            ?? PartialDownloads.Info(received: 0, expected: nil, isOriginal: job.isOriginal, allowsCellular: allowsCellular,
                                     validator: nil, acceptsRanges: false, mimeType: nil)
        let received = task.countOfBytesReceived, expected = task.countOfBytesExpectedToReceive
        if received > 0 { info.received = offset + received }
        if expected > 0 { info.expected = offset + expected }
        try? partials.saveInfo(info, key: job.key)
    }
}
