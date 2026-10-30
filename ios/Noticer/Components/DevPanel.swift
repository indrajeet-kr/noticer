import SwiftUI
import UIKit

/// Collapsible developer telemetry, collapsed by default. Monospaced,
/// selectable, with a copy button. Never shows the API key.
struct DevPanel: View {
    var lines: [String]
    /// When set, a Session log button opens the full transcript sheet.
    var log: SessionLog?
    @State private var open = false
    @State private var showingLog = false

    var body: some View {
        GlassCard {
            DisclosureGroup(isExpanded: $open) {
                VStack(alignment: .leading, spacing: Theme.Space.s8) {
                    Text(lines.joined(separator: "\n"))
                        .font(Theme.Font.monoCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: Theme.Space.s16) {
                        Button {
                            UIPasteboard.general.string = lines.joined(separator: "\n")
                        } label: {
                            HStack(spacing: Theme.Space.s4) {
                                Image(systemName: "doc.on.doc")
                                Text("Copy")
                            }
                            .font(Theme.Font.footnote)
                        }
                        .foregroundStyle(Theme.accentWarm)
                        if log != nil {
                            Button {
                                showingLog = true
                            } label: {
                                HStack(spacing: Theme.Space.s4) {
                                    Image(systemName: "doc.text")
                                    Text("Session log")
                                }
                                .font(Theme.Font.footnote)
                            }
                            .foregroundStyle(Theme.accentWarm)
                        }
                    }
                }
                .padding(.top, Theme.Space.s8)
            } label: {
                HStack {
                    Text("Developer")
                        .font(Theme.Font.headline)
                    Spacer()
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(Theme.Font.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
                .contentShape(Rectangle())
            }
            .tint(Theme.textPrimary)
        }
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showingLog) {
            if let log {
                SessionLogView(log: log)
            }
        }
    }
}

#Preview("Dev panel") {
    VStack {
        DevPanel(lines: [
            "frames seen 1,284 · passed 212",
            "model calls 37",
            "meta: water_low=true conf=0.81",
            "gate: headstart running",
            "cue: \"Her water's low.\"",
            "mastery: refill-water m=0.420 · take-baby m=0.680",
            "headstart: refill-water 20s (quick) · take-baby 9s",
        ])
    }
    .screenMargins()
    .ambientScreen()
}

#Preview("Dev panel (light, AX)") {
    VStack {
        DevPanel(lines: ["frames seen 12 · passed 3", "model calls 1"])
    }
    .screenMargins()
    .ambientScreen()
    .preferredColorScheme(.light)
    .dynamicTypeSize(.accessibility5)
}
