import SwiftUI
import AVFoundation
import EnsembleCore

struct SettingsView: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    @ObservedObject var navigation: SettingsNavigation
    let calibrate: (CalibrationRequest) -> Void
    let removeSpot: (String) -> Void
    let replayTour: (TourStep?) -> Void

    var body: some View {
        TabView(selection: $navigation.tab) {
            GeneralSettings(state: state, settings: settings, updates: updates, replayTour: replayTour)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            ActionSettings(settings: settings)
                .tabItem { Label("Actions", systemImage: "bolt") }
                .tag(SettingsTab.actions)
            DisplaySettings(settings: settings)
                .tabItem { Label("Display", systemImage: "rectangle.on.rectangle") }
                .tag(SettingsTab.display)
            CalibrationSettings(state: state, settings: settings, calibrate: calibrate, removeSpot: removeSpot)
                .tabItem { Label("Calibration", systemImage: "scope") }
                .tag(SettingsTab.calibration)
            AboutSettings(updates: updates)
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(SettingsTab.about)
        }
        .frame(width: 540, height: 440)
    }
}

private struct GeneralSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    @ObservedObject var updates: UpdateController
    let replayTour: (TourStep?) -> Void
    @State private var tourStep: TourStep = .welcome

    var body: some View {
        Form {
            Section {
                Toggle("Enable Ensemble", isOn: $settings.enabled)
                Picker("Camera", selection: $settings.cameraName) {
                    ForEach(CameraChoices.rows(connected: state.cameraNames, chosen: settings.cameraName), id: \.name) {
                        Text($0.label).tag($0.name)
                    }
                }
                Toggle("Open at login (restarts after a crash)", isOn: Binding(get: { settings.launchAtLogin }, set: { settings.setLaunchAtLogin($0) }))
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Pause other audio while dictating", isOn: $settings.pauseMediaWhileDictating)
                Text("Only when the sound comes from speakers the microphone can hear; headphones are left alone.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Use another microphone when the lid is closed", isOn: $settings.useAnotherMicrophoneWhenLidClosed)
                Text("Before each dictation with the lid closed, the Mac's input moves to the webcam, a wired or a Bluetooth microphone, and goes back when the lid opens.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Pause after typing or mouse use") {
                    HStack {
                        Slider(value: $settings.pauseAfterInputSeconds, in: HandsBusy.quietRange, step: 0.5)
                            .frame(width: 160)
                        Text(String(format: "%.1f s", settings.pauseAfterInputSeconds))
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                Text("While you type, click, scroll or move the pointer, focus and the highlight hold; gestures still work.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Show the panel from anywhere", value: "⌥⌘K")
            }
            Section {
                Toggle("Update automatically", isOn: Binding(get: { updates.autoInstall }, set: { updates.setAutoInstall($0) }))
                    .disabled(!updates.isConfigured)
                LabeledContent(UpdateController.installedVersion) {
                    UpdateButton(updates: updates) { updates.checkForUpdates() }
                        .disabled(!updates.isConfigured)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("On: checks soon after launch and then every hour, and installs a new version by itself once you have been idle for 30 seconds (not dictating, sending, calibrating or in the tour); Ensemble reopens on its own. Off: nothing is checked until you press Check for Updates, which asks once before installing. \"Update to\" installs in one press.")
            }
            Section("Tour") {
                Button("Replay tour") { replayTour(nil) }
                Picker("One step", selection: $tourStep) {
                    ForEach(TourStep.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Button("Replay this step") { replayTour(tourStep) }
            }
        }
        .formStyle(.grouped)
    }
}

/// Settings, Actions: one row per thing Ensemble can do, with the action's own icon, and on the right the gesture
/// that does it. Talk and Scroll have one fixed gesture each (pinch twice, pinch and move); Send can be any pose
/// or off; the pose-held "Scroll up" and "Scroll down" are optional extras, off by default because pinch and move
/// already scrolls and a held pose would scroll whenever the hand happened to rest in that shape.
private struct ActionSettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section {
                ActionRow(symbol: GestureSlot.talk.actionSymbol, title: "Talk",
                          detail: "Starts dictation in the session you are facing; the same gesture stops it. One headphone press does the same.") {
                    FixedGesture(symbol: "hand.pinch", title: "Pinch twice")
                }
                ActionRow(symbol: GestureSlot.send.actionSymbol, title: "Send", detail: GestureSlot.send.detail) {
                    posePicker(for: .send)
                }
                LabeledContent("Hold to send") {
                    HStack {
                        Slider(value: $settings.sendCountdownSeconds, in: SettingsStore.countdownRange, step: 0.25)
                            .frame(width: 160)
                        Text(String(format: "%.1f s", settings.sendCountdownSeconds))
                            .monospacedDigit()
                            .frame(width: 46, alignment: .trailing)
                    }
                }
                .disabled(settings.mapping.send == nil)
                ActionRow(symbol: "arrow.up.and.down", title: "Scroll",
                          detail: "Pinch, then move your hand up or down. Let go quickly and it glides on; let go slowly and it stops.") {
                    FixedGesture(symbol: "hand.pinch", title: "Pinch and move")
                }
                Toggle("Reverse the scroll direction", isOn: $settings.reverseScroll)
            } footer: {
                Text(settings.reverseScroll
                     ? "Moving your pinch up scrolls toward earlier messages."
                     : "Moving your pinch up drags the page up, toward later messages, as your Mac scrolls.")
            }
            Section {
                ActionRow(symbol: "arrow.left.and.right", title: "Maximize session",
                          detail: "Hold a peace sign for about half a second: the session you face widens to the chat's default width, and the others in that window give up only the space that needs.") {
                    onOffPicker("Maximize session", gesture: "Peace sign", symbol: "hand.point.up.fill", isOn: $settings.maximizeByPeace)
                }
                ActionRow(symbol: "rectangle.split.3x1", title: "Even out sessions",
                          detail: "Make a peace sign and close the two fingers together quickly: every session in that window gets an equal share.") {
                    onOffPicker("Even out sessions", gesture: "Scissors", symbol: "scissors", isOn: $settings.evenOutByScissors)
                }
                Toggle("Fit the focused session to the chat width", isOn: $settings.fitFocusedSession)
            } header: {
                Text("Session widths")
            } footer: {
                Text(settings.mapping.usesTwoFingers
                     ? "Two fingers is set as another action's gesture above, so the peace sign and scissors do nothing until that changes."
                     : "Only with Claude in front and never while dictating or sending. Ensemble drags the dividers between sessions for you and puts the pointer back.")
                + Text(" A session narrower than Claude's chat column widens to just past it once you have looked at it for a moment, the room coming from the widest session beside it.")
            }
            Section {
                ActionRow(symbol: GestureSlot.scrollUp.actionSymbol, title: "Scroll up", detail: GestureSlot.scrollUp.detail) {
                    posePicker(for: .scrollUp)
                }
                ActionRow(symbol: GestureSlot.scrollDown.actionSymbol, title: "Scroll down", detail: GestureSlot.scrollDown.detail) {
                    posePicker(for: .scrollDown)
                }
            } header: {
                Text("Other ways to scroll")
            } footer: {
                Text("Pinch and move already scrolls, so these are off unless you also want a held gesture for each direction. Each gesture does one thing: picking one in use swaps it with that action.")
            }
            Section {
                Toggle("Warn when my look leaves Claude", isOn: $settings.warnWhenLeavingClaude)
            } footer: {
                Text("While dictating, the edge you are looking toward glows amber if what lies beyond it is not a Claude session. Looking toward another Claude session is always shown.")
            }
            Section {
                Toggle("Headphone presses", isOn: $settings.headphonePresses)
            } footer: {
                Text("One press starts or stops dictation in the session you look at. Two presses send.")
            }
        }
        .formStyle(.grouped)
    }

    private func onOffPicker(_ title: String, gesture: String, symbol: String, isOn: Binding<Bool>) -> some View {
        Picker(title, selection: isOn) {
            Text("Off").tag(false)
            Label(gesture, systemImage: symbol).tag(true)
        }
        .labelsHidden()
        .frame(width: 170)
    }

    private func posePicker(for slot: GestureSlot) -> some View {
        Picker(slot.title, selection: Binding(
            get: { settings.mapping[slot] },
            set: { settings.assign($0, to: slot) }
        )) {
            if slot.allowsOff { Text("Off").tag(Pose?.none) }
            ForEach(Pose.allCases, id: \.self) { Label($0.title, systemImage: $0.symbolName).tag(Pose?.some($0)) }
        }
        .labelsHidden()
        .frame(width: 170)
    }
}

/// A gesture that cannot be changed, shown where the other rows have their picker.
private struct FixedGesture: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .foregroundStyle(.secondary)
            .frame(width: 170, alignment: .leading)
    }
}

private struct ActionRow<Control: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 38, height: 38)
                .glassSurface(RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            control()
        }
        .padding(.vertical, 2)
    }
}

private struct DisplaySettings: View {
    @ObservedObject var settings: SettingsStore

    var body: some View {
        Form {
            Section("Overlay") {
                Toggle("Show nose dot", isOn: $settings.showNoseDot)
                Toggle("Highlight the session you face", isOn: $settings.showHighlight)
                LabeledContent("Pointer smoothing") {
                    HStack {
                        Text("Quick").font(.caption).foregroundStyle(.secondary)
                        Slider(value: $settings.pointerSmoothing, in: 0...1)
                            .frame(width: 160)
                        Text("Steady").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("Correct for where I sit", isOn: $settings.correctForPosition)
                Text(settings.correctForPosition
                     ? "Pointing follows your nose even after you slide along the desk. Needs a calibration made with this version; older ones keep pointing by angle alone until you recalibrate."
                     : "Pointing uses only the angle of your head, so recalibrate after you move your seat.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Listening indicator") {
                Toggle("Live sound bars (asks for microphone access)", isOn: Binding(get: { settings.liveSoundBars }, set: { on in
                    settings.liveSoundBars = on
                    if on, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    }
                }))
                Text(settings.liveSoundBars
                     ? "The bars follow how loudly you speak. Audio is never recorded, stored or sent."
                     : "A blinking microphone shows Claude is listening. Ensemble never uses the microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct CalibrationSettings: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: SettingsStore
    let calibrate: (CalibrationRequest) -> Void
    let removeSpot: (String) -> Void
    @State private var removing: CalibrationSpotSummary?

    var body: some View {
        Form {
            if !state.screenChoices.isEmpty {
                Section {
                    ScreenArrangementView(screens: state.screenChoices, spotInUse: state.spotInUse, calibrating: state.calibrating,
                                          width: 440, maxHeight: 150, recalibrate: { calibrate(.screen($0)) })
                        .padding(.vertical, 4)
                    ForEach(state.screenChoices) { screen in
                        HStack {
                            Label(screen.name, systemImage: screen.isMain ? "menubar.rectangle" : "display")
                            Spacer(minLength: 8)
                            Text(ScreenArrangementView.calibrationLabel(screen, spotInUse: state.spotInUse)).font(.caption).foregroundStyle(screen.calibrated ? Color.secondary : Color.orange)
                            Button("Recalibrate") { calibrate(.screen(screen.id)) }
                                .disabled(state.calibrating)
                        }
                    }
                } header: {
                    Text("Screens")
                } footer: {
                    Text("Arranged as macOS has them. Click a screen, or its Recalibrate button, to redo only that one; the others keep theirs.")
                }
            }
            Section {
                LabeledContent("Last calibrated") {
                    if let date = settings.calibratedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Text("Never").foregroundStyle(.secondary)
                    }
                }
                Button(state.screenChoices.count > 1 ? "Calibrate all screens…" : "Calibrate…") { calibrate(.recalibrate) }
                    .disabled(state.calibrating)
                    .ensembleButtonStyle(prominent: true)
            } footer: {
                Text("A dot visits five points on each screen. Point your nose at it and keep your head still. Redo this if you move your screen or camera.")
            }
            Section {
                ForEach(state.calibrationSpots) { spot in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spot.name)
                            Text(spot.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if state.calibrationSpots.count > 1, spot.id == state.spotInUse {
                            Text("In use").font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Remove") { removing = spot }
                            .disabled(state.calibrationSpots.count < 2 || state.calibrating)
                    }
                }
                Button("Add position…") { calibrate(.newPosition) }
                    .disabled(state.calibrating || state.calibrationSpots.isEmpty)
            } header: {
                Text("Positions")
            } footer: {
                Text("Calibrate again from another place, such as standing or leaning back, and keep the ones you have. Ensemble uses the position closest to where your head is. Calibrate above redoes the one in use.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(removing?.name ?? "this position")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove", role: .destructive) {
                if let id = removing?.id { removeSpot(id) }
                removing = nil
            }
        } message: {
            Text("Its calibration is deleted. The other positions keep working.")
        }
    }
}

private struct AboutSettings: View {
    @ObservedObject var updates: UpdateController

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("Ensemble").font(.title.weight(.semibold))
            Text(UpdateController.installedVersion).font(.callout).foregroundStyle(.secondary)
            Text("Hands-free control for Claude on your Mac. Video is analysed on this Mac and never stored or sent.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            VStack(alignment: .leading, spacing: 6) {
                credit("MediaPipe", "Face landmarks. Apache-2.0, Google.")
                credit("Sleight", "Hand-pose rules. MIT, Florian Riquelme.")
                credit("claude-dictation-hotkey", "Dictation approach. MIT.")
                credit("Sparkle", "Updates. MIT, Sparkle Project.")
            }
            .padding(14)
            .frame(maxWidth: 400, alignment: .leading)
            .glassSurface(RoundedRectangle(cornerRadius: 16, style: .continuous))
            UpdateButton(updates: updates) { updates.checkForUpdates() }
            Spacer(minLength: 0)
        }
        .padding(.top, 24)
        .frame(maxWidth: .infinity)
    }

    private func credit(_ name: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).font(.callout.weight(.semibold))
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}
