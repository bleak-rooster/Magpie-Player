import MagpieCore
import SwiftUI
import UIKit

/// Cover art loaded from the server and cached in memory, keyed by server/account, cover id and size. Cleared on
/// sign-in and sign-out. The lasting copy is on disk (`ArtworkDiskCache`, P4); `AppModel.artworkImage` asks both.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<(image: UIImage?, data: Data?), Never>] = [:]
    /// Bumped by `removeAll()` so a fetch started for the previous account isn't cached (in memory or on disk).
    private(set) var generation = 0

    /// Cover-art URLs carry Subsonic auth (`u`, `t`, `s`): ephemeral, and no URLCache, so they are
    /// never written to disk. The images alone are kept: in the NSCache above and, by key, on disk (P4).
    nonisolated static let sessionConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }()
    nonisolated static let transport: HTTPTransport =
        URLSessionTransport(timeout: 20, session: SameOriginRedirects.session(configuration: sessionConfiguration))

    #if DEBUG
    /// Tests: artwork requests go here instead of the network (G0).
    var transportForTesting: HTTPTransport?
    #endif

    init() { cache.countLimit = 400 }

    static func key(scope: String, coverArtId: String, size: Int) -> String { "\(scope)|\(coverArtId)@\(size)" }

    func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    /// "Reload artwork": every size of one cover leaves memory.
    func remove(scope: String, coverArtId: String) {
        for size in ArtworkDiskCache.sizes { cache.removeObject(forKey: Self.key(scope: scope, coverArtId: coverArtId, size: size) as NSString) }
        ArtPaletteCache.shared.remove(coverArtId)   // R13: its colours are worked out again too
    }

    func removeAll() {
        cache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        generation += 1
        ArtPaletteCache.shared.removeAll()   // R13
    }

    /// Fetches the image; `fetched` gets the bytes of one that decoded, with the generation it was started in (the
    /// disk cache saves them), unless a sign-out or sign-in came in between.
    func image(key: String, url: URL, fetched: (@MainActor (_ data: Data, _ generation: Int) -> Void)? = nil) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value.image }
        let started = generation
        var transport = Self.transport
        #if DEBUG
        if let transportForTesting { transport = transportForTesting }
        #endif
        let task = Task<(image: UIImage?, data: Data?), Never> { [transport] in
            guard let (data, response) = try? await transport.send(URLRequest(url: url)),
                  response.statusCode == 200 else { return (nil, nil) }
            let image = await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() }.value
            return (image, image == nil ? nil : data)
        }
        inFlight[key] = task
        let result = await task.value
        guard generation == started else { return nil }   // signed out/in meanwhile
        inFlight[key] = nil
        if let image = result.image { store(image, for: key) }
        if let data = result.data { fetched?(data, started) }
        return result.image
    }
}

/// Hands `content` the cover image for `coverArtId` once it has loaded (nil until then).
struct Artwork<Content: View>: View {
    @Environment(AppModel.self) private var model
    @Environment(\.displayScale) private var scale
    let coverArtId: String?
    let side: CGFloat
    @ViewBuilder let content: (Image?) -> Content
    @State private var image: UIImage?

    init(_ coverArtId: String?, side: CGFloat, @ViewBuilder content: @escaping (Image?) -> Content) {
        self.coverArtId = coverArtId; self.side = side; self.content = content
    }

    /// Server-side sizes, so the cache stays small and hits often.
    private var pixelSize: Int {
        let px = Int(side * scale)
        return [120, 300, 600, 1000].first { $0 >= px } ?? 1000
    }

    var body: some View {
        let scope = model.artworkScope ?? ""
        // "Reload artwork" (P4) bumps the cover's version, which loads it again.
        let version = coverArtId.map { ArtworkReloads.shared.version($0) } ?? 0
        content(image.map { Image(uiImage: $0) })
            .task(id: "\(scope)|\(coverArtId ?? "")@\(pixelSize)#\(version)") {
                guard let coverArtId, !scope.isEmpty else { image = nil; return }
                image = await model.artworkImage(coverArtId, size: pixelSize)
            }
    }
}
