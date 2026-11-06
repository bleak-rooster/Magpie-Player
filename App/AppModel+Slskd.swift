import Foundation
import MagpieCore
import Requests
import SlskdKit

/// Round 23 (owner, 2026-11-07, D192): the optional slskd connection, Settings › Lidarr › Soulseek (slskd). Only used to
/// clear a removed artist's leftover downloads (the clean slate, D193); everything else works without it. Like Lidarr's:
/// the address and API key in the Keychain, plain http to a public address only with the owner's consent, and its write
/// switch ("Allow Magpie to change Soulseek") off until the owner turns it on, per slskd (a new address or key starts off).
extension AppModel {
    /// The connected slskd's client and gate for the runner, if any. Nil while its address is plain http to a public
    /// host without consent (so the key is never sent there).
    var slskdAccess: RequestRunner.SlskdAccess? {
        guard let slskd, plainHTTPConsent.allows(slskd.base) else { return nil }
        let client = SlskdClient(base: slskd.base, apiKey: slskd.apiKey, transport: transport)
        return RequestRunner.SlskdAccess(client: client, gate: SlskdWriteGate(client: client, defaultsSuite: gateDefaultsSuite))
    }

    /// The saved connection and its switch, read at launch (and again once the Keychain is readable).
    func readSlskdConnection() {
        slskd = slskdStore.load()
        slskdChangesAllowed = slskdScope.map { gateDefaults.bool(forKey: SlskdWriteGate.enabledKey(scope: $0)) } ?? false
    }

    private var slskdScope: String? {
        slskd.map { SlskdClient(base: $0.base, apiKey: $0.apiKey, transport: transport).instanceScope }
    }

    /// Test and Connect: reads slskd's downloads with the key (nothing is changed), then saves the connection to the
    /// Keychain with its switch off. Throws `SlskdError.unauthorized` for a wrong key, or the URL error.
    func connectSlskd(base: URL, apiKey: String) async throws {
        if atsBlocks(base) { throw Self.atsError(base) }
        guard plainHTTPConsent.allows(base) else { throw PlainHTTPConsentRequired(urls: [base]) }
        let connection = SlskdConnection(base: base, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        let client = SlskdClient(base: connection.base, apiKey: connection.apiKey, transport: transport)
        _ = try await client.downloads()
        try slskdStore.save(connection)
        if let scope = slskdScope { gateDefaults.removeObject(forKey: SlskdWriteGate.enabledKey(scope: scope)) }   // the one replaced
        slskd = connection
        gateDefaults.removeObject(forKey: SlskdWriteGate.enabledKey(scope: client.instanceScope))
        slskdChangesAllowed = false
        handSlskdToRunner()
    }

    /// Forgets the address, key and switch on this iPhone. Nothing in slskd changes.
    func disconnectSlskd() {
        if let scope = slskdScope { gateDefaults.removeObject(forKey: SlskdWriteGate.enabledKey(scope: scope)) }
        slskdStore.clear()
        slskd = nil
        slskdChangesAllowed = false
        handSlskdToRunner()
    }

    /// "Allow Magpie to change Soulseek".
    func setSlskdChangesAllowed(_ on: Bool) {
        guard let scope = slskdScope else { return }
        gateDefaults.set(on, forKey: SlskdWriteGate.enabledKey(scope: scope))
        slskdChangesAllowed = on
    }

    private func handSlskdToRunner() {
        guard let runner else { return }
        let access = slskdAccess
        Task { await runner.useSlskd(access) }
    }
}

/// The words of Settings › Lidarr › Soulseek (slskd). Named only here (the copy rule: a settings screen naming the
/// connection it sets up).
enum SlskdCopy {
    static let title = "Soulseek (slskd)"
    static let rowSummaryOff = "Not set up"
    static let rowSummaryOn = "Connected"
    static let intro = "Optional. When Magpie lets go of an artist it brought in, it can also clear that artist's leftover downloads from slskd, so trying it again starts fresh. Everything else works without it."
    static let addressFooter = "The API key is in slskd's settings (web › authentication › api_keys). Use an https:// address for anything outside your home: plain http:// sends the key unencrypted."
    static let allowChanges = "Allow Magpie to change Soulseek"
    static let allowFooter = "When on, Magpie removes only finished downloads of an artist it brought in and then let go, inside slskd's downloads folder. Anything still downloading, and anything else, stays. slskd must allow remote file management for files to be removed."
    static let badKey = "That API key didn't work. Copy it again from slskd's settings."
    static let notSlskd = "That address answered, but it doesn't look like slskd."
    static let plainHTTPMessage = "Your slskd API key will be sent in the clear. Use an https:// address when you can."
    static let disconnectFooter = "Forgets the address and key on this iPhone. Nothing in slskd changes."

    static func message(for error: Error, url: URL) -> String {
        switch error {
        case SlskdError.unauthorized: return badKey
        case SlskdError.decoding, SlskdError.http, SlskdError.forbidden: return notSlskd
        case _ where ConnectErrorCopy.isPlainHTTPAnswer(error, url: url): return ConnectErrorCopy.httpsNotAnswering
        case let e as URLError where e.code == .appTransportSecurityRequiresSecureConnection: return ConnectErrorCopy.needsHTTPS
        default:
            return "Couldn't reach slskd at \(ConnectErrorCopy.hostAndPort(url) ?? url.absoluteString). Check the address and that slskd is running."
        }
    }
}
