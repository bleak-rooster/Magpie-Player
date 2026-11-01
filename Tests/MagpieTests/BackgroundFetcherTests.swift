import Foundation
import MagpieCore
import Playback
import Synchronization
import Testing
@testable import Magpie

/// A download task the test finishes by hand.
final class StubTask: DownloadTasking, @unchecked Sendable {
    private let lock = NSLock()
    let taskIdentifier: Int
    let request: URLRequest?
    let resumeData: Data?
    private var _description: String?
    private var _resumed = false
    private var _cancelled = false
    private var _received: Int64 = 0
    private var _expected: Int64 = -1
    private var _response: URLResponse?
    /// What `cancelProducingResumeData` hands back.
    var resumeDataOnCancel: Data?
    /// Called on any cancel (the test then completes the task as URLSession would).
    var onCancel: ((StubTask) -> Void)?

    init(id: Int, request: URLRequest? = nil, resumeData: Data? = nil, description: String? = nil) {
        taskIdentifier = id; self.request = request; self.resumeData = resumeData; _description = description
    }

    var taskDescription: String? {
        get { lock.withLock { _description } }
        set { lock.withLock { _description = newValue } }
    }
    var countOfBytesReceived: Int64 {
        get { lock.withLock { _received } }
        set { lock.withLock { _received = newValue } }
    }
    var countOfBytesExpectedToReceive: Int64 {
        get { lock.withLock { _expected } }
        set { lock.withLock { _expected = newValue } }
    }
    var response: URLResponse? {
        get { lock.withLock { _response } }
        set { lock.withLock { _response = newValue } }
    }
    var sentRange: Bool { request?.value(forHTTPHeaderField: "Range") != nil }
    var isResumed: Bool { lock.withLock { _resumed } }
    var isCancelled: Bool { lock.withLock { _cancelled } }

    func resume() { lock.withLock { _resumed = true } }
    func cancel() { lock.withLock { _cancelled = true }; onCancel?(self) }
    func cancelProducingResumeData(_ done: @escaping @Sendable (Data?) -> Void) {
        lock.withLock { _cancelled = true }
        done(resumeDataOnCancel)
        onCancel?(self)
    }
}

/// A background session the test drives: it records the tasks made, and lists the ones "kept by the system".
final class StubSession: DownloadSessioning, @unchecked Sendable {
    private let lock = NSLock()
    private var _tasks: [StubTask] = []
    private var _kept: [StubTask]
    private var _invalidated = false
    private var nextId: Int

    init(kept: [StubTask] = [], firstId: Int = 100) { _kept = kept; nextId = firstId }

    var tasks: [StubTask] { lock.withLock { _tasks } }
    var invalidated: Bool { lock.withLock { _invalidated } }

    func makeTask(_ request: URLRequest) -> any DownloadTasking {
        lock.withLock { nextId += 1; let t = StubTask(id: nextId, request: request); _tasks.append(t); return t }
    }
    func makeTask(resumeData: Data) -> any DownloadTasking {
        lock.withLock { nextId += 1; let t = StubTask(id: nextId, resumeData: resumeData); _tasks.append(t); return t }
    }
    func downloadTasks() async -> [any DownloadTasking] { lock.withLock { _kept } }
    func invalidateAndCancel() { lock.withLock { _invalidated = true } }
}

/// R1: the background fetcher's delegate-driven logic, without a real background session.
@MainActor @Suite(.serialized, .timeLimit(.minutes(1))) final class BackgroundFetcherTests {
    let tmp = FileManager.default.temporaryDirectory.appending(path: "BackgroundFetcherTests-\(UUID().uuidString)")
    let url = URL(string: "http://192.168.1.2:4533/rest/stream?id=s1&format=raw")!
    let scope = "abc"

    deinit { try? FileManager.default.removeItem(at: tmp) }

    /// How many sessions the fetcher made.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func bump() { lock.withLock { _value += 1 } }
    }

    func makeFetcher(_ session: StubSession) -> (BackgroundAudioFetcher, Counter) {
        let made = Counter()
        let fetcher = BackgroundAudioFetcher(audioRoot: tmp) { _ in made.bump(); return session }
        return (fetcher, made)
    }

    func job(_ song: String = "s1", original: Bool = true) -> FetchJob {
        FetchJob(scope: scope, key: PartialDownloads.key(songId: song, quality: original ? .original : .mp3High),
                 isOriginal: original)
    }

    func partials(_ fetcher: BackgroundAudioFetcher) -> PartialDownloads { fetcher.partials(scope) }

    func file(_ bytes: [UInt8]) -> URL {
        let dir = tmp.appending(path: "system")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "CFNetworkDownload-\(UUID().uuidString).tmp")
        try! Data(bytes).write(to: url)
        return url
    }

    func response(_ status: Int, _ headers: [String: String] = [:]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    func waitForTask(_ session: StubSession, count: Int = 1) async -> StubTask? {
        _ = await eventually { session.tasks.count >= count && session.tasks[count - 1].isResumed }
        return session.tasks.count >= count ? session.tasks[count - 1] : nil
    }

    /// The system finishing `task` with `bytes` and `response`.
    func complete(_ f: BackgroundAudioFetcher, _ task: StubTask, _ bytes: [UInt8], _ response: HTTPURLResponse) {
        task.response = response
        f.handleFinished(task, location: file(bytes))
        f.handleCompleted(task, error: nil)
    }

    let original = ["Content-Type": "audio/mp4", "Accept-Ranges": "bytes", "Last-Modified": "Mon, 26 Oct 2026 15:00:12 GMT"]

    @Test func aWholeFileArrivesThroughTheDelegate() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        #expect(task.taskDescription == job().id, "named by scope and key only")
        #expect(task.request?.allowsCellularAccess == false, "the mobile-data rule is on the request")
        #expect(task.request?.value(forHTTPHeaderField: "Range") == nil)
        var headers = original
        headers["Content-Length"] = "4"
        complete(f, task, [1, 2, 3, 4], response(200, headers))
        let result = try await fetch.value
        #expect(try Data(contentsOf: result.file) == Data([1, 2, 3, 4]))
        #expect(result.mimeType == "audio/mp4")
        #expect(partials(f).keys().isEmpty, "nothing left behind")
    }

    @Test func resumesFromResumeData() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let p = partials(f), key = job().key
        try p.saveResumeData(Data("resume-me".utf8), key: key)
        try p.saveInfo(.init(received: 2_100_000, expected: 8_400_000, isOriginal: true, allowsCellular: false,
                             validator: nil, acceptsRanges: false, mimeType: nil), key: key)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        #expect(task.resumeData == Data("resume-me".utf8), "resumed with downloadTask(withResumeData:)")
        #expect(task.request == nil)
        // Review C1: as iOS does, the resumed task answers 206 for the rest, and its file is the whole, stitched file.
        var rest = original
        rest["Content-Range"] = "bytes 2-3/4"
        rest["Content-Length"] = "2"
        complete(f, task, [9, 9, 9, 9], response(206, rest))
        #expect(try Data(contentsOf: try await fetch.value.file) == Data([9, 9, 9, 9]), "the whole file, as delivered")
        #expect(session.tasks.count == 1, "no second download")
        #expect(p.keys().isEmpty)
    }

    /// Review C1: a resumed file short of the Content-Range total isn't taken.
    @Test func aResumedFileShortOfTheTotalIsNotTaken() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let p = partials(f), key = job().key
        try p.saveResumeData(Data("resume-me".utf8), key: key)
        try p.saveInfo(.init(received: 2, expected: 4, isOriginal: true, allowsCellular: false,
                             validator: nil, acceptsRanges: false, mimeType: nil), key: key)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        var rest = original
        rest["Content-Range"] = "bytes 2-3/4"
        complete(f, task, [9, 9, 9], response(206, rest))
        let next = try #require(await waitForTask(session, count: 2), "tried again")
        #expect(next.resumeData == nil && next.request?.value(forHTTPHeaderField: "Range") == nil, "from zero")
        var headers = original
        headers["Content-Length"] = "4"
        complete(f, next, [1, 2, 3, 4], response(200, headers))
        #expect(try Data(contentsOf: try await fetch.value.file) == Data([1, 2, 3, 4]))
    }

    /// Review I1: after sign-out, callbacks from the old session write nothing into the erased scope.
    @Test func lateCallbacksFromAnInvalidatedSessionWriteNothing() async throws {
        let old = StubSession(), fresh = StubSession(firstId: 500)
        let sessions = Mutex([old, fresh])
        let f = BackgroundAudioFetcher(audioRoot: tmp) { _ in sessions.withLock { $0.removeFirst() } }
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(old))
        task.countOfBytesReceived = 2
        f.invalidate()
        _ = try? await fetch.value
        let p = partials(f)
        p.removeAll()   // eraseScope
        var headers = original
        headers["Content-Length"] = "4"
        task.response = response(200, headers)
        f.handleFinished(task, location: file([1, 2, 3, 4]), from: old)
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSURLSessionDownloadTaskResumeData: Data("late".utf8)])
        f.handleCompleted(task, error: URLError(_nsError: error), from: old)
        #expect(!FileManager.default.fileExists(atPath: p.directory.path), "nothing written under the scope")
    }

    /// Review M5: a Range continuation whose type differs from the bytes held restarts from zero.
    @Test func aRangeContinuationOfAnotherTypeRestarts() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let first = try #require(await waitForTask(session))
        var headers = original
        headers["Content-Length"] = "10"
        complete(f, first, [0, 1, 2, 3], response(200, headers))
        let second = try #require(await waitForTask(session, count: 2))
        var other = original
        other["Content-Type"] = "audio/flac"
        other["Content-Range"] = "bytes 4-9/10"
        complete(f, second, [4, 5, 6, 7, 8, 9], response(206, other))
        let third = try #require(await waitForTask(session, count: 3))
        #expect(third.request?.value(forHTTPHeaderField: "Range") == nil, "from zero")
        complete(f, third, Array(0..<10), response(200, headers))
        _ = try await fetch.value
    }

    @Test func pauseKeepsResumeDataAndTheSizes() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        task.countOfBytesReceived = 2_100_000
        task.countOfBytesExpectedToReceive = 8_400_000
        task.resumeDataOnCancel = Data("paused".utf8)
        task.onCancel = { t in
            let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                userInfo: [NSURLSessionDownloadTaskResumeData: Data("paused".utf8)])
            f.handleCompleted(t, error: URLError(_nsError: error))
        }
        fetch.cancel()   // Pause all, a network flip: the manager cancels the run
        await #expect(throws: CancellationError.self) { try await fetch.value }
        let p = partials(f)
        #expect(p.resumeData(job().key) == Data("paused".utf8))
        #expect(p.progress(job().key) == PartialDownloads.Progress(received: 2_100_000, expected: 8_400_000))
    }

    @Test func rangeFallbackAppendsAndVerifiesTheFinalSize() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let first = try #require(await waitForTask(session))
        // The server stopped early: 4 of 10 bytes, no resume data. Kept, and the rest asked for with Range.
        var headers = original
        headers["Content-Length"] = "10"
        complete(f, first, [0, 1, 2, 3], response(200, headers))
        let second = try #require(await waitForTask(session, count: 2))
        #expect(second.request?.value(forHTTPHeaderField: "Range") == "bytes=4-")
        #expect(second.request?.value(forHTTPHeaderField: "If-Range") == "Mon, 26 Oct 2026 15:00:12 GMT")
        var partial = original
        partial["Content-Range"] = "bytes 4-9/10"
        complete(f, second, [4, 5, 6, 7, 8, 9], response(206, partial))
        let result = try await fetch.value
        #expect(try Data(contentsOf: result.file) == Data([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]))
        #expect(partials(f).keys().isEmpty)
    }

    @Test func aTranscodedDownloadRestartsFromZero() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let p = partials(f), transcoded = job(original: false)
        try p.saveResumeData(Data("old".utf8), key: transcoded.key)
        try p.adoptPart(file([1, 2, 3]), info: .init(received: 3, expected: 10, isOriginal: false, allowsCellular: false,
                                                     validator: "x", acceptsRanges: true, mimeType: nil), key: transcoded.key)
        let fetch = Task { try await f.fetch(url, job: transcoded, allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        #expect(task.resumeData == nil, "no resume data for a conversion")
        #expect(task.request?.value(forHTTPHeaderField: "Range") == nil, "and no Range")
        #expect(p.resumeData(transcoded.key) == nil && p.partSize(transcoded.key) == 0, "the partial is gone")
        // Stopped part-way, it keeps nothing.
        task.onCancel = { t in f.handleCompleted(t, error: URLError(.cancelled)) }
        task.countOfBytesReceived = 5
        fetch.cancel()
        _ = try? await fetch.value
        #expect(p.resumeData(transcoded.key) == nil && p.progress(transcoded.key) == nil)
    }

    @Test func relaunchParksAFinishedFileForItsJob() async throws {
        // Magpie was closed; the system relaunched it for a task it kept. Nobody waits for it yet.
        let kept = StubTask(id: 7, description: job().id)
        let session = StubSession(kept: [kept])
        let (f, _) = makeFetcher(session)
        var headers = original
        headers["Content-Length"] = "3"
        complete(f, kept, [5, 6, 7], response(200, headers))
        #expect(FileManager.default.fileExists(atPath: partials(f).url(job().key, "done").path), "parked")
        // The job, read back from pending.json, asks: it gets the file without the network.
        let result = try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in }
        #expect(try Data(contentsOf: result.file) == Data([5, 6, 7]))
        #expect(session.tasks.isEmpty, "no new task")
        #expect(partials(f).keys().isEmpty)
    }

    @Test func relaunchWaitsForATaskStillRunning() async throws {
        let kept = StubTask(id: 7, description: job().id)
        let session = StubSession(kept: [kept])
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(session.tasks.isEmpty, "it attaches to the kept task")
        complete(f, kept, [1], response(200, original))
        #expect(try Data(contentsOf: try await fetch.value.file) == Data([1]))
    }

    @Test func reconcileCancelsTasksAndPartialsNoJobWants() async throws {
        let wanted = job("s1"), stray = job("s2")
        let keptWanted = StubTask(id: 1, description: wanted.id), keptStray = StubTask(id: 2, description: stray.id)
        let session = StubSession(kept: [keptWanted, keptStray])
        let (f, _) = makeFetcher(session)
        let p = partials(f)
        try p.saveResumeData(Data(count: 5), key: stray.key)
        try p.saveResumeData(Data(count: 5), key: wanted.key)
        await f.reconcile([wanted.key], scope: scope, partials: p.directory)
        #expect(keptStray.isCancelled && !keptWanted.isCancelled)
        #expect(p.keys() == [wanted.key])
        // A late resume-data callback for the dropped job writes nothing.
        f.handleCompleted(keptStray, error: URLError(.cancelled))
        #expect(p.keys() == [wanted.key])
    }

    @Test func cancelRemovesThePartialAndALateCallbackWritesNothing() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        f.retain([], scope: scope, partials: partials(f).directory)   // the download was cancelled
        #expect(task.isCancelled)
        await #expect(throws: CancellationError.self) { try await fetch.value }
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                            userInfo: [NSURLSessionDownloadTaskResumeData: Data("late".utf8)])
        f.handleCompleted(task, error: URLError(_nsError: error))
        #expect(partials(f).keys().isEmpty, "nothing comes back")
    }

    @Test func signOutInvalidatesAndTheNextFetchMakesANewSession() async throws {
        let session = StubSession()
        let (f, made) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        _ = try #require(await waitForTask(session))
        f.invalidate()
        #expect(session.invalidated)
        await #expect(throws: CancellationError.self) { try await fetch.value }
        let again = Task { try await f.fetch(url, job: job("s2"), allowsCellular: false) { _, _ in } }
        // Review M1: the identifier isn't reused until the old session has become invalid.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(made.value == 1, "waits for the old session to go")
        f.sessionBecameInvalid(session)
        let task = try #require(await waitForTask(session, count: 2))
        #expect(made.value == 2, "made again, lazily")
        complete(f, task, [1], response(200, original))
        _ = try await again.value
    }

    @Test func anErrorStatusFails() async throws {
        let session = StubSession()
        let (f, _) = makeFetcher(session)
        let fetch = Task { try await f.fetch(url, job: job(), allowsCellular: false) { _, _ in } }
        let task = try #require(await waitForTask(session))
        complete(f, task, Array("{\"error\":1}".utf8), response(404))
        await #expect(throws: BackgroundAudioFetcher.FetchError.status(404)) { try await fetch.value }
    }

    @Test func backgroundSessionConfiguration() {
        #expect(BackgroundAudioFetcher.identifier == "com.bleak-rooster.magpie.downloads")
        let config = URLSessionConfiguration.background(withIdentifier: "com.bleak-rooster.magpie.tests-\(UUID())")
        #expect(config.sessionSendsLaunchEvents)
        #expect(FetchJob(id: "abc/../../x") == nil, "a description that isn't ours names nothing")
        #expect(FetchJob(id: job().id)?.key == job().key)
    }
}
