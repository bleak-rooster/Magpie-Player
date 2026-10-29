import Foundation
import MagpieCore
import Playback
import Testing

/// iOS only: the file protection class lets the car play downloads while the phone is locked (spec §6, §11).
@Suite struct AudioStoreAppTests {
    @Test func fileProtectionLetsTheCarPlayWhileLocked() async throws {
        let store = AudioStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString), scope: "abc")
        await store.load()
        let temp = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(count: 100).write(to: temp)
        let e = try await store.add(temp, metadata: AudioMetadata(Song(id: "s1", title: "T", artist: "A", album: "B", duration: 200)),
                                    quality: .original, kind: .download, reason: .song, fileExtension: "mp3", downloadsLimit: nil)
        let values = try store.directory.appending(path: e.fileName).resourceValues(forKeys: [.fileProtectionKey])
        #expect(values.fileProtection == .completeUntilFirstUserAuthentication)
    }
}
