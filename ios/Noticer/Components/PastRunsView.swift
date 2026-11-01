import SwiftUI
import UIKit

/// Saved run transcripts, newest first. Each run opens read-only with the
/// same Share and Copy actions as the live log.
struct PastRunsView: View {
    @Bindable var log: SessionLog
    @State private var runs: [SavedRun] = []
    @State private var shareAllURLs: [URL] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.s16) {
                if runs.isEmpty {
                    Text("No saved runs yet. Stop a session and its transcript lands here.")
                        .font(Theme.Font.body)
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, Theme.Space.s16)
                } else {
                    GlassCard(padding: Theme.Space.card) {
                        VStack(spacing: 0) {
                            ForEach(runs) { run in
                                NavigationLink {
                                    PastRunDetailView(run: run)
                                } label: {
                                    PastRunRow(run: run)
                                }
                                if run.id != runs.last?.id {
                                    Divider().background(Theme.textPrimary.opacity(0.08))
                                }
                            }
                        }
                    }
                    .padding(.top, Theme.Space.s16)
                }
            }
            .screenMargins()
            .padding(.bottom, Theme.Space.s32)
        }
        .background(Theme.bgBase)
        .navigationTitle("Past runs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !shareAllURLs.isEmpty {
                    ShareLink(items: shareAllURLs, preview: { _ in SharePreview("All runs") }) {
                        Image(systemName: "square.and.arrow.up.on.square")
                    }
                    .accessibilityLabel("Share all runs")
                    .simultaneousGesture(TapGesture().onEnded { _ in
                        log.appendActivity("UI", "all runs shared count=\(shareAllURLs.count)")
                    })
                }
            }
        }
        .onAppear {
            runs = SessionLogStore.runs()
            refreshShareAll()
        }
    }

    /// The current log plus every saved run, written once on appear.
    private func refreshShareAll() {
        var urls: [URL] = []
        if !log.isEmpty, let current = SessionLogExport.writeFile(text: log.text) {
            urls.append(current)
        }
        urls += runs.map(\.url)
        shareAllURLs = urls
    }
}

private struct PastRunRow: View {
    var run: SavedRun

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Space.s4) {
                Text(Self.dateLine(run.date))
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textPrimary)
                Text("\(Self.sizeLine(run.size)) · \(run.url.lastPathComponent)")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
        }
        .padding(.vertical, Theme.Space.s8)
        .contentShape(Rectangle())
    }

    private static func dateLine(_ date: Date?) -> String {
        guard let date else { return "Unknown date" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private static func sizeLine(_ size: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

/// One saved run, read-only, with Share (as file) and Copy.
struct PastRunDetailView: View {
    var run: SavedRun
    @State private var text: String = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Loading…" : text)
                .font(Theme.Font.monoCaption)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.Space.card)
        }
        .background(Theme.bgBase)
        .navigationTitle(run.url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy run")
                .disabled(text.isEmpty)
                ShareLink(item: run.url, preview: SharePreview("Past run")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share run")
            }
        }
        .onAppear {
            text = (try? String(contentsOf: run.url, encoding: .utf8)) ?? "Could not read this run."
        }
    }
}

#Preview("Past runs") {
    NavigationStack {
        PastRunsView(log: SessionLog())
    }
}
