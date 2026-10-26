import Foundation
import NavidromeKit

/// What the Connect screen says when signing in fails. Plain words; the fix, not the fault.
enum ConnectErrorCopy {
    static let badCredentials = "That username or password didn't work."
    static let noAddress = "Add the address of your music server."
    static let generic = "Something went wrong talking to your music server. Try again in a moment."
    /// Something answered, but not Navidrome's API (a reverse proxy's sign-in page, a captive portal).
    static let notAMusicServer = "That address answered, but it doesn't look like a music server. If a sign-in page sits in front of it, use an address that reaches the server directly."

    /// B3: a certificate this device doesn't trust. v1 has no in-app override (AVPlayer would ignore it).
    static let untrustedCertificate = """
        Your server's certificate isn't trusted by this device yet. Install the certificate authority \
        that signed it (in the simulator: xcrun simctl keychain booted add-root-cert ca.pem), then try again.
        """

    /// Security M5: `user:password@host` typed into an address.
    static let credentialsInAddress = "Leave your username and password out of the address. Enter them in the fields below."

    /// Security H2: asked before the password goes over plain http to an address outside the home network.
    static let plainHTTPTitle = "This address isn't encrypted."
    static let plainHTTPMessage = "Your password will be sent in the clear. Use an https:// address when you can."
    static let plainHTTPConfirm = "Send Anyway"

    /// Connect's advice under the addresses.
    static let httpsAdvice = "Use an https:// address for anything outside your home. Plain http:// sends your password unencrypted."

    /// B2: plain HTTP outside the home network in a Release build.
    static let needsHTTPS = "Use HTTPS for addresses outside your home network."

    /// B4: a home-network address that didn't answer.
    static func localNetworkHint(_ host: String) -> String {
        """
        Couldn't reach \(host) on your home network. If it opens in a browser, check that Local Network \
        access is on for Magpie in Settings › Privacy & Security › Local Network (for the simulator: \
        on the Mac, for Xcode and Simulator).
        """
    }

    static func unreachable(_ host: String) -> String {
        "Couldn't reach \(host). Check the address and that the server is running."
    }

    static func invalidAddress(_ text: String) -> String {
        "\u{201C}\(text)\u{201D} doesn't look like a web address."
    }

    static func message(for error: Error) -> String {
        switch error {
        case SignInError.noAddress:
            return noAddress
        case SignInError.invalidAddress(let text):
            return invalidAddress(text)
        case SignInError.unreachable(let failures):
            return unreachableMessage(failures)
        case NavidromeError.badCredentials:
            return badCredentials
        case NavidromeError.noReachableServer:
            return unreachable("your music server")
        case NavidromeError.unexpectedResponse:
            return notAMusicServer
        case let urlError as URLError:
            return message(for: urlError, url: urlError.failingURL)
        default:
            return generic
        }
    }

    /// The most useful single message across all addresses: certificate trouble first (it never
    /// fixes itself), then HTTPS, then a home-network hint, then plain "couldn't reach".
    private static func unreachableMessage(_ failures: [ProbeFailure]) -> String {
        guard let first = failures.first else { return unreachable("your music server") }
        if failures.contains(where: { isCertificateError($0.error) }) { return untrustedCertificate }
        if failures.contains(where: { ($0.error as? URLError)?.code == .appTransportSecurityRequiresSecureConnection }) {
            return needsHTTPS
        }
        if let local = failures.first(where: { isTimeout($0.error) && ServerAddress.isLocalNetwork($0.url) }) {
            return localNetworkHint(local.url.host ?? local.url.absoluteString)
        }
        if failures.contains(where: { ($0.error as? NavidromeError) == .unexpectedResponse }) { return notAMusicServer }
        if case NavidromeError.http = first.error {
            return "\(first.url.host ?? "That address") answered, but it doesn't look like a music server."
        }
        return unreachable(first.url.host ?? first.url.absoluteString)
    }

    private static func message(for error: URLError, url: URL?) -> String {
        if isCertificateError(error) { return untrustedCertificate }
        if error.code == .appTransportSecurityRequiresSecureConnection { return needsHTTPS }
        if let url, isTimeout(error), ServerAddress.isLocalNetwork(url) { return localNetworkHint(url.host ?? "") }
        return unreachable(url?.host ?? "your music server")
    }

    static func isCertificateError(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.serverCertificateUntrusted, .serverCertificateHasUnknownRoot, .serverCertificateHasBadDate,
                .serverCertificateNotYetValid, .clientCertificateRejected, .clientCertificateRequired].contains(e.code)
    }

    private static func isTimeout(_ error: Error) -> Bool {
        guard let e = error as? URLError else { return false }
        return [.timedOut, .cannotConnectToHost].contains(e.code)
    }
}
