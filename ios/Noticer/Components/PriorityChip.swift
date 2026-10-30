import SwiftUI

/// One priority word with its symbol: leaf for gentle, circle for normal,
/// star for important. Never color alone — the word is always shown.
struct PriorityChip: View {
    var priority: NeedsIntentPriority

    var body: some View {
        HStack(spacing: Theme.Space.s4) {
            Image(systemName: symbol)
            Text(word)
        }
        .font(Theme.Font.caption)
        .foregroundStyle(Theme.textSecondary)
        .padding(.horizontal, Theme.Space.s8)
        .padding(.vertical, Theme.Space.s4)
        .overlay(
            Theme.Radius.rect(Theme.Radius.chip)
                .stroke(Theme.textPrimary.opacity(0.14), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Priority \(word)")
    }

    private var word: String {
        switch priority {
        case .gentle: return "Gentle"
        case .normal: return "Normal"
        case .important: return "Important"
        }
    }

    private var symbol: String {
        switch priority {
        case .gentle: return "leaf"
        case .normal: return "circle"
        case .important: return "star.fill"
        }
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
