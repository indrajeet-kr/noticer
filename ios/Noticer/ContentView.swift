import SwiftUI
import UIKit
import NoticerCore

/// The phone sits on the counter with the screen on. Streaming pauses if the app leaves the foreground.
struct ContentView: View {
    @Bindable var model: PhoneSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var apiKeyDraft = ""
    @State private var keyMessage: String?
    @FocusState private var focusedNeedField: NeedField?

    private enum NeedField: Hashable {
        case words(UUID)
        case whisper(UUID)

        var uiID: UUID {
            switch self {
            case .words(let id), .whisper(let id):
                return id
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !model.notices.isEmpty {
                    notices
                }
                status
                modePicker
                controls
                apiKey
                needEditor
            }
            .padding(20)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            model.reloadLibrary()
            model.refreshKeyStatus()
            updateIdleTimer()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onChange(of: scenePhase) { _, phase in
            Task {
                await model.setForeground(phase == .active)
            }
            updateIdleTimer()
        }
        .onChange(of: model.keepsScreenOn) { _, _ in
            updateIdleTimer()
        }
        .onChange(of: model.needs) { _, _ in
            model.saveNeeds()
        }
        .onChange(of: focusedNeedField) { previous, current in
            guard let previous, previous.uiID != current?.uiID else {
                return
            }
            guard model.needs.contains(where: { $0.uiID == previous.uiID }) else {
                return
            }
            model.nameNeed(uiID: previous.uiID)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Noticer")
                .font(.largeTitle.bold())
            Text("Leave this phone face up. The session pauses if you leave the app.")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(model.notices, id: \.self) { notice in
                Text(notice)
                    .font(.body)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.phase)
                .font(.title2.bold())
            if let runError = model.runError {
                Text(runError)
                    .foregroundStyle(.orange)
            }
            Text(model.registration)
            Text("Glasses \(model.dat.deviceType) · battery \(model.dat.battery) · thermal \(model.dat.thermal) · hinge \(model.dat.hinge)")
            Text("Stream \(model.dat.stream)")
            Text("Frames \(model.framesSeen) seen, \(model.framesPassed) passed")
            Text("Model calls \(model.modelCalls)")
            Text(model.gateLine)
            Text(model.toolLine)
            Text(model.cueLine)
            Text(model.headStartLine)
            Text(model.masteryLine)
            Text("A cue waits out the head start. Replay scenarios jump the clock, so you do not wait 90 seconds.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .font(.body)
    }

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Mode", selection: $model.mode) {
                ForEach(CaptureMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(model.isRunning)
            if model.mode == .replay {
                if model.replayOptions.isEmpty {
                    Text("No scenario in fixtures/scenarios, and no clip in fixtures/clips.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Replay", selection: $model.selectedReplayID) {
                        ForEach(model.replayOptions) { option in
                            Text(option.label).tag(option.id)
                        }
                    }
                    .disabled(model.isRunning)
                    Text("Scenarios need no account and no glasses. A clip still runs the same pipeline.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Button(model.isRunning ? "Stop" : "Start") {
                    if model.isRunning {
                        model.stop()
                    } else {
                        model.start()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canStart)
                Button("Dismiss cue") {
                    model.dismissCue()
                }
                .buttonStyle(.bordered)
            }
            if model.mode == .live {
                Button("Register with Meta AI") {
                    model.registerGlasses()
                }
                .buttonStyle(.bordered)
                .disabled(!model.configured || model.isRunning)
                if model.dat.needsResume {
                    Button("Resume glasses") {
                        model.resumeGlasses()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var apiKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Meta Model API key")
                .font(.headline)
            Text(model.keyStatus)
                .foregroundStyle(.secondary)
            SecureField("Key", text: $apiKeyDraft)
                .textFieldStyle(.roundedBorder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            HStack {
                Button("Save to Keychain") {
                    saveKey()
                }
                .buttonStyle(.bordered)
                Button("Remove key") {
                    removeKey()
                }
                .buttonStyle(.bordered)
            }
            if let keyMessage {
                Text(keyMessage)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var needEditor: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mom's list")
                .font(.headline)
            Text("Up to \(SessionLimits.maxAuthoredNeeds). Write what she needs in her own words. Leave the whisper blank to say that same line.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            ForEach($model.needs, id: \.uiID) { $need in
                VStack(alignment: .leading, spacing: 8) {
                    TextField("What she needs", text: $need.authorText, axis: .vertical)
                        .focused($focusedNeedField, equals: .words(need.uiID))
                        .textInputAutocapitalization(.sentences)
                    TextField("What to whisper, if it should differ", text: $need.cueWording, axis: .vertical)
                        .focused($focusedNeedField, equals: .whisper(need.uiID))
                        .textInputAutocapitalization(.sentences)
                    Stepper("Priority \(need.priority)", value: $need.priority, in: 0...5)
                    Toggle("Allow a check-in if a re-check is inconclusive", isOn: $need.allowsCheckIn)
                    Button("Remove") {
                        let uiID = need.uiID
                        focusedNeedField = nil
                        Task { @MainActor in
                            model.deleteNeed(uiID: uiID)
                        }
                    }
                    .foregroundStyle(.red)
                }
                .padding(12)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Add need") {
                model.addNeed()
            }
            .buttonStyle(.bordered)
            .disabled(model.needs.count >= SessionLimits.maxAuthoredNeeds)
        }
        .textFieldStyle(.roundedBorder)
    }

    private func saveKey() {
        do {
            try ModelKeyStore.save(apiKeyDraft)
            apiKeyDraft = ""
            keyMessage = "Saved."
            model.refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    private func removeKey() {
        do {
            try ModelKeyStore.clear()
            apiKeyDraft = ""
            keyMessage = "Removed."
            model.refreshKeyStatus()
        } catch {
            keyMessage = error.localizedDescription
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = model.keepsScreenOn && scenePhase == .active
    }
}

#Preview {
    ContentView(model: PhoneSessionModel())
}
