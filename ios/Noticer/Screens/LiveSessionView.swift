import SwiftUI

/// Tonight: a serif title above one big centered circle, with nothing
/// competing. A 1 s tick keeps the head-start countdown and recency windows
/// live between pipeline steps.
struct LiveSessionView: View {
    @Bindable var model: PhoneSessionModel
    var onWins: () -> Void = {}

    @State private var path = NavigationPath()
    @AppStorage("noticer.demo.mode") private var demoSettingOn = false

    /// Demo strip shows while a demo session runs, and after stop while its
    /// rows remain and the setting is still on. Off means off: nothing extra
    /// enters the hierarchy.
    private var showDemoStrip: Bool {
        model.demoModeActive || (!model.demoStrip.items.isEmpty && demoSettingOn)
    }

    var body: some View {
        NavigationStack(path: $path) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: Theme.Space.sectionGap) {
                            header
                            deviceRow
                            circleSection
                            if showDemoStrip {
                                DemoLiveStrip(
                                    items: model.demoStrip.visibleItems(),
                                    chip: model.demoChip,
                                    relative: { model.demoStrip.relativeTime($0) }
                                )
                                // Keeps the newest strip row above the tab bar:
                                // scrolling this tail to the bottom lands the
                                // strip exactly clear of it. Off means off.
                                Color.clear
                                    .frame(height: 96)
                                    .id("demoStripTail")
                            }
                            if model.runError != nil || !model.notices.isEmpty {
                                attentionCard
                            }
                            TonightTimeline(
                                moments: model.tonightMoments,
                                isRunning: model.isRunning,
                                wordsForMoment: { model.momentWords(for: $0) }
                            )
                            quickTiming
                            auxiliaryActions
                        }
                        .screenMargins()
                        .padding(.top, Theme.Space.s16)
                        .padding(.bottom, Theme.Space.s32)
                    }
                    .contentMargins(.bottom, 96, for: .scrollContent)
                    .onChange(of: model.demoStrip.items.map(\.id)) { _, _ in
                        guard showDemoStrip else { return }
                        proxy.scrollTo("demoStripTail", anchor: .bottom)
                    }
                }
            }
            .ambientScreen()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    TabTopMenu(onWins: onWins) { destination in
                        path.append(destination)
                    }
                }
            }
            .tabMenuDestinations(model: model)
        }
    }

    // MARK: - Header and device row

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            Text("Tonight")
                .font(Theme.Font.display)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        }
        .accessibilityElement(children: .combine)
    }

    /// Oura-style device row. Battery appears only when the data is real —
    /// never faked; the "82%" sample lives in `#Preview` only.
    private var deviceRow: some View {
        HStack(spacing: Theme.Space.s4) {
            Text("Ray-Ban Meta")
                .foregroundStyle(Theme.textSecondary)
            Text("·")
                .foregroundStyle(Theme.textSecondary)
            Text(linkWord)
                .foregroundStyle(linkColor)
            if model.dat.battery != "—" {
                Text("· battery \(model.dat.battery)")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .font(Theme.Font.footnote)
        .padding(.horizontal, Theme.Space.s16)
        .padding(.vertical, Theme.Space.s12)
        .background(Theme.bgSubtle, in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(deviceAccessibilityText)
    }

    private var linkWord: String {
        switch model.glassesLink {
        case .connected:
            return "Connected"
        case .unknown:
            return "Looking…"
        case .none, .notConnected:
            return "Not connected"
        }
    }

    private var linkColor: Color {
        switch model.glassesLink {
        case .connected:
            return Theme.sage
        case .unknown:
            return Theme.textSecondary
        case .none, .notConnected:
            return Theme.terracotta
        }
    }

    private var deviceAccessibilityText: String {
        var text = "Ray-Ban Meta, \(linkWord)"
        if model.dat.battery != "—" {
            text += ", battery \(model.dat.battery)"
        }
        return text
    }

    // MARK: - Circle

    private var circleSection: some View {
        VStack(spacing: Theme.Space.s16) {
            // About 64% of a phone's content width; smaller while the demo
            // strip shows so everything fits without scrolling.
            SessionCircle(status: model.sessionStatus, size: showDemoStrip ? 180 : 240) {
                guard !model.isRunning else {
                    return
                }
                model.mode = .live
                model.start()
            }
            .frame(maxWidth: .infinity, alignment: .center)
            Text(SessionCircleWords.text(for: model.sessionStatus))
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            if model.isRunning {
                Button("Stop") {
                    model.stop()
                }
                .font(Theme.Font.headline)
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
        }
    }

    // MARK: - Attention, timeline extras, timing

    private var attentionCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            if let runError = model.runError {
                Text(runError)
                    .font(Theme.Font.body)
            }
            ForEach(model.notices, id: \.self) { notice in
                Text(notice)
                    .font(Theme.Font.footnote)
            }
        }
        .foregroundStyle(Theme.terracottaText)
        .padding(Theme.Space.s12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.terracottaTile, in: Theme.Radius.rect(Theme.Radius.row))
        .accessibilityElement(children: .combine)
    }

    private var quickTiming: some View {
        GlassCard(padding: Theme.Space.card) {
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
            .tint(Theme.sage)
            .disabled(model.isRunning)
        }
        .sensoryFeedback(.selection, trigger: model.quickTiming)
    }

    @ViewBuilder
    private var auxiliaryActions: some View {
        if model.dat.needsResume {
            Button("Resume glasses") {
                model.resumeGlasses()
            }
            .buttonStyle(.ghostCapsule)
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

#Preview("Tonight") {
    LiveSessionView(model: PhoneSessionModel())
}

#Preview("Tonight (night, AX)") {
    LiveSessionView(model: PhoneSessionModel())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}

#Preview("Tonight with samples") {
    TonightSamplePreview()
}

#if DEBUG
/// Preview-only sample data: battery and moments are set here so screenshots
/// show a lived-in Tonight. Production never fakes these values.
private struct TonightSamplePreview: View {
    @State private var model = PhoneSessionModel()

    var body: some View {
        LiveSessionView(model: model)
            .onAppear {
                model.dat.battery = "82%"
                model.moments = [
                    SessionMoment(
                        at: Date().addingTimeInterval(-3600),
                        needID: "take-baby",
                        kind: .selfNotice,
                        text: "eating one-handed, take the baby"
                    ),
                    SessionMoment(
                        at: Date().addingTimeInterval(-1800),
                        needID: "refill-water",
                        kind: .cued,
                        text: "nursing, no water"
                    ),
                ]
            }
    }
}
#endif
