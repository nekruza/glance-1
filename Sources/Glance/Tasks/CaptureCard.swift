import SwiftUI

/// Floating quick-capture card (N key / pill "+"). Enter drops the task onto
/// the canvas (same create-then-AI-enrich path as the old quick-add row);
/// Esc dismisses. The decompose flow stays reachable via the footer link.
struct CaptureCard: View {
    @ObservedObject var session: TaskBoardSession
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Image(systemName: "plus.circle.fill")
                    .font(DS.Typo.headline)
                    .foregroundStyle(DS.accentText)
                TextField("", text: $session.quickAdd,
                          prompt: Text("Drop a task…").foregroundColor(DS.textTertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .tint(DS.accentText)
                    .focused($focused)
                    .onSubmit {
                        session.submitQuickAdd()
                        session.showCapture = false
                    }
            }
            HStack {
                Button(action: {
                    session.showCapture = false
                    session.startDecompose()
                }) {
                    Label("Paste a braindump instead", systemImage: "text.badge.plus")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .buttonStyle(.plain)
                .help("AI splits it into tasks you confirm")

                Spacer()

                Text("↩ add · esc close")
                    .font(DS.Typo.overline)
                    .foregroundStyle(DS.textTertiary)
            }
        }
        .padding(DS.Space.md)
        .frame(width: 480)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .fill(DS.bg)
                .shadow(color: .black.opacity(0.14), radius: 24, y: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .strokeBorder(DS.accent, lineWidth: 1)
        )
        .onAppear { focused = true }
        .onExitCommand {
            session.quickAdd = ""
            session.showCapture = false
        }
    }
}
