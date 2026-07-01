import SwiftUI

/// FR3/FR11/FR13: translucent overlay content — auto-focused input plus a
/// streaming, Markdown-rendered answer area with a visible working state.
struct OverlayView: View {
    @ObservedObject var session: OverlaySession
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !session.turns.isEmpty {
                transcript
                Divider().opacity(0.4)
            }
            inputRow
        }
        .padding(14)
        .frame(width: 620)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .onAppear { inputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.turns) { turn in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(turn.question)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                            if turn.answer.isEmpty && session.isWorking && turn.id == session.turns.last?.id {
                                workingRow
                            } else if turn.failed {
                                Text(turn.answer)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                MarkdownText(text: turn.answer)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(turn.id)
                    }
                }
                .padding(.bottom, 4)
            }
            .frame(maxHeight: 360)
            .onChange(of: session.turns.last?.answer) { _, _ in
                if let last = session.turns.last?.id {
                    withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
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
            TextField(session.turns.isEmpty ? "Ask about what's on screen…" : "Ask a follow-up…",
                      text: $session.input)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($inputFocused)
                .onSubmit { session.submit() }
            if session.isWorking {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.vertical, 4)
    }
}
