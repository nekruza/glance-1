import SwiftUI

/// Floating navigation capsule at the top of the Tasks window: tabs with the
/// inbox badge, quick-capture "+", expandable search, Tidy (with sort menu),
/// AI prioritize, and the Composio pull menu. Replaces the old full-width
/// header so the canvas reads as one uninterrupted surface.
struct TabPill: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore
    /// Observed (not read statically) so the pull menu re-renders live when
    /// connectors are toggled in Settings ▸ Connections.
    @ObservedObject private var prefs = Preferences.shared
    @FocusState private var searchFocused: Bool
    @State private var searchOpen = false

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            tabs
            pillDivider

            iconButton("plus", help: "New task (N)") {
                session.showCapture = true
            }

            searchControl

            if session.tab == .board || session.tab == .inbox { tidyControl }

            prioritizeControl
            pullControl
        }
        .padding(.horizontal, DS.Space.xs)
        .padding(.vertical, DS.Space.xxs + 1)
        .background(
            Capsule()
                .fill(DS.bg)
                .shadow(color: DS.Shadow.card, radius: DS.Shadow.cardRadius, y: DS.Shadow.cardY)
        )
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
    }

    private var pillDivider: some View {
        Rectangle().fill(DS.divider).frame(width: 1, height: 16)
            .padding(.horizontal, DS.Space.xxs)
    }

    // MARK: - Tabs

    private var tabs: some View {
        HStack(spacing: 2) {
            ForEach(TaskBoardSession.Tab.allCases, id: \.self) { tab in
                let selected = session.tab == tab
                Hover { hovering in
                    Button(action: { session.tab = tab }) {
                        HStack(spacing: DS.Space.xxs) {
                            Text(Self.title(tab))
                                .font(selected ? DS.Typo.headline : DS.Typo.body)
                                .foregroundStyle(selected ? DS.textPrimary : DS.textSecondary)
                            if let n = tabCount(tab), n > 0 {
                                let callout = tab == .inbox || tab == .review
                                Text(n > 99 ? "99+" : "\(n)")
                                    .font(DS.Typo.overline)
                                    .foregroundStyle(callout ? DS.accentText : DS.textSecondary)
                                    .padding(.horizontal, DS.Space.xxs)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(callout ? DS.accentSoft : DS.surfaceHover))
                            }
                        }
                        .padding(.horizontal, DS.Space.xs + 2)
                        .padding(.vertical, DS.Space.xxs)
                        .background(
                            Capsule().fill(selected ? DS.surface
                                           : (hovering ? DS.surfaceHover.opacity(0.6) : .clear))
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(Self.title(tab)) tab")
                }
            }
        }
    }

    /// Board reads as "Todo" in the new design; the enum rawValue stays
    /// untouched (persistence + logic depend on it).
    static func title(_ tab: TaskBoardSession.Tab) -> String {
        tab == .board ? "Todo" : tab.rawValue
    }

    private func tabCount(_ tab: TaskBoardSession.Tab) -> Int? {
        switch tab {
        case .inbox: return store.inboxTasks().count
        case .board: return store.boardTasks().count
        case .review: return session.reviewTasks().count
        case .done: return store.doneTasks().count
        }
    }

    // MARK: - Search (collapsed to an icon until needed)

    @ViewBuilder private var searchControl: some View {
        if searchOpen || !session.searchText.isEmpty {
            HStack(spacing: DS.Space.xxs) {
                Image(systemName: "magnifyingglass")
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.textTertiary)
                TextField("", text: $session.searchText,
                          prompt: Text("Search").foregroundColor(DS.textTertiary))
                    .textFieldStyle(.plain)
                    .font(DS.Typo.body)
                    .focused($searchFocused)
                    .onExitCommand {
                        session.searchText = ""
                        searchOpen = false
                    }
                if !session.searchText.isEmpty {
                    Button(action: { session.searchText = ""; searchOpen = false }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(DS.Typo.caption)
                            .foregroundStyle(DS.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 150)
            .padding(.horizontal, DS.Space.xs)
            .padding(.vertical, 3)
            .background(Capsule().fill(DS.surface))
            .onAppear { searchFocused = true }
        } else {
            iconButton("magnifyingglass", help: "Search") {
                searchOpen = true
            }
        }
    }

    // MARK: - Tidy + sort (canvas only)

    private var tidyControl: some View {
        HStack(spacing: 0) {
            Hover { hovering in
                Button(action: { session.tidyCanvas() }) {
                    Label("Tidy", systemImage: "square.grid.2x2")
                        .font(DS.Typo.label)
                        .foregroundStyle(DS.textSecondary)
                        .padding(.horizontal, DS.Space.xs)
                        .padding(.vertical, DS.Space.xxs)
                        .background(Capsule().fill(hovering ? DS.surfaceHover : .clear))
                }
                .buttonStyle(.plain)
            }
            .help("Arrange into 4 columns — Coding / Communication / Research / Other — ordered by the sort at right")

            Menu {
                Section("Sort columns by") {
                    ForEach(TaskBoardSession.SortMode.allCases, id: \.self) { mode in
                        Button(action: { session.sortMode = mode }) {
                            HStack {
                                Text(mode.rawValue)
                                if session.sortMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 2) {
                    Text(session.sortMode.rawValue)
                    Image(systemName: "chevron.down")
                }
                .font(DS.Typo.overline)
                .foregroundStyle(session.sortMode == .aiRank ? DS.textTertiary : DS.accentText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Column order when you Tidy: \(session.sortMode.rawValue)")
        }
    }

    // MARK: - Prioritize + pull (moved verbatim from the old header)

    @ViewBuilder private var prioritizeControl: some View {
        if session.isPrioritizing {
            HStack(spacing: DS.Space.xxs) {
                ProgressView().controlSize(.mini)
                Text("Prioritizing…").font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Space.xxs)
        } else {
            iconButton("wand.and.stars", help: "Re-prioritize with AI") {
                session.schedulePrioritize(force: true)
            }
        }
    }

    @ViewBuilder private var pullControl: some View {
        if let target = session.pullingSource {
            HStack(spacing: DS.Space.xxs) {
                ProgressView().controlSize(.mini)
                Text("Pulling \(target.displayName)…").font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Space.xxs)
        } else if session.pullAllRemaining > 0 {
            HStack(spacing: DS.Space.xxs) {
                ProgressView().controlSize(.mini)
                Text("Pulling \(session.pullAllRemaining) source\(session.pullAllRemaining == 1 ? "" : "s")…")
                    .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Space.xxs)
        } else {
            Hover { hovering in
                Menu {
                    Button("Pull from all") { session.pullAll() }
                    Divider()
                    ForEach(prefs.enabledFetchTargets) { target in
                        Button("Pull from \(target.displayName)") { session.pull(target) }
                    }
                } label: {
                    Image(systemName: "tray.and.arrow.down")
                        .font(DS.Typo.label)
                        .foregroundStyle(DS.textSecondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .padding(DS.Space.xxs)
                .background(Circle().fill(hovering ? DS.surfaceHover : .clear))
            }
            .help("Fetch new work into the Inbox (read-only)")
        }
    }

    // MARK: - Helpers

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Hover { hovering in
            Button(action: action) {
                Image(systemName: symbol)
                    .font(DS.Typo.label)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                    .padding(DS.Space.xxs + 1)
                    .background(Circle().fill(hovering ? DS.surfaceHover : .clear))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(help)
        }
        .help(help)
    }
}
