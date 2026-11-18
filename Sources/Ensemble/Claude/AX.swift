import ApplicationServices
import CoreGraphics
import Foundation

/// Thin, defensive wrappers over the Accessibility C API. Every read has a short messaging timeout so a
/// hung Electron renderer cannot stall a caller for the system default (6 s).
enum AX {
    static let timeout: Float = 0.5

    static func application(pid: pid_t) -> AXUIElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, timeout)
        return app
    }

    /// The value and the error, so callers can tell a missing attribute from a revoked or disabled API.
    static func read(_ el: AXUIElement, _ attr: String) -> (value: CFTypeRef?, error: AXError) {
        AXUIElementSetMessagingTimeout(el, timeout)
        var value: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &value)
        return (err == .success ? value : nil, err)
    }

    static func copy(_ el: AXUIElement, _ attr: String) -> CFTypeRef? { read(el, attr).value }

    static func error(_ el: AXUIElement, _ attr: String) -> AXError {
        AXUIElementSetMessagingTimeout(el, timeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(el, attr as CFString, &value)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        copy(el, attr) as? String
    }

    static func bool(_ el: AXUIElement, _ attr: String) -> Bool? {
        guard let v = copy(el, attr) else { return nil }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }

    static func number(_ el: AXUIElement, _ attr: String) -> Double? {
        (copy(el, attr) as? NSNumber)?.doubleValue
    }

    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        guard let v = copy(el, attr), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ el: AXUIElement, _ attr: String) -> [AXUIElement] {
        (copy(el, attr) as? [AXUIElement]) ?? []
    }

    /// Several attributes in one round trip; missing or errored attributes come back as nil.
    static func multi(_ el: AXUIElement, _ attrs: [String]) -> [CFTypeRef?] {
        AXUIElementSetMessagingTimeout(el, timeout)
        var out: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(el, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &out)
        guard err == .success, let values = out as? [CFTypeRef], values.count == attrs.count else {
            return Array(repeating: nil, count: attrs.count)
        }
        return values.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v
        }
    }

    static func attributeNames(_ el: AXUIElement) -> [String] {
        AXUIElementSetMessagingTimeout(el, timeout)
        var names: CFArray?
        guard AXUIElementCopyAttributeNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func actionNames(_ el: AXUIElement) -> [String] {
        AXUIElementSetMessagingTimeout(el, timeout)
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    static func isSettable(_ el: AXUIElement, _ attr: String) -> Bool {
        var settable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(el, attr as CFString, &settable) == .success && settable.boolValue
    }

    @discardableResult
    static func set(_ el: AXUIElement, _ attr: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetMessagingTimeout(el, timeout)
        return AXUIElementSetAttributeValue(el, attr as CFString, value)
    }

    @discardableResult
    static func perform(_ el: AXUIElement, _ action: String) -> AXError {
        AXUIElementSetMessagingTimeout(el, timeout)
        return AXUIElementPerformAction(el, action as CFString)
    }

    static func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    static func subrole(_ el: AXUIElement) -> String? { string(el, kAXSubroleAttribute) }
    static func desc(_ el: AXUIElement) -> String? { string(el, kAXDescriptionAttribute) }
    static func title(_ el: AXUIElement) -> String? { string(el, kAXTitleAttribute) }
    static func children(_ el: AXUIElement) -> [AXUIElement] { elements(el, kAXChildrenAttribute) }
    static func parent(_ el: AXUIElement) -> AXUIElement? { element(el, kAXParentAttribute) }

    /// Global top-left frame from AXPosition + AXSize.
    /// Position and size in one round trip: each read is a message Claude's main thread answers.
    static func frame(_ el: AXUIElement) -> CGRect? {
        let v = multi(el, [kAXPositionAttribute, kAXSizeAttribute])
        guard let p = v[0], CFGetTypeID(p) == AXValueGetTypeID(),
              let s = v[1], CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Depth-first walk, pre-order, capped by depth and total node count.
    /// The visitor returns false to stop the whole walk.
    static func walk(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 20_000,
                     _ visit: (AXUIElement, Int) -> Bool) {
        var count = 0
        func go(_ el: AXUIElement, _ depth: Int) -> Bool {
            count += 1
            if count > maxNodes { return false }
            if !visit(el, depth) { return false }
            if depth >= maxDepth { return true }
            for c in children(el) {
                if !go(c, depth + 1) { return false }
            }
            return true
        }
        _ = go(root, 0)
    }

    static func nodeCount(_ root: AXUIElement, maxDepth: Int = 40, maxNodes: Int = 20_000) -> Int {
        var n = 0
        walk(root, maxDepth: maxDepth, maxNodes: maxNodes) { _, _ in n += 1; return true }
        return n
    }

    /// The window server's number for an accessibility window. Claude's windows do not answer "AXWindowNumber"
    /// (attribute unsupported, measured 2026-10-15), so this asks `_AXUIElementGetWindow`, the lookup window
    /// managers use. It is looked up at run time and is nil when macOS no longer has it; callers then match by frame.
    static func windowNumber(_ window: AXUIElement) -> Int? {
        guard let getWindow = getWindowFn else { return nil }
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return Int(id)
    }

    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindowFn: GetWindowFn? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindowFn.self)
    }()
}
