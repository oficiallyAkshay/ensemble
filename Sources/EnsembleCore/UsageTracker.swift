import Foundation

/// The counters for the current day and the finished days still waiting to be sent. Pure: the tracker owns the clock
/// and the storage.
public struct UsageLedger: Codable, Equatable, Sendable {
    public private(set) var today: UsageDay?
    public private(set) var finished: [UsageDay] = []
    public private(set) var lastSent: String?

    public init() {}

    /// A new day closes the one before it. A day with no launch and no active time is not worth a report.
    mutating func roll(to day: String) {
        guard let current = today, current.day != day else {
            if today == nil { today = UsageDay(day: day) }
            return
        }
        if current.launches > 0 || current.activeSeconds > 0 { finished.append(current) }
        today = UsageDay(day: day)
    }

    mutating func record(_ event: UsageEvent, day: String) {
        roll(to: day)
        today?.apply(event)
    }

    /// Adds seconds of active time. True when it crossed a whole minute, the point where the tracker saves.
    mutating func addActive(seconds: Int, day: String) -> Bool {
        roll(to: day)
        let before = today?.activeSeconds ?? 0
        today?.activeSeconds = before + seconds
        return (before + seconds) / 60 > before / 60
    }

    /// Finished days that are still unsent and not older than `UsagePolicy.keepDays`; older ones are dropped.
    mutating func due(on day: String) -> [UsageDay] {
        roll(to: day)
        finished.removeAll { Self.age(of: $0.day, on: day) > UsagePolicy.keepDays || $0.day <= (lastSent ?? "") }
        return finished
    }

    mutating func sent(_ day: String) {
        finished.removeAll { $0.day == day }
        lastSent = max(lastSent ?? day, day)
    }

    /// Whole days from `day` to `now`, both "yyyy-MM-dd".
    static func age(of day: String, on now: String) -> Int {
        let calendar = Calendar(identifier: .gregorian)
        func date(_ s: String) -> Date? {
            let parts = s.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            return calendar.date(from: DateComponents(timeZone: TimeZone(identifier: "UTC"), year: parts[0], month: parts[1], day: parts[2]))
        }
        guard let a = date(day), let b = date(now) else { return 0 }
        return calendar.dateComponents([.day], from: a, to: b).day ?? 0
    }
}

/// Counts what the app does and keeps one summary per local day until it has been sent. Everything is on the main
/// actor and nothing here touches the network. While sharing is off it records nothing and stores nothing: turning it
/// off deletes the counters and the install id.
@MainActor
public final class UsageTracker: UsageCounting {
    private enum Key {
        static let ledger = "usageLedger"
        static let installID = "usageInstallID"
    }

    public private(set) var sharing: Bool
    /// The first-run notice has been shown to this user. Nothing is sent until it has: on by default must not mean unseen.
    public private(set) var disclosed: Bool
    private let defaults: UserDefaults
    private let appVersion: String
    private let macOSVersion: String
    private let calendar: Calendar
    private let now: () -> Date
    private var ledger = UsageLedger()
    private var lastActive: Date?
    private var lastCheck: Date?

    public init(defaults: UserDefaults, sharing: Bool, disclosed: Bool = true, appVersion: String, macOSVersion: String,
                calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.sharing = sharing
        self.disclosed = disclosed
        self.appVersion = appVersion
        self.macOSVersion = macOSVersion
        self.calendar = calendar
        self.now = now
        if sharing, let data = defaults.data(forKey: Key.ledger), let saved = try? JSONDecoder().decode(UsageLedger.self, from: data) {
            ledger = saved
        } else if !sharing {
            erase()
        }
    }

    /// Off deletes everything this tracker stored; on starts from nothing.
    public func setSharing(_ on: Bool) {
        guard on != sharing else { return }
        sharing = on
        if !on { erase() }
    }

    public func setDisclosed(_ shown: Bool) { disclosed = shown }

    private func erase() {
        ledger = UsageLedger()
        lastActive = nil
        defaults.removeObject(forKey: Key.ledger)
        defaults.removeObject(forKey: Key.installID)
    }

    private var dayString: String {
        let c = calendar.dateComponents([.year, .month, .day], from: now())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(ledger) { defaults.set(data, forKey: Key.ledger) }
    }

    public func count(_ event: UsageEvent) {
        guard sharing else { return }
        ledger.record(event, day: dayString)
        save()
    }

    /// Called about once a second while the camera runs. A longer gap (sleep, a lock) adds nothing.
    public func activeTick() {
        guard sharing else { return }
        let at = now()
        guard let last = lastActive else { lastActive = at; return }
        let gap = at.timeIntervalSince(last)
        if (0..<0.5).contains(gap) { return }
        lastActive = at
        guard (0.5...5).contains(gap) else { return }
        if ledger.addActive(seconds: Int(gap.rounded()), day: dayString) { save() }
    }

    /// Writes the counters now (the quit path).
    public func flush() {
        if sharing { save() }
    }

    // MARK: Sending

    /// The finished days to send now, oldest first: nothing while sharing is off or before the notice has been shown, and
    /// nothing unless a check is due.
    /// A check is due at the first call, then once `UsagePolicy.checkInterval` has passed; `force` is for the day
    /// rolling over. A failed send is simply asked for again at the next due check.
    public func daysToSend(force: Bool = false) -> [UsageDay] {
        guard sharing, disclosed else { return [] }
        let at = now()
        if !force, let last = lastCheck, at.timeIntervalSince(last) >= 0, at.timeIntervalSince(last) < UsagePolicy.checkInterval { return [] }
        lastCheck = at
        let days = ledger.due(on: dayString)
        save()
        return days
    }

    public func markSent(_ day: String) {
        guard sharing else { return }
        ledger.sent(day)
        save()
    }

    /// The current day so far, for "Show what would be sent".
    public var todaySoFar: UsageDay {
        if let today = ledger.today, today.day == dayString { return today }
        return UsageDay(day: dayString)
    }

    /// The install id, made on first use. Only the sender asks for it, so an install that never sends has none.
    private func installID() -> String {
        if let id = defaults.string(forKey: Key.installID) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Key.installID)
        return id
    }

    /// A fresh random id; the old one is forgotten and nothing links the two.
    public func resetInstallID() {
        guard sharing else { return }
        defaults.set(UUID().uuidString, forKey: Key.installID)
    }

    /// The request body for `day`. The sender and the preview both come here. The preview passes `preview: true`: it
    /// shows a stand-in rather than make an id.
    public func requestBody(for day: UsageDay, writeKey: String, preview: Bool = false) throws -> Data {
        let properties = UsageSummary.properties(for: day, appVersion: appVersion, macOSVersion: macOSVersion)
        let id = preview ? (defaults.string(forKey: Key.installID) ?? "assigned-at-first-send") : installID()
        return try UsageSummary.body(properties: properties, day: day.day, distinctID: id, writeKey: writeKey)
    }
}
