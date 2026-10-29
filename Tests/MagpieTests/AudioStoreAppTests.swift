import AVFoundation
import Foundation
import MagpieCore
import Playback
import Testing

/// iOS only: the file protection class lets the car play downloads while the phone is locked (spec §6, §11).
@Suite struct AudioStoreAppTests {
    @Test func fileProtectionLetsTheCarPlayWhileLocked() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioStore(root: root, scope: "abc")
        await store.load()
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(count: 100).write(to: temp)
        let e = try await store.add(temp, metadata: AudioMetadata(Song(id: "s1", title: "T", artist: "A", album: "B", duration: 200)),
                                    quality: .original, kind: .download, reason: .song, fileExtension: "mp3", downloadsLimit: nil)
        let values = try store.directory.appending(path: e.fileName).resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection == .completeUntilFirstUserAuthentication)
    }

    /// D45: an Ogg Opus body is stored under `.ogg`, and AVFoundation opens the stored file.
    @Test func storedOggOpusIsPlayableFromTheLocalFile() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AudioStore(root: root, scope: "abc")
        await store.load()
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try OggOpusFixture.data.write(to: temp)
        #expect(OggOpusFixture.data.prefix(4) == Data("OggS".utf8))
        let ext = try #require(AudioStore.fileExtension(quality: .opus128, suffix: "flac", mimeType: "audio/ogg"))
        let e = try await store.add(temp, metadata: AudioMetadata(Song(id: "o1", title: "T", artist: "A", album: "B", duration: 2)),
                                    quality: .opus128, kind: .download, reason: .song, fileExtension: ext, downloadsLimit: nil)
        let stored = try #require(await store.localFiles()["o1"])
        #expect(stored.pathExtension == "ogg" && e.fileName == stored.lastPathComponent)
        let asset = AVURLAsset(url: stored)
        let (playable, duration) = try await asset.load(.isPlayable, .duration)
        #expect(playable)
        #expect(duration.seconds > 1 && duration.seconds < 3, "an Ogg length is an estimate, so only its range")
    }
}
