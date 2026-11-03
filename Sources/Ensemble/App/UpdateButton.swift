import SwiftUI

/// The one update button, used everywhere updates appear: "Check for Updates", "Update to x.y.z" once a check (the
/// user's or an automatic one) finds a version (one press installs it end to end), "Installing x.y.z..." or "Installs
/// x.y.z when you finish" while an install runs or waits, "Downloading x.y.z (42%)" during the download, "Update failed.
/// Retry" after a failure, and "Up to date" for a few seconds after a check finds nothing. A spinner shows exactly while a
/// check, download or install runs. Its title changes on the app's smooth spring, never instantly.
struct UpdateButton: View {
    @ObservedObject var updates: UpdateController
    var fillsWidth = false
    let action: () -> Void

    var body: some View {
        let state = updates.buttonState
        Button(action: action) {
            HStack(spacing: 6) {
                if state.spinning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol)
                }
                Text(state.title)
            }
            .contentTransition(.opacity)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .animation(.smooth(duration: 0.4), value: state.title)
    }

    private var symbol: String {
        if updates.installingVersion != nil { return "hourglass" }
        if updates.failed { return "exclamationmark.triangle" }
        if updates.availableVersion != nil { return "arrow.down.circle.fill" }
        return updates.showingUpToDate ? "checkmark.circle" : "arrow.down.circle"
    }
}
