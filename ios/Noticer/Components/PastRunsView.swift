import SwiftUI
import UIKit

/// Saved run transcripts, newest first. Each run opens read-only with the
/// same Share and Copy actions as the live log.
struct PastRunsView: View {
    @Bindable var log: SessionLog
    @State private var runs: [SavedRun] = []
    @State private var sharePayload: LogSharePayload?
    @State private var isWritingShareAll = false

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
                Button {
                    writeAndShareAll()
                } label: {
                    Image(systemName: "square.and.arrow.up.on.square")
                }
                .accessibilityLabel("Share all runs")
                .disabled((runs.isEmpty && log.isEmpty) || isWritingShareAll)
            }
        }
        .sheet(item: $sharePayload) { payload in
            ShareSheet(urls: payload.urls)
        }
        .onAppear {
            runs = SessionLogStore.runs()
        }
    }

    /// Writes the current-log file and gathers every saved run when Share
    /// all runs is tapped. Nothing is written when the screen opens.
    @MainActor
    private func writeAndShareAll() {
        isWritingShareAll = true
        let text = log.text
        let includeCurrent = !log.isEmpty
        let runURLs = runs.map(\.url)
        Task {
            var urls: [URL] = []
            if includeCurrent,
               let current = await Task.detached { SessionLogExport.writeFile(text: text) }.value {
                urls.append(current)
            }
            urls += runURLs
            isWritingShareAll = false
            guard !urls.isEmpty else { return }
            log.appendActivity("UI", "all runs shared count=\(urls.count)")
            sharePayload = LogSharePayload(urls: urls)
        }
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

/// One saved run, read-only, with Share (as file) and Copy. The file
/// loads off the main thread; the screen shows the newest lines while
/// Share and Copy use the full file.
struct PastRunDetailView: View {
    var run: SavedRun
    @State private var loaded: PastRunContent?

    var body: some View {
        ScrollView {
            if let loaded {
                if let note = loaded.slice.note {
                    Text(note)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding([.horizontal, .top], Theme.Space.card)
                }
                Text(loaded.slice.text)
                    .font(Theme.Font.monoCaption)
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.card)
            } else {
                Text("Loading run…")
                    .font(Theme.Font.body)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Theme.Space.card)
            }
        }
        .background(Theme.bgBase)
        .navigationTitle(run.url.lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    UIPasteboard.general.string = loaded?.full ?? ""
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("Copy run")
                .disabled(loaded?.full.isEmpty ?? true)
                ShareLink(item: run.url, preview: SharePreview("Past run")) {
                    Image(systemName: "square.and.arrow.up")
                }
                .accessibilityLabel("Share run")
            }
        }
        .onAppear {
            loadRun()
        }
    }

    @MainActor
    private func loadRun() {
        let url = run.url
        Task {
            let content = await Task.detached { PastRunLoader.load(url: url) }.value
            loaded = content ?? PastRunContent(
                full: "",
                slice: LogDisplaySlice(text: "Could not read this run.", totalLines: 1, note: nil)
            )
        }
    }
}

#Preview("Past runs") {
    NavigationStack {
        PastRunsView(log: SessionLog())
    }
}
