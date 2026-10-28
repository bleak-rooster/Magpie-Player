import Foundation
import NavidromeKit
import Testing
@testable import Magpie

// T3: each failed sign-in step gets its own plain explanation, and Local Network is blamed only when it is the
// cause (plan Review Focus 1: `homeserver` resolves only through Tailscale).
@Suite struct ConnectDiagnosisTests {
    let homebox = URL(string: "http://homeserver:4533")!
    func c(_ e: Error, _ u: URL, _ s: LocalNetworkState = .granted, denied d: Bool = false, device: Bool = true) -> ConnectDiagnosis {
        ConnectDiagnosis.classify(e, url: u, localNetwork: s, pathDenied: d, onDevice: device)
    }

    @Test func localhostOnDeviceOnly() {
        let url = URL(string: "http://localhost:4533")!
        #expect(c(URLError(.cannotConnectToHost), url) == .localhostOnDevice)
        #expect(c(URLError(.cannotConnectToHost), URL(string: "http://127.0.0.1:4533")!) == .localhostOnDevice)
        #expect(c(URLError(.cannotConnectToHost), url, device: false) == .unreachable("localhost:4533"))
        #expect(ConnectDiagnosis.localhostOnDevice.message == "localhost means this iPhone itself. Use your server's name or address, like http://homeserver:4533.")
    }

    @Test func eachStep() {
        #expect(c(URLError(.cannotFindHost), homebox) == .nameNotFound("homeserver"))
        #expect(c(URLError(.appTransportSecurityRequiresSecureConnection), homebox) == .atsBlocked)
        #expect(c(URLError(.timedOut), URL(string: "https://music.example.com")!) == .timedOut("music.example.com"))
        #expect(c(NavidromeError.badCredentials, homebox) == .loginFailed)
        #expect(c(URLError(.networkConnectionLost), URL(string: "https://music.example.com:8443")!) == .unreachable("music.example.com:8443"))
        #expect(c(URLError(.notConnectedToInternet), URL(string: "http://192.168.1.20:4533")!, denied: true) == .localNetworkDenied)
        #expect(c(URLError(.badServerResponse), homebox) == .other)
        #expect(ConnectDiagnosis.nameNotFound("homeserver").message == "This iPhone can't find homeserver; check the name, or use the server's address instead.")
        #expect(ConnectDiagnosis.localNetworkDenied.message == "Magpie needs local network access to reach your server. Turn it on in Settings › Privacy & Security › Local Network.")
    }

    @Test func diagnosisOrderForOwnersSetup() {                               // Review Focus 1
        #expect(c(URLError(.cannotFindHost), homebox, .denied) == .nameNotFound("homeserver"))
        #expect(c(URLError(.cannotFindHost), URL(string: "http://nas.local:4533")!, .denied) == .localNetworkDenied)
        #expect(c(URLError(.timedOut), URL(string: "http://192.168.1.20:4533")!, denied: true) == .localNetworkDenied)
        #expect(c(URLError(.timedOut), URL(string: "http://192.168.1.20:4533")!) == .timedOut("192.168.1.20:4533"))
        #expect(c(URLError(.timedOut), URL(string: "http://100.64.10.20:4533")!, .denied) == .timedOut("100.64.10.20:4533"))
    }

    /// The rest of the copy, and how Connect picks one failure: certificate and https-answer trouble first, then the
    /// first address whose step is known; Open Settings only for a Local Network denial.
    @Test func messagesAndChoice() {
        #expect(ConnectDiagnosis.timedOut("nas:4533").message == "nas:4533 didn't answer in time; check the server is on and reachable from this iPhone.")
        #expect(ConnectDiagnosis.atsBlocked.message == ConnectErrorCopy.needsHTTPS)
        #expect(ConnectDiagnosis.loginFailed.message == ConnectErrorCopy.badCredentials)
        #expect(ConnectDiagnosis.unreachable("nas").message == ConnectErrorCopy.unreachable("nas"))
        #expect(ConnectDiagnosis.other.message == ConnectErrorCopy.generic)

        var denied = ProbeFailure(url: URL(string: "http://192.168.1.20:4533")!, error: URLError(.timedOut))
        denied.localNetworkDenied = true
        let away = ProbeFailure(url: URL(string: "https://music.example.com")!, error: URLError(.badServerResponse))
        let both = SignInError.unreachable([denied, away])
        #expect(ConnectErrorCopy.message(for: both) == ConnectErrorCopy.httpsNotAnswering, "https answer still first")
        #expect(!ConnectErrorCopy.offersOpenSettings(for: both))
        let alone = SignInError.unreachable([ProbeFailure(url: homebox, error: URLError(.badServerResponse)), denied])
        #expect(ConnectErrorCopy.message(for: alone) == ConnectDiagnosis.localNetworkDenied.message, "first known step")
        #expect(ConnectErrorCopy.offersOpenSettings(for: alone))
        #expect(!ConnectErrorCopy.offersOpenSettings(for: NavidromeError.badCredentials))
    }
}
