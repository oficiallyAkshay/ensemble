import AppKit
import ApplicationServices
import EnsembleCore
import CoreGraphics
import Foundation

// Mic discovery through the accessibility tree follows the approach of
// github.com/reneceo/claude-dictation-hotkey (MIT, Rene Banuelos); see Vendor/LICENSE-claude-dictation-hotkey.

/// Everything that talks to Claude desktop. All Accessibility work runs on a private serial queue,
/// never the main thread. `stopDictation` alone uses a second queue so that a stuck read can never
/// delay turning the microphone off.
final class ClaudeBridge: AgentAdapter, @unchecked Sendable {
    let queue = DispatchQueue(label: "ensemble.claude.bridge", qos: .userInitiated)
    let urgentQueue = DispatchQueue(label: "ensemble.claude.bridge.urgent", qos: .userInteractive)
    /// Dictation start has its own queue so a slow session refresh on `queue` cannot delay it.
    let startQueue = DispatchQueue(label: "ensemble.claude.bridge.start", qos: .userInteractive)
    let inFlight = InFlightTracker()
    /// Claude's own notifications that its windows or panes changed; see `refreshSessions(watched:)`.
    let watcher = ClaudeWatcher()

    private let lock = NSLock()
    private var cache: [String: CachedSession] = [:]
    /// The cached sessions' ids in the order the walk found them.
    private var cacheOrder: [String] = []
    /// Archived sessions from the last walk, listed beside the cached ones but never looked up by `liveEntry`.
    private var archivedCache: [CachedArchived] = []
    /// Claude's window list as of the last full walk, and when it ran: the 1 s refresh re-walks only when these
    /// say the layout may have changed (`SessionScan`).
    private var walkedWindows: [WindowCandidate]?
    private var lastFullWalk = Date.distantPast
    private var listHold = SessionListHold()
    private var flaggedPID: pid_t = 0
    private var lastStopPressAt: Date?
    private var scrollMethod: ScrollMethod?
    private var noScrollAreaUntil: [String: Date] = [:]
    private var shuttingDown = false
    private var startPresses = 0
    private var axDisabled = false
    private var lastMicReading: (text: String, at: Date)?

    static let ambientInputAllowlist: Set<String> = []

    init() {}

    func startWorkspaceWatch() { watcher.startWorkspaceWatch() }
    var onSessionsChanged: (@MainActor () -> Void)? {
        get { watcher.onChange }
        set { watcher.onChange = newValue }
    }

    // MARK: Claude process

    private var claudeApps: [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeLabels.bundleID).filter { !$0.isTerminated }
    }

    var claudePID: pid_t? { claudeApps.first?.processIdentifier }

    func claudeIsRunning() -> Bool { !claudeApps.isEmpty }

    /// Once set, no new dictation can start; the quit path uses it so a start in flight cannot press after the stop.
    func beginShutdown() { lock.lock(); shuttingDown = true; lock.unlock() }
    var isShuttingDown: Bool { lock.lock(); defer { lock.unlock() }; return shuttingDown }

    /// A start press is queued or running: it could still turn the microphone on. The quit path waits for it
    /// before trusting an "off" reading.
    var startPressInFlight: Bool { lock.lock(); defer { lock.unlock() }; return startPresses > 0 }
    func noteStartPress(_ began: Bool) { lock.lock(); startPresses += began ? 1 : -1; lock.unlock() }

    /// The pane's frame read straight from its cached element: one bounded Accessibility read, never a tree walk,
    /// so it is safe while dictating. nil when the pane is not cached or does not answer.
    func paneFrame(_ s: ClaudeSession) async -> CGRect? {
        guard let pane = cachedPane(s.id) else { return nil }
        return await run { AX.frame(pane) }
    }

    private func cachedPane(_ id: String) -> AXUIElement? {
        lock.lock(); defer { lock.unlock() }
        return cache[id]?.elements.pane
    }

    /// True when the last discovery was refused because Accessibility is off or the grant is stale.
    var accessibilityDisabled: Bool { lock.lock(); defer { lock.unlock() }; return axDisabled }

    /// What a refusal says when a session cannot be found.
    var sessionNotFound: String {
        accessibilityDisabled ? "Accessibility is off or stale for Ensemble; remove it in Settings and add it again" : "session not found"
    }

    func noteMic(_ text: String) { lock.lock(); lastMicReading = (text, Date()); lock.unlock() }

    /// Both mic sources as of the last read ("mic AX value=1 label=... capture=true, 2.1 s ago"), for logs.
    /// Cached from the last bridge call; reading it never touches Accessibility.
    var micSnapshot: String {
        lock.lock(); defer { lock.unlock() }
        guard let r = lastMicReading else { return "mic not read yet" }
        return "mic \(r.text), \(String(format: "%.1f", Date().timeIntervalSince(r.at))) s ago"
    }

    private func noteAX(_ error: AXError) {
        lock.lock(); axDisabled = error == .apiDisabled; lock.unlock()
    }

    func claudeIsFrontmost() -> Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == ClaudeLabels.bundleID
    }

    var claudeVersion: String? {
        guard let url = claudeApps.first?.bundleURL, let bundle = Bundle(url: url) else { return nil }
        return bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    var lastScrollMethod: ScrollMethod? {
        lock.lock(); defer { lock.unlock() }
        return scrollMethod
    }

    /// Longest time any normal-queue Accessibility job has been running, 0 when idle.
    var longestAXCallSeconds: TimeInterval { inFlight.longestSeconds }

    // MARK: Running work

    func run<T>(urgent: Bool = false, onStartQueue: Bool = false, _ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { cont in
            (urgent ? urgentQueue : onStartQueue ? startQueue : queue).async {
                let token = urgent ? nil : self.inFlight.begin()
                let result = work()
                if let token { self.inFlight.end(token) }
                cont.resume(returning: result)
            }
        }
    }

    // MARK: Sessions

    /// The session list. A full walk costs Claude's own main thread a read per node, so this re-reads only what the
    /// last walk cached (`SessionScan.plan`), walking again when a window opened, closed or left the screen, a cached
    /// element stopped answering, or the cache is old.
    /// `watched`: the 1 s check, using Claude's change notifications. While `watcher` receives them, the pane frames are
    /// read only when a notification or the window server says something moved, a window move no longer walks, and
    /// the walk that runs regardless comes every `SessionScan.safetyWalkEvery`. Otherwise (and for the width steps,
    /// which watch their own drags) every call reads each checkbox and pane frame and walks every
    /// `SessionScan.fullWalkEvery`.
    /// `recording`: the sessions whose dictation checkbox reads "Stop dictation", from the same read that checks the
    /// checkbox still answers (no extra Accessibility call), so a dictation Claude runs without Ensemble is seen. The
    /// checkboxes are read on every call either way.
    func refreshSessions(watched: Bool = false) async -> (sessions: [ClaudeSession], recording: Set<String>) {
        await run { self.refreshNow(watched: watched) }
    }

    private func refreshNow(watched: Bool) -> (sessions: [ClaudeSession], recording: Set<String>) {
        let windows = Self.cgWindows(pids: Set(claudeApps.map(\.processIdentifier)))
        let observing = watched && claudePID.map { watcher.isObserving($0) } == true
        let changes = watched ? watcher.take() : []
        lock.lock()
        let cached = cacheOrder.compactMap { cache[$0] }
        let cachedArchived = archivedCache
        let walked = walkedWindows
        let sinceWalk = Date().timeIntervalSince(lastFullWalk)
        lock.unlock()
        let setChanged = SessionScan.windowSetChanged(walked, windows)
        var plan = SessionScan.plan(cached: cached.count + cachedArchived.count, windowSetChanged: setChanged,
                                    boundsChanged: walked != windows,
                                    changes: changes, observing: observing, sinceFullWalk: sinceWalk)
        var refreshed: [CachedSession] = []
        var refreshedArchived: [CachedArchived] = []
        var recording = Set<String>()
        if case .reread(let frames) = plan {
            for var entry in cached {
                guard let label = Self.micLabel(entry.elements.mic) else { plan = .walk; break }
                if frames {
                    guard let frame = AX.frame(entry.elements.pane), frame.width > 50, frame.height > 50 else { plan = .walk; break }
                    let moved = SessionScan.windowMoved(entry.session.windowNumber, from: walked, to: windows)
                    if observing, SessionScan.retiled(cachedFrame: entry.session.frame, frame: frame, windowMoved: moved) {
                        plan = .walk; break
                    }
                    entry.session.frame = frame
                }
                if label == ClaudeLabels.micActive { recording.insert(entry.session.id) }
                refreshed.append(entry)
            }
            // An archived pane is checked the way a checkbox is: its note bar must still be there (unarchiving removes
            // it), or the list is walked again at once.
            for var entry in cachedArchived where plan != .walk {
                guard AX.subrole(entry.bar) == Self.noteSubrole else { plan = .walk; break }
                if frames {
                    guard let pane = AX.frame(entry.pane), pane.width > 50, pane.height > 50, let bar = AX.frame(entry.bar) else {
                        plan = .walk; break
                    }
                    entry.session.frame = pane
                    entry.session.archivedBar = bar
                }
                refreshedArchived.append(entry)
            }
        }
        guard plan != .walk else {
            let found = discover(windows: windows)
            let active = found.filter { Self.micLabel($0.elements.mic) == ClaudeLabels.micActive }
            lock.lock(); let archived = archivedCache.map(\.session); lock.unlock()
            return (found.map(\.session) + archived, Set(active.map(\.session.id)))
        }
        lock.lock()
        // A stop or send may have re-walked meanwhile; its result wins over these frames.
        if cacheOrder == refreshed.map(\.session.id) {
            for entry in refreshed { cache[entry.session.id]?.session.frame = entry.session.frame }
            if archivedCache.map(\.session.id) == refreshedArchived.map(\.session.id) { archivedCache = refreshedArchived }
            // The frames now match these window positions: the next check need not read them again.
            if observing, plan == .reread(frames: true) { walkedWindows = windows }
        }
        let current = cacheOrder.compactMap { cache[$0]?.session }
        let archived = archivedCache.map(\.session)
        lock.unlock()
        return (current + archived, recording.intersection(current.map(\.id)))
    }

    func session(at point: CGPoint) -> ClaudeSession? {
        lock.lock(); defer { lock.unlock() }
        return cache.values.map(\.session)
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    /// A walk that has not finished by then stops, so a hung Claude (every read waiting out its timeout) cannot hold
    /// the bridge queue for minutes; a healthy walk takes a fraction of this.
    private static let walkBudget: TimeInterval = 2

    /// Full discovery; replaces the cache, except that one doubtful walk (nothing found, or cut short) keeps the
    /// previous sessions while they still answer (`SessionListHold`). Runs on a bridge queue.
    func discover(windows given: [WindowCandidate]? = nil) -> [CachedSession] {
        guard let pid = claudePID else {
            noteAX(.success)
            lock.lock(); listHold.reset(); lock.unlock()
            replaceCache([], windows: nil)
            watcher.forget()
            return []
        }
        let app = AX.application(pid: pid)
        let justEnabled = ensureManualAccessibility(app: app, pid: pid)

        let cgWindows = given ?? Self.cgWindows(pids: Set(claudeApps.map(\.processIdentifier)))
        var found: [CachedSession] = []
        var foundArchived: [CachedArchived] = []
        var complete = true
        var shownWindows: [AXUIElement] = []
        var dividers: [AXUIElement] = []
        // Right after the flag is set Chromium builds its tree incrementally; give it a few passes.
        for attempt in 0..<(justEnabled ? 8 : 1) {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.4) }
            found = []
            foundArchived = []
            complete = true
            shownWindows = []
            dividers = []
            let deadline = Date().addingTimeInterval(Self.walkBudget)
            let windows = AX.read(app, kAXWindowsAttribute)
            noteAX(windows.error)
            for (windowIndex, window) in ((windows.value as? [AXUIElement]) ?? []).enumerated() {
                if AX.bool(window, kAXMinimizedAttribute) == true { continue }
                guard let wf = AX.frame(window), wf.width > 50, wf.height > 50 else { continue }
                // A window on another Space, or hidden behind a full-screen app, has no session to point at.
                let match = WindowMatch.match(axNumber: AX.windowNumber(window), axFrame: wf, among: cgWindows)
                if let match, !match.onScreen { continue }
                let number = match?.number ?? 0
                let walked = sessions(in: window, windowNumber: number, idKey: number != 0 ? number : -(windowIndex + 1),
                                      deadline: deadline)
                found += walked.sessions
                foundArchived += walked.archived
                dividers += walked.dividers
                shownWindows.append(window)
                complete = complete && walked.complete
            }
            if !found.isEmpty || !foundArchived.isEmpty { break }
        }
        lock.lock()
        let previous = cacheOrder.compactMap { cache[$0] }
        lock.unlock()
        let doubtful = (found.isEmpty && foundArchived.isEmpty) || !complete
        let previousAnswer = doubtful && !previous.isEmpty && previous.allSatisfy { Self.isMicCheckbox($0.elements.mic) }
        lock.lock()
        let keep = listHold.keepPrevious(found: found.count + foundArchived.count, walkComplete: complete, previous: previous.count,
                                         previousAnswer: previousAnswer)
        lock.unlock()
        if keep {
            // Walk again on the next refresh instead of trusting the cache: a second doubtful walk drops the list.
            lock.lock(); lastFullWalk = .distantPast; lock.unlock()
            return previous
        }
        replaceCache(found, archived: foundArchived, windows: cgWindows)
        watcher.watch(pid: pid, windows: shownWindows, panes: found.map(\.elements.pane), mics: found.map(\.elements.mic),
                      dividers: dividers)
        return found
    }

    private func replaceCache(_ sessions: [CachedSession], archived: [CachedArchived] = [], windows: [WindowCandidate]?) {
        lock.lock(); defer { lock.unlock() }
        archivedCache = archived
        cache = Dictionary(sessions.map { ($0.session.id, $0) }, uniquingKeysWith: { a, _ in a })
        cacheOrder = []
        for s in sessions where !cacheOrder.contains(s.session.id) { cacheOrder.append(s.session.id) }
        walkedWindows = windows
        lastFullWalk = Date()
    }

    private func sessions(in window: AXUIElement, windowNumber: Int, idKey: Int, deadline: Date)
        -> (sessions: [CachedSession], archived: [CachedArchived], dividers: [AXUIElement], complete: Bool) {
        let walk = Self.collectMics(in: window, deadline: deadline)
        let (mics, dividers, complete) = (walk.hits, walk.dividers, walk.complete)
        let archived = Self.archivedSessions(in: walk, window: window, windowNumber: windowNumber, idKey: idKey)
        var result: [CachedSession] = []
        for (i, mic) in mics.enumerated() {
            guard Date() < deadline else { return (result, archived, dividers, false) }
            guard let paneIndex = Self.paneIndex(for: i, among: mics, deadline: deadline),
                  let pane = Optional(mic.path[paneIndex]),
                  let frame = AX.frame(pane) else { continue }
            let scan = Self.scanPane(pane)
            let id = Self.sessionID(windowKey: idKey, micIndex: i)
            let elements = PaneElements(window: window, pane: pane, mic: mic.element, composer: scan.composer,
                                        sendButton: scan.send, stopButton: scan.stop,
                                        modeControl: scan.mode, transcript: scan.transcript)
            result.append(CachedSession(session: ClaudeSession(id: id, frame: frame, windowNumber: windowNumber, title: scan.title), elements: elements))
        }
        return (result, archived, dividers, complete && Date() < deadline)
    }

    /// Keyed on the window and the mic's order in it, never on the frame, so dragging or resizing a window
    /// mid-hold does not change the id the stop is looked up by.
    static func sessionID(windowKey: Int, micIndex: Int) -> String { "w\(windowKey)#\(micIndex)" }

    /// The pane a dictated draft is read from and sent in, and only that pane (`SessionMatch`): the cached entry when
    /// it is still the same window, title and place, otherwise a fresh walk's pane that is. nil rather than another
    /// pane that took the id after a layout change, or another window's pane at the same place.
    func dictatedEntry(_ s: ClaudeSession) -> CachedSession? {
        if let entry = liveEntry(s, rescanPane: true) {
            var live = entry.session
            if let frame = AX.frame(entry.elements.pane) { live.frame = frame }
            if SessionMatch.same(s, live) { return entry }
        }
        let all = discover()
        return SessionMatch.pick(s, among: all.map(\.session)).map { all[$0] }
    }

    /// A cached session whose mic checkbox still answers; otherwise rediscover and match by id, then by overlap.
    func liveEntry(_ s: ClaudeSession, rescanPane: Bool = false) -> CachedSession? {
        // An archived session has nothing to press, and looking for it would walk the whole tree for nothing.
        if s.archivedBar != nil { return nil }
        lock.lock()
        let cached = cache[s.id]
        lock.unlock()
        if let cached, Self.isMicCheckbox(cached.elements.mic) {
            guard rescanPane else { return cached }
            var fresh = cached
            let scan = Self.scanPane(cached.elements.pane)
            if scan.composer != nil || scan.send != nil || scan.mode != nil {
                fresh.elements.composer = scan.composer
                fresh.elements.sendButton = scan.send
                fresh.elements.stopButton = scan.stop
                fresh.elements.modeControl = scan.mode
                fresh.elements.transcript = scan.transcript
                lock.lock(); cache[s.id] = fresh; lock.unlock()
                return fresh
            }
        }
        let all = discover()
        if let exact = all.first(where: { $0.session.id == s.id }) { return exact }
        return all.max { overlap($0.session.frame, s.frame) < overlap($1.session.frame, s.frame) }
            .flatMap { overlap($0.session.frame, s.frame) > s.frame.width * s.frame.height * 0.6 ? $0 : nil }
    }

    private func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        return i.isNull ? 0 : i.width * i.height
    }

    // MARK: Accessibility enablement

    /// Electron only builds its accessibility tree for web content after this flag is set; it must be
    /// set again after each Claude launch.
    private func ensureManualAccessibility(app: AXUIElement, pid: pid_t) -> Bool {
        lock.lock()
        let already = flaggedPID == pid
        lock.unlock()
        if already { return false }
        let error = AX.set(app, "AXManualAccessibility", kCFBooleanTrue)
        guard error == .success else { noteAX(error); return false }
        lock.lock(); flaggedPID = pid; lock.unlock()
        return true
    }

    // MARK: Tree scanning

    struct MicHit {
        var element: AXUIElement
        var path: [AXUIElement]       // window ... mic, inclusive
        var roles: [String]
        /// Only for an archived session's note bar: it holds a button (Unarchive).
        var hasButton = false
    }

    /// What one walk of a window found.
    struct WindowWalk {
        var hits: [MicHit] = []
        var dividers: [AXUIElement] = []
        /// The chat messages feeds, and an archived session's note bar (a note group in place of the message box).
        var feeds: [MicHit] = []
        var bars: [MicHit] = []
        var complete = true
    }

    static let noteSubrole = "AXDocumentNote"

    static func isMicLabel(_ s: String?) -> Bool { s == ClaudeLabels.micIdle || s == ClaudeLabels.micActive }

    static func isMicCheckbox(_ el: AXUIElement) -> Bool { micLabel(el) != nil }

    /// The dictation checkbox's label ("Stop dictation" while recording), or nil when `el` is no longer one.
    static func micLabel(_ el: AXUIElement) -> String? {
        let v = AX.multi(el, [kAXRoleAttribute, kAXDescriptionAttribute])
        guard (v[0] as? String) == "AXCheckBox", let label = v[1] as? String, isMicLabel(label) else { return nil }
        return label
    }

    private static let walkAttrs = [kAXRoleAttribute, kAXDescriptionAttribute, kAXTitleAttribute, kAXChildrenAttribute]

    /// Every dictation checkbox under `window` with its ancestor path, and every divider (`AXSplitter`, for
    /// `ClaudeWatcher`). The transcript is not entered: it holds most of the nodes and never contains a composer.
    /// The same walk notes the feeds and note bars an archived session is found from (`ArchivedPane`).
    /// `complete` is false when the walk ran out of time before `deadline`.
    static func collectMics(in window: AXUIElement, maxNodes: Int = 12_000,
                            deadline: Date = .distantFuture) -> WindowWalk {
        var walk = WindowWalk()
        var count = 0
        var outOfTime = false
        func go(_ el: AXUIElement, _ path: [AXUIElement], _ roles: [String], _ depth: Int, _ bar: Int?) {
            count += 1
            if count > maxNodes || depth > 70 || outOfTime { return }
            // Checking the clock every 64 nodes keeps the check itself out of the cost.
            if count % 64 == 0, Date() >= deadline { outOfTime = true; return }
            let v = AX.multi(el, walkAttrs + [kAXSubroleAttribute])
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            let path = path + [el]
            let roles = roles + [role]
            if role == "AXCheckBox", isMicLabel(desc) {
                walk.hits.append(MicHit(element: el, path: path, roles: roles))
                return
            }
            if role == "AXSplitter" { walk.dividers.append(el) }
            if desc == ClaudeLabels.transcript {
                walk.feeds.append(MicHit(element: el, path: path, roles: roles))
                return
            }
            var bar = bar
            if role == "AXGroup", (v[4] as? String) == noteSubrole {
                walk.bars.append(MicHit(element: el, path: path, roles: roles))
                bar = walk.bars.count - 1
            } else if role == "AXButton", let b = bar {
                walk.bars[b].hasButton = true
            }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, path, roles, depth + 1, bar) }
        }
        go(window, [], [], 0, nil)
        walk.complete = !outOfTime
        return walk
    }

    /// The archived sessions in one window: a note bar holding a button whose pane (the lowest ancestor holding a chat
    /// messages feed) holds no dictation checkbox. Live sessions are found by their checkbox as before.
    static func archivedSessions(in walk: WindowWalk, window: AXUIElement, windowNumber: Int, idKey: Int) -> [CachedArchived] {
        var result: [CachedArchived] = []
        for bar in walk.bars where bar.hasButton {
            let lowest = (bar.roles.lastIndex(of: "AXWebArea") ?? 0) + 1
            let ks = Array(lowest..<max(lowest, bar.path.count - 1))
            func holds(_ hits: [MicHit], _ k: Int) -> Bool { hits.contains { $0.path.count > k && CFEqual($0.path[k], bar.path[k]) } }
            let ancestors = ks.map { ArchivedAncestor(hasFeed: holds(walk.feeds, $0), hasMic: holds(walk.hits, $0)) }
            guard let i = ArchivedPane.index(among: ancestors) else { continue }
            let pane = bar.path[ks[i]]
            guard !result.contains(where: { CFEqual($0.pane, pane) }),
                  let frame = AX.frame(pane), let barFrame = AX.frame(bar.element) else { continue }
            let id = "w\(idKey)#a\(result.count)"
            let session = ClaudeSession(id: id, frame: frame, windowNumber: windowNumber, title: scanPane(pane).title,
                                        archivedBar: barFrame)
            result.append(CachedArchived(session: session, bar: bar.element, pane: pane))
        }
        return result
    }

    /// Index into `mics[i].path` of the session's pane. The choice itself is `PaneChoice`; this reads the
    /// facts it needs (frame, which session parts and whether the sidebar each ancestor holds) in one walk.
    static func paneIndex(for i: Int, among mics: [MicHit], deadline: Date = .distantFuture) -> Int? {
        let me = mics[i]
        let lowest = (me.roles.lastIndex(of: "AXWebArea") ?? 0) + 1
        let micIndex = me.path.count - 1
        guard lowest < micIndex else { return nil }
        let ks = Array(lowest..<micIndex)
        let found = ownParts(under: me.path, from: lowest, deadline: deadline)
        let ancestors = ks.map { k -> PaneAncestor in
            PaneAncestor(frame: AX.frame(me.path[k]) ?? .zero,
                         hasHeader: found.header >= k, hasTranscript: found.transcript >= k,
                         hasComposer: found.composer >= k, hasSidebar: found.sidebar >= k,
                         otherMics: mics.filter { $0.path.count > k && CFEqual($0.path[k], me.path[k]) }.count - 1)
        }
        return PaneChoice.index(among: ancestors).map { ks[$0] }
    }

    /// For each page part, the deepest index on `path` whose subtree holds it (-1 when not found).
    private static func ownParts(under path: [AXUIElement], from lowest: Int, maxNodes: Int = 12_000,
                                 deadline: Date = .distantFuture)
        -> (header: Int, transcript: Int, composer: Int, sidebar: Int) {
        var r = (header: -1, transcript: -1, composer: -1, sidebar: -1)
        var count = 0
        var outOfTime = false
        func go(_ el: AXUIElement, _ shared: Int, _ depth: Int) {
            count += 1
            if count > maxNodes || depth > 70 || outOfTime { return }
            if count % 64 == 0, Date() >= deadline { outOfTime = true; return }
            var shared = shared
            if shared + 1 < path.count, CFEqual(el, path[shared + 1]) { shared += 1 }
            let v = AX.multi(el, walkAttrs)
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            if desc == ClaudeLabels.transcript { r.transcript = max(r.transcript, shared); return }
            if desc == ClaudeLabels.sidebar { r.sidebar = max(r.sidebar, shared) }
            if role == "AXButton", let desc, desc.hasSuffix(ClaudeLabels.renameSuffix) { r.header = max(r.header, shared) }
            if role == "AXTextArea", desc == ClaudeLabels.composer { r.composer = max(r.composer, shared) }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, shared, depth + 1) }
        }
        go(path[lowest], lowest, 0)
        return r
    }

    struct PaneScan {
        var composer: AXUIElement?
        var send: AXUIElement?
        var stop: AXUIElement?
        var mode: AXUIElement?
        var transcript: AXUIElement?
        var title: String?
    }

    static func scanPane(_ pane: AXUIElement, maxNodes: Int = 4_000) -> PaneScan {
        var scan = PaneScan()
        var anyTextArea: AXUIElement?
        var anyPopup: AXUIElement?
        var count = 0
        func go(_ el: AXUIElement, _ depth: Int) {
            count += 1
            if count > maxNodes || depth > 60 { return }
            let v = AX.multi(el, walkAttrs)
            let role = (v[0] as? String) ?? ""
            let desc = v[1] as? String
            let title = v[2] as? String
            switch role {
            case "AXTextArea":
                if desc == ClaudeLabels.composer, scan.composer == nil { scan.composer = el }
                if anyTextArea == nil { anyTextArea = el }
            case "AXButton":
                if desc == ClaudeLabels.send || title == ClaudeLabels.send { scan.send = scan.send ?? el }
                if desc == ClaudeLabels.stop || title == ClaudeLabels.stop { scan.stop = scan.stop ?? el }
                if scan.title == nil, let desc, desc.hasSuffix(ClaudeLabels.renameSuffix) {
                    scan.title = String(desc.dropLast(ClaudeLabels.renameSuffix.count))
                }
            case "AXPopUpButton":
                if let title, !title.isEmpty {
                    if ClaudeLabels.allModes.contains(title) { scan.mode = scan.mode ?? el }
                    if anyPopup == nil, desc == nil || desc!.isEmpty { anyPopup = el }
                }
            default: break
            }
            if desc == ClaudeLabels.transcript { scan.transcript = el; return }
            for c in (v[3] as? [AXUIElement]) ?? [] { go(c, depth + 1) }
        }
        go(pane, 0)
        if scan.composer == nil { scan.composer = anyTextArea }
        if scan.mode == nil { scan.mode = anyPopup }
        return scan
    }

    // MARK: Windows

    static func cgWindows(pids: Set<pid_t>) -> [WindowCandidate] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var out: [WindowCandidate] = []
        for w in list {
            guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let number = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: b) else { continue }
            out.append(WindowCandidate(number: number, bounds: rect, onScreen: (w[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        return out
    }


    // MARK: Shared state used by the other extensions

    func notePress(stop: Bool) {
        guard stop else { return }
        lock.lock(); lastStopPressAt = Date(); lock.unlock()
    }

    func secondsSinceStopPress() -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        return lastStopPressAt.map { Date().timeIntervalSince($0) }
    }

    func setScrollMethod(_ m: ScrollMethod) {
        lock.lock(); scrollMethod = m; lock.unlock()
    }

    func scrollAreaCooldownActive(_ id: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        if let until = noScrollAreaUntil[id], until > Date() { return true }
        return false
    }

    func suppressScrollAreaSearch(_ id: String, for seconds: TimeInterval) {
        lock.lock(); noScrollAreaUntil[id] = Date().addingTimeInterval(seconds); lock.unlock()
    }
}
