import SwiftUI

/// Floating navigation capsule at the top of the Tasks window: tabs with the
/// inbox badge, quick-capture "+", expandable search, Tidy (with sort menu),
/// AI prioritize, and the Composio pull menu. Replaces the old full-width
/// header so the canvas reads as one uninterrupted surface.
struct TabPill: View {
    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore
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

            if session.tab == .board { tidyControl }

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
                                Text(n > 99 ? "99+" : "\(n)")
                                    .font(DS.Typo.overline)
                                    .foregroundStyle(tab == .inbox ? DS.accentText : DS.textSecondary)
                                    .padding(.horizontal, DS.Space.xxs)
                                    .frame(minWidth: 15, minHeight: 15)
                                    .background(Capsule().fill(tab == .inbox ? DS.accentSoft : DS.surfaceHover))
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

    /// Board reads as "Canvas" in the new design; the enum rawValue stays
    /// untouched (persistence + logic depend on it).
    static func title(_ tab: TaskBoardSession.Tab) -> String {
        tab == .board ? "Canvas" : tab.rawValue
    }

    private func tabCount(_ tab: TaskBoardSession.Tab) -> Int? {
        switch tab {
        case .inbox: return store.inboxTasks().count
        case .board: return store.boardTasks().count
        case .done: return store.doneTasks().count
        case .activity: return nil
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
            .help("Arrange all cards by \(session.sortMode.rawValue)")

            Menu {
                ForEach(TaskBoardSession.SortMode.allCases, id: \.self) { mode in
                    Button(action: { session.sortMode = mode }) {
                        HStack {
                            Text(mode.rawValue)
                            if session.sortMode == mode { Image(systemName: "checkmark") }
                        }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(DS.Typo.overline)
                    .foregroundStyle(session.sortMode == .aiRank ? DS.textTertiary : DS.accentText)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Tidy order: \(session.sortMode.rawValue)")
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
        if let src = session.pullingSource {
            HStack(spacing: DS.Space.xxs) {
                ProgressView().controlSize(.mini)
                Text("Pulling \(src.rawValue)…").font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
            }
            .padding(.horizontal, DS.Space.xxs)
        } else {
            Hover { hovering in
                Menu {
                    Button("Pull from all") { session.pullAll() }
                    Divider()
                    ForEach(ComposioIngest.Source.allCases, id: \.self) { src in
                        Button("Pull from \(src.rawValue)") { session.pull(src) }
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
