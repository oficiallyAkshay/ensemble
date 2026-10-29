#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
import Foundation

/// One connected screen, as seen by the matcher: its stable id, display name and current frame
/// (global, top-left origin).
public struct ScreenSnapshot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var frame: CGRect
    public init(id: String, name: String, frame: CGRect) { self.id = id; self.name = name; self.frame = frame }
}

/// Calibration samples recorded for one screen under one camera, tagged with the screen's id and the
/// frame it had when they were taken: a later frame change is what marks the screen as moved.
public struct ScreenCalibration: Codable, Equatable, Sendable {
    public var screenID: String
    public var frame: CGRect
    public var samples: [CalibrationSample]
    public var calibratedAt: Date
    public init(screenID: String, frame: CGRect, samples: [CalibrationSample], calibratedAt: Date) {
        self.screenID = screenID; self.frame = frame; self.samples = samples; self.calibratedAt = calibratedAt
    }
}

/// One place the owner calibrated from (sitting, standing, leaning back): a calibration per screen, each taken
/// with the head at about the same position. The pointer uses, screen by screen, the spot nearest where the
/// head is now.
public struct CalibrationSpot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var screens: [ScreenCalibration]
    public init(id: String, name: String, screens: [ScreenCalibration] = []) { self.id = id; self.name = name; self.screens = screens }

    /// The latest date any of its screens was calibrated.
    public var calibratedAt: Date? { screens.map(\.calibratedAt).max() }
}

/// Everything calibrated for one camera: its stable id, its display name, and one or more spots, each with a
/// calibration per screen it has been calibrated on.
///
/// `store` keeps one rule: every spot's calibration of the same screen was taken at the same frame, so a
/// screen is valid, or moved, for all spots at once.
public struct CameraProfile: Codable, Equatable, Sendable {
    public var cameraID: String
    public var cameraName: String
    public var spots: [CalibrationSpot]
    /// The fitted pointer model from before profiles existed. Raw samples were never stored then, so a
    /// migrated profile has this instead; it is used until the first new calibration replaces it.
    public var legacyModel: Data?

    public init(cameraID: String, cameraName: String, screens: [ScreenCalibration] = [], legacyModel: Data? = nil) {
        self.cameraID = cameraID; self.cameraName = cameraName; self.legacyModel = legacyModel
        spots = screens.isEmpty ? [] : [CalibrationSpot(id: Self.spotID(1), name: Self.spotName(1), screens: screens)]
    }

    static func spotID(_ n: Int) -> String { "spot-\(n)" }
    static func spotName(_ n: Int) -> String { "Position \(n)" }

    /// The first spot's screens: all a profile saved before spots existed held, and what an older version reads.
    public var screens: [ScreenCalibration] {
        get { spots.first?.screens ?? [] }
        set {
            if spots.isEmpty { spots = [CalibrationSpot(id: Self.spotID(1), name: Self.spotName(1))] }
            spots[0].screens = newValue
        }
    }

    /// Every screen calibration of every spot.
    public var allScreens: [ScreenCalibration] { spots.flatMap(\.screens) }

    /// True when any of these screens has no samples of its own (it came from the migrated model).
    public func hasModelOnly(_ screenIDs: Set<String>) -> Bool {
        allScreens.contains { screenIDs.contains($0.screenID) && $0.samples.isEmpty }
    }

    /// A screen's calibration from the first spot that has one (every spot's has the same frame).
    public func calibration(forScreenID id: String) -> ScreenCalibration? { allScreens.first { $0.screenID == id } }

    /// Replaces (or adds) the calibration for each given screen in the first spot; every other screen's
    /// calibration is untouched.
    public mutating func merge(_ updates: [ScreenCalibration]) {
        if spots.isEmpty { spots = [CalibrationSpot(id: Self.spotID(1), name: Self.spotName(1))] }
        store(updates, inSpot: spots[0].id)
    }

    /// Replaces (or adds) the calibration for each given screen in spot `spotID`, leaving its other screens and
    /// every other spot as they were, except that another spot's calibration of one of these screens made at a
    /// different frame is dropped: that screen has moved since, so it could never be valid again.
    public mutating func store(_ updates: [ScreenCalibration], inSpot spotID: String) {
        guard let s = spots.firstIndex(where: { $0.id == spotID }) else { return }
        for u in updates {
            if let i = spots[s].screens.firstIndex(where: { $0.screenID == u.screenID }) { spots[s].screens[i] = u } else { spots[s].screens.append(u) }
            for o in spots.indices where o != s {
                spots[o].screens.removeAll { $0.screenID == u.screenID && !SetupEvaluator.framesMatch($0.frame, u.frame) }
            }
        }
    }

    /// Replaces everything spot `spotID` held with these screens: a full recalibration of that spot.
    public mutating func replaceSpot(_ spotID: String, with screens: [ScreenCalibration]) {
        guard let s = spots.firstIndex(where: { $0.id == spotID }) else { return }
        spots[s].screens = []
        store(screens, inSpot: spotID)
    }

    /// The id and name the next added spot gets: one past the highest number used so far.
    public var nextSpot: (id: String, name: String) {
        let used = spots.compactMap { Int($0.id.dropFirst("spot-".count)) }
        let n = (used.max() ?? 0) + 1
        return (Self.spotID(n), Self.spotName(n))
    }

    /// Adds a spot holding these screens and returns its id.
    @discardableResult
    public mutating func addSpot(_ screens: [ScreenCalibration]) -> String {
        let next = nextSpot
        spots.append(CalibrationSpot(id: next.id, name: next.name))
        store(screens, inSpot: next.id)
        return next.id
    }

    /// Removes a spot, unless it is the last one.
    public mutating func removeSpot(_ spotID: String) {
        guard spots.count > 1 else { return }
        spots.removeAll { $0.id == spotID }
    }

    /// Drops what the migrated single calibration left behind (screens with no samples, and the model) once a
    /// calibration with samples replaces it.
    public mutating func dropLegacy() {
        legacyModel = nil
        for i in spots.indices { spots[i].screens.removeAll { $0.samples.isEmpty } }
        spots.removeAll { $0.screens.isEmpty }
    }

    /// Every sample tagged to one of `screenIDs`, from every spot.
    public func samples(for screenIDs: Set<String>) -> [CalibrationSample] {
        allScreens.filter { screenIDs.contains($0.screenID) }.flatMap(\.samples)
    }

    /// The per-screen inputs for the pointer fit: each of `screenIDs` that has samples, with its frame, once for
    /// every spot that calibrated it.
    public func pointerScreens(for screenIDs: Set<String>) -> [PointerScreen] {
        spots.flatMap { spot in
            spot.screens.filter { screenIDs.contains($0.screenID) && !$0.samples.isEmpty }
                .map { PointerScreen(id: $0.screenID, frame: $0.frame, samples: $0.samples, spotID: spot.id) }
        }
    }

    /// The screen, among `validScreenIDs` in spot `spotID` and other than `screenID`, whose calibrated angle range
    /// holds at least four in five of `samples`. From one spot two screens never share an angle range, so such samples
    /// were taken looking at that other screen; stored, they would leave the pointer unable to tell the two apart
    /// (2026-10-15: a one-screen recalibration of the left screen repeated the main screen's angles point for point,
    /// and the nose never reached the left screen again).
    public func screenRepeated(by samples: [CalibrationSample], forScreen screenID: String, inSpot spotID: String,
                               validScreenIDs: Set<String>) -> String? {
        guard !samples.isEmpty, let spot = spots.first(where: { $0.id == spotID }) else { return nil }
        for other in spot.screens where other.screenID != screenID && validScreenIDs.contains(other.screenID) && !other.samples.isEmpty {
            let ys = other.samples.map(\.yaw), ps = other.samples.map(\.pitch)
            guard let y0 = ys.min(), let y1 = ys.max(), let p0 = ps.min(), let p1 = ps.max() else { continue }
            let inside = samples.filter { (y0...y1).contains($0.yaw) && (p0...p1).contains($0.pitch) }.count
            if inside * 5 >= samples.count * 4 { return other.screenID }
        }
        return nil
    }

    /// For a run over only some screens: the calibrated screen in spot `spotID` (among `validScreenIDs`, not in
    /// `excluding`) whose centre is nearest `frame`, with its sample nearest its own centre. The first dot of such a
    /// run then needs a turn away from where that screen's centre was looked at, instead of only stillness, which
    /// captured the head still resting on the screen the Recalibrate click came from.
    public func neighbour(of frame: CGRect, inSpot spotID: String, validScreenIDs: Set<String>,
                          excluding: Set<String>) -> (frame: CGRect, centre: CalibrationSample)? {
        guard let spot = spots.first(where: { $0.id == spotID }) else { return nil }
        func gap(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let candidates = spot.screens.filter {
            validScreenIDs.contains($0.screenID) && !excluding.contains($0.screenID) && !$0.samples.isEmpty
        }
        guard let nearest = candidates.min(by: {
            gap(CGPoint(x: $0.frame.midX, y: $0.frame.midY), centre) < gap(CGPoint(x: $1.frame.midX, y: $1.frame.midY), centre)
        }) else { return nil }
        let own = CGPoint(x: nearest.frame.midX, y: nearest.frame.midY)
        guard let sample = nearest.samples.min(by: { gap($0.target, own) < gap($1.target, own) }) else { return nil }
        return (nearest.frame, sample)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey { case cameraID, cameraName, spots, screens, legacyModel }

    /// A profile saved before spots existed has only `screens`; it becomes the first spot, nothing lost.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cameraID = try c.decode(String.self, forKey: .cameraID)
        cameraName = try c.decode(String.self, forKey: .cameraName)
        legacyModel = try c.decodeIfPresent(Data.self, forKey: .legacyModel)
        if let spots = try c.decodeIfPresent([CalibrationSpot].self, forKey: .spots) {
            self.spots = spots
        } else {
            let screens = try c.decodeIfPresent([ScreenCalibration].self, forKey: .screens) ?? []
            spots = screens.isEmpty ? [] : [CalibrationSpot(id: Self.spotID(1), name: Self.spotName(1), screens: screens)]
        }
    }

    /// Writes `screens` (the first spot) beside `spots`, so a version from before spots still restores that spot.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(cameraID, forKey: .cameraID)
        try c.encode(cameraName, forKey: .cameraName)
        try c.encode(spots, forKey: .spots)
        try c.encode(screens, forKey: .screens)
        try c.encodeIfPresent(legacyModel, forKey: .legacyModel)
    }
}

/// Every camera profile the app has ever calibrated, persisted as one blob.
public struct SetupProfiles: Codable, Equatable, Sendable {
    public var cameras: [CameraProfile]
    public init(cameras: [CameraProfile] = []) { self.cameras = cameras }

    public func profile(forCameraID id: String) -> CameraProfile? { cameras.first { $0.cameraID == id } }

    public mutating func setProfile(_ profile: CameraProfile) {
        if let i = cameras.firstIndex(where: { $0.cameraID == profile.cameraID }) { cameras[i] = profile } else { cameras.append(profile) }
    }
}

/// What a camera-or-screen change means for the current desk setup, decided from the stored profiles
/// and the facts of the moment alone (no camera, no AppKit).
public enum SetupDecision: Equatable, Sendable {
    /// This camera has never been calibrated. `previousCameraName` is the camera calibration was last
    /// made with (nil only when nothing has ever been calibrated at all).
    case newCamera(cameraName: String, previousCameraName: String?, screenCount: Int)
    /// This camera has a profile. `validScreenIDs` already have usable samples at their current frame and
    /// keep working; `newScreens` do not (never seen, or moved) and need calibrating. `newScreens` empty
    /// means every connected screen matches and the setup can restore silently.
    case ready(cameraName: String, validScreenIDs: [String], newScreens: [ScreenSnapshot], mostRecentCalibration: Date?)
}

public enum SetupEvaluator {
    /// `frameTolerance` absorbs the pixel jitter some displays report across a sleep/wake cycle without
    /// reading as "moved".
    public static func evaluate(
        profiles: SetupProfiles, cameraID: String, cameraName: String, previousCameraName: String?,
        screens: [ScreenSnapshot], frameTolerance: CGFloat = 2
    ) -> SetupDecision {
        guard let profile = profiles.profile(forCameraID: cameraID), !profile.allScreens.isEmpty else {
            return .newCamera(cameraName: cameraName, previousCameraName: previousCameraName, screenCount: screens.count)
        }
        var validIDs: [String] = []
        var newScreens: [ScreenSnapshot] = []
        for screen in screens {
            if let stored = profile.calibration(forScreenID: screen.id), framesMatch(stored.frame, screen.frame, tolerance: frameTolerance) {
                validIDs.append(screen.id)
            } else {
                newScreens.append(screen)
            }
        }
        let recent = profile.allScreens.filter { validIDs.contains($0.screenID) }.map(\.calibratedAt).max()
        return .ready(cameraName: profile.cameraName, validScreenIDs: validIDs, newScreens: newScreens, mostRecentCalibration: recent)
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }
}
