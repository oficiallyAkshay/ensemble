import SwiftUI
import EnsembleCore

/// Step 3: one tab per gesture, plus a headphones tab while the Settings switch for headphone presses is on. While
/// this step is open, real gesture intents and stem presses go to the tour instead of Claude (`TourModel.tourPractice`),
/// so a tab can mark itself done the moment the owner performs the real thing, without pressing, dictating or
/// sending anything. The headphones tab never has to be done: presses reach the app only in some situations.
struct TourGesturesStep: View {
    @ObservedObject var model: TourModel
    let headphones: Bool

    var body: some View {
        let tabs = TourGestureTab.shown(headphones: headphones)
        VStack(spacing: 18) {
            Text(headphones ? "Gestures and headphones" : "Three gestures").font(.largeTitle.weight(.semibold))

            Picker("Gesture", selection: Binding(get: { model.activeTab }, set: { model.selectTab($0) })) {
                ForEach(tabs, id: \.self) { tab in
                    Label(tab.title, systemImage: model.practiceDone.contains(tab) ? "checkmark.circle.fill" : tab.symbolName)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(Color.ensembleBlue)
            .frame(maxWidth: 460)

            TabIllustration(model: model)

            Text(model.activeTab.explanation)
                .font(.callout)
                .foregroundStyle(Color.tourMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            // Fixed height: success shows inside the canvas, so nothing here changes size when a gesture is done.
            HStack(spacing: 10) {
                Label(model.activeTab.practicePrompt, systemImage: "hand.wave")
                    .foregroundStyle(Color.ensembleBlueInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer()
                if let next = tabs.drop(while: { $0 != model.activeTab }).dropFirst().first {
                    Button("Skip this step") { model.selectTab(next) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tourMuted)
                } else if model.activeTab == .headphones {
                    Button("Skip") { model.next() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.tourMuted)
                }
            }
            .frame(maxWidth: 480, minHeight: 22, maxHeight: 22)
        }
        .onChange(of: headphones) { _, on in
            if !on, model.activeTab == .headphones { model.selectTab(.dictate) }
        }
    }
}

/// The gestures canvas: a flat Claude window with one focused session (drawn by the web page, which also draws
/// the 3D hand in the top half of the right-hand column), and the live skeleton of the owner's own hand as Vision
/// reads it in the bottom half (on the Dictate tab the page's hand panel takes the whole column and there is no live
/// skeleton). A gesture's success shows as a small widget at the canvas's bottom left. The
/// scene is created once for the step, so switching tabs changes its animation without reloading the page.
private struct TabIllustration: View {
    @ObservedObject var model: TourModel
    @StateObject private var scene: TourSceneController

    init(model: TourModel) {
        self.model = model
        // Starts on the tab that is open, which is not always the first one when the step is revisited.
        _scene = StateObject(wrappedValue: TourSceneController(scene: TourScene(model.activeTab) ?? .dictate))
    }

    var body: some View {
        let tab = model.activeTab
        TourSceneStage(controller: scene, symbol: tab.symbolName, caption: tab.explanation) {
            ZStack {
                if tab == .headphones {
                    // Covers the page, which keeps its last scene underneath.
                    HeadphoneIllustration()
                } else if tab != .dictate {
                    // Dictate shows the animation alone: the page gives its hand panel the whole column, so no live panel goes here.
                    TourGestureColumn { TourHandInset(model: model.handInset) }
                }
                TourSuccessBadge(text: tab.successText)
                    .opacity(model.practiceDone.contains(tab) ? 1 : 0)
                    .animation(.smooth(duration: 0.3), value: model.practiceDone.contains(tab))
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
        .aspectRatio(16.0 / 10.0, contentMode: .fit)
        .frame(maxWidth: 560)
        .onChange(of: tab) { _, new in
            if let next = TourScene(new) { scene.setScene(next) }
        }
    }
}

/// One AirPod with a stem, pressed once (one ripple) and twice (two ripples), in the tour's palette.
private struct HeadphoneIllustration: View {
    var body: some View {
        HStack(spacing: 56) {
            PodPress(ripples: 1, title: "Press once", detail: "Same as a double pinch: start or stop dictating")
            PodPress(ripples: 2, title: "Press twice", detail: "Same as thumbs-up: send")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.tourSurface)
    }
}

private struct PodPress: View {
    let ripples: Int
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                ForEach(0..<ripples, id: \.self) { i in
                    Circle()
                        .strokeBorder(Color.ensembleBlue.opacity(i == 0 ? 0.6 : 0.3), lineWidth: 2)
                        .frame(width: 62 + CGFloat(i) * 26, height: 62 + CGFloat(i) * 26)
                }
                VStack(spacing: -4) {
                    Circle().fill(Color.tourInk).frame(width: 30, height: 30)
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.tourInk).frame(width: 10, height: 34)
                }
            }
            .frame(width: 96, height: 96)
            Text(title).font(.callout.weight(.semibold)).foregroundStyle(Color.tourInk)
            Text(detail)
                .font(.caption)
                .foregroundStyle(Color.tourMuted)
                .multilineTextAlignment(.center)
                .frame(width: 130)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The right-hand column of the canvas: `columnShare` of its width, with two panels of half its height each. The
/// page draws the top one (the 3D hand); this places the bottom one at exactly the rectangle the page leaves
/// empty. The margins and radius mirror the page's, in `scene3d.js` (COLUMN and the column's padding).
struct TourGestureColumn<Panel: View>: View {
    static var columnShare: CGFloat { 0.18 }
    static var margin: CGFloat { 8 }
    private let panel: Panel

    init(@ViewBuilder panel: () -> Panel) { self.panel = panel() }

    var body: some View {
        GeometryReader { geo in
            let m = Self.margin
            panel
                .frame(width: geo.size.width * Self.columnShare - 2 * m, height: geo.size.height / 2 - 1.5 * m)
                .position(x: geo.size.width - m - (geo.size.width * Self.columnShare - 2 * m) / 2,
                          y: geo.size.height / 2 + m / 2 + (geo.size.height / 2 - 1.5 * m) / 2)
        }
    }
}

/// "Pinch detected" and its kin: appears when the open tab's gesture is done.
private struct TourSuccessBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color(red: 0.13, green: 0.62, blue: 0.33))
            Text(text).foregroundStyle(Color.tourInk)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.tourSurface))
        .overlay(Capsule().strokeBorder(Color(red: 0.13, green: 0.62, blue: 0.33).opacity(0.55), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.12), radius: 6, y: 2)
        .accessibilityLabel(text)
    }
}

extension TourGestureTab {
    var title: String {
        switch self {
        case .dictate: return "Dictate"
        case .send: return "Send"
        case .scroll: return "Scroll"
        case .headphones: return "Headphones"
        }
    }

    var symbolName: String {
        switch self {
        case .dictate: return "hand.pinch"
        case .send: return "hand.thumbsup"
        case .scroll: return "hand.draw"
        case .headphones: return "airpods"
        }
    }

    var explanation: String {
        switch self {
        case .dictate: return "Double pinch (thumb tip to index tip, twice) to start dictating into the session you face. Double pinch again to stop."
        case .send: return "Hold thumbs-up for 0.75 s to send — only within 30 s of speaking, only to that session, and only if you have not typed since."
        case .scroll: return "Pinch and drag your hand up or down to scroll the session you're facing."
        case .headphones: return "Bluetooth headphones only: press the stem once to do what a double pinch does (start or stop dictating), twice to send like thumbs-up."
        }
    }

    /// What the success widget says once the tab's gesture is done.
    var successText: String {
        switch self {
        case .dictate: return "Double pinch detected"
        case .send: return "Thumbs-up detected"
        case .scroll: return "Pinch and drag detected"
        case .headphones: return "Headphone press heard"
        }
    }

    var practicePrompt: String {
        switch self {
        case .dictate: return "Your turn: double pinch to start, double pinch again to stop."
        case .send: return "Your turn: hold thumbs-up for about three quarters of a second."
        case .scroll: return "Your turn: pinch, then drag your hand up or down."
        case .headphones: return "Optional: press the stem; skip if your headphones are not connected."
        }
    }
}
