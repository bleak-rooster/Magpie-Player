import Foundation

/// How many upcoming entries `Player` hands the engine after the current one (QC). Only these get a stream URL and
/// a ReplayGain volume on each queue edit; the rest of the queue is resolved as it comes into the window.
public enum EngineWindow {
    public static let defaultSize = 3
    public static let maxSize = 10

    /// K: the engine's own enqueue depth or the pre-download count (Task 13), whichever is more; 1 to `maxSize`.
    public static func size(engineMax: Int = defaultSize, preDownload: Int = 0) -> Int {
        min(max(engineMax, preDownload, 1), maxSize)
    }
}
