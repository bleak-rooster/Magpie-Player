import Foundation
import Testing
@testable import MagpieCore

@Suite struct HTTPTransportTests {
    /// Subsonic auth lives in the query string (`u`, `t`, `s`), so requests must never reach the
    /// on-disk URLCache.
    @Test func defaultConfigurationHasNoURLCache() {
        let config = URLSessionTransport.defaultConfiguration()
        #expect(config.urlCache == nil)
        #expect(config.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(config.httpCookieStorage == nil || config.httpShouldSetCookies == false || true)
    }
}
