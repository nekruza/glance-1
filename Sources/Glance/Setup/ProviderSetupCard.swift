import SwiftUI
import AppKit

/// Shown in place of the prompt when the selected CLI is missing or broken:
/// what's wrong, the steps to fix it, a command to copy, and Try again.
struct ProviderSetupCard: View {
    let issue: ProviderSetupIssue
    let textScale: CGFloat
    let onRetry: () -> Void
    let onTerminal: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accent.opacity(0.14)))
                Text(issue.title)
                    .font(.system(size: 15 * textScale, weight: .semibold))
            }

            Text(inline(issue.detail))
                .font(.system(size: 13 * textScale))
                .foregroundStyle(Theme.fg.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(issue.steps.enumerated()), id: \.offset) { i, step in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(i + 1).").foregroundStyle(Theme.muted)
                            .font(.system(size: 13 * textScale, design: .monospaced))
                        Text(inline(step))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 13 * textScale))
                }
            }

            if let command = issue.copyCommand {
                HStack(spacing: 10) {
                    Text(command)
                        .font(.system(size: 12 * textScale, design: .monospaced))
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    CopyChip(helpText: "Copy command", palette: .dark) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.codeBg))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.glassBorder, lineWidth: 1))
            }

            HStack(spacing: 10) {
                Spacer()
                if let url = issue.helpURL {
                    Button("Setup guide") { NSWorkspace.shared.open(url) }
                        .buttonStyle(OverlayChipButtonStyle())
                }
                Button("Try again", action: onRetry)
                    .buttonStyle(OverlayChipButtonStyle())
                    .help("Check again now")
                if let action = issue.terminalAction {
                    Button { onTerminal(action.command) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "terminal").font(.system(size: 11, weight: .semibold))
                            Text(action.label).font(.system(size: 12.5, weight: .semibold))
                        }
                        .foregroundStyle(Color.black.opacity(0.82))
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(.plain)
                    .help("Opens Terminal and runs it — you'll see every step")
                }
            }
        }
        .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 16)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s)) ?? AttributedString(s)
    }
}
