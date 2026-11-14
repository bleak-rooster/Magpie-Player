import Foundation
import LidarrKit

/// Round 27 R (owner, 2026-11-14): "a setting to automatically trigger this search every day or week when you open the
/// app (ie it should save when it last triggered it and if opened again after the set wait period, it should send the
/// trigger again)" (D291). Pure: whether the missing-album search is due, and what the saved time becomes after each
/// kind of answer. The app saves the time before it asks (so two activations can't both send) and puts the previous
/// one back when the gate refused before sending. "Already running" and a lost answer count as asked. Only when Magpie
/// becomes active, online, with Lidarr connected and "Allow Magpie to change your library" on; never in a background
/// request pass. The gate's own ten-minute record and command read stay the last word (`MissingAlbumSearch.swift`).
public enum MissingAlbumSchedule {
    /// "Search automatically": Off (the default), Every day, Every week. Per Lidarr.
    public enum Every: String, CaseIterable, Sendable, Identifiable {
        case off, day, week
        public var id: String { rawValue }

        /// How long after the last ask the next is due, on the phone's clock; nil when off.
        public var interval: TimeInterval? {
            switch self {
            case .off: nil
            case .day: 24 * 3_600
            case .week: 7 * 24 * 3_600
            }
        }
    }

    /// What is asking: Magpie becoming active (launch included), or a background request pass (never sends).
    public enum Trigger: Sendable, Equatable { case becameActive, backgroundPass }

    public struct Situation: Sendable, Equatable {
        public var trigger: Trigger
        public var online: Bool
        public var lidarrConnected: Bool
        /// "Allow Magpie to change your library" (G1).
        public var changesAllowed: Bool

        public init(trigger: Trigger, online: Bool, lidarrConnected: Bool, changesAllowed: Bool) {
            self.trigger = trigger; self.online = online; self.lidarrConnected = lidarrConnected
            self.changesAllowed = changesAllowed
        }
    }

    /// How an ask ended, for the saved time and the words under the button.
    public enum Answer: Sendable, Equatable {
        /// Lidarr took it.
        case sent
        /// One is queued or running in Lidarr.
        case alreadyRunning
        /// Refused before anything was sent (switch off, Lidarr unreadable, change log), or Lidarr turned it down.
        case refused
        /// Sent, but no answer came back: Lidarr may be looking already.
        case lostAnswer
        /// Fix round 1 L6: this gate sent one less than ten minutes ago (its own words; counts as asked).
        case tooSoon
    }

    static let everyKeyPrefix = "magpie.lidarr.missingSearchEvery"
    static let askedKeyPrefix = "magpie.lidarr.missingSearchAsked"

    /// The choice for one Lidarr (`LidarrClient.instanceScope`).
    public static func everyKey(scope: String) -> String { "\(everyKeyPrefix).\(scope)" }
    /// When Magpie last asked that Lidarr (by hand or on schedule), shown as "Last asked".
    public static func askedKey(scope: String) -> String { "\(askedKeyPrefix).\(scope)" }
    static let scheduleFromKeyPrefix = "magpie.lidarr.missingSearchFrom"
    /// Fix round 2 N4: when the schedule was chosen; its first wait starts then. Used only for "due", never shown.
    public static func scheduleFromKey(scope: String) -> String { "\(scheduleFromKeyPrefix).\(scope)" }

    /// Due when the chosen day or week has passed since the later of the last ask and when the schedule was chosen.
    public static func isDue(every: Every, lastAsked: Date?, scheduleFrom: Date? = nil, now: Date,
                             situation: Situation) -> Bool {
        guard situation.trigger == .becameActive, situation.online, situation.lidarrConnected, situation.changesAllowed,
              let interval = every.interval else { return false }
        guard let since = [lastAsked, scheduleFrom].compactMap({ $0 }).max() else { return true }
        return now >= since && now.timeIntervalSince(since) >= interval
    }

    /// A saved time ahead of the phone's clock (the clock was put back) counts as now, so the wait starts again from
    /// now rather than from a day that hasn't come.
    public static func lastAskedClamped(_ lastAsked: Date?, now: Date) -> Date? {
        lastAsked.map { min($0, now) }
    }

    /// What the gate's answer means. Its refusals all come before anything is sent; Lidarr's own 4xx (and a wrong key)
    /// is a refusal too. A 5xx or no answer at all may have started one.
    public static func answer(for error: Error?) -> Answer {
        guard let error else { return .sent }
        switch error {
        case WriteGateError.forbidden(let why) where why == MissingAlbumSearch.alreadyRunning:
            return .alreadyRunning
        case WriteGateError.forbidden(let why) where why == MissingAlbumSearch.tooSoon:
            return .tooSoon
        case is WriteGateError:
            return .refused
        case LidarrError.unauthorized:
            return .refused
        case LidarrError.http(let status) where status < 500:
            return .refused
        default:
            return .lostAnswer
        }
    }

    /// The saved time after an ask that began at `askedAt` (saved then): kept unless it was refused before sending,
    /// when `previous` goes back.
    public static func lastAsked(after answer: Answer, previous: Date?, askedAt: Date) -> Date? {
        answer == .refused ? previous : askedAt
    }

    /// The two per-Lidarr keys, in the app's gate defaults.
    public final class Store: @unchecked Sendable {
        private let defaults: UserDefaults
        private let scope: String

        public init(defaults: UserDefaults, scope: String) {
            self.defaults = defaults; self.scope = scope
        }

        public var every: Every {
            get { defaults.string(forKey: MissingAlbumSchedule.everyKey(scope: scope)).flatMap(Every.init) ?? .off }
            set { defaults.set(newValue.rawValue, forKey: MissingAlbumSchedule.everyKey(scope: scope)) }
        }

        public var lastAsked: Date? {
            get { defaults.object(forKey: MissingAlbumSchedule.askedKey(scope: scope)) as? Date }
            set {
                if let newValue { defaults.set(newValue, forKey: MissingAlbumSchedule.askedKey(scope: scope)) }
                else { defaults.removeObject(forKey: MissingAlbumSchedule.askedKey(scope: scope)) }
            }
        }

        /// Fix round 2 N4: when the schedule was chosen.
        public var scheduleFrom: Date? {
            get { defaults.object(forKey: MissingAlbumSchedule.scheduleFromKey(scope: scope)) as? Date }
            set {
                if let newValue { defaults.set(newValue, forKey: MissingAlbumSchedule.scheduleFromKey(scope: scope)) }
                else { defaults.removeObject(forKey: MissingAlbumSchedule.scheduleFromKey(scope: scope)) }
            }
        }

        /// Disconnect and sign-out (with the other Lidarr keys).
        public func forget() {
            defaults.removeObject(forKey: MissingAlbumSchedule.everyKey(scope: scope))
            defaults.removeObject(forKey: MissingAlbumSchedule.askedKey(scope: scope))
            defaults.removeObject(forKey: MissingAlbumSchedule.scheduleFromKey(scope: scope))
        }
    }
}
