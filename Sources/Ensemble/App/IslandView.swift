import SwiftUI
import EnsembleCore

/// A Dynamic Island style capsule hanging from the top centre of the screen. It grows and morphs with a
/// spring between dictation, gesture feedback and short messages, and folds away when idle. Timed waits
/// (switching sessions, holding to send) fill the island's own edge, starting the moment the clock starts.
struct IslandView: View {
    @ObservedObject var model: OverlayModel
    let notch: CGSize

    private enum Mode: Equatable { case idle, dictating, switching, firstPinch, sendHold, sending, otherGesture, banner }
    /// What is drawn. It follows `liveMode` only once that has held steady for a moment, so a state that lasts
    /// a frame or two (a dropped hand frame, the gap between a gesture firing and Claude confirming) never flashes.
    @State private var shown: Mode = .idle
    private var mode: Mode { shown }
    private var liveMode: Mode {
        // From the end of the hold until the result, a send is one step, even while its stop is still completing.
        if model.sending != nil { return .sending }
        if model.listening, model.sessionSwitch != nil { return .switching }
        if let g = model.gesture {
            if (g.action == .talk || g.action == .stop) && !g.active { return .firstPinch }
            if g.action == .send, g.willAct { return .sendHold }
            if g.action == .scrollUp || g.action == .scrollDown { return .otherGesture }
        }
        if model.listening { return .dictating }
        if model.banner != nil { return .banner }
        return .idle
    }
    /// Screens without a camera notch (external displays, a closed MacBook) get a floating capsule below the
    /// menu bar instead of one growing out of the notch.
    private var floating: Bool { notch.height == 0 }

    private var size: CGSize {
        switch mode {
        case .idle: return CGSize(width: 120, height: 0)
        case .otherGesture: return CGSize(width: 200, height: 36)
        case .dictating, .switching, .firstPinch, .sendHold, .sending, .banner: return CGSize(width: 360, height: floating ? 46 : 48)
        }
    }

    /// The edge fill for timed waits; nil when this state has no clock.
    private var edgeProgress: Double? {
        switch mode {
        case .switching: return model.sessionSwitch?.progress
        case .sendHold: return model.gesture?.progress
        case .sending: return 1
        default: return nil
        }
    }

    /// How far toward the neighbour's column the lit column leans when the nose is at its session's edge. It
    /// stays short of arriving: arriving is the switch itself.
    private static let maxLean = 0.4

    /// The columns toward the neighbouring session, while the nose nears (or is just across) its edge.
    private var approach: SessionSwitch? {
        guard model.listening, model.sessionSwitch == nil, let e = model.edge, e.warning.neighbourId != nil,
              let ap = e.approach, ap.sessionCount > 1 else { return nil }
        return ap
    }

    private var name: String { model.sessionName ?? "this session" }

    var body: some View {
        let r: CGFloat = 22
        let shape = UnevenRoundedRectangle(topLeadingRadius: floating ? r : 0, bottomLeadingRadius: r,
                                          bottomTrailingRadius: r, topTrailingRadius: floating ? r : 0, style: .continuous)
        ZStack {
            shape.fill(Color.black)
            content
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.85)).animation(.spring(response: 0.4, dampingFraction: 0.8).delay(0.08)),
                                        removal: .opacity.animation(.easeOut(duration: 0.12))))
                // The hold turns into the send in place: same content, no re-entry animation.
                .id(mode == .sending ? Mode.sendHold : mode)
        }
        .padding(.top, mode == .idle ? 0 : notch.height)
        .frame(width: max(size.width, notch.width + (mode == .idle ? 0 : 40)), height: size.height + (mode == .idle ? 0 : notch.height))
        .overlay {
            if let p = edgeProgress {
                IslandEdge(floating: floating, radius: r)
                    .trim(from: 0, to: min(max(p, 0), 1))
                    .stroke(Color.ensembleBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .animation(.linear(duration: 0.1), value: p)
            }
        }
        .background(shape.fill(Color.black))
        .clipShape(shape)
        .shadow(color: .black.opacity(mode == .idle ? 0 : 0.35), radius: 14, y: 6)
        .opacity(mode == .idle ? 0 : 1)
        .scaleEffect(floating && mode == .idle ? 0.85 : 1, anchor: .top)
        .padding(.top, floating ? NSStatusBar.system.thickness + 8 : 0)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: mode)
        .environment(\.colorScheme, .dark)
        .onAppear { shown = liveMode }
        .onChange(of: liveMode) { _, next in settle(next) }
    }

    /// 0.15 s for a new state, 0.35 s before folding away. A send's hold turning into the send, and the send turning
    /// into its result, are decided facts rather than flickers: they show at once.
    private func settle(_ next: Mode) {
        if (shown == .sendHold && next == .sending) || (shown == .sending && next == .banner) {
            shown = next
            return
        }
        let wait: UInt64 = next == .idle ? 350_000_000 : 150_000_000
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: wait)
            if liveMode == next, shown != next { shown = next }
        }
    }

    private func lines(_ title: Text, _ sub: Text?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            title.font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            if let sub { sub.font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6)).lineLimit(1).truncationMode(.middle) }
        }
    }

    private func session(_ n: String) -> Text { Text(n).foregroundColor(Color.ensembleSoftBlue) }

    private func hint(_ s: String) -> some View {
        Text(s).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).fixedSize()
    }

    /// One column per open session when there is more than one to show; the plain two-tile glyph otherwise
    /// (a single session, or the list not available yet).
    @ViewBuilder private var switchGlyph: some View {
        if let sw = model.sessionSwitch, sw.sessionCount > 1 {
            SessionColumnsGlyph(count: sw.sessionCount, groupBreaks: sw.groupBreaks, from: sw.fromIndex, to: sw.toIndex, progress: sw.progress)
        } else {
            SwitchGlyph()
        }
    }

    private var switchGlyphWidth: CGFloat {
        (model.sessionSwitch?.sessionCount ?? 0) > 1 ? 56 : 26
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .idle:
            EmptyView()
        case .dictating:
            HStack(spacing: 11) {
                if let ap = approach {
                    SessionColumnsGlyph(count: ap.sessionCount, groupBreaks: ap.groupBreaks, from: ap.fromIndex, to: ap.toIndex,
                                        progress: Self.maxLean * (model.edge?.warning.proximity ?? 0))
                        .frame(width: 56, height: 16)
                        .transition(.opacity)
                } else if model.liveSoundBars {
                    SoundWaves(color: .ensembleBlue, level: model.audioLevel).frame(width: 26, height: 16)
                } else {
                    BlinkingMic()
                }
                if let ap = approach {
                    lines(Text("Dictation on, looking toward ") + session(ap.name ?? "another session"), Text("in ") + session(name))
                } else {
                    lines(Text("Claude dictation on"), Text("in ") + session(name))
                }
                Spacer(minLength: 8)
                hint("double pinch to stop")
            }
            .animation(.smooth(duration: 0.3), value: approach != nil)
        case .switching:
            HStack(spacing: 11) {
                switchGlyph.frame(width: switchGlyphWidth, height: 16)
                lines(Text("Activating ") + session(model.sessionSwitch?.name ?? "the other session"), Text("Original message unsent"))
                Spacer(minLength: 8)
                hint("look back to stay")
            }
        case .firstPinch:
            let stopping = model.gesture?.action == .stop
            HStack(spacing: 11) {
                DoublePinchGlyph().frame(width: 26, height: 18)
                lines(Text(stopping ? "Pinch again to stop dictation" : "Pinch again to dictate"), Text("in ") + session(name))
                Spacer(minLength: 0)
            }
        case .sendHold, .sending:
            HStack(spacing: 11) {
                Image(systemName: "paperplane.fill").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.ensembleBlue)
                    .frame(width: 26)
                lines(Text("Sending in ") + session(mode == .sending ? (model.sending ?? name) : name), nil)
                Spacer(minLength: 8)
                if mode == .sendHold { hint("lower to cancel") }
            }
        case .otherGesture:
            if let g = model.gesture {
                HStack(spacing: 10) {
                    Image(systemName: Self.symbol(g.action)).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.ensembleBlue)
                    Text(Self.label(g)).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
            }
        case .banner:
            if let b = model.banner {
                HStack(spacing: 11) {
                    Image(systemName: Self.bannerSymbol(b.style)).font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Self.bannerTint(b.style)).frame(width: 26)
                    switch b.style {
                    case .sent: lines(Text("Sent in ") + session(b.body), nil)
                    case .stopped: lines(Text(b.title), Text("Text kept in ") + session(b.body) + Text(", thumbs-up to send"))
                    case .refused, .info, .success: lines(Text(b.title), Text(b.body))
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

extension IslandView {
    static func symbol(_ a: GestureAction) -> String {
        switch a {
        case .talk: return "mic.fill"
        case .stop: return "stop.fill"
        case .send: return "paperplane.fill"
        case .scrollUp: return "arrow.up"
        case .scrollDown: return "arrow.down"
        }
    }

    static func label(_ g: GestureProgress) -> String {
        switch g.action {
        case .talk, .stop: return "Pinch again"
        case .send: return "Sending"
        case .scrollUp, .scrollDown: return "Scrolling"
        }
    }

    static func bannerSymbol(_ s: OverlayBanner.Style) -> String {
        switch s {
        case .sent: return "checkmark"
        case .stopped: return "mic.slash.fill"
        case .success: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .refused: return "exclamationmark.circle.fill"
        }
    }

    static func bannerTint(_ s: OverlayBanner.Style) -> Color {
        switch s {
        case .sent: return .ensembleBlue
        case .stopped: return .white.opacity(0.55)
        case .success: return Color(red: 0.35, green: 0.80, blue: 0.55)
        case .info: return .ensembleBlue
        case .refused: return Color(red: 1.0, green: 0.70, blue: 0.25)
        }
    }
}

/// The island's outline as one stroke for progress: on a notch it runs down the left side, along the bottom
/// and up the right (the top edge is the screen edge); floating, it runs clockwise from the top centre.
struct IslandEdge: Shape {
    let floating: Bool
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let r = min(radius, rect.height / 2), i: CGFloat = 1.25
        let b = rect.insetBy(dx: i, dy: i)
        var p = Path()
        if floating {
            p.move(to: CGPoint(x: b.midX, y: b.minY))
            p.addLine(to: CGPoint(x: b.maxX - r, y: b.minY))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.minY + r), radius: r, startAngle: .degrees(-90), endAngle: .degrees(0), clockwise: false)
            p.addLine(to: CGPoint(x: b.maxX, y: b.maxY - r))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
            p.addLine(to: CGPoint(x: b.minX + r, y: b.maxY))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
            p.addLine(to: CGPoint(x: b.minX, y: b.minY + r))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.minY + r), radius: r, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: b.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
            p.addArc(center: CGPoint(x: b.minX + r, y: b.maxY - r), radius: r, startAngle: .degrees(180), endAngle: .degrees(90), clockwise: true)
            p.addLine(to: CGPoint(x: b.maxX - r, y: b.maxY))
            p.addArc(center: CGPoint(x: b.maxX - r, y: b.maxY - r), radius: r, startAngle: .degrees(90), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: b.maxX, y: rect.minY))
        }
        return p
    }
}
