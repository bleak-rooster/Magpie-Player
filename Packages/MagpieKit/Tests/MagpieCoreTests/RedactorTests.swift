import Foundation
import Testing
@testable import MagpieCore

@Suite struct RedactorTests {
    @Test func redactsSubsonicAuth() {
        let url = URL(string: "https://h/navidrome/rest/ping?u=sam&t=abc&s=xyz&p=pw&apiKey=k&v=1.16.1&c=Magpie")!
        let out = Redactor.sanitize(url)
        #expect(out.contains("u=•••"))
        #expect(out.contains("t=•••"))
        #expect(out.contains("s=•••"))
        #expect(out.contains("p=•••"))
        #expect(out.contains("apiKey=•••"))
        #expect(out.contains("v=1.16.1"))
        #expect(out.contains("c=Magpie"))
        for secret in ["sam", "abc", "xyz", "pw", "=k&"] { #expect(!out.contains(secret)) }
        #expect(out.hasPrefix("https://h/navidrome/rest/ping?"))
    }

    @Test func redactsTokenAndPassword() {
        let out = Redactor.sanitize(URL(string: "https://h/x?token=T&password=P&id=7")!)
        #expect(out == "https://h/x?token=•••&password=•••&id=7")
    }

    @Test func redactsHeaders() {
        let out = Redactor.sanitize(headers: [
            "X-Api-Key": "k", "X-ND-Authorization": "Bearer abc", "Authorization": "Basic zzz",
            "Accept": "application/json",
        ])
        #expect(out["X-Api-Key"] == "•••")
        #expect(out["X-ND-Authorization"] == "•••")
        #expect(out["Authorization"] == "•••")
        #expect(out["Accept"] == "application/json")
    }

    @Test func redactsHeadersCaseInsensitively() {
        #expect(Redactor.sanitize(headers: ["authorization": "x"])["authorization"] == "•••")
    }

    /// Security M5: a logged error never carries its failing URL (credentials included).
    @Test func errorCategoryNeverIncludesTheURL() {
        let secret = "https://user:pw@music.example/rest/ping?u=sam&t=tok&s=salt"
        let error = URLError(.timedOut, userInfo: [NSURLErrorFailingURLStringErrorKey: secret,
                                                   NSURLErrorFailingURLErrorKey: URL(string: secret)!])
        #expect(String(describing: error).contains("tok"), "precondition: the default description leaks")
        let text = Log.category(of: error)
        #expect(text == "URLError \(URLError.Code.timedOut.rawValue)")
        let ns = NSError(domain: "X", code: 7, userInfo: [NSURLErrorFailingURLStringErrorKey: secret])
        #expect(Log.category(of: ns) == "X 7")
    }

    /// Security M5 lint: no source logs `String(describing:)` or `localizedDescription` publicly (either can
    /// carry a URL with credentials). Use `Log.category(of:)`.
    @Test func noPublicErrorDescriptionsInLogs() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent()   // Tests/MagpieCoreTests
            .deletingLastPathComponent().deletingLastPathComponent()      // Packages/MagpieKit
        let dirs = [root.appending(path: "Sources"),
                    root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "App")]
        var offenders: [String] = []
        var scanned = 0
        for dir in dirs {
            let files = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?
                .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
            for file in files {
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                for (n, line) in lines.enumerated() where line.contains("privacy: .public")
                    && (line.contains("String(describing:") || line.contains("localizedDescription")) {
                    offenders.append("\(file.lastPathComponent):\(n + 1)")
                }
            }
        }
        #expect(scanned > 20)
        #expect(offenders.isEmpty, "public error text in logs: \(offenders)")
    }
}
