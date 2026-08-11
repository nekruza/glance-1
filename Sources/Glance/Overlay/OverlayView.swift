import SwiftUI

/// Dark-glass overlay built to the screens/ visual contract (01-overlay-idle,
/// 02-overlay-answer). Idle = prompt + context strip + backend footer; answer =
/// asked header(s) + streamed Markdown + follow-up bar + footer.
struct OverlayView: View {
    @ObservedObject var session: OverlaySession
    @ObservedObject private var prefs = Preferences.shared
    @ObservedObject private var liveTranscript = TranscriptPanelModel.shared
    @FocusState private var inputFocused: Bool
    @State private var showHistory = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                if session.turns.isEmpty {
                    promptRow
                } else {
                    transcript
                    if !session.suggestions.isEmpty && !session.isWorking {
                        suggestionChips
                    }
                    followUpBar
                }
                footer
            }
            .frame(width: Theme.overlayWidth)
            if liveTranscript.isVisible {
                Divider().overlay(Theme.glassBorder)
                TranscriptPaneView(model: liveTranscript)
                    .frame(width: Theme.transcriptPaneWidth)
            }
        }
        .frame(width: Theme.overlayWidth + (liveTranscript.isVisible ? Theme.transcriptPaneWidth + 1 : 0))
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { session.contentHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in session.contentHeight = h }
        })
        .background(glass)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            closeButton.padding(5)
        }
        .foregroundStyle(Theme.fg)
        .onAppear { inputFocused = true }
        // Clearing (trash) or resuming (History) swaps the text field between
        // promptRow and followUpBar; FocusState resets when the focused field
        // leaves the hierarchy, so re-focus or typing goes nowhere. The new
        // field isn't focusable until after the view update, hence the delay.
        .onChange(of: session.turns.isEmpty) { _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { inputFocused = true }
        }
    }

    // MARK: - Surface

    private var glass: some View {
        // No blur material — any NSVisualEffectView material reads as frosted
        // near-opaque gray. Pure translucent color = genuinely see-through.
        // Opacity is user-tunable in Settings.
        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
            .fill(Theme.glassTint.opacity(prefs.overlayOpacity))
    }

    private var spark: some View {
        Image(systemName: "sparkle")
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Theme.accent)
    }

    // MARK: - Idle: prompt row + context strip

    private var promptRow: some View {
        HStack(spacing: 14) {
            spark
            TextField("", text: $session.input, prompt: Text(placeholder).foregroundColor(Theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
                .onKeyPress(.return, phases: .down, action: handleReturn)
            micButton
            kbd("↩ Ask")
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
    }

    private func thumbnail(_ image: NSImage) -> some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: 44, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.glassBorderHi, lineWidth: 1))
    }

    // MARK: - Answer: transcript + follow-up

    private var transcript: some View {
        ScrollViewReader { proxy in
            // Always a scroll view: the window is a fixed height in conversation
            // mode (set by the controller), the transcript fills the middle and
            // scrolls when content overflows. Input + footer stay pinned below.
            ScrollView {
                transcriptContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: session.turns.last?.answer) { _, _ in scrollToEnd(proxy) }
            .onChange(of: session.turns.count) { _, _ in scrollToEnd(proxy) }
        }
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.turns.enumerated()), id: \.element.id) { idx, turn in
                askedHeader(turn)
                answerBlock(turn)
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
                if idx < session.turns.count - 1 {
                    Divider().overlay(Theme.glassBorder)
                }
                Color.clear.frame(height: 1).id(turn.id)
            }
        }
    }

    private func askedHeader(_ turn: OverlaySession.Turn) -> some View {
        HStack(alignment: .top, spacing: 12) {
            spark.font(.system(size: 16, weight: .semibold))
            Text(turn.question)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
            if let thumb = turn.thumbnail {
                thumbnail(thumb)
            }
        }
        .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 14)
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .bottom)
    }

    @ViewBuilder private func answerBlock(_ turn: OverlaySession.Turn) -> some View {
        if turn.answer.isEmpty && session.isWorking && turn.id == session.turns.last?.id {
            workingRow
        } else if turn.failed {
            Label {
                Text(turn.answer)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
            }
            .foregroundStyle(Theme.danger)
            .font(.system(size: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            MarkdownText(text: turn.answer)
                .font(.system(size: 12))
        }
    }

    private var workingRow: some View {
        HStack(spacing: 10) {
            BouncingDots()
            Text(session.attachImage ? "Reading your screen…" : "Thinking…")
                .foregroundStyle(Theme.muted).font(.system(size: 14))
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.suggestions, id: \.self) { s in
                    Button(action: { session.submitSuggestion(s) }) {
                        Text(s)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.fg.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Theme.field))
                            .overlay(Capsule().strokeBorder(Theme.glassBorderHi, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 22).padding(.vertical, 8)
        }
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
    }

    private var followUpBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.faint)
            TextField("", text: $session.input,
                      prompt: Text(placeholder).foregroundColor(Theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...6)
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
                .onKeyPress(.return, phases: .down, action: handleReturn)
            micButton
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
    }

    /// Shift+Return inserts a newline instead of submitting. Insertion goes
    /// through the field editor so the break lands at the cursor, not the end.
    private func handleReturn(_ press: KeyPress) -> KeyPress.Result {
        guard press.modifiers.contains(.shift) else { return .ignored }
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.insertText("\n", replacementRange: editor.selectedRange())
        } else {
            session.input += "\n"
        }
        return .handled
    }

    // MARK: - Shared controls

    private var micButton: some View {
        Button(action: {
            // System dictation types into the focused field, so focus first.
            inputFocused = true
            DispatchQueue.main.async {
                NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil)
            }
        }) {
            Image(systemName: "mic")
                .font(.system(size: 15))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .help("Dictate with macOS dictation")
    }

    private var attachButton: some View {
        Button(action: { session.attachImage.toggle() }) {
            Image(systemName: session.attachImage ? "photo.fill" : "photo")
                .font(.system(size: 17))
                .foregroundStyle(session.attachImage ? Theme.accent : Theme.muted)
        }
        .buttonStyle(.plain)
        .help(session.attachImage ? "Screenshot will be sent — click for text-only"
                                  : "Text-only — click to attach the current screen")
    }

    private var closeButton: some View {
        Button(action: { session.dismissHandler?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(Theme.muted)
                .padding(4)
                .background(Circle().fill(Theme.field))
                .overlay(Circle().strokeBorder(Theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Close overlay")
    }

    /// Opens/closes the live-transcript side pane (next to the gear).
    private var transcriptPaneButton: some View {
        Button(action: { liveTranscript.isVisible.toggle() }) {
            Image(systemName: liveTranscript.isVisible ? "sidebar.right" : "sidebar.right")
                .font(.system(size: 15))
                .foregroundStyle(liveTranscript.isVisible ? Theme.accent
                                 : (liveTranscript.isRecording ? Theme.danger : Theme.muted))
        }
        .buttonStyle(.plain)
        .help(liveTranscript.isVisible ? "Hide live transcript" : "Show live transcript")
    }

    private var transcribeButton: some View {
        Button(action: { session.transcribeHandler?() }) {
            Image(systemName: session.isTranscribing ? "record.circle.fill" : "waveform.circle")
                .font(.system(size: 15))
                .foregroundStyle(session.isTranscribing ? Theme.danger : Theme.muted)
        }
        .buttonStyle(.plain)
        .help(session.isTranscribing ? "Stop meeting transcription and save notes"
                                     : "Start meeting transcription (Granola-style notes)")
    }

    private var clearButton: some View {
        Button(action: { session.clearHandler?() }) {
            Image(systemName: "trash")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.muted)
        }
        .buttonStyle(.plain)
        .help("Clear conversation and start a fresh session")
    }

    // MARK: - History (past Claude CLI sessions)

    private var historyButton: some View {
        Button(action: { showHistory.toggle() }) {
            HStack(spacing: 5) {
                Text("History").font(.system(size: 11.5))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.glassBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Resume a past Claude CLI session")
        .popover(isPresented: $showHistory, arrowEdge: .bottom) { historyList }
    }

    private var historyList: some View {
        Group {
            if session.historySessions.isEmpty {
                Text("No past sessions")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.muted)
                    .padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(session.historySessions) { item in
                            historyRow(item)
                        }
                    }
                    .padding(6)
                }
                .frame(width: 340)
                .frame(maxHeight: 320)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func historyRow(_ item: SessionSummary) -> some View {
        Button {
            showHistory = false
            session.historyHandler?(item)
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                Text("\(item.projectLabel) · \(Self.relativeTime.localizedString(for: item.modified, relativeTo: Date()))")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(HistoryRowButtonStyle())
    }

    private static let relativeTime: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private var footer: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.backendConnected ? Theme.success : Theme.danger)
                .frame(width: 6, height: 6)
                .shadow(color: session.backendConnected ? Theme.success : .clear, radius: 4)
            Text(session.backendLabel)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.muted)
            Spacer()
            transcribeButton
            if !session.turns.isEmpty {
                clearButton
            }
            if session.showsHistory {
                historyButton
            }
            attachButton
            transcriptPaneButton
            Button(action: { session.settingsHandler?() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
            }
            .buttonStyle(.plain)
            .help("Settings")
        }
        .padding(.horizontal, 22).padding(.vertical, 10)
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
    }

    private func kbd(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    private var placeholder: String {
        if !session.turns.isEmpty {
            return session.attachImage ? "Ask a follow-up (with current screen)…" : "Ask a follow-up (text only)…"
        }
        return session.attachImage ? "Ask about what's on screen…" : "Ask anything (no screenshot)…"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = session.turns.last?.id {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
        }
    }
}

/// Hover highlight for history rows inside the popover.
private struct HistoryRowButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0))
            )
            .onHover { hovering = $0 }
    }
}

/// Three bouncing accent dots — the answer "working" state (02-overlay-answer).
private struct BouncingDots: View {
    @State private var phase = 0.0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { i in
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    .offset(y: phase == Double(i) ? -3 : 0)
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.4).repeatForever()) { phase = 2 }
        }
    }
}
