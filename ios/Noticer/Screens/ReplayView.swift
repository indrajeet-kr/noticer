import SwiftUI

/// Replay: a scenario or clip picker plus the same session view as Live,
/// with a scrubber, transport, and state markers. The "Replay" chip keeps
/// it distinct from live at a glance.
struct ReplayView: View {
    @Bindable var model: PhoneSessionModel
    @State private var controller = ReplayController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s24) {
                header
                picker
                if controller.isLoading {
                    loadingRow
                }
                if let loadError = controller.loadError {
                    Text(loadError)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.cue)
                }
                if !controller.notices.isEmpty {
                    notices
                }
                if !controller.frames.isEmpty {
                    player
                    DevPanel(lines: controller.currentDevLines)
                }
            }
            .screenMargins()
            .padding(.top, Theme.Space.s16)
            .padding(.bottom, Theme.Space.s32)
        }
        .ambientScreen()
        .onAppear {
            controller.reload()
            selectFirstIfNeeded()
        }
    }

    // MARK: - Header and picker

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s4) {
            HStack {
                Text("Replay")
                    .font(Theme.Font.statusWord)
                Spacer()
                StatusCapsule(systemImage: "arrow.counterclockwise", text: "Replay", tint: Theme.accentWarm)
            }
            Text("Pick a recorded scenario.")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var picker: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            if !controller.scenarios.isEmpty {
                Text("Scenarios")
                    .font(Theme.Font.headline)
                ForEach(controller.scenarios) { scenario in
                    replayRow(
                        id: "scenario:\(scenario.scenarioID)",
                        title: scenario.summary.isEmpty ? scenario.scenarioID : scenario.summary,
                        detail: durationString(scenario.until)
                    )
                }
            }
            if !controller.clips.isEmpty {
                Text("Clips")
                    .font(Theme.Font.headline)
                    .padding(.top, Theme.Space.s8)
                ForEach(controller.clips, id: \.self) { url in
                    replayRow(
                        id: "clip:\(url.lastPathComponent)",
                        title: url.deletingPathExtension().lastPathComponent,
                        detail: "clip"
                    )
                }
            }
            if controller.options.isEmpty {
                Text("No scenario in fixtures/scenarios, and no clip in fixtures/clips.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func replayRow(id: String, title: String, detail: String) -> some View {
        let selected = controller.selectedID == id
        let traits: AccessibilityTraits = selected ? [.isButton, .isSelected] : .isButton
        return Button {
            controller.select(id, timing: model.timing, needs: model.needsForSession())
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text(title)
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textPrimary)
                    Text(detail)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accentWarm)
                }
            }
            .padding(Theme.Space.card)
            .background(Theme.bgElevated)
            .overlay(
                Theme.Radius.rect(Theme.Radius.card)
                    .stroke(selected ? Theme.accentWarm : Theme.textPrimary.opacity(0.1), lineWidth: 1)
            )
            .clipShape(Theme.Radius.rect(Theme.Radius.card))
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(traits)
    }

    private var loadingRow: some View {
        HStack {
            ThinkingDots()
            Spacer()
        }
    }

    private var notices: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s8) {
            ForEach(controller.notices, id: \.self) { notice in
                Text(notice)
                    .font(Theme.Font.body)
                    .padding(Theme.Space.s12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.noticed.opacity(0.18), in: Theme.Radius.rect(Theme.Radius.row))
            }
        }
    }

    // MARK: - Player

    private var player: some View {
        GlassCard {
            VStack(spacing: Theme.Space.s16) {
                SessionStatusHero(status: controller.currentStatus, orbSize: 130)
                ReplayScrubber(
                    fraction: controller.fraction,
                    elapsed: controller.elapsed,
                    total: controller.duration,
                    markers: controller.markers,
                    isPlaying: controller.isPlaying,
                    onScrub: { controller.seek($0) },
                    onPlayPause: { controller.togglePlay() },
                    onSkip: { controller.skip($0) }
                )
            }
        }
    }

    // MARK: - Helpers

    private func selectFirstIfNeeded() {
        if controller.selectedID.isEmpty, let first = controller.options.first {
            controller.select(first.id, timing: model.timing, needs: model.needsForSession())
        } else if !controller.selectedID.isEmpty, controller.frames.isEmpty, !controller.isLoading {
            controller.select(controller.selectedID, timing: model.timing, needs: model.needsForSession())
        }
    }

    private func durationString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

#Preview("Replay") {
    ReplayView(model: PhoneSessionModel())
}

#Preview("Replay (light, AX)") {
    ReplayView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
