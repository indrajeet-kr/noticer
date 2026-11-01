import SwiftUI
import UIKit

/// Full developer-mode transcript: session lifecycle, frames, model turns,
/// engine events, speech, and errors. Copy or share the text straight into
/// an LLM to debug a run.
struct SessionLogView: View {
    @Bindable var log: SessionLog
    @Environment(\.dismiss) private var dismiss
    @State private var shareFile: ShareFile?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                .onAppear {
                    proxy.scrollTo("bottom", anchor: .bottom)
                    refreshShareFile()
                }
                .onChange(of: log.entries.count) { _, _ in
                    refreshShareFile()
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
                    if let shareFile {
                        ShareLink(item: shareFile.url, preview: SharePreview("Session log")) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share log")
                        .disabled(log.isEmpty)
                        .simultaneousGesture(TapGesture().onEnded { _ in
                            log.appendActivity(
                                "UI",
                                "log shared file=\(shareFile.url.lastPathComponent) bytes=\(shareFile.bytes)"
                            )
                        })
                    }
                }
            }
        }
    }

    /// Writes the shareable file on appear and as entries land, never on
    /// every render. The file holds the full text, not the display slice.
    private func refreshShareFile() {
        guard !log.isEmpty,
              let url = SessionLogExport.writeFile(text: log.text)
        else {
            shareFile = nil
            return
        }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        shareFile = ShareFile(url: url, bytes: bytes)
    }
}

/// A written share file and its byte size for the `[UI] log shared` line.
private struct ShareFile {
    var url: URL
    var bytes: Int
}

#Preview("Session log") {
    SessionLogView(log: SessionLog())
}
