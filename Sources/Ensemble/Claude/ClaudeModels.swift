import ApplicationServices
import EnsembleCore
import CoreGraphics
import Foundation

enum ScrollMethod: String, Sendable {
    case accessibility, wheelEvent, failed
}

/// Strings Claude desktop shows. Taken from the app's own UI strings, not guessed.
enum ClaudeLabels {
    static let bundleID = "com.anthropic.claudefordesktop"
    static let micIdle = "Press and hold to record"
    static let micActive = "Stop dictation"
    static let send = "Send"
    static let stop = "Stop"
    static let transcript = "Chat messages"
    static let composer = "Prompt"
    /// The left navigation group; it also holds the window top bar buttons.
    static let sidebar = "Sidebar"
    /// The pane header's title button reads "<session name>, rename session".
    static let renameSuffix = ", rename session"
    /// The divider between two side-by-side session panes (an AXSplitter, value 0-100: that pair's split).
    static let paneResize = "Resize pane columns"
    static let allModes: Set<String> = ["Manual", "Accept edits", "Plan", "Auto", "Bypass permissions", "Don't ask"]
}

/// The live elements of one session pane. Elements go stale when Claude re-renders, so a pane is
/// re-scanned whenever it is used for something that matters.
struct PaneElements {
    var window: AXUIElement
    var pane: AXUIElement
    var mic: AXUIElement
    var composer: AXUIElement?
    var sendButton: AXUIElement?
    var stopButton: AXUIElement?
    var modeControl: AXUIElement?
    var transcript: AXUIElement?
}

/// An archived session: only looked at (outlined), never pressed, so it holds no mic, composer or buttons.
struct CachedArchived {
    var session: ClaudeSession
    var bar: AXUIElement
    var pane: AXUIElement
}

struct CachedSession {
    var session: ClaudeSession
    var elements: PaneElements
}

/// Serial-queue-confined bookkeeping for AX calls in flight, readable from any thread.
final class InFlightTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var starts: [UInt64: Date] = [:]
    private var next: UInt64 = 0

    func begin() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        next += 1
        starts[next] = Date()
        return next
    }

    func end(_ token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        starts[token] = nil
    }

    var longestSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let oldest = starts.values.min() else { return 0 }
        return Date().timeIntervalSince(oldest)
    }
}
