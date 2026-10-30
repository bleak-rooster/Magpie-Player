import Foundation

/// A deterministic random source (SplitMix64) for seeded fuzz tests: the same seed gives the same cases on every run.
public struct SeededRNG: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// A seeded generative fuzzer for JSON bodies (crash hunt 4). It parses a seed document (a fixture), applies a few
/// structural mutations (fields missing, null or of the wrong type; hostile numbers and strings; huge or deep
/// containers; duplicated elements), and renders raw JSON text, so it can also write what `JSONSerialization` would
/// refuse to: out-of-range numbers (`1e400`), lone surrogate escapes, NUL. Some cases replace the whole body (HTML,
/// XML, empty, truncated JSON, random bytes).
public struct JSONFuzzer {
    /// A JSON tree whose scalars keep their raw text.
    public indirect enum Node {
        case raw(String)                        // null, true, false or a number, as written
        case string(String)                     // already escaped, without the quotes
        case array([Node])
        case object([(String, Node)])           // keys escaped, without the quotes; order kept, duplicates allowed
        /// `node` inside `depth` arrays (or `{"x":` objects). Kept flat, so a deep document costs no recursion here.
        case nested(depth: Int, objects: Bool, Node)
    }

    public var rng: SeededRNG
    /// Largest array a "huge array" mutation makes. Tests keep most cases small and run a few big ones.
    public var hugeArrayCount: Int
    /// Chance that a case replaces the whole body instead of mutating the tree.
    public var bodyChance: Double

    public init(seed: UInt64, hugeArrayCount: Int = 2_000, bodyChance: Double = 0.08) {
        rng = SeededRNG(seed: seed)
        self.hugeArrayCount = hugeArrayCount
        self.bodyChance = bodyChance
    }

    // MARK: - Hostile values

    public static let hostileNumbers = [
        "1e400", "-1e400", "1e300", "-1e300", "1e17", "-1e17", "1e-400", "-1", "0", "-0", "1.5", "-2.5",
        "9223372036854775807", "-9223372036854775808", "9223372036854775808", "18446744073709551616",
        "4294967296", "2147483648", "123456789012345678901234567890", "1.7976931348623157e308", "5e-324",
    ]

    /// Escaped JSON string contents (no quotes).
    public static let hostileStrings: [String] = [
        "", " ", "   \\t\\n  ", "\u{202E}evil\u{202C}", "مرحبا بالعالم", "עִבְרִית", String(repeating: "e\u{0301}", count: 300),
        "Z\u{0337}\u{0322}\u{031B}\u{0316}\u{0317}", "👩‍👩‍👧‍👦🇬🇧🏳️‍🌈", "\\u0000", "a\\u0000b", "\\ud800", "x\\udc00y", "\\ud83d\\ude00",
        "\\uFEFF", "\\uFFFF", String(repeating: "a", count: 20_000), "<script>alert(1)</script>", "../../../etc/passwd",
        "%00%2F", "1e400", "true", "null", "Rock & Pop; Jazz/Blues, Folk", "Drum & Bass", "١٢٣", "—–-", "(((((((",
        "[Live] (feat. x) - Remastered 2011", "lidarr:not-an-mbid", "00000000-0000-0000-0000-000000000000",
        "2026-13-45T25:61:61.9999999999Z", "0001-01-01T00:00:00Z", "9999-12-31T23:59:59.123456789+14:00",
        "....", "T", ".5", "2024-01-01T00:00:00.", "https://musicbrainz.org/recording/", "/", "//",
    ]

    static let bodies: [String] = [
        "", " ", "null", "true", "0", "\"\"", "[]", "{}", "[null]", "{\"a\":",
        "<html><head><title>Sign in</title></head><body>Captive portal</body></html>",
        "<?xml version=\"1.0\"?><subsonic-response status=\"ok\" version=\"1.16.1\"></subsonic-response>",
        "{\"subsonic-response\":{\"status\":\"failed\",\"version\":\"1.16.1\",\"error\":{\"code\":70,\"message\":\"not found\"}}}",
        "{\"subsonic-response\":{\"status\":\"failed\",\"version\":\"1.16.1\",\"error\":{\"code\":0}}}",
        "{\"subsonic-response\":{\"status\":\"failed\",\"error\":{\"code\":\"x\"}}}",
        "{\"subsonic-response\":{\"status\":\"ok\"}}", "{\"subsonic-response\":null}", "{\"subsonic-response\":[]}",
        "\u{FEFF}{}", "{\"error\":\"Unauthorized\"}", "Internal Server Error",
    ]

    // MARK: - Cases

    /// One mutated body made from `seed`.
    public mutating func mutate(_ seed: Data) -> Data {
        if rng.chance(bodyChance) { return wholeBody(seed) }
        guard var tree = Self.parse(seed) else { return wholeBody(seed) }
        for _ in 0..<Int.random(in: 1...4, using: &rng) { tree = mutateSomewhere(tree, depth: 0) }
        if Self.size(tree, cap: 4 * maxBytes) > 4 * maxBytes { return wholeBody(seed) }
        var text = Self.render(tree)
        if rng.chance(0.03) { text = String(text.prefix(Int.random(in: 0...max(0, text.count), using: &rng))) }
        return Data(text.utf8)
    }

    /// A body that replaces the document: HTML, XML, an error envelope, empty, truncated, random bytes.
    public mutating func wholeBody(_ seed: Data) -> Data {
        switch Int.random(in: 0..<4, using: &rng) {
        case 0: return seed.prefix(Int.random(in: 0...seed.count, using: &rng))
        case 1: return Data((0..<Int.random(in: 0...256, using: &rng)).map { _ in UInt8.random(in: 0...255, using: &rng) })
        default: return Data(Self.bodies.randomElement(using: &rng)!.utf8)
        }
    }

    // MARK: - Tree mutations

    private mutating func mutateSomewhere(_ node: Node, depth: Int) -> Node {
        // Descend most of the time while there is somewhere to go.
        switch node {
        case .array(let items) where !items.isEmpty && rng.chance(0.75):
            var items = items
            let i = Int.random(in: 0..<items.count, using: &rng)
            if rng.chance(0.12) { items.remove(at: i); return .array(items) }
            items[i] = mutateSomewhere(items[i], depth: depth + 1)
            return .array(items)
        case .object(let pairs) where !pairs.isEmpty && rng.chance(0.75):
            var pairs = pairs
            let i = Int.random(in: 0..<pairs.count, using: &rng)
            if rng.chance(0.15) { pairs.remove(at: i); return .object(pairs) }
            if rng.chance(0.05) { pairs.append(pairs[i]); return .object(pairs) }   // duplicate key
            pairs[i].1 = mutateSomewhere(pairs[i].1, depth: depth + 1)
            return .object(pairs)
        default:
            return replace(node)
        }
    }

    private mutating func replace(_ node: Node) -> Node {
        switch Int.random(in: 0..<11, using: &rng) {
        case 0: return .raw("null")
        case 1: return .raw(Self.hostileNumbers.randomElement(using: &rng)!)
        case 2: return .string(Self.hostileStrings.randomElement(using: &rng)!)
        case 3: return .raw(Bool.random(using: &rng) ? "true" : "false")
        case 4: return rng.chance(0.5) ? .array([]) : .object([])
        case 5: return .array([node])                                       // one level deeper
        case 6: return .object([("value", node)])
        case 7:                                                              // huge array of copies
            let source: Node
            if case .array(let items) = node, let first = items.first { source = first } else { source = node }
            let wanted = rng.chance(0.1) ? hugeArrayCount : Int.random(in: 2...200, using: &rng)
            // Copies of an already big node would make bodies of gigabytes: at most `maxBytes` in all.
            let count = max(2, min(wanted, maxBytes / max(1, Self.size(source, cap: maxBytes))))
            return .array(Array(repeating: source, count: count))
        case 8:                                                              // deep nesting
            return .nested(depth: Int.random(in: 50...5_000, using: &rng), objects: rng.chance(0.5), node)
        case 9:                                                              // duplicate elements (same ids)
            if case .array(let items) = node, !items.isEmpty {
                return .array(items + items + [items[0]])
            }
            return .raw(Self.hostileNumbers.randomElement(using: &rng)!)
        default:
            return .string(String(repeating: "x", count: Int.random(in: 0...64, using: &rng)))
        }
    }

    // MARK: - Parse and render

    /// About how many bytes one huge-array mutation may make (a case at most four times that).
    public var maxBytes = 4_000_000

    /// About how many bytes `node` renders to, counting no further than `cap`.
    static func size(_ node: Node, cap: Int) -> Int {
        switch node {
        case .raw(let s): return s.utf8.count
        case .string(let s): return s.utf8.count + 2
        case .nested(let depth, _, let inner): return depth * 6 + size(inner, cap: cap)
        case .array(let items):
            var total = 2
            for item in items where total < cap { total += size(item, cap: cap) + 1 }
            return total
        case .object(let pairs):
            var total = 2
            for pair in pairs where total < cap { total += pair.0.utf8.count + 4 + size(pair.1, cap: cap) }
            return total
        }
    }

    /// Nil when `data` isn't JSON.
    public static func parse(_ data: Data) -> Node? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return node(any)
    }

    static func node(_ any: Any) -> Node {
        switch any {
        case let d as [String: Any]: return .object(d.sorted { $0.key < $1.key }.map { (escape($0.key), node($0.value)) })
        case let a as [Any]: return .array(a.map(node))
        case let s as String: return .string(escape(s))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .raw(n.boolValue ? "true" : "false") }
            return .raw(n.stringValue)
        default: return .raw("null")
        }
    }

    public static func render(_ node: Node) -> String {
        var out = ""
        render(node, into: &out)
        return out
    }

    private static func render(_ node: Node, into out: inout String) {
        switch node {
        case .raw(let s): out += s
        case .string(let s): out += "\""; out += s; out += "\""
        case .array(let items):
            out += "["
            for (i, item) in items.enumerated() { if i > 0 { out += "," }; render(item, into: &out) }
            out += "]"
        case .nested(let depth, let objects, let inner):
            out += String(repeating: objects ? "{\"x\":" : "[", count: depth)
            render(inner, into: &out)
            out += String(repeating: objects ? "}" : "]", count: depth)
        case .object(let pairs):
            out += "{"
            for (i, pair) in pairs.enumerated() {
                if i > 0 { out += "," }
                out += "\""; out += pair.0; out += "\":"
                render(pair.1, into: &out)
            }
            out += "}"
        }
    }

    static func escape(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where u.value < 0x20: out += String(format: "\\u%04x", u.value)
            default: out.unicodeScalars.append(u)
            }
        }
        return out
    }
}

/// Wall-clock timing for fuzz tests. A sum over thousands of cases measures the machine, not the algorithm, and
/// failed whenever other suites ran alongside (merged crash-hunt review, I1). So quadratic blow-ups are caught per case
/// (`caseBound`) and by how time grows with size (`growth`); a whole sweep's bound is only a hang backstop.
public enum FuzzClock {
    /// No single case over this many seconds: ~0.1 s idle, a quadratic blow-up takes many seconds.
    public static let caseBound = 3.0
    /// A whole sweep or a large input: generous, so a loaded machine never trips it, but a hang still fails.
    public static let sweepBackstop = 90.0

    /// How much longer the work takes at `factor` × `n` than at `n`: about `factor` when linear, `factor`² when
    /// quadratic. `timed` does the work at a size and returns the seconds it took, so setup stays out of the clock.
    /// Each size is measured `repeats` times, interleaved, and the fastest kept, so load slows both sizes alike and a
    /// passing hiccup doesn't count.
    public static func growth(n: Int, factor: Int = 4, repeats: Int = 3, _ timed: (Int) throws -> Double) rethrows -> Double {
        var small = Double.infinity, large = Double.infinity
        for _ in 0..<repeats {
            small = min(small, try timed(n))
            large = min(large, try timed(n * factor))
        }
        return large / max(small, 1e-6)
    }

    public static func growth(n: Int, factor: Int = 4, repeats: Int = 3, _ timed: (Int) async throws -> Double) async rethrows -> Double {
        var small = Double.infinity, large = Double.infinity
        for _ in 0..<repeats {
            small = min(small, try await timed(n))
            large = min(large, try await timed(n * factor))
        }
        return large / max(small, 1e-6)
    }

    /// The most `growth` may be and still count as linear (or n log n): twice `factor`, half of quadratic's `factor`².
    public static func linearBound(factor: Int = 4) -> Double { Double(factor * 2) }

    /// Seconds `body` takes.
    public static func seconds(_ body: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    public static func seconds(_ body: () async throws -> Void) async rethrows -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        try await body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }
}
