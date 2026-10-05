import SwiftUI

/// Dark-glass overlay built to the screens/ visual contract (01-overlay-idle,
/// 02-overlay-answer). Idle = prompt + context strip + backend footer; answer =
/// asked header(s) + streamed Markdown + follow-up bar + footer.
struct OverlayView: View {
    @ObservedObject var session: OverlaySession
    @ObservedObject private var prefs = Preferences.shared
    @FocusState private var inputFocused: Bool
    @State private var showHistory = false
    // "Viewport is at the bottom" — streaming auto-scroll runs only while
    // true. User scrolling up disengages it (ScrollPinTracker); scrolling
    // back to the bottom, tapping the ↓ pill, or asking a new question
    // re-engages.
    @State private var pinAtBottom = true

    /// Chat text size multiplier from Settings (your text + the answer).
    private var textScale: CGFloat { CGFloat(prefs.chatTextScale) }

    /// True while the panel height should track its content (idle prompt row).
    private var growsWithContent: Bool {
        session.turns.isEmpty
    }

    var body: some View {
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
        // Idle mode: refuse the window's proposed height and report the
        // TRUE ideal height instead. Without this the hosting view forces
        // the column into the window's current (short) bounds, SwiftUI
        // compresses the growing TextField to fit, and the height we
        // measure below is just the window height we were handed — a
        // circular constraint that pins the panel at one row forever.
        // fixedSize breaks the cycle: content height depends only on the
        // text, so the controller's resize settles in one step.
        // Conversation mode keeps the flexible layout (fixed 560pt window,
        // scrolling transcript in the middle).
        .fixedSize(horizontal: false, vertical: growsWithContent)
        .background(GeometryReader { geo in
            Color.clear
                .onAppear { session.contentHeight = geo.size.height }
                .onChange(of: geo.size.height) { _, h in session.contentHeight = h }
        })
        .background(glass)
        .overlay(
            // Lit-from-above rim: bright along the top edge, fading out
            // toward the bottom, so the panel has an edge instead of an outline.
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(
                    LinearGradient(colors: [Color.white.opacity(0.22), Color.white.opacity(0.07),
                                            Color.white.opacity(0.10)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(alignment: .topTrailing) {
            closeButton.padding(8)
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
        // Opacity is user-tunable in Settings. The vertical lift and the faint
        // accent bloom in the top-left corner give the flat tint some depth.
        let shape = RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
        return shape
            .fill(LinearGradient(
                colors: [Theme.glassLift.opacity(prefs.overlayOpacity), Theme.glassTint.opacity(prefs.overlayOpacity)],
                startPoint: .top, endPoint: .bottom))
            .overlay(
                shape.fill(RadialGradient(colors: [Theme.accent.opacity(0.09), .clear],
                                          center: .topLeading, startRadius: 0, endRadius: 280))
            )
    }

    /// Brand spark on a soft accent tile — the one place the accent leads.
    private func sparkBadge(size: CGFloat = 28) -> some View {
        Image(systemName: "sparkle")
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .fill(Theme.accent.opacity(0.14))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.22), lineWidth: 1)
            )
    }

    // MARK: - Idle: prompt row + context strip

    private var promptRow: some View {
        HStack(spacing: 14) {
            sparkBadge(size: 30)
            TextField("", text: $session.input, prompt: Text(placeholder).foregroundColor(Theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 14 * textScale))
                .lineLimit(1...6)
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
                .onKeyPress(.return, phases: .down, action: handleReturn)
            micButton
            kbd("↩ Ask")
        }
        .padding(.leading, 20).padding(.trailing, 36).padding(.vertical, 18)
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
                    .background(ScrollPinTracker(pinned: $pinAtBottom))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Streamed chunks follow the bottom only while pinned. Instant
            // scroll: chunks arrive faster than any animation, so animating
            // each one queues up and feels rubbery.
            .onChange(of: session.turns.last?.answer) { _, _ in
                if pinAtBottom { scrollToEnd(proxy) }
            }
            // New turn = the user just asked something: snap down and re-pin
            // regardless of where they had scrolled.
            .onChange(of: session.turns.count) { _, _ in
                pinAtBottom = true
                scrollToEnd(proxy, animated: true)
            }
            .overlay(alignment: .bottom) {
                if !pinAtBottom {
                    jumpToBottomPill(proxy).padding(.bottom, 10)
                }
            }
            .animation(.easeOut(duration: 0.12), value: pinAtBottom)
        }
    }

    /// Escape hatch back to live-follow after scrolling up mid-stream.
    private func jumpToBottomPill(_ proxy: ScrollViewProxy) -> some View {
        Button {
            pinAtBottom = true
            scrollToEnd(proxy, animated: true)
        } label: {
            Image(systemName: "arrow.down")
                .font(.system(size: 11, weight: .bold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.glassLift))
                .overlay(Circle().strokeBorder(Theme.glassBorderHi, lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        }
        .buttonStyle(OverlayIconButtonStyle(minWidth: 28, height: 28, corner: 14))
        .help("Jump to latest")
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    private var transcriptContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(session.turns.enumerated()), id: \.element.id) { idx, turn in
                askedHeader(turn)
                answerBlock(turn)
                    .padding(.horizontal, 22).padding(.top, 18).padding(.bottom, 22)
                if idx < session.turns.count - 1 {
                    Divider().overlay(Theme.hairline)
                }
                Color.clear.frame(height: 1).id(turn.id)
            }
        }
    }

    /// The user's question, set on a faint band so it reads as the prompt and
    /// the answer below it as the response.
    private func askedHeader(_ turn: OverlaySession.Turn) -> some View {
        HStack(alignment: .center, spacing: 12) {
            sparkBadge(size: 26)
            Text(turn.question)
                .font(.system(size: 14.5 * textScale, weight: .medium))
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let thumb = turn.thumbnail {
                thumbnail(thumb)
            }
        }
        .padding(.leading, 18).padding(.trailing, 44).padding(.vertical, 14)
        .background(Color.white.opacity(0.035))
        .overlay(Divider().overlay(Theme.hairline), alignment: .bottom)
    }

    @ViewBuilder private func answerBlock(_ turn: OverlaySession.Turn) -> some View {
        if turn.answer.isEmpty && session.isWorking && turn.id == session.turns.last?.id {
            workingRow
        } else if turn.failed {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                Text(turn.answer)
                    .font(.system(size: 13 * textScale))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.fg.opacity(0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Theme.danger)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.danger.opacity(0.09)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.danger.opacity(0.28), lineWidth: 1))
        } else {
            MarkdownText(text: turn.answer)
                .font(.system(size: 13 * textScale))
                .foregroundStyle(Theme.fg.opacity(0.92))
                .environment(\.chatTextScale, textScale)
        }
    }

    private var workingRow: some View {
        HStack(spacing: 10) {
            BouncingDots()
            Text(session.attachImage ? "Reading your screen…" : "Thinking…")
                .foregroundStyle(Theme.muted).font(.system(size: 13 * textScale))
        }
    }

    private var suggestionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(session.suggestions, id: \.self) { s in
                    Button(action: { session.submitSuggestion(s) }) {
                        Text(s)
                            .font(.system(size: 12))
                            .lineLimit(1)
                    }
                    .buttonStyle(OverlayChipButtonStyle())
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 2)
        }
    }

    /// Follow-up input as an inset field: the border warms to the accent when
    /// focused, and Send lights up only once there is something to send.
    private var followUpBar: some View {
        HStack(alignment: .bottom, spacing: 4) {
            TextField("", text: $session.input,
                      prompt: Text(placeholder).foregroundColor(Theme.faint),
                      axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5 * textScale))
                .lineLimit(1...6)
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
                .onKeyPress(.return, phases: .down, action: handleReturn)
                .padding(.leading, 14).padding(.vertical, 10)
            micButton
            sendButton
        }
        .padding(.trailing, 6).padding(.bottom, 0)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(inputFocused ? Theme.accent.opacity(0.55) : Theme.glassBorder, lineWidth: 1)
        )
        .animation(.easeOut(duration: 0.15), value: inputFocused)
        .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 10)
    }

    private var canSend: Bool {
        !session.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !session.isWorking
    }

    private var sendButton: some View {
        Button(action: { session.submit() }) {
            Image(systemName: "arrow.up")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(canSend ? Color.black.opacity(0.82) : Theme.faint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(canSend ? Theme.accent : Theme.field))
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .padding(.bottom, 5)
        .help("Send (↩)")
        .animation(.easeOut(duration: 0.12), value: canSend)
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
                .font(.system(size: 13.5))
        }
        .buttonStyle(OverlayIconButtonStyle())
        .padding(.bottom, 4)
        .help("Dictate with macOS dictation")
    }

    private var attachButton: some View {
        Button(action: { session.toggleAttachImage() }) {
            Image(systemName: session.attachImage ? "photo.fill" : "photo")
                .font(.system(size: 14))
        }
        .buttonStyle(OverlayIconButtonStyle(tint: session.attachImage ? Theme.accent : nil))
        .help(session.attachImage ? "⌘J — screenshot will be sent; press to go text-only"
                                  : "⌘J — text-only; press to attach the current screen")
    }

    private var closeButton: some View {
        Button(action: { session.dismissHandler?() }) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
        }
        .buttonStyle(OverlayIconButtonStyle(minWidth: 22, height: 22, corner: 11))
        .help("Close overlay")
    }

    private var clearButton: some View {
        Button(action: { session.clearHandler?() }) {
            Image(systemName: "trash")
                .font(.system(size: 13))
        }
        .buttonStyle(OverlayIconButtonStyle())
        .help("Clear conversation and start a fresh session")
    }

    // MARK: - History (past Claude CLI sessions)

    private var historyButton: some View {
        Button(action: { showHistory.toggle() }) {
            HStack(spacing: 4) {
                Text("History").font(.system(size: 11.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 8.5, weight: .bold))
            }
            .padding(.horizontal, 8)
        }
        .buttonStyle(OverlayIconButtonStyle(minWidth: 28, height: 28))
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
        HStack(spacing: 2) {
            HStack(spacing: 7) {
                Circle()
                    .fill(session.backendConnected ? Theme.success : Theme.danger)
                    .frame(width: 6, height: 6)
                    .shadow(color: session.backendConnected ? Theme.success.opacity(0.8) : .clear, radius: 4)
                Text(session.backendLabel)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let model = session.modelName, !model.isEmpty {
                    Text(model)
                        .fontWeight(.medium)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .font(.system(size: 11.5))
            Spacer(minLength: 12)
            if !session.turns.isEmpty {
                clearButton
            }
            if session.showsHistory {
                historyButton
            }
            attachButton
            Button(action: { session.settingsHandler?() }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
            }
            .buttonStyle(OverlayIconButtonStyle())
            .help("Settings")
        }
        .padding(.leading, 22).padding(.trailing, 12).padding(.vertical, 6)
        .overlay(Divider().overlay(Theme.hairline), alignment: .top)
    }

    /// Keycap hint ("↩ Ask") — a bottom-weighted edge reads as a physical key.
    private func kbd(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.glassBorder, lineWidth: 1))
    }

    private var placeholder: String {
        if !session.turns.isEmpty {
            return session.attachImage ? "Ask a follow-up (with current screen)…" : "Ask a follow-up (text only)…"
        }
        return session.attachImage ? "Ask about what's on screen…" : "Ask anything (no screenshot)…"
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy, animated: Bool = false) {
        guard let last = session.turns.last?.id else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
        } else {
            proxy.scrollTo(last, anchor: .bottom)
        }
    }
}

/// Tracks whether the user has the transcript scrolled to the bottom.
/// NSScrollView live-scroll notifications fire ONLY for user-initiated
/// scrolling (trackpad, wheel, scroller drag) — programmatic scrollTo()
/// never posts them — so user intent needs no ignore-my-own-scroll flag.
/// Sits invisibly in the ScrollView's content to reach enclosingScrollView.
private struct ScrollPinTracker: NSViewRepresentable {
    @Binding var pinned: Bool

    func makeNSView(context: Context) -> TrackerView { TrackerView() }

    func updateNSView(_ view: TrackerView, context: Context) {
        view.onUserScroll = { distanceFromBottom in
            let nowPinned = distanceFromBottom < 50
            if nowPinned != pinned { pinned = nowPinned }
        }
    }

    final class TrackerView: NSView {
        var onUserScroll: ((CGFloat) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard observers.isEmpty, let scroll = enclosingScrollView else { return }
            // didLiveScroll fires throughout the gesture and momentum;
            // didEndLiveScroll catches the settled position.
            for name in [NSScrollView.didLiveScrollNotification,
                         NSScrollView.didEndLiveScrollNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: scroll, queue: .main
                ) { [weak self, weak scroll] _ in
                    guard let scroll, let doc = scroll.documentView else { return }
                    let clip = scroll.contentView
                    let distance = doc.isFlipped
                        ? doc.frame.height - clip.bounds.maxY
                        : clip.bounds.minY
                    self?.onUserScroll?(distance)
                })
            }
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
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
