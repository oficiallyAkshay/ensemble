import AppKit
import EnsembleCore
import QuartzCore

/// The nose dot as its own tiny borderless window: a glass bead you can see through. AppKit's Liquid Glass view
/// only samples its own window, so over other apps it renders as an opaque dark disc (measured 2026-10-14);
/// instead a behind-window blur, faded to 60%, softens what is underneath, and a drawn rim and highlight give
/// it the bead's edge. Click-through, never activates, joins every Space. Fades out while the keyboard, mouse
/// or trackpad is in use, on the same curve as the highlight.
@MainActor
final class GlassDot {
    private let size: CGFloat = 18
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.level = .screenSaver
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.isReleasedWhenClosed = false
        p.alphaValue = 0
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let root = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        root.wantsLayer = true
        root.layer?.cornerRadius = size / 2
        root.layer?.masksToBounds = true
        let blur = NSVisualEffectView(frame: root.bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.alphaValue = 0.6
        blur.autoresizingMask = [.width, .height]
        let bead = BeadView(frame: root.bounds)
        bead.autoresizingMask = [.width, .height]
        root.addSubview(blur)
        root.addSubview(bead)
        root.addSubview(glyph)
        p.contentView = root
        return p
    }()
    /// The scroll symbol (the one the Actions tab uses for Scroll), centred on the bead and white like its rim, so
    /// it reads over the dark blur in light and dark; it is invisible except while a pinch-drag scrolls.
    private lazy var glyph: NSImageView = {
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        let image = NSImage(systemSymbolName: "arrow.up.and.down", accessibilityDescription: nil)?.withSymbolConfiguration(config)
        let v = NSImageView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        v.image = image
        v.contentTintColor = .white
        v.imageAlignment = .alignCenter
        v.autoresizingMask = [.width, .height]
        v.wantsLayer = true
        v.alphaValue = 0
        return v
    }()
    private var showsGlyph = false
    /// The opacity the dot is heading to; an animation runs only when this changes.
    private var target: CGFloat = 0
    /// Head readings arrive 15 to 30 times a second; jumping the window to each one reads as a stepping dot. The
    /// window instead moves on every screen refresh, as a spring toward the latest reading (DotSpring), so its
    /// speed carries through from one reading to the next.
    private var goal: CGPoint?
    /// While the nose moves, the spring aims ahead of `goal` between readings (`DotLead`); the dot still rests on `goal`.
    private var lead: DotLead?
    private var spring = DotSpring()
    private var lastTick: CFTimeInterval?
    private var link: CADisplayLink?
    /// Whether the link asks for 120 Hz: only while the dot moves fast (`DotSpring.isFast`), else 60, half the wakeups.
    private var linkFast = false
    /// The screen the display link was made for. A link stops firing when its screen goes away (unplugged,
    /// mirrored, asleep), so it is remade when the dot's window moves to another screen.
    private weak var linkScreen: NSScreen?
    private lazy var ticker = DisplayTicker { [weak self] in self?.tick($0) }
    private var screenObserver: NSObjectProtocol?

    /// Shows the dot centred on a global top-left point, or hides it when `point` is nil. `dimmed` (hands on the
    /// keyboard or trackpad) fades it away and back over 0.7 s.
    func show(at point: CGPoint?, lead: DotLead?, dimmed: Bool) {
        self.lead = lead
        guard let point else {
            target = 0
            goal = nil
            spring.clear()
            stopLink()
            if panel.isVisible { panel.alphaValue = 0; panel.orderOut(nil) }
            return
        }
        goal = point
        if spring.position == nil || !panel.isVisible {
            spring.reset(to: point)
            place(point)
        } else {
            startLink()
        }
        if !panel.isVisible { panel.orderFrontRegardless() }
        let next: CGFloat = dimmed ? 0 : 1
        guard next != target else { return }
        target = next
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.7
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = next
        }
    }

    /// Fades the scroll symbol in over the bead (and back out) on the same curve as the dot's own fade. The window
    /// is not resized or moved, so the dot keeps its position.
    func setScrolling(_ on: Bool) {
        guard on != showsGlyph else { return }
        showsGlyph = on
        guard panel.isVisible else { glyph.alphaValue = on ? 1 : 0; return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyph.animator().alphaValue = on ? 1 : 0
        }
    }

    private func place(_ p: CGPoint) {
        panel.setFrameOrigin(NSPoint(x: p.x - size / 2, y: ScreenGeometry.primaryHeight - p.y - size / 2))
    }

    private func tick(_ now: CFTimeInterval) {
        guard let goal, spring.position != nil else { stopLink(); return }
        // A refresh that comes late (a busy main thread) is stepped by its real gap; the spring is exact for any gap.
        let dt = min(max(now - (lastTick ?? now - 1.0 / 60), 0), 0.1)
        lastTick = now
        let next = spring.step(toward: lead?.goal(at: now) ?? goal, dt: dt)
        if spring.isResting(at: goal) {
            spring.reset(to: goal)
            place(goal)
            stopLink()
        } else {
            place(next)
            setFast(spring.isFast)
        }
    }

    private func setFast(_ fast: Bool) {
        guard fast != linkFast, let link else { return }
        linkFast = fast
        link.preferredFrameRateRange = fast ? CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                                            : CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
    }

    private func startLink() {
        let screen = panel.screen ?? NSScreen.main
        if link != nil, linkScreen === screen { return }
        stopLink()
        observeScreenChanges()
        let l = screen?.displayLink(target: ticker, selector: #selector(DisplayTicker.fire(_:)))
        l?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        l?.add(to: .main, forMode: .common)
        link = l
        linkScreen = screen
        linkFast = false
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkScreen = nil
        lastTick = nil
    }

    /// The dot crossing onto another screen, or the screen under it going away, needs a link for the new screen.
    private func observeScreenChanges() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(forName: NSWindow.didChangeScreenNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.link != nil else { return }
                self.stopLink()
                self.startLink()
            }
        }
    }
}

/// CADisplayLink needs an Objective-C target; this forwards each refresh to the dot.
private final class DisplayTicker: NSObject {
    private let onFire: (CFTimeInterval) -> Void
    init(_ onFire: @escaping (CFTimeInterval) -> Void) { self.onFire = onFire }
    @objc func fire(_ link: CADisplayLink) { onFire(link.targetTimestamp) }
}

/// The bead's edge: a faint fill, a light rim, and a small highlight in the upper left.
private final class BeadView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let b = bounds.insetBy(dx: 0.75, dy: 0.75)
        let circle = NSBezierPath(ovalIn: b)
        NSColor.white.withAlphaComponent(0.08).setFill()
        circle.fill()
        NSColor.white.withAlphaComponent(0.8).setStroke()
        circle.lineWidth = 1
        circle.stroke()
        NSColor.white.withAlphaComponent(0.6).setFill()
        NSBezierPath(ovalIn: NSRect(x: b.minX + b.width * 0.24, y: b.minY + b.height * 0.56,
                                    width: b.width * 0.3, height: b.height * 0.18)).fill()
    }
}
