import SwiftUI

/// Live-transcript side pane docked to the ask overlay. Header carries the
/// record state and start/stop; body streams finalized lines plus the
/// in-progress partial; auto-scrolls to the newest line.
struct TranscriptPaneView: View {
    @ObservedObject var model: TranscriptPanelModel
    @State private var showHistory = false
    @State private var history: [MeetingHistory.Entry] = []
    @State private var openEntry: MeetingHistory.Entry?
    @State private var openContent: String = ""
    @State private var extracting = false
    @State private var extractedCount: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.glassBorder)
            if let entry = openEntry {
                readerView(entry)
            } else if showHistory {
                historyList
            } else {
                body_
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.black.opacity(0.12))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if model.isRecording {
                Circle().fill(Theme.danger).frame(width: 7, height: 7)
                    .shadow(color: Theme.danger, radius: 3)
                Text(showHistory ? "Past meetings" : "Transcribing")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.fg)
            } else {
                Circle().fill(Theme.faint).frame(width: 7, height: 7)
                Text(showHistory ? "Past meetings" : "Transcript")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            Button(action: {
                showHistory.toggle()
                if showHistory { history = MeetingHistory.entries() }
            }) {
                Image(systemName: showHistory ? "waveform" : "clock.arrow.circlepath")
                    .font(.system(size: 12))
                    .foregroundStyle(showHistory ? Theme.accent : Theme.muted)
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Back to live transcript" : "All saved transcriptions")
            Button(action: { model.toggleRecording() }) {
                Text(model.isRecording ? "Stop" : "Start")
                    .font(.system(size: 10.5, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(model.isRecording
                                               ? Theme.danger.opacity(0.2) : Theme.field))
                    .foregroundStyle(model.isRecording ? Theme.danger : Theme.muted)
            }
            .buttonStyle(.plain)
            .help(model.isRecording ? "Stop and save meeting notes" : "Start meeting transcription")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: - Saved transcriptions

    private var historyList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if history.isEmpty {
                    Text("No saved meetings yet. Stop a recording and its notes land in ~/Documents/Glance Meetings.")
                        .font(.system(size: 11)).foregroundStyle(Theme.faint)
                        .padding(.top, 8)
                }
                ForEach(history) { entry in
                    Button(action: { open(entry) }) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(Theme.fg.opacity(0.9))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(entry.modified, format: .dateTime.day().month().hour().minute())
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Theme.faint)
                                if !entry.snippet.isEmpty {
                                    Text(entry.snippet)
                                        .font(.system(size: 10))
                                        .foregroundStyle(Theme.muted)
                                        .lineLimit(1)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8).padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HistoryRowStyle())
                    .help("Open in pane")
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 6)
        }
    }

    // MARK: - Reader (opened meeting + actions)

    private func open(_ entry: MeetingHistory.Entry) {
        openContent = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? "Couldn't read file."
        extractedCount = nil
        openEntry = entry
    }

    private func readerView(_ entry: MeetingHistory.Entry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Button(action: { openEntry = nil }) {
                    Label("Back", systemImage: "chevron.left")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                Spacer()
                Button(action: { NSWorkspace.shared.open(entry.url) }) {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 11)).foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
                .help("Open file")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)

            // Action bar
            HStack(spacing: 6) {
                actionChip("Summarize", icon: "text.append") {
                    model.summarizeHandler?(entry)
                }
                actionChip(extracting ? "Extracting…" : "Add my tasks", icon: "checklist") {
                    guard !extracting else { return }
                    extracting = true
                    model.extractTasksHandler?(entry) { count in
                        extracting = false
                        extractedCount = count
                    }
                }
                if let n = extractedCount {
                    Text(n == 0 ? "No action items found" : "✓ \(n) task\(n == 1 ? "" : "s") added")
                        .font(.system(size: 10))
                        .foregroundStyle(n == 0 ? Theme.muted : Theme.success)
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 7)

            Divider().overlay(Theme.glassBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.title)
                        .font(.system(size: 12, weight: .semibold))
                    MarkdownText(text: openContent)
                        .font(.system(size: 11))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
    }

    private func actionChip(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 9.5))
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(Theme.field))
            .overlay(Capsule().strokeBorder(Theme.glassBorderHi, lineWidth: 1))
            .foregroundStyle(Theme.fg.opacity(0.85))
        }
        .buttonStyle(.plain)
    }

    private var body_: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if model.lines.isEmpty && model.partial.isEmpty {
                        Text(model.isRecording
                             ? "Listening…"
                             : "Start transcription to see the conversation here. Ask the AI about it any time — recent transcript rides along with your question.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.faint)
                            .padding(.top, 8)
                    }
                    ForEach(model.lines) { line in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(line.at, format: .dateTime.hour().minute())
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Theme.faint)
                            Text(line.text)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.fg.opacity(0.88))
                                .textSelection(.enabled)
                        }
                        .id(line.id)
                    }
                    if !model.partial.isEmpty {
                        Text(model.partial)
                            .font(.system(size: 11.5))
                            .italic()
                            .foregroundStyle(Theme.muted)
                            .id("partial")
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: model.lines.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: model.partial) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

/// Hover highlight for history rows.
private struct HistoryRowStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0))
            )
            .onHover { hovering = $0 }
    }
}
