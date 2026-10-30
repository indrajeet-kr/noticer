import SwiftUI
import UIKit

/// Full developer-mode transcript: session lifecycle, frames, model turns,
/// engine events, speech, and errors. Copy or share the text straight into
/// an LLM to debug a run.
struct SessionLogView: View {
    @Bindable var log: SessionLog
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "No entries yet. Start a session." : log.text)
                        .font(Theme.Font.monoCaption)
                        .foregroundStyle(Theme.textSecondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.Space.card)
                        .id("log")
                    Color.clear.frame(height: 1).id("bottom")
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
            .background(Theme.bgBase)
            .navigationTitle("Session log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = log.text
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy log")
                    .disabled(log.isEmpty)
                    ShareLink(item: log.text, preview: SharePreview("Session log")) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share log")
                    .disabled(log.isEmpty)
                }
            }
        }
    }
}

#Preview("Session log") {
    SessionLogView(log: SessionLog())
}
