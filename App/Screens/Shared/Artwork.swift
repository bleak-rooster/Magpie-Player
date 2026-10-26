import MagpieCore
import SwiftUI
import UIKit

/// Cover art loaded from the server and cached in memory only, keyed by server/account, cover id
/// and size. Cleared on sign-in and sign-out.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    /// Bumped by `removeAll()` so a fetch started for the previous account isn't cached.
    private var generation = 0

    /// Cover-art URLs carry Subsonic auth (`u`, `t`, `s`): ephemeral, and no URLCache, so they are
    /// never written to disk. The NSCache above is the only cache.
    nonisolated static let sessionConfiguration: URLSessionConfiguration = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return config
    }()
    nonisolated static let transport: HTTPTransport =
        URLSessionTransport(timeout: 20, session: SameOriginRedirects.session(configuration: sessionConfiguration))

    init() { cache.countLimit = 400 }

    static func key(scope: String, coverArtId: String, size: Int) -> String { "\(scope)|\(coverArtId)@\(size)" }

    func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func store(_ image: UIImage, for key: String) { cache.setObject(image, forKey: key as NSString) }

    func removeAll() {
        cache.removeAllObjects()
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        generation += 1
    }

    func image(key: String, url: URL) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }
        let started = generation
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await Self.transport.send(URLRequest(url: url)),
                  response.statusCode == 200 else { return nil }
            return await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() }.value
        }
        inFlight[key] = task
        let image = await task.value
        guard generation == started else { return nil }   // signed out/in meanwhile
        inFlight[key] = nil
        if let image { store(image, for: key) }
        return image
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
        content(image.map { Image(uiImage: $0) })
            .task(id: "\(scope)|\(coverArtId ?? "")@\(pixelSize)") {
                guard let coverArtId, !scope.isEmpty else { image = nil; return }
                let key = ArtworkCache.key(scope: scope, coverArtId: coverArtId, size: pixelSize)
                if let hit = ArtworkCache.shared.cached(key) { image = hit; return }
                guard let url = model.coverArtURL(coverArtId, size: pixelSize) else { return }
                image = await ArtworkCache.shared.image(key: key, url: url)
            }
    }
}
