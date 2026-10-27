import Foundation
import Testing
@testable import MagpieCore

@Suite struct AtomicFileTests {
    struct Doc: Codable, Equatable { var name: String; var n: Int }

    @Test func writeReadReplace() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sub/doc.json")
        #expect(try AtomicFile.read(Doc.self, from: url) == nil)
        try AtomicFile.write(Doc(name: "a", n: 1), to: url)
        #expect(try AtomicFile.read(Doc.self, from: url) == Doc(name: "a", n: 1))
        try AtomicFile.write(Doc(name: "b", n: 2), to: url)
        #expect(try AtomicFile.read(Doc.self, from: url) == Doc(name: "b", n: 2))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        #expect(leftovers == ["doc.json"])
    }
}
