import NoticerCore
import SwiftUI

/// How it's going: one card per need with a fading mastery ring. Progress
/// reads as "coaching → quiet" — fading support, never scoring or streaks.
struct LearningView: View {
    @Bindable var model: PhoneSessionModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text("How it's going")
                        .font(Theme.Font.statusWord)
                    Text("Support fades as he notices on his own.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .padding(.top, Theme.Space.s16)

                if model.needs.isEmpty {
                    GlassCard {
                        Text("No needs yet — her list is empty.")
                            .font(Theme.Font.headline)
                    }
                } else {
                    ForEach(model.needs, id: \.uiID) { need in
                        learningCard(for: need)
                    }
                }
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .ambientScreen()
    }

    private func learningCard(for need: Need) -> some View {
        let quiet = need.mastery.phase != .coaching
        let percent = Int((need.mastery.score * 100).rounded())
        return GlassCard {
            HStack(spacing: Theme.Space.s16) {
                MasteryRing(
                    score: need.mastery.score,
                    quiet: quiet,
                    accessibilityText: "\(need.authorText): \(phaseWords(for: need).lowercased()), \(percent) percent"
                )
                VStack(alignment: .leading, spacing: Theme.Space.s4) {
                    Text(need.authorText.isEmpty ? need.id : need.authorText)
                        .font(Theme.Font.headline)
                    Text(phaseWords(for: need))
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                    if need.mastery.phase == .retired {
                        Text("Quiet now — you've got this one.")
                            .font(Theme.Font.body)
                    } else {
                        Text(headStartLine(for: need))
                            .font(Theme.Font.body)
                        Text(streakLine(for: need))
                            .font(Theme.Font.body)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let samples = model.masterySamples[need.id], samples.count > 1 {
                        MasterySparkline(samples: samples)
                            .padding(.top, Theme.Space.s4)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func phaseWords(for need: Need) -> String {
        switch need.mastery.phase {
        case .coaching:
            return need.mastery.score >= 0.25 ? "Coaching, getting quieter" : "Coaching"
        case .quiet:
            return "Quiet"
        case .retired:
            return "Quiet"
        }
    }

    private func headStartLine(for need: Need) -> String {
        let baseline = Int(model.displayHeadStartBaseline(for: need).rounded())
        let current = Int(model.displayHeadStart(for: need).rounded())
        if current == baseline {
            return "Head start: \(current) s"
        }
        return "Head start: \(baseline) s → \(current) s"
    }

    private func streakLine(for need: Need) -> String {
        let streak = need.mastery.consecutiveSelfNotices
        if streak <= 0 {
            return "We're still coaching this one."
        }
        if streak == 1 {
            return "Noticed on his own once."
        }
        return "Noticed on his own \(streak) times in a row."
    }
}

/// Tiny mastery history, oldest to newest.
private struct MasterySparkline: View {
    var samples: [Double]

    var body: some View {
        GeometryReader { proxy in
            let points = normalized(size: proxy.size)
            Path { path in
                guard let first = points.first else {
                    return
                }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(Theme.accentWarm, lineWidth: 2)
        }
        .frame(height: 24)
        .accessibilityHidden(true)
    }

    private func normalized(size: CGSize) -> [CGPoint] {
        guard samples.count > 1, size.width > 0, size.height > 0 else {
            return []
        }
        return samples.enumerated().map { index, sample in
            let x = size.width * CGFloat(index) / CGFloat(samples.count - 1)
            let clamped = max(0, min(1, sample))
            let y = size.height * (1 - CGFloat(clamped))
            return CGPoint(x: x, y: y)
        }
    }
}

#Preview("Learning") {
    LearningView(model: PhoneSessionModel())
}

#Preview("Learning (light, AX)") {
    LearningView(model: PhoneSessionModel())
        .preferredColorScheme(.light)
        .dynamicTypeSize(.accessibility5)
}
