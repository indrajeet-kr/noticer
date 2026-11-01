import SwiftUI
import UIKit

/// Full developer-mode transcript: session lifecycle, frames, model turns,
/// engine events, speech, and errors. Copy or share the text straight into
/// an LLM to debug a run.
struct SessionLogView: View {
    @Bindable var log: SessionLog
    @Environment(\.dismiss) private var dismiss
    @State private var sharePayload: LogSharePayload?
    @State private var isWritingShare = false

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                TimelineView(.periodic(from: Date(), by: SessionLog.displayRefreshInterval)) { _ in
                    ScrollView {
                        let slice = log.displaySlice()
                        if let note = slice.note {
                            Text(note)
                                .font(Theme.Font.caption)
                                .foregroundStyle(Theme.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding([.horizontal, .top], Theme.Space.card)
                        }
                        Text(log.isEmpty ? "No entries yet. Start a session." : slice.text)
                            .font(Theme.Font.monoCaption)
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.card)
                            .id("log")
                        Color.clear.frame(height: 1).id("bottom")
                    }
                }
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    SessionLogExport.cleanupOldFiles()
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
                    NavigationLink {
                        PastRunsView(log: log)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Past runs")
                    Button {
                        UIPasteboard.general.string = log.text
                        log.appendActivity("UI", "log copied")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .accessibilityLabel("Copy log")
                    .disabled(log.isEmpty)
                    Button {
                        writeAndShare()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Share log")
                    .disabled(log.isEmpty || isWritingShare)
                }
            }
            .sheet(item: $sharePayload) { payload in
                ShareSheet(urls: payload.urls)
            }
        }
    }

    /// Builds the share file from the current full text when Share is
    /// tapped. The text is captured on the main actor; the write runs
    /// off it. The `[UI] log shared` line lands only after the write.
    @MainActor
    private func writeAndShare() {
        isWritingShare = true
        let text = log.text
        Task {
            let url = await Task.detached { SessionLogExport.writeFile(text: text) }.value
            isWritingShare = false
            guard let url else { return }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            log.appendActivity("UI", "log shared file=\(url.lastPathComponent) bytes=\(bytes)")
            sharePayload = LogSharePayload(urls: [url])
        }
    }
}

/// Presented share payload: file URLs ready to attach.
struct LogSharePayload: Identifiable {
    var id = UUID()
    var urls: [URL]
}

/// Share sheet for one or more log file URLs.
struct ShareSheet: UIViewControllerRepresentable {
    var urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview("Session log") {
    SessionLogView(log: SessionLog())
}
