import AppKit
import EnsembleCore
import Foundation

/// PostHog's project token. It is write-only and PostHog documents it as safe to ship in a public app: it can add
/// events to the project and read nothing. An empty string turns the reporter off. Rotation: docs/telemetry.md.
private let usageWriteKey = "phc_BGLN5bXDwYbwdzkzci7L2tNbyWXtUfwokDRhP6TG5w2Q"

/// The one place the app sends usage. PostHog Cloud US today; moving to EU is this line and the host in
/// scripts/check-network.sh.
private let usageCaptureURL = URL(string: "https://us.i.posthog.com/i/v0/e/")!

/// Sends the anonymous daily summary (docs/telemetry.md) by plain HTTPS, with no SDK. This is the only file allowed to
/// use URLSession (scripts/check-network.sh). The payload and the key are never logged.
@MainActor
final class UsageReporter {
    static var isConfigured: Bool { !usageWriteKey.isEmpty }

    private let tracker: UsageTracker
    private var timer: Timer?
    private var sending = false
    private let session: URLSession = {
        // No cookies, no cache, no credentials stored: a request carries the body and nothing else.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    init(tracker: UsageTracker) { self.tracker = tracker }

    /// Checks at launch, when the day rolls over, and then hourly while the app runs.
    func start() {
        check()
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(force: true) }
        }
        let t = Timer(timeInterval: UsagePolicy.checkInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// The exact request body for the current day so far, for Settings.
    func previewJSON() -> String {
        guard let data = try? tracker.requestBody(for: tracker.todaySoFar, writeKey: usageWriteKey, preview: true) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    private func check(force: Bool = false) {
        guard Self.isConfigured, !sending else { return }
        let days = tracker.daysToSend(force: force)
        guard !days.isEmpty else { return }
        sending = true
        Task { @MainActor in
            defer { self.sending = false }
            // Oldest first; the first failure stops the run and the rest wait for the next check.
            for day in days {
                guard self.tracker.sharing, let body = try? self.tracker.requestBody(for: day, writeKey: usageWriteKey),
                      await self.post(body) else { return }
                self.tracker.markSent(day.day)
            }
        }
    }

    private func post(_ body: Data) async -> Bool {
        var request = URLRequest(url: usageCaptureURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await session.data(for: request), let http = response as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }
}
