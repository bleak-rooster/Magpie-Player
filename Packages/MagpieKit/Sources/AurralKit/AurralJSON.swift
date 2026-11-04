import Foundation
import MagpieCore

// Aurral's answers, read leniently: every field optional, a bad element dropped, never a crash on a newer or older
// shape. Measured before parsing (JSONNesting), like every other client. Round 14 A1 moved these here from
// AurralModels.swift so the 2.13 models share them.

func object(_ data: Data) -> Any? { JSONNesting.object(with: data) }

/// Longest list Magpie keeps from any one Aurral answer (Aurral itself caps playlists at 2,000 songs).
let aurralListCap = 2_000
/// Longest text Magpie keeps from any one Aurral field.
let aurralTextCap = 2_000

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { (self[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    func int(_ key: String) -> Int? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let d = n.doubleValue
            return d.isFinite && abs(d) < 1e12 ? Int(d) : nil
        }
        return nil
    }
    func bool(_ key: String) -> Bool? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue }
        return nil
    }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func mbid(_ key: String) -> MBID? { string(key).flatMap(MBID.init) }

    /// Round 14: text, trimmed and capped; nil when empty.
    func text(_ key: String) -> String? {
        guard let s = string(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s.count > aurralTextCap ? String(s.prefix(aurralTextCap)) : s
    }
    /// A string or a number as text (ids Aurral sends either way).
    func idText(_ key: String) -> String? {
        if let s = text(key) { return s.count <= 100 ? s : nil }
        return int(key).map(String.init)
    }
    /// A list of strings (anything else in it dropped), capped.
    func strings(_ key: String, cap: Int = 100) -> [String] {
        (self[key] as? [Any] ?? []).lazy.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.prefix(cap).map { $0.count > aurralTextCap ? String($0.prefix(aurralTextCap)) : $0 }
    }
    /// A list of objects (anything else dropped), capped.
    func objects(_ key: String, cap: Int = aurralListCap) -> [[String: Any]] {
        Array((self[key] as? [Any] ?? []).lazy.compactMap { $0 as? [String: Any] }.prefix(cap))
    }
    /// A date as milliseconds since 1970 or ISO 8601 text.
    func date(_ key: String) -> Date? {
        if let n = self[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() {
            let ms = n.doubleValue
            return ms.isFinite && ms > 0 && ms < 1e15 ? Date(timeIntervalSince1970: ms / 1000) : nil
        }
        guard let text = string(key) else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
