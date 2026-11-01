import NoticerCore
import SwiftUI

/// One priority word with its symbol: leaf for gentle, circle for normal,
/// star for important. Never color alone — the word is always shown.
/// Urgent (the engine's safety flag) overrides the word in terracotta.
struct PriorityChip: View {
    var priority: NeedsIntentPriority
    var urgent: Bool = false

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            Image(systemName: symbol)
            Text(word)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(urgent ? Theme.terracottaText : Theme.textSecondary)
        .padding(.horizontal, Theme.Space.s8)
        .padding(.vertical, Theme.Space.s4)
        .overlay(
            Theme.Radius.rect(Theme.Radius.chip)
                .stroke(stroke, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Priority \(word)")
    }

    private var word: String {
        if urgent {
            return "Urgent"
        }
        switch priority {
        case .gentle: return "Gentle"
        case .normal: return "Normal"
        case .important: return "Important"
        }
    }

    private var symbol: String {
        if urgent {
            return "exclamationmark.circle.fill"
        }
        switch priority {
        case .gentle: return "leaf"
        case .normal: return "circle"
        case .important: return "star.fill"
        }
    }

    private var stroke: Color {
        urgent ? Theme.terracotta.opacity(0.5) : Theme.textPrimary.opacity(0.14)
    }
}

#Preview("Priority chips") {
    HStack(spacing: Theme.Space.s8) {
        PriorityChip(priority: .gentle)
        PriorityChip(priority: .normal)
        PriorityChip(priority: .important)
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Priority chips (light, AX)") {
    HStack(spacing: Theme.Space.s8) {
        PriorityChip(priority: .gentle)
        PriorityChip(priority: .important)
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
