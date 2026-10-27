import Foundation
import Testing
@testable import MagpieCore

@Suite struct KeychainTests {
    @Test func roundTrip() throws {
        let store = KeychainStore(service: "com.bleak-rooster.magpie.tests.\(UUID().uuidString)")
        defer { try? store.remove("token") }
        #expect(try store.get("token") == nil)
        try store.set(Data("one".utf8), for: "token")
        #expect(try store.get("token") == Data("one".utf8))
        try store.set(Data("two".utf8), for: "token")
        #expect(try store.get("token") == Data("two".utf8))
        try store.remove("token")
        #expect(try store.get("token") == nil)
        try store.remove("token")  // removing a missing key is not an error
    }
}
