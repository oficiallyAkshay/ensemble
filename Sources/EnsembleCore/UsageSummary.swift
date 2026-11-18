#if canImport(CryptoKit)
import CryptoKit
#endif
import Foundation

/// The anonymous daily usage report: what is counted, the fixed list of property names it may carry, the checksum and
/// the exact JSON that is sent. The list of names is public in docs/telemetry.md; this file is where it is enforced.
public enum UsagePolicy {
    /// Whether usage sharing starts on for an install that has not chosen. The one place to change the default.
    public static let sharingDefault = true
    public static let eventName = "daily_summary"
    public static let schemaVersion = 1
    /// How often the app looks for a summary to send, and how long a summary that could not be sent is kept.
    public static let checkInterval: TimeInterval = 3600
    public static let keepDays = 7
}

/// A property value: a number or a short word, never free text.
public enum UsageValue: Equatable, Sendable, Encodable {
    case int(Int)
    case text(String)
    case flag(Bool)

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .int(let n): try container.encode(n)
        case .text(let s): try container.encode(s)
        case .flag(let b): try container.encode(b)
        }
    }

    /// The text the checksum reads, so the analysis job can rebuild it from the JSON.
    var checksumText: String {
        switch self {
        case .int(let n): return String(n)
        case .text(let s): return s
        case .flag(let b): return b ? "true" : "false"
        }
    }
}

/// One local day's counts. Only counts and the camera format live here.
public struct UsageDay: Codable, Equatable, Sendable {
    /// Local calendar day, "2026-10-18".
    public var day: String
    public var launches = 0
    public var activeSeconds = 0
    public var cameraWidth = 0
    public var cameraHeight = 0
    public var cameraFPS = 0
    public var gesturesAttempted: [String: Int] = [:]
    public var gesturesSucceeded: [String: Int] = [:]
    public var focusMoves = 0
    public var sendsRefused: [String: Int] = [:]
    public var safetyStops: [String: Int] = [:]

    public init(day: String) { self.day = day }

    mutating func apply(_ event: UsageEvent) {
        switch event {
        case .launch: launches += 1
        case .gestureAttempted(let g): gesturesAttempted[g.rawValue, default: 0] += 1
        case .gestureSucceeded(let g): gesturesSucceeded[g.rawValue, default: 0] += 1
        case .sendRefused(let r): sendsRefused[r.rawValue, default: 0] += 1
        case .safetyStop(let s): safetyStops[s.rawValue, default: 0] += 1
        case .focusMoved: focusMoves += 1
        case .cameraFormat(let w, let h, let fps): cameraWidth = w; cameraHeight = h; cameraFPS = fps
        }
    }
}

/// Which names may be sent, and what their values may look like.
public enum UsageAllowlist {
    static let fixed: Set<String> = [
        "app_version", "macos_version", "schema_version", "launches", "active_minutes", "focus_moves",
        "camera_width", "camera_height", "camera_fps", "chk", "$process_person_profile", "$geoip_disable",
    ]

    /// Every name a summary can carry: the fixed ones, and one count for each gesture, send refusal and safety stop.
    public static var names: Set<String> {
        var all = fixed
        for g in UsageGesture.allCases { all.insert("gesture_\(g.rawValue)_attempted"); all.insert("gesture_\(g.rawValue)_succeeded") }
        for r in SendRefusal.allCases { all.insert("sends_refused_\(r.rawValue)") }
        for s in SafetyStop.allCases { all.insert("safety_stops_\(s.rawValue)") }
        return all
    }

    /// Words only: letters, digits, dot, dash, underscore, at most 32 of them. A version like "1.4.2" or "26.0.1" fits;
    /// a name, a path, a title or a sentence does not.
    static func isShortWord(_ s: String) -> Bool {
        (1...32).contains(s.count) && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-_".contains($0)) }
    }

    /// The first property that is not on the list or whose value is not a number or a short word, nil when all pass.
    public static func violation(in properties: [String: UsageValue]) -> String? {
        let allowed = names
        for (name, value) in properties.sorted(by: { $0.key < $1.key }) {
            if !allowed.contains(name) { return name }
            switch value {
            case .int(let n) where !(0...10_000_000).contains(n): return name
            case .text(let s) where !isShortWord(s): return name
            default: break
            }
        }
        return nil
    }
}

#if canImport(CryptoKit)
public enum UsageChecksum {
    /// Public on purpose. The checksum only stops a casual copy-paste of an event into the project; anyone who reads
    /// this file can forge it (docs/telemetry.md).
    static let salt = "ensemble-usage-1"

    /// First 8 hex digits of SHA-256 over the salt and the sorted `name=value` lines of every property that is not
    /// `chk` and does not start with `$`.
    public static func value(for properties: [String: UsageValue]) -> String {
        let lines = properties.filter { $0.key != "chk" && !$0.key.hasPrefix("$") }
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.checksumText)" }
        let digest = SHA256.hash(data: Data(([salt] + lines).joined(separator: "\n").utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }
}

public enum UsageSummary {
    public struct Violation: Error, Equatable { public let property: String }

    /// The properties for one day. Counts that are zero are left out (absent means zero); the camera format is left
    /// out until a camera has run.
    public static func properties(for day: UsageDay, appVersion: String, macOSVersion: String) -> [String: UsageValue] {
        var p: [String: UsageValue] = [
            "app_version": .text(appVersion),
            "macos_version": .text(macOSVersion),
            "schema_version": .int(UsagePolicy.schemaVersion),
            "launches": .int(day.launches),
            "active_minutes": .int(day.activeSeconds / 60),
            "$process_person_profile": .flag(false),
            "$geoip_disable": .flag(true),
        ]
        func put(_ name: String, _ n: Int) { if n > 0 { p[name] = .int(n) } }
        put("focus_moves", day.focusMoves)
        put("camera_width", day.cameraWidth)
        put("camera_height", day.cameraHeight)
        put("camera_fps", day.cameraFPS)
        for (g, n) in day.gesturesAttempted { put("gesture_\(g)_attempted", n) }
        for (g, n) in day.gesturesSucceeded { put("gesture_\(g)_succeeded", n) }
        for (r, n) in day.sendsRefused { put("sends_refused_\(r)", n) }
        for (s, n) in day.safetyStops { put("safety_stops_\(s)", n) }
        p["chk"] = .text(UsageChecksum.value(for: p))
        return p
    }

    /// The request body, byte for byte. The sender and "Show what would be sent" both come here, so the display cannot
    /// drift from what goes out. Throws, and so sends nothing, when a property is not on the allowlist.
    public static func body(properties: [String: UsageValue], day: String, distinctID: String, writeKey: String) throws -> Data {
        if let name = UsageAllowlist.violation(in: properties) { throw Violation(property: name) }
        struct Body: Encodable {
            let api_key: String
            let event: String
            let distinct_id: String
            let timestamp: String
            let properties: [String: UsageValue]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(Body(api_key: writeKey, event: UsagePolicy.eventName, distinct_id: distinctID,
                                       timestamp: timestamp(ofDay: day), properties: properties))
    }

    /// Noon UTC on the day's date, so the event lands on that calendar date in any time zone.
    static func timestamp(ofDay day: String) -> String { day + "T12:00:00Z" }
}
#endif
