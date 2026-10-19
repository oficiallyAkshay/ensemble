import EnsembleCore
import QuartzCore
import SwiftUI

/// Feeds the gestures step's inset from the engine's hand readings: joint coordinates only (the engine passes
/// nothing else out), eased between readings, plus the words for what the system reads right now.
@MainActor
final class TourHandInsetModel: ObservableObject {
    @Published private(set) var readout = HandReading.noHand.title

    private var smoother = HandSkeletonSmoother()
    private var tracker = HandReadoutTracker()

    func ingest(_ hand: HandObservation) {
        smoother.observe(hand.skeleton, at: hand.t)
        let text = tracker.observe(hand, at: hand.t)
        if text != readout { readout = text }
    }

    func reset() {
        smoother.reset()
        tracker.reset()
        readout = HandReading.noHand.title
    }

    /// The joints to draw now, in the unit square, mirrored like a selfie.
    func points(at now: TimeInterval) -> [CGPoint?] {
        smoother.sample(at: now)
    }
}

/// The bottom half of the gestures canvas's right-hand column: the owner's hand as Vision sees it, 21 joints as
/// dots and bones as lines, in the app's blue, on the window's raised surface, with the gesture the system reads
/// under it. It fills whatever rectangle it is given (`TourGestureColumn` gives it the page's empty half).
struct TourHandInset: View {
    @ObservedObject var model: TourHandInsetModel

    var body: some View {
        VStack(spacing: 4) {
            TimelineView(.animation) { _ in
                let points = model.points(at: CACurrentMediaTime())
                ZStack {
                    Canvas { context, size in draw(points, in: &context, size: size) }
                    if points.allSatisfy({ $0 == nil }) {
                        Text("Raise a hand to the camera")
                            .font(.caption2)
                            .foregroundStyle(Color.tourMuted)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 6)
                    }
                }
            }
            .clipped()

            Text(model.readout)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.tourInk)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tourSurface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.tourHairline, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your hand as the camera sees it: \(model.readout)")
    }

    private func draw(_ points: [CGPoint?], in context: inout GraphicsContext, size: CGSize) {
        // The joints are in the camera picture's unit square. The panel is a tall slice of it: draw the picture at
        // its true shape, a little larger than the panel is high, centred, so the hand is not squashed.
        let side = size.height * 1.15
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: size.width / 2 + (p.x - 0.5) * side, y: size.height / 2 + (p.y - 0.5) * side)
        }
        var bones = Path()
        for (a, b) in HandSkeleton.segments(of: points) {
            bones.move(to: place(a))
            bones.addLine(to: place(b))
        }
        context.stroke(bones, with: .color(Color.ensembleBlue), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        let tips: Set<Int> = [4, 8, 12, 16, 20]
        for (i, p) in points.enumerated() {
            guard let p else { continue }
            let r: CGFloat = tips.contains(i) ? 4 : 2.8
            let c = place(p)
            context.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)), with: .color(Color.ensembleBlueInk))
        }
    }
}
