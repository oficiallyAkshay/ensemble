import CryptoKit
import Foundation
import Testing
@testable import EnsembleCore

@Suite struct UsageSummaryTests {
    /// A day with every kind of count set, so each property name that can exist does.
    static func fullDay() -> UsageDay {
        var d = UsageDay(day: "2026-10-18")
        d.launches = 2; d.activeSeconds = 3_700; d.focusMoves = 9
        for e in [UsageEvent.cameraFormat(width: 640, height: 480, fps: 30)] { d.apply(e) }
        for g in UsageGesture.allCases { d.apply(.gestureAttempted(g)); d.apply(.gestureSucceeded(g)) }
        for r in SendRefusal.allCases { d.apply(.sendRefused(r)) }
        for s in SafetyStop.allCases { d.apply(.safetyStop(s)) }
        return d
    }

    static func properties(_ day: UsageDay = fullDay()) -> [String: UsageValue] {
        UsageSummary.properties(for: day, appVersion: "1.4.2", macOSVersion: "26.0")
    }

    @Test func summaryHasTheFixedFieldsAndNoZeroCounts() {
        let p = Self.properties(UsageDay(day: "2026-10-18"))
        #expect(p["app_version"] == .text("1.4.2"))
        #expect(p["macos_version"] == .text("26.0"))
        #expect(p["schema_version"] == .int(1))
        #expect(p["launches"] == .int(0))
        #expect(p["active_minutes"] == .int(0))
        #expect(p["$process_person_profile"] == .flag(false))
        #expect(p["$geoip_disable"] == .flag(true))
        #expect(p["camera_width"] == nil)
        #expect(p["gesture_pinch_attempted"] == nil)
        #expect(p["chk"] != nil)
    }

    @Test func countsBecomeProperties() {
        let p = Self.properties()
        #expect(p["launches"] == .int(2))
        #expect(p["active_minutes"] == .int(61))
        #expect(p["focus_moves"] == .int(9))
        #expect(p["camera_width"] == .int(640))
        #expect(p["camera_height"] == .int(480))
        #expect(p["camera_fps"] == .int(30))
        #expect(p["gesture_thumbs_up_attempted"] == .int(1))
        #expect(p["gesture_scissors_succeeded"] == .int(1))
        #expect(p["sends_refused_not_in_front"] == .int(1))
        #expect(p["safety_stops_dead_man"] == .int(1))
    }

    @Test func everyPropertyThatCanExistIsAllowed() {
        let p = Self.properties()
        #expect(Set(p.keys) == UsageAllowlist.names)
        #expect(UsageAllowlist.violation(in: p) == nil)
    }

    @Test func unknownPropertiesAreRejected() throws {
        var p = Self.properties()
        p["window_title"] = .int(1)
        #expect(UsageAllowlist.violation(in: p) == "window_title")
        #expect(throws: UsageSummary.Violation(property: "window_title")) {
            try UsageSummary.body(properties: p, day: "2026-10-18", distinctID: "id", writeKey: "k")
        }
    }

    @Test func valuesMustBeNumbersOrShortWords() {
        for bad: UsageValue in [.text("a sentence with spaces"), .text("/Users/someone"), .text(""), .text(String(repeating: "a", count: 33)),
                                .text("caf\u{e9}"), .int(-1), .int(10_000_001)] {
            var p = Self.properties()
            p["app_version"] = bad
            #expect(UsageAllowlist.violation(in: p) == "app_version")
        }
    }

    @Test func noPropertyNameCanCarryPersonalData() {
        for name in UsageAllowlist.names {
            for word in ["name", "email", "path", "title", "host", "user", "text", "transcript", "image", "ip"] {
                // "ip" would also match "pinch" etc., so it is compared as a whole word below.
                if word != "ip" { #expect(!name.contains(word), "\(name) contains \(word)") }
            }
            #expect(!name.split(separator: "_").contains("ip"))
        }
    }

    // MARK: Checksum

    @Test func checksumIsTheDocumentedHash() {
        let p: [String: UsageValue] = ["b": .text("x"), "a": .int(1), "$geoip_disable": .flag(true), "chk": .text("ignored")]
        let digest = SHA256.hash(data: Data("ensemble-usage-1\na=1\nb=x".utf8))
        let expected = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        #expect(UsageChecksum.value(for: p) == expected)
        #expect(expected.count == 8)
    }

    @Test func checksumSeesEveryValue() {
        let p = Self.properties()
        var changed = p
        changed["launches"] = .int(3)
        #expect(UsageChecksum.value(for: changed) != p["chk"].map { v -> String in if case .text(let s) = v { return s } else { return "" } })
        #expect(UsageChecksum.value(for: p) == { if case .text(let s)? = p["chk"] { return s } else { return "" } }())
        #expect(UsageValue.flag(false).checksumText == "false")
    }

    // MARK: JSON

    @Test func bodyHasTheCaptureShape() throws {
        let day = Self.fullDay()
        let data = try UsageSummary.body(properties: Self.properties(day), day: day.day, distinctID: "11111111-2222-3333-4444-555555555555",
                                         writeKey: "phc_test")
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["api_key", "event", "distinct_id", "timestamp", "properties"])
        #expect(json["api_key"] as? String == "phc_test")
        #expect(json["event"] as? String == "daily_summary")
        #expect(json["distinct_id"] as? String == "11111111-2222-3333-4444-555555555555")
        #expect(json["timestamp"] as? String == "2026-10-18T12:00:00Z")
        let properties = try #require(json["properties"] as? [String: Any])
        #expect(properties["schema_version"] as? Int == 1)
        #expect(properties["$process_person_profile"] as? Bool == false)
        #expect(properties["$geoip_disable"] as? Bool == true)
        #expect(properties["app_version"] as? String == "1.4.2")
        #expect(properties["chk"] as? String == UsageChecksum.value(for: Self.properties(day)))
    }

    @Test func bodyCarriesNothingPersonal() throws {
        let day = Self.fullDay()
        let data = try UsageSummary.body(properties: Self.properties(day), day: day.day, distinctID: UUID().uuidString, writeKey: "phc_test")
        let text = String(decoding: data, as: UTF8.self)
        for personal in [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, NSHomeDirectory(), "/Users/", "@"] where !personal.isEmpty {
            #expect(!text.contains(personal), "the body contains \(personal)")
        }
    }
}
