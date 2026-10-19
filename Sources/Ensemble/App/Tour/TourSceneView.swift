import AppKit
import SwiftUI
import WebKit
import EnsembleCore

/// The scenes scene3d.js draws, by the names the page takes.
enum TourScene: String {
    case welcome, calibrate, dictate, send, scroll

    /// The headphone tab has no 3D scene: the app draws its illustration itself.
    init?(_ tab: TourGestureTab) {
        switch tab {
        case .dictate: self = .dictate
        case .send: self = .send
        case .scroll: self = .scroll
        case .headphones: return nil
        }
    }
}

/// Owns the tour's one WKWebView for a step. The page is bundled and reached only through `ensemble-asset://`;
/// like the face tracker it is never loaded before the network block list is installed, and any navigation off
/// the app's own scheme is cancelled. Nothing is stored (non-persistent data store) and no frame of video ever
/// reaches it: the page draws a scripted scene.
@MainActor
final class TourSceneController: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    /// True when the 3D page could not start (WebGL off, a file missing, the web process ended); the view then
    /// shows a plain still.
    @Published private(set) var failed = false

    /// The AppKit view SwiftUI hosts; the web view is added to it once the block list is ready.
    let container = NSView()

    private var scene: TourScene
    private let reducedMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var webView: WKWebView?
    private var pageReady = false
    private var pageScene: TourScene
    private var started = false
    private var readyTimeout: Task<Void, Never>?
    private static let readyTimeoutSeconds: UInt64 = 8

    init(scene: TourScene) {
        self.scene = scene
        self.pageScene = scene
        super.init()
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true
        container.layer?.backgroundColor = NSColor.white.cgColor
    }

    func start() {
        guard !started else { return }
        started = true
        readyTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.readyTimeoutSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.pageReady else { return }
            self.fail("the page did not become ready within \(Self.readyTimeoutSeconds) s")
        }
        Task { @MainActor [weak self] in
            do {
                let blockList = try await NetworkBlock.compile()
                self?.load(blockList: blockList)
            } catch {
                self?.fail("the network block could not be set up: \(error.localizedDescription)")
            }
        }
    }

    func setScene(_ new: TourScene) {
        guard new != scene else { return }
        scene = new
        if !pageReady { return }          // applied when the page reports ready
        apply(scene)
    }

    func stop() {
        readyTimeout?.cancel()
        readyTimeout = nil
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "tour")
        webView?.stopLoading()
        webView?.removeFromSuperview()
        webView = nil
        pageReady = false
        started = false
    }

    private func load(blockList: WKContentRuleList) {
        guard started, webView == nil else { return }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(blockList)
        config.setURLSchemeHandler(AssetSchemeHandler(), forURLScheme: AssetSchemeHandler.scheme)
        config.userContentController.add(WeakScriptHandler(self), name: "tour")
        let view = WKWebView(frame: container.bounds, configuration: config)
        view.autoresizingMask = [.width, .height]
        view.navigationDelegate = self
        container.addSubview(view)
        webView = view
        let query = "scene=\(scene.rawValue)&rm=\(reducedMotion ? 1 : 0)"
        pageScene = scene
        view.load(URLRequest(url: URL(string: "\(AssetSchemeHandler.scheme)://local/tour/tour.html?\(query)")!))
    }

    private func apply(_ scene: TourScene) {
        pageScene = scene
        webView?.evaluateJavaScript("EnsembleTour.setScene('\(scene.rawValue)')", completionHandler: nil)
    }

    private func fail(_ reason: String) {
        EnsembleLog.write("tour 3D scene unavailable: \(reason)")
        stop()
        failed = true
    }

    // MARK: WKScriptMessageHandler

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        if let reason = body["failed"] as? String {
            fail("the page reported \(reason)")
        } else if body["ready"] as? Bool == true {
            pageReady = true
            readyTimeout?.cancel()
            if pageScene != scene { apply(scene) }
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        NetworkBlock.allowsNavigation(to: navigationAction.request.url) ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        fail("the page failed to load: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        fail("the web content process ended")
    }
}

private struct TourSceneHost: NSViewRepresentable {
    let controller: TourSceneController
    func makeNSView(context: Context) -> NSView { controller.container }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// A tour illustration: the 3D scene, or a plain still with the step's text when 3D is unavailable. Content
/// drawn over the scene (the gestures step's hand inset) goes in `overlay`, inside the rounded clip.
struct TourSceneStage<Overlay: View>: View {
    @ObservedObject var controller: TourSceneController
    let symbol: String
    let caption: String
    private let overlay: Overlay

    init(controller: TourSceneController, symbol: String, caption: String, @ViewBuilder overlay: () -> Overlay) {
        self.controller = controller
        self.symbol = symbol
        self.caption = caption
        self.overlay = overlay()
    }

    var body: some View {
        ZStack {
            TourSceneHost(controller: controller)
            if controller.failed {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white)
                VStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Color.ensembleBlueInk)
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(Color.tourMuted)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            overlay
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color(red: 0.898, green: 0.898, blue: 0.898), lineWidth: 1))
        .onAppear { controller.start() }
        .onDisappear { controller.stop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }
}

extension TourSceneStage where Overlay == EmptyView {
    init(controller: TourSceneController, symbol: String, caption: String) {
        self.init(controller: controller, symbol: symbol, caption: caption) { EmptyView() }
    }
}
