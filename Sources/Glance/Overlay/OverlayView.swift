import SwiftUI

/// FR3/FR11/FR13: translucent overlay — auto-focused input plus a streaming,
/// Markdown-rendered answer area with a visible working state. Kept minimal by
/// design (owner: "keep minimal, just polish").
struct OverlayView: View {
    @ObservedObject var session: OverlaySession
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !session.turns.isEmpty {
                transcript
                Divider().opacity(0.35).padding(.vertical, 4)
            }
            inputRow
            footerHint
        }
        .padding(16)
        .frame(width: 640)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { inputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(session.turns) { turn in
                        VStack(alignment: .leading, spacing: 8) {
                            questionBubble(turn.question)
                            answerBlock(turn)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(turn.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(maxHeight: 380)
            .onChange(of: session.turns.last?.answer) { _, _ in scrollToEnd(proxy) }
            .onChange(of: session.turns.count) { _, _ in scrollToEnd(proxy) }
        }
    }

    private func questionBubble(_ text: String) -> some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.accentColor.opacity(0.85)))
        }
    }

    @ViewBuilder private func answerBlock(_ turn: OverlaySession.Turn) -> some View {
        if turn.answer.isEmpty && session.isWorking && turn.id == session.turns.last?.id {
            workingRow
        } else if turn.failed {
            Label(turn.answer, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            MarkdownText(text: turn.answer)
                .font(.system(size: 14))
        }
    }

    private var placeholder: String {
        if !session.turns.isEmpty {
            return session.attachImage ? "Ask a follow-up (with current screen)…" : "Ask a follow-up (no screenshot)…"
        }
        return session.attachImage ? "Ask about what's on screen…" : "Ask anything (no screenshot)…"
    }

    private var workingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").foregroundStyle(.secondary).font(.system(size: 13))
        }
    }

    private var inputRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkle.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(placeholder, text: $session.input)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($inputFocused)
                .onSubmit { session.submit() }
            // Attach-screenshot toggle — available on every message. On follow-
            // ups with it on, a fresh screenshot of the current screen is sent.
            Button(action: { session.attachImage.toggle() }) {
                Image(systemName: session.attachImage ? "photo.fill" : "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(session.attachImage ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(session.attachImage ? "Screenshot will be sent — click to ask without it"
                                      : "Text-only — click to attach the current screen")
            Button(action: { session.submit() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(session.canSubmit ? Color.accentColor : Color.secondary.opacity(0.5))
            }
            .buttonStyle(.plain)
            .disabled(!session.canSubmit)
        }
        .padding(.vertical, 2)
    }

    private var footerHint: some View {
        HStack(spacing: 10) {
            hint("return", "send")
            hint("escape", "dismiss")
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    private func hint(_ symbol: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(label)
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = session.turns.last?.id {
            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last, anchor: .bottom) }
        }
    }
}
