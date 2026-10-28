import Foundation
import Observation

/// What iOS's Local Network setting (Settings › Privacy & Security › Local Network) means for Magpie, as far as the
/// app can tell (iOS has no API that reads it).
enum LocalNetworkState: String, Equatable, Sendable {
    /// Never answered, or not known yet.
    case unknown, granted, denied
    /// None of the addresses in question is on the local network. Returned, never persisted.
    case notNeeded
}

/// Asks the system about local network access. `NWBrowserLocalNetworkProber` on a device; fakes in tests.
@MainActor protocol LocalNetworkProbing: AnyObject {
    /// Triggers the system prompt if it hasn't been answered; returns .granted, .denied, or .unknown on timeout.
    func requestAccess() async -> LocalNetworkState
    /// A connection to host:port is held back by the Local Network setting right now (answers within 2 s).
    func isDenied(host: String, port: Int) async -> Bool
}

/// The hosted-test stand-in (and any context that must never meet the system prompt): nothing needs asking.
@MainActor final class NotNeededProber: LocalNetworkProbing {
    func requestAccess() async -> LocalNetworkState { .notNeeded }
    func isDenied(host: String, port: Int) async -> Bool { false }
}

/// T3 (spec §8, D38): the Local Network permission. Asked once at first launch, so Magpie is listed under
/// Settings › Privacy & Security › Local Network even when the first address it tries isn't on the LAN (the owner's
/// `homeserver` resolves only through Tailscale, so no LAN connection, and so no prompt, ever happened). The last
/// known answer is kept in the app's settings; it is not a secret.
@MainActor @Observable final class LocalNetworkAccess {
    static let stateKey = "magpie.localNetwork.state"
    static let askedAtLaunchKey = "magpie.localNetwork.askedAtLaunch"

    @ObservationIgnored private let prober: any LocalNetworkProbing
    @ObservationIgnored private let defaults: UserDefaults
    /// `granted` or `denied` once known, else `unknown`. Never `notNeeded`.
    private(set) var state: LocalNetworkState

    init(prober: any LocalNetworkProbing, defaults: UserDefaults) {
        self.prober = prober
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.stateKey).flatMap(LocalNetworkState.init(rawValue:))
        state = saved == .granted || saved == .denied ? saved! : .unknown
    }

    /// Once per install, whatever the first screen is: the prompt shows (iOS shows it once ever), and Magpie appears
    /// in Settings › Privacy & Security › Local Network from then on.
    func requestAtFirstLaunch() async {
        guard !defaults.bool(forKey: Self.askedAtLaunchKey) else { return }
        defaults.set(true, forKey: Self.askedAtLaunchKey)
        store(await prober.requestAccess())
    }

    /// "Allow local network access": always asks. After the first answer iOS doesn't prompt again; the answer then
    /// reflects the setting.
    @discardableResult
    func request() async -> LocalNetworkState {
        let answer = await prober.requestAccess()
        store(answer)
        return answer
    }

    /// Before signing in to `urls`: asks when it hasn't been answered; while denied, only the quick check runs
    /// (turned on in Settings since?), never the slow ask.
    func ensureAccess(for urls: [URL]) async -> LocalNetworkState {
        guard let first = urls.first(where: ServerAddress.needsLocalNetworkPermission) else { return .notNeeded }
        switch state {
        case .granted, .notNeeded:
            return .granted
        case .denied:
            // Fix M1: only an address whose reachability proves the setting (an IP literal or `.local`) turns it back on.
            let check = urls.first(where: ServerAddress.provesLocalNetworkAccess) ?? first
            if !(await checkDenied(for: check)), ServerAddress.provesLocalNetworkAccess(check) { store(.granted) }
            return state
        case .unknown:
            let answer = await prober.requestAccess()
            store(answer)
            return answer
        }
    }

    /// A request to a local-network address worked: the setting is on.
    func noteLocalSuccess() {
        guard state != .granted else { return }
        store(.granted)
    }

    /// The Local Network setting holds back a connection to `url` right now (its port, or 80/443 by scheme).
    func checkDenied(for url: URL) async -> Bool {
        guard let host = url.host(percentEncoded: false) else { return false }
        let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
        return await prober.isDenied(host: bare, port: port)
    }

    private func store(_ answer: LocalNetworkState) {
        guard answer == .granted || answer == .denied else { return }
        state = answer
        defaults.set(answer.rawValue, forKey: Self.stateKey)
    }
}
