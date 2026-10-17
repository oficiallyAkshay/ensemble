import SwiftUI

/// Step 4: three cards. Camera and Accessibility can each be granted here, or sent to System Settings when
/// macOS will not ask again; Microphone is shown struck out, because Ensemble never asks for it.
struct TourPermissionsStep: View {
    @ObservedObject var model: TourModel

    var body: some View {
        VStack(spacing: 26) {
            Text("Permissions").font(.largeTitle.weight(.semibold))
            VStack(spacing: 14) {
                cameraCard
                card(symbol: "accessibility", title: "Accessibility", granted: model.accessibilityGranted,
                     detail: "Presses Claude's own dictation, Send and scroll controls. Turn Ensemble on in the list that opens.",
                     action: model.accessibilityGranted ? nil : (title: "Grant\u{2026}", perform: model.requestAccessibility))
                microphoneCard
            }
            .frame(maxWidth: 480)
            Spacer(minLength: 0)
        }
    }

    /// Three states: not asked (a button that shows macOS's prompt), denied (macOS will not ask again, so the
    /// only way is the Settings list), granted.
    @ViewBuilder private var cameraCard: some View {
        switch model.cameraAccess {
        case .granted:
            card(symbol: "camera.fill", title: "Camera", granted: true, detail: "Reads your head and hands. Frames are never saved or sent.")
        case .notAsked:
            card(symbol: "camera.fill", title: "Camera", granted: false, detail: "Reads your head and hands. Frames are never saved or sent.",
                 action: (title: "Allow\u{2026}", perform: Permissions.requestCamera))
        case .denied:
            card(symbol: "camera.fill", title: "Camera", granted: false,
                 detail: "Camera access was turned off. Turn Ensemble on in the Camera list, then press Still stuck?, then Restart Ensemble, in the menu bar panel.",
                 action: (title: "Open Settings", perform: { Permissions.openSettings(for: "Camera") }))
        }
    }

    private func card(symbol: String, title: String, granted: Bool, detail: String,
                       action: (title: String, perform: () -> Void)? = nil) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol).font(.system(size: 20)).frame(width: 34)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(Color.tourMuted)
            }
            Spacer(minLength: 12)
            if let action {
                Button(action.title, action: action.perform).ensembleButtonStyle(prominent: true)
            } else {
                Label(granted ? "Granted" : "Not yet", systemImage: granted ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(granted ? .green : .secondary)
                    .animation(.smooth(duration: 0.3), value: granted)
            }
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var microphoneCard: some View {
        HStack(spacing: 14) {
            Image(systemName: "mic.slash.fill").font(.system(size: 20)).frame(width: 34).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Microphone").font(.headline).strikethrough().foregroundStyle(.secondary)
                Text("Not needed: Claude does the listening.").font(.caption).foregroundStyle(Color.tourMuted)
            }
            Spacer(minLength: 12)
        }
        .padding(14)
        .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(0.55)
    }
}
