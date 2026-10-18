import Foundation

/// What Ensemble does when a check finds a new version. The owner asked for one decision at most: an automatic
/// update never asks, a press of "Update to x.y.z" never asks again, and any other find asks once with Install / Later.
public enum UpdateOffer: Equatable, Sendable {
    /// Download, install and relaunch with no further question (still only while idle).
    case install
    /// Show the one alert: "Ensemble x.y.z is available. Install now?"
    case ask
    /// Say nothing; the update button still shows the version.
    case quiet

    /// - installRequested: the owner pressed "Update to x.y.z" or Install, so the find is the go-ahead.
    /// - userInitiated: the owner pressed "Check for Updates".
    /// - automatic: "Update automatically" is on.
    /// - declined: versions the owner answered Later to since launch; a background find of one stays quiet.
    public static func decide(version: String, installRequested: Bool, userInitiated: Bool, automatic: Bool,
                              declined: Set<String>) -> UpdateOffer {
        if installRequested { return .install }
        if userInitiated { return .ask }
        if automatic { return .install }
        return declined.contains(version) ? .quiet : .ask
    }
}

/// What a press of the one update button starts. A button that already says "Update to x.y.z" is the go-ahead
/// itself: the install starts and nothing is asked, whatever state Sparkle's previous session is in.
public enum UpdatePress: Equatable, Sendable {
    /// Download, install and relaunch the known version with no alert.
    case install(version: String)
    /// No version is known yet: check, and ask once if one is found.
    case check

    public static func decide(availableVersion: String?) -> UpdatePress {
        availableVersion.map { .install(version: $0) } ?? .check
    }
}

/// The version Ensemble was installing when it quit for an update, kept on disk so the copy that opens next can
/// say "Updated to x.y.z" and log the relaunch.
public struct PendingUpdate: Equatable, Sendable {
    public var version: String
    /// Set once the opened copy has handed itself to the login agent, so a second hand-over can never loop.
    public var handedOver: Bool

    public init(version: String, handedOver: Bool = false) {
        self.version = version
        self.handedOver = handedOver
    }
}

/// What the copy that opens after an update does first.
public enum UpdateRelaunch: Equatable, Sendable {
    case nothing
    /// The update is in: show "Updated to x.y.z" and forget the record.
    case announce(String)
    /// The update did not land (the running version is not the one being installed): log it, forget the record.
    case notInstalled(String)
    /// With open at login on, quit and let launchd start its own copy, so crash restarts keep working after an update.
    case handOverToLoginAgent

    /// - installedVersion: this copy's CFBundleShortVersionString.
    /// - loginAgentOn: the agent file points at this copy.
    /// - startedByLoginAgent: this process is launchd's job (Sparkle's relaunch opens the app outside the job).
    public static func decide(pending: PendingUpdate?, installedVersion: String, loginAgentOn: Bool,
                              startedByLoginAgent: Bool) -> UpdateRelaunch {
        guard let pending else { return .nothing }
        guard pending.version == installedVersion else { return .notInstalled(pending.version) }
        if loginAgentOn, !startedByLoginAgent, !pending.handedOver { return .handOverToLoginAgent }
        return .announce(pending.version)
    }
}

/// Tracks how long Ensemble has been idle (not dictating, sending, calibrating or in the tour), so an install never
/// starts in the middle of something.
public struct IdleGate: Sendable {
    public private(set) var idleSince: Date?

    public init() {}

    public mutating func observe(busy: Bool, at now: Date) {
        if busy { idleSince = nil } else if idleSince == nil { idleSince = now }
    }

    /// Idle without a break for at least `seconds`; 0 means idle right now.
    public func idle(for seconds: TimeInterval, at now: Date) -> Bool {
        guard let idleSince else { return false }
        return now.timeIntervalSince(idleSince) >= seconds
    }
}

extension UpdatePolicy {
    /// An automatic install waits for this much unbroken idle time, so it does not land between two dictations.
    public static let automaticIdleSeconds: TimeInterval = 30

    /// The update question waits until no key has been typed for this long, so it never comes up under a sentence
    /// being typed into Claude and takes the keys meant for it.
    public static let offerTypingQuiet: TimeInterval = 3

    /// Whether the update question may come up now: Ensemble idle and the keyboard at rest. Clicks do not count, so
    /// pressing Check for Updates still shows it.
    public static func offerMayShow(idle: Bool, secondsSinceKey: TimeInterval) -> Bool {
        idle && !(secondsSinceKey < offerTypingQuiet)
    }

    /// Whether the menu bar icon carries the upgrade arrow: a newer version has been found and not yet installed. An
    /// installed update relaunches the app, which starts with no version known.
    public static func showsUpgradeBadge(available: String?) -> Bool {
        !(available ?? "").isEmpty
    }

    /// The one alert's question.
    public static func offerMessage(version: String) -> String { "Ensemble \(version) is available. Install now?" }

    /// Where "What's new" points: the feed's own notes or info link, or else the release page the download comes
    /// from (a GitHub download URL `.../releases/download/<tag>/<file>` maps to `.../releases/tag/<tag>`). Every
    /// address comes from the signed feed; Ensemble itself never fetches it, the browser does when the owner clicks.
    public static func releaseNotesLink(fullNotes: URL?, notes: URL?, info: URL?, download: URL?) -> URL? {
        if let link = fullNotes ?? notes ?? info { return link }
        guard let download, var parts = URLComponents(url: download, resolvingAgainstBaseURL: false) else { return nil }
        let path = parts.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let i = path.firstIndex(of: "releases"), path.count > i + 2, path[i + 1] == "download" else { return nil }
        parts.path = "/" + (path[..<i] + ["releases", "tag", path[i + 2]]).joined(separator: "/")
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }
}
