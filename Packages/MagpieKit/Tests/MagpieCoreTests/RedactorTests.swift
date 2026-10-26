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
}
