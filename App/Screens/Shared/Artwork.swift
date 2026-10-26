import SwiftUI
import UIKit

/// Cover art loaded from the server and cached in memory by cover id and size.
@MainActor
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]

    init() { cache.countLimit = 400 }

    func cached(_ key: String) -> UIImage? { cache.object(forKey: key as NSString) }

    func image(key: String, url: URL) async -> UIImage? {
        if let hit = cached(key) { return hit }
        if let task = inFlight[key] { return await task.value }
        let task = Task<UIImage?, Never> {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            return await Task.detached(priority: .utility) { UIImage(data: data)?.preparingForDisplay() }.value
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image { cache.setObject(image, forKey: key as NSString) }
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
        content(image.map { Image(uiImage: $0) })
            .task(id: "\(coverArtId ?? "")@\(pixelSize)") {
                guard let coverArtId else { image = nil; return }
                let key = "\(coverArtId)@\(pixelSize)"
                if let hit = ArtworkCache.shared.cached(key) { image = hit; return }
                guard let url = model.coverArtURL(coverArtId, size: pixelSize) else { return }
                image = await ArtworkCache.shared.image(key: key, url: url)
            }
    }
}
