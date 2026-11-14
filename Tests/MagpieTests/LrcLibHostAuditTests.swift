import Foundation
import MagpieCore
import Testing
@testable import Magpie

/// Round 27 L (owner, 2026-11-14, Q1 yes; D311): LRCLIB is the one new outside host, named in one file. A static read
/// of the source tree (as `scripts/check-writes.sh` does, which also pins the request's shape): the host appears in
/// product code only in `MagpieCore/LrcLib.swift`, once, as its https `GET /api/get` URL; Deezer and Apple stay refused
/// (plan decision 11, `RefusedMediaHosts` unchanged).
@Suite struct LrcLibHostAuditTests {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let lrclibFile = "Packages/MagpieKit/Sources/MagpieCore/LrcLib.swift"

    /// Every Swift file of product code (the app and the package's sources), relative to the repo.
    static func productFiles() -> [String] {
        var found: [String] = []
        for top in ["App", "Packages/MagpieKit/Sources"] {
            let base = root.appending(path: top)
            guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where url.pathExtension == "swift" {
                found.append(String(url.path.dropFirst(root.path.count + 1)))
            }
        }
        return found
    }

    @Test func hostNamedOnlyInLrcLibFile() throws {
        let files = Self.productFiles()
        #expect(files.count > 100, "the source tree was found")
        var naming: [String] = []
        for file in files {
            let text = try String(contentsOf: Self.root.appending(path: file), encoding: .utf8).lowercased()
            if text.range(of: #"lrclib\.(net|org|com|io|app|dev)"#, options: .regularExpression) != nil { naming.append(file) }
        }
        #expect(naming == [Self.lrclibFile])
        let lines = try String(contentsOf: Self.root.appending(path: Self.lrclibFile), encoding: .utf8)
            .split(separator: "\n").filter { $0.lowercased().contains("lrclib.n") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(lines == [#"    public static let getURL = URL(string: "https://lrclib.net/api/get")!"#])
        #expect(LrcLib.getURL.scheme == "https" && LrcLib.getURL.host() == "lrclib.net" && LrcLib.getURL.path == "/api/get")
    }

    @Test func refusedHostsUnchanged() {
        #expect(RefusedMediaHosts.domains == ["deezer.com", "dzcdn.net", "mzstatic.com", "apple.com"])
        #expect(!RefusedMediaHosts.refuses(host: "lrclib.net"))
        #expect(RefusedMediaHosts.refuses(host: "api.deezer.com"))
    }

    /// The app's ATS stays as it was: LRCLIB is https, so it needs no exception, and none was added for it.
    @Test func noATSExceptionForLyrics() throws {
        let plist = try String(contentsOf: Self.root.appending(path: "App/Info.plist"), encoding: .utf8).lowercased()
        #expect(!plist.contains("lrclib"))
    }
}
