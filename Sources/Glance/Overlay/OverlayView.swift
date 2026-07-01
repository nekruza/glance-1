import SwiftUI

/// Dark-glass overlay built to the screens/ visual contract (01-overlay-idle,
/// 02-overlay-answer). Idle = prompt + context strip + backend footer; answer =
/// asked header(s) + streamed Markdown + follow-up bar + footer.
struct OverlayView: View {
    @ObservedObject var session: OverlaySession
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if session.turns.isEmpty {
                promptRow
            } else {
                transcript
                followUpBar
            }
            footer
        }
        .frame(width: Theme.overlayWidth)
        .background(glass)
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: .black.opacity(0.55), radius: 40, y: 24)
        .foregroundStyle(Theme.fg)
        .onAppear { inputFocused = true }
    }

    // MARK: - Surface

    private var glass: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(.regularMaterial)
            // Opaque-enough dark tint so background UI (editor text, tooltips)
            // doesn't bleed through and hurt readability. Still a hint of glass.
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.glassTint.opacity(0.9))
        }
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
            TextField("", text: $session.input, prompt: Text(placeholder).foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
            attachButton
            kbd("↩ Ask")
        }
        .padding(.horizontal, 22).padding(.vertical, 20)
    }

    private var thumbnail: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(LinearGradient(colors: [Theme.glassTint, Color(red: 26/255, green: 33/255, blue: 48/255)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: 52, height: 33)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.glassBorderHi, lineWidth: 1))
            .opacity(session.attachImage ? 1 : 0.4)
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
                askedHeader(turn, showThumb: idx == 0 && session.attachImage)
                answerBlock(turn)
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 18)
                if idx < session.turns.count - 1 {
                    Divider().overlay(Theme.glassBorder)
                }
                Color.clear.frame(height: 1).id(turn.id)
            }
        }
    }

    private func askedHeader(_ turn: OverlaySession.Turn, showThumb: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            spark.font(.system(size: 16, weight: .semibold))
            Text(turn.question)
                .font(.system(size: 17))
                .frame(maxWidth: .infinity, alignment: .leading)
            if showThumb {
                thumbnail.frame(width: 44, height: 28)
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
                .font(.system(size: 15))
        }
    }

    private var workingRow: some View {
        HStack(spacing: 10) {
            BouncingDots()
            Text(session.turns.count <= 1 ? "Reading your screen…" : "Thinking…")
                .foregroundStyle(Theme.muted).font(.system(size: 14))
        }
    }

    private var followUpBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.faint)
            TextField("", text: $session.input,
                      prompt: Text(placeholder).foregroundColor(Theme.faint))
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .tint(Theme.accent)
                .focused($inputFocused)
                .onSubmit { session.submit() }
            attachButton
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
        .background(Color.white.opacity(0.03))
        .overlay(Divider().overlay(Theme.glassBorder), alignment: .top)
    }

    // MARK: - Shared controls

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
            Text("Backend · Claude CLI (local)")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
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
