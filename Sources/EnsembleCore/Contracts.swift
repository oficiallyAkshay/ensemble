import CoreGraphics
import Foundation

// Shared types between the vision engine, the Claude bridge, the UI shell and the coordinator.
// Coordinates: every screen-space rect/point here is GLOBAL, TOP-LEFT origin (the Accessibility API's space),
// y grows downward. Convert to AppKit (bottom-left) only when drawing windows.

/// A static hand pose, per frame. Produced by the Sleight classifier (Vendor/Sleight).
public enum Pose: String, Codable, CaseIterable, Sendable {
    case fist, openPalm, thumbsUp, twoFingers
    case gather       // all five fingertips brought together into a point
    case pointUp, pointDown                 // index finger out, the other three curled, pointing up or down
}

/// Why the classifier refused a pose it recognised: the hand is too far away, or turned away from the camera.
public enum PoseGate: String, Sendable {
    case tooFar, angled
}

/// One camera frame's hand reading. `present == false` means no hand was found.
public struct HandObservation: Sendable {
    public var t: TimeInterval            // seconds, monotonic (CACurrentMediaTime)
    public var present: Bool
    public var pose: Pose?                // nil = a hand that is not one of the known poses (or gated out)
    public var palmCenter: CGPoint?       // normalized image coords, origin bottom-left, 0...1
    /// Thumb tip to index tip distance in palm lengths (wrist to middle knuckle); nil when either tip is unseen.
    public var pinch: Double?
    /// The 21 joint coordinates, for the tour's skeleton inset. Points only, never pixels.
    public var skeleton: HandSkeletonFrame?
    /// Index tip to middle tip distance in palm lengths: how far apart a two-fingers pose holds its fingers
    /// (peace sign apart, scissors closed). nil when either tip is unseen.
    public var fingerSpread: Double?
    /// The hand has the two-fingers shape (index and middle out, ring and little folded) whether or not `pose` says so:
    /// `gate` then names what refused it. For the two-fingers diagnostics only.
    public var twoUp: Bool
    public var gate: PoseGate?
    public init(t: TimeInterval, present: Bool, pose: Pose?, palmCenter: CGPoint?, pinch: Double? = nil, skeleton: HandSkeletonFrame? = nil,
                fingerSpread: Double? = nil, twoUp: Bool = false, gate: PoseGate? = nil) {
        self.t = t; self.present = present; self.pose = pose; self.palmCenter = palmCenter; self.pinch = pinch; self.skeleton = skeleton
        self.fingerSpread = fingerSpread; self.twoUp = twoUp; self.gate = gate
    }
}

/// Where the head is, in centimetres, in the face tracker's camera space (MediaPipe's facial transformation
/// matrix translation: x along the image, y up, and z negative in front of the camera). Also used as a plain 3-vector by the position correction.
public struct HeadPosition: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) { self.x = x; self.y = y; self.z = z }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
}

/// One camera frame's head reading from MediaPipe. Angles in radians; sign conventions don't matter
/// because the pointer calibration fits them. `position` is nil when the tracker did not report one.
public struct HeadObservation: Sendable {
    public var t: TimeInterval
    public var yaw: Double
    public var pitch: Double
    public var faceCount: Int
    public var position: HeadPosition?
    public init(t: TimeInterval, yaw: Double, pitch: Double, faceCount: Int, position: HeadPosition? = nil) {
        self.t = t; self.yaw = yaw; self.pitch = pitch; self.faceCount = faceCount; self.position = position
    }
}

/// Brightness statistics of one frame, for the covered-camera check.
public struct FrameLight: Sendable {
    public var t: TimeInterval
    public var meanLuma: Double           // 0...1
    public var lumaStdDev: Double         // 0...1
    public init(t: TimeInterval, meanLuma: Double, lumaStdDev: Double) { self.t = t; self.meanLuma = meanLuma; self.lumaStdDev = lumaStdDev }
}

/// Which pose does what. User-configurable.
public struct GestureMapping: Codable, Equatable, Sendable {
    public var talk: Pose = .gather             // kept for saved settings; the double tap needs no pose
    public var send: Pose? = .thumbsUp          // nil = sending by gesture is off
    public var scrollUp: Pose? = nil            // optional pose scroll (off by default: pinch and drag scrolls)
    public var scrollDown: Pose? = nil
    public init() {}

    private enum CodingKeys: String, CodingKey { case talk, send, scrollUp, scrollDown, scroll }

    /// Settings saved before pointing scroll have a single `scroll` key (a pose, or null when it was off).
    /// They get the pointing defaults, or both directions off when scrolling was off. A `cancel` key from
    /// settings saved while open hand cancelled is ignored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GestureMapping()
        talk = try c.decodeIfPresent(Pose.self, forKey: .talk) ?? d.talk
        send = c.contains(.send) ? try c.decode(Pose?.self, forKey: .send) : d.send
        if c.contains(.scrollUp) || c.contains(.scrollDown) {
            scrollUp = c.contains(.scrollUp) ? try c.decode(Pose?.self, forKey: .scrollUp) : d.scrollUp
            scrollDown = c.contains(.scrollDown) ? try c.decode(Pose?.self, forKey: .scrollDown) : d.scrollDown
        } else if c.contains(.scroll), try c.decode(Pose?.self, forKey: .scroll) == nil {
            scrollUp = nil
            scrollDown = nil
        } else {
            scrollUp = d.scrollUp
            scrollDown = d.scrollDown
        }
    }

    /// Two fingers is the pose of send or a scroll direction. The peace sign and the scissors are that same
    /// hand shape, so they stand aside meanwhile instead of both acting on one hand. (`talk` is unused: see above.)
    public var usesTwoFingers: Bool { [send, scrollUp, scrollDown].contains(.twoFingers) }

    /// Writes nil as an explicit null so "off" survives a round trip.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(talk, forKey: .talk)
        try c.encode(send, forKey: .send)
        try c.encode(scrollUp, forKey: .scrollUp)
        try c.encode(scrollDown, forKey: .scrollDown)
    }
}

/// What the gesture state machine asks for. The coordinator applies the safety guards before acting.
public enum GestureIntent: Equatable, Sendable {
    case talkBegan
    case talkEnded(TalkEndReason)
    case sendRequested
    case scroll(dy: Double)                 // points for this frame; negative = up the transcript, positive = down
    case dragScroll(handDy: Double)         // pinch and drag: points of hand travel this frame, positive = hand moved up
    case dragScrollEnded                    // the pinch opened or the hand left: scrolling stops now
    case maximizeSession                    // peace sign held: the session under the nose widens to the chat's default width
    case evenOutSessions                    // scissors: every session in that row gets an equal share again
}

public enum TalkEndReason: String, Sendable { case released, stale }

/// Claude's microphone in one session pane, from two sources that must agree: the dictation checkbox and CoreAudio's
/// per-process capture flag. `.on` and `.off` need both; anything else is `.unknown` with the reason.
public enum MicState: Equatable, Sendable {
    case on
    case off
    case unknown(String)
}

/// A Claude Code session pane visible on screen.
public struct ClaudeSession: Equatable, Sendable {
    public var id: String                   // opaque, stable while the pane exists
    public var frame: CGRect                // global, top-left origin
    public var windowNumber: Int
    /// The session's name as Claude shows it in the pane header; nil when it could not be read.
    public var title: String?
    public init(id: String, frame: CGRect, windowNumber: Int, title: String? = nil) {
        self.id = id; self.frame = frame; self.windowNumber = windowNumber; self.title = title
    }
}

/// One calibration reading: where the user was asked to point their nose (global, top-left) and the
/// head angles averaged while they did.
public struct CalibrationSample: Codable, Equatable, Sendable {
    public var yaw: Double
    public var pitch: Double
    public var target: CGPoint
    /// Where the head was while this sample was taken; nil in calibrations saved before head position existed.
    public var position: HeadPosition?
    public init(yaw: Double, pitch: Double, target: CGPoint, position: HeadPosition? = nil) {
        self.yaw = yaw; self.pitch = pitch; self.target = target; self.position = position
    }
}

/// The result of asking Claude to do something.
public enum BridgeResult: Equatable, Sendable {
    case done
    case refused(String)    // a guard said no; nothing was pressed
    case unknown(String)    // pressed, but the outcome could not be confirmed
}

/// What a held pose will do once its hold completes.
public enum GestureAction: String, Sendable { case talk, stop, send, scrollUp, scrollDown }

/// A pose being held right now: `progress` fills from 0 to 1 over the hold; `willAct` is false when this hold
/// cannot fire (for example a fist that arrived already closed); `active` is true while it is acting (dictating, scrolling).
public struct GestureProgress: Equatable, Sendable {
    public var pose: Pose
    public var action: GestureAction
    public var progress: Double
    public var willAct: Bool
    public var active: Bool
    public init(pose: Pose, action: GestureAction, progress: Double, willAct: Bool, active: Bool) {
        self.pose = pose; self.action = action; self.progress = progress; self.willAct = willAct; self.active = active
    }
}
