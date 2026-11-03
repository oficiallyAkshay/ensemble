import Foundation

/// When Ensemble looks for a new version and what its one update button says. The trust rule holds here: with
/// automatic updates off nothing is checked until the owner presses the button.
public enum UpdatePolicy {
    /// Automatic updates check this often.
    public static let checkInterval: TimeInterval = 3600
    /// The first automatic check waits this long after launch, so it never competes with the camera starting.
    public static let launchDelay: TimeInterval = 15
    /// "Up to date" stays on the button this long after a check the owner started finds nothing.
    public static let upToDateSeconds: TimeInterval = 4

    /// Whether to check shortly after launch: only with updates set up in this build and turned on by the owner.
    public static func checksAtLaunch(configured: Bool, automatic: Bool) -> Bool { configured && automatic }

    /// Whole percent of a download received, nil until the size is known. Never above 100.
    public static func downloadPercent(received: UInt64, expected: UInt64) -> Int? {
        guard expected > 0 else { return nil }
        return Int(min(100, Double(received) / Double(expected) * 100))
    }

    /// What the one update button shows: its title and whether it spins. The spinner runs exactly while work runs
    /// (a check, a download, an install) and never while the install waits for an idle moment or nothing runs.
    /// Order: work in progress, then a failure, then the version on offer, a brief "Up to date", the plain check.
    public static func buttonState(available: String?, showingUpToDate: Bool, installing: String? = nil,
                                   waitingForIdle: Bool = false, checking: Bool = false, failed: Bool = false,
                                   downloading: Bool = false, downloadPercent: Int? = nil) -> UpdateButtonState {
        if let installing {
            // A download is harmless while Ensemble is busy, so it shows as work even though the install will wait.
            if downloading {
                let percent = downloadPercent.map { " (\($0)%)" } ?? ""
                return UpdateButtonState(title: "Downloading \(installing)\(percent)", spinning: true)
            }
            if waitingForIdle { return UpdateButtonState(title: "Installs \(installing) when you finish", spinning: false) }
            return UpdateButtonState(title: "Installing \(installing)...", spinning: true)
        }
        if checking { return UpdateButtonState(title: "Checking...", spinning: true) }
        if failed { return UpdateButtonState(title: "Update failed. Retry", spinning: false) }
        if let available { return UpdateButtonState(title: "Update to \(available)", spinning: false) }
        return UpdateButtonState(title: showingUpToDate ? "Up to date" : "Check for Updates", spinning: false)
    }
}

/// The update button's title and whether it shows a spinner.
public struct UpdateButtonState: Equatable {
    public let title: String
    public let spinning: Bool
}
