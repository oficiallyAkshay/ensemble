import AppKit
import CoreGraphics
import IOKit

/// Facts about what is on screen, read without Screen Recording permission (window owner and bounds only).
enum ScreenFacts {
    /// Owner pid of the frontmost normal window under a global top-left point, ignoring Ensemble's own overlays.
    static func topWindowOwner(at p: CGPoint) -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = ProcessInfo.processInfo.processIdentifier
        for w in list {   // front to back
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = b["X"], let y = b["Y"], let width = b["Width"], let height = b["Height"],
                  CGRect(x: x, y: y, width: width, height: height).contains(p) else { continue }
            return pid
        }
        return nil
    }

    /// True while the screen is locked, the screen saver runs, or another user's session owns the console:
    /// nothing Ensemble does then is something the person at the keyboard asked for.
    static func sessionAway() -> Bool {
        guard let info = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        if (info["CGSSessionScreenIsLocked"] as? Bool) == true { return true }
        if let onConsole = info[kCGSessionOnConsoleKey as String] as? Bool, !onConsole { return true }
        return false
    }

    /// Whether the MacBook's lid is closed, from the power manager's registry entry (a plain property read, no private
    /// API, no permission). nil when the Mac reports none (a desktop Mac). The built-in display going offline is no
    /// substitute: an external display unplugged with the lid open looks the same.
    static func lidClosed() -> Bool? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        return IORegistryEntryCreateCFProperty(entry, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Bool
    }

    /// A stable description of the current screen arrangement (screen ids and frames).
    static func displayFingerprint() -> String {
        NSScreen.screens.map { s in
            let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let uuid = CGDisplayCreateUUIDFromDisplayID(id).map { CFUUIDCreateString(nil, $0.takeRetainedValue()) as String } ?? "\(id)"
            let f = s.frame
            return "\(uuid)@\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width))x\(Int(f.height))"
        }.sorted().joined(separator: "|")
    }
}
