import SwiftUI

/// Replay timeline: state markers in state colors, a scrubber, elapsed and
/// total time, and play/pause with ±5 s transport.
struct ReplayScrubber: View {
    /// 0...1.
    var fraction: Double
    var elapsed: TimeInterval
    var total: TimeInterval
    var markers: [ReplayMarker]
    var isPlaying: Bool
    var onScrub: (Double) -> Void
    var onPlayPause: () -> Void
    var onSkip: (TimeInterval) -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s8) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Theme.textPrimary.opacity(0.14))
                    Capsule()
                        .fill(Theme.accentWarm)
                        .frame(width: proxy.size.width * clamped)
                    ForEach(markers) { marker in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(marker.color)
                            .frame(width: 4, height: 14)
                            .offset(x: proxy.size.width * marker.fraction - 2)
                    }
                }
                .frame(height: 6)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            onScrub(max(0, min(1, value.location.x / proxy.size.width)))
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Replay position")
                .accessibilityValue("\(timeString(elapsed)) of \(timeString(total))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: onSkip(5)
                    case .decrement: onSkip(-5)
                    @unknown default: break
                    }
                }
            }
            .frame(height: 28)

            HStack {
                Text(timeString(elapsed))
                Spacer()
                Text(timeString(total))
            }
            .font(Theme.Font.caption)
            .foregroundStyle(Theme.textSecondary)
            .contentTransition(.numericText())

            HStack(spacing: Theme.Space.s12) {
                TransportButton(systemImage: "gobackward.5") { onSkip(-5) }
                    .accessibilityLabel("Back 5 seconds")
                Button(action: onPlayPause) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.onAccentFill)
                        .frame(width: 52, height: 52)
                        .background(Theme.accentFill)
                        .clipShape(Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                TransportButton(systemImage: "goforward.5") { onSkip(5) }
                    .accessibilityLabel("Forward 5 seconds")
            }
        }
    }

    private var clamped: Double { max(0, min(1, fraction)) }

    private func timeString(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct ReplayMarker: Identifiable, Equatable {
    var id = UUID()
    /// 0...1 along the timeline.
    var fraction: Double
    var color: Color

    static func == (lhs: ReplayMarker, rhs: ReplayMarker) -> Bool {
        lhs.id == rhs.id
    }
}

private struct TransportButton: View {
    var systemImage: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 46, height: 46)
        }
        .glassBackground(cornerRadius: 999)
    }
}

#Preview("Replay scrubber") {
    VStack {
        ReplayScrubber(
            fraction: 0.35,
            elapsed: 17,
            total: 48,
            markers: [
                ReplayMarker(fraction: 0.15, color: Theme.noticed),
                ReplayMarker(fraction: 0.3, color: Theme.headstart),
                ReplayMarker(fraction: 0.62, color: Theme.cue),
                ReplayMarker(fraction: 0.8, color: Theme.gotIt),
            ],
            isPlaying: true,
            onScrub: { _ in },
            onPlayPause: {},
            onSkip: { _ in }
        )
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Replay scrubber (light, AX)") {
    VStack {
        ReplayScrubber(
            fraction: 0.7,
            elapsed: 34,
            total: 48,
            markers: [ReplayMarker(fraction: 0.62, color: Theme.cue)],
            isPlaying: false,
            onScrub: { _ in },
            onPlayPause: {},
            onSkip: { _ in }
        )
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
