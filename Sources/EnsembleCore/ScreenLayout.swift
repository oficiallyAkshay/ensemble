#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// A connected screen as the display arrangement in System Settings has it. `frame` is global, top-left origin.
public struct ScreenDescription: Equatable, Sendable {
    public var name: String
    public var frame: CGRect
    public var isMain: Bool
    public init(name: String, frame: CGRect, isMain: Bool) { self.name = name; self.frame = frame; self.isMain = isMain }
}

public enum ScreenLayout {
    public static func orientation(of frame: CGRect) -> String { frame.width >= frame.height ? "landscape" : "portrait" }

    /// "1920 x 1080" in points.
    public static func size(of frame: CGRect) -> String { "\(Int(frame.width.rounded())) \u{00D7} \(Int(frame.height.rounded()))" }

    /// Where a screen sits relative to the main one: "main", or "left, portrait", "right, landscape", "above, ...".
    public static func position(of screen: ScreenDescription, among screens: [ScreenDescription]) -> String {
        if screen.isMain { return "main" }
        let main = screens.first(where: \.isMain) ?? screens.first
        guard let main else { return orientation(of: screen.frame) }
        let dx = screen.frame.midX - main.frame.midX, dy = screen.frame.midY - main.frame.midY
        let side: String
        if abs(dx) >= abs(dy) { side = dx < 0 ? "left" : "right" } else { side = dy < 0 ? "above" : "below" }
        return "\(side), \(orientation(of: screen.frame))"
    }

    /// "Found 2 screens".
    public static func headline(count: Int) -> String { "Found \(count) screen\(count == 1 ? "" : "s")" }

    /// "DELL U2723QE" and a detail line "2560 x 1440, main" / "1080 x 1920, left, portrait".
    public static func detail(of screen: ScreenDescription, among screens: [ScreenDescription]) -> String {
        let place = position(of: screen, among: screens)
        return screen.isMain ? "\(size(of: screen.frame)), \(orientation(of: screen.frame)), main" : "\(size(of: screen.frame)), \(place)"
    }

    /// "Screen 2 of 2 \u{00B7} DELL U2723QE \u{00B7} turn to face it".
    public static func stepTitle(index: Int, count: Int, name: String, facing: Bool) -> String {
        var parts: [String] = []
        if count > 1 { parts.append("Screen \(index + 1) of \(count)") }
        parts.append(name)
        if facing { parts.append("turn to face it") }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// "Calibrated for 2 screens", or "... for 1 of 2 screens" when only some connected screens are.
    public static func calibratedLine(valid: Int, connected: Int) -> String? {
        guard valid > 0, connected > 0 else { return nil }
        if valid >= connected { return "Calibrated for \(connected) screen\(connected == 1 ? "" : "s")" }
        return "Calibrated for \(valid) of \(connected) screens"
    }

    /// The arrangement drawn small, as System Settings > Displays draws it: every frame scaled by one factor so
    /// the whole arrangement fits `width` by `maxHeight`, moved so its top-left corner is the origin. Relative
    /// positions and sizes are kept exactly; `size` is the drawing's own size. Empty or degenerate input gives
    /// no rects and a zero size.
    public static func fit(_ frames: [CGRect], width: CGFloat, maxHeight: CGFloat) -> (rects: [CGRect], size: CGSize) {
        let finite = frames.allSatisfy { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite }
        guard finite, let first = frames.first, width > 0, maxHeight > 0 else { return ([], .zero) }
        let bounds = frames.dropFirst().reduce(first) { $0.union($1) }
        guard bounds.width > 0, bounds.height > 0 else { return ([], .zero) }
        let scale = min(width / bounds.width, maxHeight / bounds.height)
        let rects = frames.map {
            CGRect(x: ($0.minX - bounds.minX) * scale, y: ($0.minY - bounds.minY) * scale,
                   width: $0.width * scale, height: $0.height * scale)
        }
        return (rects, CGSize(width: bounds.width * scale, height: bounds.height * scale))
    }

    /// A screen's calibration as the arrangement labels it: "Calibrated Oct 15" (the date already formatted),
    /// "Calibrated" when no date is known, "Not calibrated" when its calibration is not usable now (a new or moved
    /// screen, or none yet).
    public static func calibrationState(valid: Bool, calibratedOn: String?) -> String {
        guard valid else { return "Not calibrated" }
        return calibratedOn.map { "Calibrated \($0)" } ?? "Calibrated"
    }

    /// The panel's camera line. The camera's rate and the dot's are different numbers: a webcam delivers at most its
    /// own rate (30 a second for most), while the dot window moves on every refresh of the screen it is on. Only the
    /// name while off or before the first rate report: "HD Pro Webcam C920 · camera 30 fps · dot 60 Hz".
    public static func cameraLine(name: String?, running: Bool, cameraFPS: Int, dotHz: Int) -> String {
        let name = name ?? "No camera"
        guard running, cameraFPS > 0 else { return name }
        var parts = [name, "camera \(cameraFPS) fps"]
        if dotHz > 0 { parts.append("dot \(dotHz) Hz") }
        return parts.joined(separator: " \u{00B7} ")
    }
}
