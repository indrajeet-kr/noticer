import SwiftUI

/// Home while running. One focal point: the status orb with the status word.
/// A 1 s tick keeps the head-start countdown and recency windows live
/// between pipeline steps.
struct LiveSessionView: View {
    @Bindable var model: PhoneSessionModel
    @State private var showingAsk = false

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollView {
                    VStack(spacing: Theme.Space.s24) {
                        statusStrip
                        SessionStatusHero(status: model.sessionStatus)
                        if !model.notices.isEmpty {
                            notices
                        }
                        if let runError = model.runError {
                            Text(runError)
                                .font(Theme.Font.body)
                                .foregroundStyle(Theme.cue)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        controls
                        quickTiming
                        DevPanel(lines: devLines)
                    }
                    .screenMargins()
                    .padding(.top, Theme.Space.s16)
                    .padding(.bottom, Theme.Space.s32)
                }
            }
            .ambientScreen()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingAsk = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Ask about settings")
            }
        }
        .sheet(isPresented: $showingAsk) {
            AskSettingsView(model: model)
        }
    }

    // MARK: - Status strip

    private var statusStrip: some View {
        HStack(spacing: Theme.Space.s8) {
            StatusCapsule(
                systemImage: "battery.50",
                text: "Glasses \(model.dat.battery)"
            )
            StatusCapsule(
                systemImage: thermalSymbol,
                text: thermalWord
            )
            StatusCapsule(
                systemImage: "wifi",
                text: model.dat.stream
            )
            Spacer()
        }
    }

    private var thermalSymbol: String {
        switch model.dat.thermal.lowercased() {
        case let text where text.contains("serious"), let text where text.contains("critical"):
            return "thermometer.high"
        case let text where text.contains("fair"):
            return "thermometer.medium"
        default:
            return "thermometer.low"
        }
    }

    private var thermalWord: String {
        model.dat.thermal == "—" ? "Normal" : model.dat.thermal
    }

    // MARK: - Notices

    private var notices: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            ForEach(model.notices, id: \.self) { notice in
                Text(notice)
                    .font(Theme.Font.body)
                    .padding(Theme.Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.noticed.opacity(0.18), in: Theme.Radius.rect(Theme.Radius.row))
            }
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: Theme.Space.s12) {
            Button(model.isRunning ? "Stop" : "Start") {
                if model.isRunning {
                    model.stop()
                } else {
                    model.mode = .live
                    model.start()
                }
            }
            .buttonStyle(.primaryCapsule)
            .disabled(!model.canStart)
            .sensoryFeedback(.selection, trigger: model.isRunning)

            if case .cue = model.sessionStatus {
                Button("Dismiss cue") {
                    model.dismissCue()
                }
                .buttonStyle(.ghostCapsule)
            }
            if model.dat.needsResume {
                Button("Resume glasses") {
                    model.resumeGlasses()
                }
                .buttonStyle(.primaryCapsule)
            }
            if model.registration != "Registered" {
                Button("Register with Meta AI") {
                    model.registerGlasses()
                }
                .buttonStyle(.ghostCapsule)
                .disabled(!model.configured || model.isRunning)
            }
        }
    }

    // MARK: - Quick timing

    private var quickTiming: some View {
        GlassCard {
            Toggle(isOn: Binding(
                get: { model.quickTiming },
                set: { model.setQuickTiming($0) }
            )) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("Quick timing")
                        .font(Theme.Font.headline)
                    Text("Shorter head start for testing and demos")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .tint(Theme.gotIt)
            .disabled(model.isRunning)
        }
        .sensoryFeedback(.selection, trigger: model.quickTiming)
    }

    // MARK: - Dev lines

    private var devLines: [String] {
        [
            "frames seen \(model.framesSeen) · passed \(model.framesPassed)",
            "model calls \(model.modelCalls)",
            "meta: \(model.toolLine)",
            "gate: \(model.gateLine)",
            "cue: \(model.cueLine)",
            "mastery: \(model.masteryLine)",
            "headstart: \(model.headStartLine)",
            SessionTelemetry.droppedLine(model.liveDroppedNeedIDs),
            model.timingLine,
        ]
    }
}

#Preview("Live") {
    LiveSessionView(model: PhoneSessionModel())
}

#Preview("Live (light, AX)") {
    LiveSessionView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
