import AppKit
import EnsembleCore
import WebKit

/// MediaPipe Face Landmarker running in a hidden WKWebView. Frames go in as raw RGBA pixels the page fetches from the
/// asset scheme, head angles and position come out.
@MainActor
final class FaceTracker: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var onReady: ((_ delegate: String) -> Void)?
    var onFailure: ((String) -> Void)?
    var onHead: ((HeadObservation) -> Void)?
    var onDiagnostic: ((String) -> Void)?

    nonisolated let gate = FrameGate()
    /// The frame the page fetches next; the asset scheme handler hands it out.
    nonisolated let frames = FaceFrameSlot()

    private var webView: WKWebView?
    private var window: NSWindow?
    private(set) var isReady = false
    /// Loading or ready: `start()` was called and neither `stop()` nor a failure followed.
    var isStarted: Bool { startAttempt != nil }
    private var consecutiveFrameErrors = 0
    private var readyTimeout: Task<Void, Never>?
    private var startAttempt: UUID?
    private static let readyTimeoutSeconds: UInt64 = 10

    /// Compiles the network block, then loads the page. Safe to call again after `stop()`. The page is never
    /// loaded without the block: if the rule list does not compile, the tracker fails instead of starting.
    func start() {
        stop()
        let attempt = UUID()
        startAttempt = attempt
        Task { @MainActor [weak self] in
            do {
                let blockList = try await NetworkBlock.compile()
                guard let self, self.startAttempt == attempt else { return }
                self.load(blockList: blockList)
            } catch {
                guard let self, self.startAttempt == attempt else { return }
                self.fail("Face tracking is off because its network block could not be set up: \(error.localizedDescription)")
            }
        }
        readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, self.startAttempt == attempt, !self.isReady else { return }
            self.fail("The face tracker did not become ready within \(Self.readyTimeoutSeconds) s")
        }
    }

    private func load(blockList: WKContentRuleList) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(blockList)
        config.setURLSchemeHandler(AssetSchemeHandler(frames: frames), forURLScheme: AssetSchemeHandler.scheme)
        config.userContentController.add(WeakScriptHandler(self), name: "head")
        config.mediaTypesRequiringUserActionForPlayback = []

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1, height: 1), configuration: config)
        view.navigationDelegate = self
        // Without a window WebKit throttles the page as if it were in a background tab.
        let host = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1, height: 1),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.ignoresMouseEvents = true
        host.alphaValue = 0
        host.level = .normal
        host.collectionBehavior = [.stationary, .ignoresCycle, .canJoinAllSpaces]
        host.contentView = view
        host.orderFrontRegardless()

        webView = view
        window = host
        view.load(URLRequest(url: URL(string: "\(AssetSchemeHandler.scheme)://local/head.html")!))
    }

    /// The page is torn down first: a failed page left alive could report a second failure, counted as another.
    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }

    func stop() {
        startAttempt = nil
        readyTimeout?.cancel()
        readyTimeout = nil
        gate.setOpen(false)
        frames.clear()
        isReady = false
        consecutiveFrameErrors = 0
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "head")
        webView?.stopLoading()
        window?.orderOut(nil)
        window?.contentView = nil
        webView = nil
        window = nil
    }

    /// Sends one frame. The caller must already hold the gate; it is released when the page answers.
    func submit(rgba: Data, width: Int, height: Int, t: TimeInterval) {
        guard isReady, let webView else { gate.leave(); return }
        let number = frames.put(rgba)
        let script = "ensembleFrame(\(number), \(width), \(height), \(t))"
        webView.evaluateJavaScript(script) { [weak self] _, error in
            guard let error else { return }
            MainActor.assumeIsolated {
                self?.gate.leave()
                self?.onDiagnostic?("evaluateJavaScript failed: \(error.localizedDescription)")
            }
        }
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        handle(message.body)
    }

    private func handle(_ body: Any) {
        guard let m = body as? [String: Any] else { return }
        if let message = m["error"] as? String, m["t"] == nil {
            fail(message)
        } else if m["ready"] as? Bool == true {
            readyTimeout?.cancel()
            isReady = true
            gate.setOpen(true)
            onReady?(m["delegate"] as? String ?? "?")
        } else if let t = (m["t"] as? NSNumber)?.doubleValue {
            if let g = gate.leave(), EnsembleTrace.enabled {
                EnsembleTrace.write(t, "face gate held \(Int((g.held * 1000).rounded())) ms, frames skipped \(g.skipped)")
            }
            if let message = m["frameError"] as? String {
                consecutiveFrameErrors += 1
                onDiagnostic?("frame error: \(message)")
                if consecutiveFrameErrors >= 30 { fail("Face tracking failed repeatedly: \(message)") }
                return
            }
            consecutiveFrameErrors = 0
            let faces = (m["faces"] as? NSNumber)?.intValue ?? 0
            var position: HeadPosition?
            if let x = (m["x"] as? NSNumber)?.doubleValue, let y = (m["y"] as? NSNumber)?.doubleValue,
               let z = (m["z"] as? NSNumber)?.doubleValue {
                let p = HeadPosition(x: x, y: y, z: z)
                if p.isFinite { position = p }
            }
            onHead?(HeadObservation(t: t,
                                    yaw: (m["yaw"] as? NSNumber)?.doubleValue ?? 0,
                                    pitch: (m["pitch"] as? NSNumber)?.doubleValue ?? 0,
                                    faceCount: faces,
                                    position: position))
        } else if let note = m["log"] as? String {
            onDiagnostic?(note)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        if NetworkBlock.allowsNavigation(to: url) { return .allow }
        if webView === self.webView {
            fail("The face tracker page tried to open \(url?.scheme ?? "an unknown")://\(url?.host ?? "") and was stopped")
        }
        return .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail("The face tracker page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        fail("The face tracker page failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        fail("The face tracker's web content process ended")
    }
}

private final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
