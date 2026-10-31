import Charts
import NoticerCore
import SwiftUI

/// You're learning: stats labeled in words. Per-need fading rows, a week of
/// session dots, cue bars from real history, and a short fading explainer.
/// Never shows fake numbers — samples live in `#Preview` only.
struct LearningView: View {
    @Bindable var model: PhoneSessionModel
    var onWins: () -> Void = {}
    /// Preview-only history override; production always reads the store.
    var sampleHistory: [String: Int]?

    @State private var path = NavigationPath()
    @State private var range = CueRange.day

    private var history: [String: Int] {
        sampleHistory ?? CueHistoryStore.load()
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.sectionGap) {
                    VStack(alignment: .leading, spacing: Theme.Space.s4) {
                        Text("You're learning")
                            .font(Theme.Font.display)
                        Text("Support fades as he notices on his own.")
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .accessibilityElement(children: .combine)
                    .padding(.top, Theme.Space.s16)

                    needsCard
                    weekCard
                    cuesCard
                    fadingExplainer
                }
                .screenMargins()
                .padding(.bottom, Theme.Space.s32)
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

    // MARK: - Per-need rows

    private var needsCard: some View {
        GlassCard(padding: Theme.Space.card) {
            if model.needs.isEmpty {
                Text("No needs yet — her list is empty.")
                    .font(Theme.Font.headline)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.needs, id: \.uiID) { need in
                        needRow(for: need)
                        if need.uiID != model.needs.last?.uiID {
                            Divider().background(Theme.textPrimary.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private func needRow(for need: Need) -> some View {
        let word = phaseWord(for: need)
        let caption = catchCaption(for: need)
        let percent = Int((need.mastery.score * 100).rounded())
        let words = need.authorText.isEmpty ? need.id : need.authorText
        return HStack(spacing: Theme.Space.s16) {
            MasteryRing(
                score: need.mastery.score,
                quiet: need.mastery.phase != .coaching,
                retired: need.mastery.phase == .retired,
                size: 56,
                accessibilityText: "\(words), \(word.lowercased()), \(caption)"
            )
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(word)
                    .font(Theme.Font.headline)
                Text(words)
                    .font(Theme.Font.body)
                HStack(spacing: Theme.Space.s8) {
                    Text(caption)
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.textSecondary)
                    Text("\(percent)%")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.Space.s12)
        .accessibilityElement(children: .combine)
    }

    private func phaseWord(for need: Need) -> String {
        switch need.mastery.phase {
        case .coaching:
            return "Learning"
        case .quiet:
            return "Getting there"
        case .retired:
            return "You've got this"
        }
    }

    private func catchCaption(for need: Need) -> String {
        switch need.mastery.consecutiveSelfNotices {
        case ...0:
            return "not caught yet"
        case 1:
            return "caught once yourself"
        default:
            return "caught \(need.mastery.consecutiveSelfNotices) times yourself"
        }
    }

    // MARK: - This week

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s12) {
            Text("This week")
                .font(Theme.Font.headline)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: Theme.Space.s12) {
                ForEach(weekDays, id: \.date) { day in
                    VStack(spacing: Theme.Space.s4) {
                        Circle()
                            .fill(CueHistoryStore.hasSession(on: day.date, in: history) ? Theme.sage : Theme.textPrimary.opacity(0.14))
                            .frame(width: 14, height: 14)
                        Text(day.label)
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(day.name), \(CueHistoryStore.hasSession(on: day.date, in: history) ? "session" : "no session")")
                }
            }
            Text(weekSentence)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private var weekDays: [(date: Date, label: String, name: String)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let weekday = calendar.component(.weekday, from: today)
        let backToMonday = (weekday + 5) % 7
        let monday = calendar.date(byAdding: .day, value: -backToMonday, to: today) ?? today
        let labels = ["M", "T", "W", "T", "F", "S", "S"]
        let namer = DateFormatter()
        namer.dateFormat = "EEEE"
        return (0..<7).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: monday) else {
                return nil
            }
            return (day, labels[offset], namer.string(from: day))
        }
    }

    private var weekSentence: String {
        let tonight = CueHistoryStore.count(on: Date(), in: history)
        let prior = CueHistoryStore.mostRecentPriorDay(before: Date(), in: history)?.count
        let noun = tonight == 1 ? "1 cue" : "\(tonight) cues"
        switch (tonight, prior) {
        case (0, _):
            return "No cues tonight."
        case (_, let prior?) where prior > tonight:
            return "\(noun) tonight, down from \(prior)."
        default:
            return "\(noun) tonight."
        }
    }

    // MARK: - Cues per day

    private var cuesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: Theme.Space.s12) {
                HStack {
                    Text("Cues per day")
                        .font(Theme.Font.headline)
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    Picker("Range", selection: $range) {
                        ForEach(CueRange.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
                if history.isEmpty {
                    Text("No cues yet. This fills in after your first sessions.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    Chart(bars) { bar in
                        BarMark(
                            x: .value("Day", bar.label),
                            y: .value("Cues", bar.count)
                        )
                        .foregroundStyle(Theme.sagePale)
                        .cornerRadius(4)
                    }
                    .chartYAxis(.hidden)
                    .chartXAxis {
                        AxisMarks { _ in
                            AxisValueLabel()
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .frame(height: 140)
                    .accessibilityLabel("Cues per \(range == .day ? "day" : range == .week ? "week" : "month"): \(barSummary)")
                    if CueHistoryStore.isFading(history: history) {
                        HStack(spacing: Theme.Space.s4) {
                            Image(systemName: "arrow.trend.down")
                                .fontWeight(.light)
                            Text("Fading — you're learning")
                        }
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.sageStrong)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var bars: [CueBar] {
        switch range {
        case .day:
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEEE"
            return CueHistoryStore.lastDays(7, ending: Date(), in: history).map {
                CueBar(label: formatter.string(from: $0.date), count: $0.count)
            }
        case .week:
            return CueHistoryStore.weeklyBuckets(6, ending: Date(), in: history).map {
                CueBar(label: $0.label, count: $0.count)
            }
        case .month:
            return CueHistoryStore.monthlyBuckets(6, ending: Date(), in: history).map {
                CueBar(label: $0.label, count: $0.count)
            }
        }
    }

    private var barSummary: String {
        bars.map { "\($0.label) \($0.count)" }.joined(separator: ", ")
    }

    // MARK: - Explainer

    private var fadingExplainer: some View {
        GlassCard {
            DisclosureGroup {
                Text("When you notice on your own, we whisper less. After a few catches in a row, that need goes quiet.")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, Theme.Space.s8)
            } label: {
                Text("What does fading mean?")
                    .font(Theme.Font.headline)
            }
            .tint(Theme.textPrimary)
        }
    }
}

private enum CueRange: String, CaseIterable, Identifiable {
    case day = "D"
    case week = "W"
    case month = "M"

    var id: String { rawValue }
    var label: String { rawValue }
}

private struct CueBar: Identifiable {
    var id: String { label }
    var label: String
    var count: Int
}

#Preview("Learning") {
    LearningView(model: PhoneSessionModel())
}

#Preview("Learning with data") {
    LearningSamplePreview()
}

#Preview("Learning (night, AX)") {
    LearningView(model: PhoneSessionModel())
        .preferredColorScheme(.dark)
        .dynamicTypeSize(.accessibility5)
}

#if DEBUG
/// Preview-only sample history so screenshots show filled bars.
private struct LearningSamplePreview: View {
    @State private var model = PhoneSessionModel()

    private var history: [String: Int] {
        let calendar = Calendar.current
        let today = Date()
        var history: [String: Int] = [:]
        // Indexed by days back: today resolved 3 cues, a week ago 7.
        let counts = [3, 3, 4, 5, 5, 6, 7]
        for (back, count) in counts.enumerated() {
            if let day = calendar.date(byAdding: .day, value: -back, to: today) {
                history[CueHistoryStore.dayKey(for: day)] = count
            }
        }
        return history
    }

    var body: some View {
        LearningView(model: model, sampleHistory: history)
    }
}
#endif
