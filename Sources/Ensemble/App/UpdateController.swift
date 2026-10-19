import AppKit
import Sparkle
import SwiftUI
import EnsembleCore

/// Release-channel settings. The owner edits this file and Info.plist (SUPublicEDKey) once; see docs/RELEASING.md.
enum UpdateConfig {
    static let feedURL = "https://oficiallyakshay.github.io/ensemble/appcast.xml"

    /// Placeholder shipped in Info.plist until the owner generates a key with Sparkle's generate_keys.
    static let publicKeyPlaceholder = "TODO-REPLACE-WITH-SPARKLE-PUBLIC-ED-KEY"

    /// Sparkle refuses to start without a valid EdDSA public key, so a build without a real key and feed has updates off.
    static var isConfigured: Bool {
        guard let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              key != publicKeyPlaceholder, Data(base64Encoded: key)?.count == 32 else { return false }
        return !feedURL.contains("OWNER")
    }
}

/// Sparkle 2 with Ensemble's own user interface instead of Sparkle's windows (it is the `SPUUserDriver`). The owner
/// asked for at most one decision per update:
/// - No network until the user turns on automatic updates (Settings > General) or presses the update button.
/// - Automatic updates (opt-in) check 15 s after launch and then every hour (`UpdatePolicy`), download in the
///   background and install after 30 s of unbroken idle time, with no question.
/// - Otherwise a found version asks once, in a "What's new" window of three to five items from the feed (or the
///   plain "Ensemble x.y.z is available. Install now?" when the feed has none), with Install and Later. Check for
///   Updates and "Update to x.y.z" both open it. Install downloads, installs and relaunches with no further window.
/// - Nothing is shown and nothing installs while Ensemble is busy (dictating, sending, calibrating, the tour): the
///   alert waits and the button says "Installs x.y.z when you finish".
/// - The copy that opens after an update says "Updated to x.y.z" and logs it; with open at login on, it hands itself
///   to launchd so crash restarts keep working (`UpdateRelaunch`).
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate, SPUUserDriver {
    /// The newer version the last check found, from a check the user started or the automatic checks they turned on.
    @Published private(set) var availableVersion: String?
    /// True for a few seconds after a check the user started found nothing.
    @Published private(set) var showingUpToDate = false
    @Published private(set) var autoInstall = false
    /// The version being downloaded or installed, once the owner said Install (or automatic updates decided to).
    @Published private(set) var installingVersion: String?
    /// True while an install is waiting for Ensemble to be idle.
    @Published private(set) var waitingForIdle = false
    @Published private(set) var checking = false
    /// True while installing would interrupt the user (dictating, sending, calibrating, tour open); set by the app.
    var isBusy: () -> Bool = { false }
    /// A short island notice (title, body); set by the app.
    var notice: (String, String) -> Void = { _, _ in }

    /// A found version waiting for the one alert, held until Ensemble is idle.
    private var pendingOffer: (item: SUAppcastItem, stage: SPUUserUpdateStage, reply: (SPUUserUpdateChoice) -> Void)?
    /// Sparkle waiting for the go to install and relaunch.
    private var pendingInstallReply: ((SPUUserUpdateChoice) -> Void)?
    /// An update downloaded in the background by automatic updates, installed by calling this block.
    private var pendingAutoInstall: (() -> Void)?
    /// An error from a flow the owner started, shown once with Retry.
    private var pendingError: Error?
    /// The owner pressed Install or Retry: no idle grace period and no further question.
    private var installRequested = false
    private var userCheckInFlight = false
    private var alertShowing = false
    /// Versions answered Later since launch; a background find of one stays quiet until the next launch or a press.
    private var declined: Set<String> = []
    private var gate = IdleGate()
    private var tickTimer: Timer?
    private var upToDateTask: Task<Void, Never>?
    private var notesLink: URL?

    /// What the one update button says.
    var buttonTitle: String {
        UpdatePolicy.buttonTitle(available: availableVersion, showingUpToDate: showingUpToDate, installing: installingVersion,
                                 waitingForIdle: waitingForIdle, checking: checking)
    }

    /// The installed version, read from the bundle (no network): "Version 0.4.2 (42)".
    static var installedVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(short) (\(build))"
    }

    private var updater: SPUUpdater!
    let isConfigured = UpdateConfig.isConfigured

    override init() {
        super.init()
        updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: self, delegate: self)
        guard isConfigured else { return }
        do { try updater.start() } catch { EnsembleLog.write("update: Sparkle did not start (\(error.localizedDescription))") }
        autoInstall = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
        if autoInstall { updater.updateCheckInterval = UpdatePolicy.checkInterval }
        if UpdatePolicy.checksAtLaunch(configured: isConfigured, automatic: autoInstall) {
            // Sparkle's own schedule counts a full interval from the last check; this finds a new version soon after launch.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(UpdatePolicy.launchDelay * 1_000_000_000))
                guard let self, self.autoInstall else { return }
                self.updater.checkForUpdatesInBackground()
            }
        }
    }

    func setAutoInstall(_ on: Bool) {
        guard isConfigured else { return }
        updater.updateCheckInterval = UpdatePolicy.checkInterval
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
        autoInstall = on
        if on { updater.checkForUpdatesInBackground() }
    }

    /// The update button. Both "Check for Updates" and "Update to x.y.z" check and, if a version is found, show the
    /// one window; Install is the go-ahead. An Install while Ensemble is busy never installs at once: the install
    /// waits for the first idle moment and the button says so.
    func checkForUpdates() {
        guard isConfigured else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Updates are not set up in this build"
            alert.informativeText = "This build has no update feed. Download the latest Ensemble from the project's GitHub releases page."
            alert.runModal()
            return
        }
        guard installingVersion == nil else { return }
        declined.removeAll()
        if pendingOffer != nil {
            // A found version waiting for its window: the press brings it up now.
            tick()
            return
        }
        if pendingAutoInstall != nil, let version = availableVersion {
            EnsembleLog.write("update: install of downloaded \(version) requested by the user")
            installRequested = true
            installingVersion = version
            tick()
            return
        }
        installRequested = false
        checking = true
        userCheckInFlight = true
        EnsembleLog.write("update: check requested by the user")
        updater.checkForUpdates()
    }

    // MARK: The idle gate

    /// Runs every second while anything waits: shows the alert, gives Sparkle the go, or starts a background
    /// install, each only while Ensemble is idle.
    private func tick() {
        let now = Date()
        gate.observe(busy: isBusy(), at: now)
        let idleNow = gate.idle(for: 0, at: now)
        let installNeeds = installRequested ? 0 : UpdatePolicy.automaticIdleSeconds
        waitingForIdle = installingVersion != nil && !idleNow
        let waiting = pendingOffer != nil || pendingInstallReply != nil || pendingAutoInstall != nil || pendingError != nil
        if waiting, tickTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            tickTimer = timer
        } else if !waiting {
            tickTimer?.invalidate()
            tickTimer = nil
        }
        guard !alertShowing else { return }
        if let reply = pendingInstallReply, gate.idle(for: installNeeds, at: now) {
            pendingInstallReply = nil
            beginInstall()
            reply(.install)
        } else if let install = pendingAutoInstall, installingVersion != nil || autoInstall, gate.idle(for: installNeeds, at: now) {
            pendingAutoInstall = nil
            if installingVersion == nil { installingVersion = availableVersion }
            beginInstall()
            install()
        } else if pendingOffer != nil, UpdatePolicy.offerMayShow(idle: idleNow, secondsSinceKey: ClaudeBridge.secondsSinceOwnerKey()) {
            // Out of the timer's call: the alert runs a modal loop.
            alertShowing = true
            DispatchQueue.main.async { [weak self] in self?.showOffer() }
        } else if pendingError != nil, idleNow {
            alertShowing = true
            DispatchQueue.main.async { [weak self] in self?.showError() }
        }
    }

    /// Ensemble quits for the installer next; the copy that opens reads this record (`afterLaunch`).
    private func beginInstall() {
        guard let version = installingVersion else { return }
        waitingForIdle = false
        let defaults = UserDefaults.standard
        defaults.set(version, forKey: Self.pendingVersionKey)
        defaults.set(false, forKey: Self.handedOverKey)
        EnsembleLog.write("update: installing \(version); Ensemble quits and Sparkle opens the new version")
        notice("Installing Ensemble \(version)", "Ensemble opens again by itself in a moment.")
        Self.reopenIfRelaunchMissing()
    }

    /// The safety net under Sparkle's relaunch: once this copy has quit, a detached shell looks for a running
    /// Ensemble 30 and 60 seconds later and opens it if none is there (a copy started twice exits at launch, so a
    /// late open cannot make two). It gives up if this copy never quits, which means the install did not start.
    private static func reopenIfRelaunchMissing() {
        DetachedShell.run("""
        i=0; while kill -0 "$1" 2>/dev/null && [ "$i" -lt 600 ]; do sleep 0.5; i=$((i+1)); done
        kill -0 "$1" 2>/dev/null && exit 0
        for pause in 30 30; do sleep "$pause"; /usr/bin/pgrep -qx Ensemble && exit 0; reopen; done
        """)
    }

    /// - byOwner: the owner said Install or pressed the button; an automatic install keeps its idle grace period.
    private func accept(_ version: String, stage: SPUUserUpdateStage, byOwner: Bool = true,
                        reply: @escaping (SPUUserUpdateChoice) -> Void) {
        if byOwner { installRequested = true }
        installingVersion = version
        checking = false
        if stage == .notDownloaded {
            // Downloading is harmless while busy; Sparkle then asks `showReady(toInstallAndRelaunch:)`, which waits.
            reply(.install)
        } else {
            // Already downloaded or installing: Sparkle would quit Ensemble at once, so the go waits for idle.
            pendingInstallReply = reply
        }
        tick()
    }

    // MARK: Alerts

    private func showOffer() {
        defer { alertShowing = false; tick() }
        guard let offer = pendingOffer else { return }
        pendingOffer = nil
        let version = offer.item.displayVersionString
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.informativeText = "Ensemble downloads it, installs it and opens again by itself."
        // No button answers Return: a Return typed for Claude as the alert comes up must never install. Escape is Later.
        alert.addButton(withTitle: "Install").keyEquivalent = ""
        alert.addButton(withTitle: "Later").keyEquivalent = "\u{1b}"
        let item = offer.item
        notesLink = UpdatePolicy.releaseNotesLink(fullNotes: item.fullReleaseNotesURL, notes: item.releaseNotesURL,
                                                  info: item.infoURL, download: item.fileURL)
        // The summary comes from the feed already on disk, so the window needs no connection. A missing or malformed
        // one leaves the plain prompt.
        if let items = WhatsNew.parse(item.propertiesDictionary["whatsNew"] as? String) {
            alert.messageText = "What's new in Ensemble \(version)"
            let host = NSHostingView(rootView: WhatsNewView(items: items, notesLink: notesLink == nil ? nil : { [weak self] in self?.openReleaseNotes() }))
            host.frame.size = host.fittingSize
            alert.accessoryView = host
        } else {
            alert.messageText = UpdatePolicy.offerMessage(version: version)
            if notesLink != nil {
                let link = NSButton(title: "What's new in \(version)", target: self, action: #selector(openReleaseNotes))
                link.isBordered = false
                link.contentTintColor = .linkColor
                link.sizeToFit()
                alert.accessoryView = link
            }
        }
        alert.window.level = .floating
        if alert.runModal() == .alertFirstButtonReturn {
            EnsembleLog.write("update: Install pressed for \(version)")
            accept(version, stage: offer.stage, reply: offer.reply)
        } else {
            EnsembleLog.write("update: Later pressed for \(version)")
            declined.insert(version)
            offer.reply(.dismiss)
        }
    }

    @objc private func openReleaseNotes() {
        // The browser fetches the page; Ensemble itself never does.
        if let notesLink { NSWorkspace.shared.open(notesLink) }
    }

    private func showError() {
        defer { alertShowing = false; tick() }
        guard let error = pendingError else { return }
        pendingError = nil
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Ensemble could not update"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "Retry")
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        if alert.runModal() == .alertFirstButtonReturn { checkForUpdates() }
    }

    // MARK: State

    private func found(_ version: String) {
        upToDateTask?.cancel()
        showingUpToDate = false
        checking = false
        availableVersion = version
    }

    private func foundNothing() {
        availableVersion = nil
        checking = false
        installingVersion = nil
        installRequested = false
        guard userCheckInFlight else { return }
        userCheckInFlight = false
        showingUpToDate = true
        upToDateTask?.cancel()
        upToDateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdatePolicy.upToDateSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.showingUpToDate = false
        }
    }

    /// The update session ended without installing (Later, an error, or nothing found).
    private func endSession() {
        // The previous session (a background find answered Later or quiet) can end after a press started a new
        // check; its end must not cancel the press, or the find would ask "Install now?" a second time.
        if !userCheckInFlight {
            installingVersion = nil
            installRequested = false
        }
        waitingForIdle = false
        checking = false
        pendingInstallReply = nil
        tick()
    }

    // MARK: SPUUserDriver (all on the main thread)

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Never asked (`updaterShouldPromptForPermissionToCheck` is false); answer with the current setting.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: autoInstall, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {}

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let version = appcastItem.displayVersionString
        found(version)
        let userInitiated = state.userInitiated
        if userInitiated { userCheckInFlight = false }
        guard !appcastItem.isInformationOnlyUpdate else {
            EnsembleLog.write("update: \(version) is information only; nothing to install")
            availableVersion = nil
            installingVersion = nil
            reply(.dismiss)
            return
        }
        let offer = UpdateOffer.decide(version: version, installRequested: installRequested, userInitiated: userInitiated,
                                       automatic: autoInstall, declined: declined)
        EnsembleLog.write("update: found \(version) (\(userInitiated ? "user check" : "background check")), \(offer)")
        switch offer {
        case .install: accept(version, stage: state.stage, byOwner: installRequested || userInitiated, reply: reply)
        case .quiet: reply(.dismiss)
        case .ask:
            pendingOffer = (appcastItem, state.stage, reply)
            tick()
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        let ownersFlow = userCheckInFlight || installRequested
        EnsembleLog.write("update: error (\(error.localizedDescription))\(ownersFlow ? "" : ", background check, not shown")")
        userCheckInFlight = false
        endSession()
        guard ownersFlow else { return }
        pendingError = error
        tick()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {}

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}

    func showDownloadDidReceiveData(ofLength length: UInt64) {}

    func showDownloadDidStartExtractingUpdate() {}

    func showExtractionReceivedProgress(_ progress: Double) {}

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        pendingInstallReply = reply
        tick()
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        // Sparkle ends every session here; an install already handed to the installer quits Ensemble regardless.
        guard pendingOffer == nil else { return }
        endSession()
    }

    // MARK: SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? { UpdateConfig.feedURL }

    nonisolated func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        Task { @MainActor in self.foundNothing() }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        Task { @MainActor in self.userCheckInFlight = false; self.checking = false }
    }

    /// Automatic updates downloaded a version in the background: Ensemble installs it itself at the first idle
    /// moment (`tick`), never Sparkle on its own schedule.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        Task { @MainActor in
            self.found(version)
            EnsembleLog.write("update: \(version) downloaded in the background; installs at the first idle moment")
            self.pendingAutoInstall = immediateInstallationBlock
            self.tick()
        }
        return true
    }

    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        Task { @MainActor in EnsembleLog.write("update: Sparkle relaunching Ensemble") }
    }

    // MARK: After the relaunch

    private static let pendingVersionKey = "updateInstallingVersion"
    private static let handedOverKey = "updateHandedOverToLoginAgent"
    /// The version this copy was just updated to, for the "Updated to x.y.z" notice once the overlay is up.
    private(set) static var justUpdatedTo: String?

    /// Runs first thing at launch. Returns true when this copy must quit so launchd's own job starts Ensemble
    /// (open at login on, and this copy was opened by Sparkle outside the job): `Permissions.reopenAfterExit`
    /// waits for this process to end, then kickstarts the job, or opens the app if the job is not loaded.
    static func afterLaunch() -> Bool {
        let defaults = UserDefaults.standard
        let pending = defaults.string(forKey: pendingVersionKey).map {
            PendingUpdate(version: $0, handedOver: defaults.bool(forKey: handedOverKey))
        }
        let installed = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        let byAgent = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == LoginAgent.label
        switch UpdateRelaunch.decide(pending: pending, installedVersion: installed, loginAgentOn: LoginAgent.isEnabled,
                                     startedByLoginAgent: byAgent) {
        case .nothing:
            return false
        case .notInstalled(let version):
            EnsembleLog.write("update: \(version) did not install; still running \(installed)")
        case .announce(let version):
            EnsembleLog.write("update: relaunched after update to \(version) (\(byAgent ? "started by the login agent" : "opened by Sparkle"))")
            justUpdatedTo = version
        case .handOverToLoginAgent:
            EnsembleLog.write("update: relaunched as \(installed) outside the login agent; handing over to launchd")
            defaults.set(true, forKey: handedOverKey)
            // This copy exits at once; the mark must be on disk or a failed hand-over could loop.
            defaults.synchronize()
            return true
        }
        defaults.removeObject(forKey: pendingVersionKey)
        defaults.removeObject(forKey: handedOverKey)
        return false
    }
}
