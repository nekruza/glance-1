import SwiftUI

/// The spatial canvas — Board and Inbox tabs. Cards float on a dot grid:
/// undragged ones flow into columns (order = pins + current sort), dragged
/// ones stay where the user left them until "Tidy". Board mode adds the
/// completion overlays (confetti, momentum meter, undo toast, quick capture);
/// inbox mode is a triage surface (accept / archive).
struct CanvasView: View {
    enum Mode { case board, inbox }

    @ObservedObject var session: TaskBoardSession
    @ObservedObject var store: TaskStore
    var mode: Mode = .board

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Measured card heights (PreferenceKey) — flow layout input.
    @State private var cardHeights: [UUID: CGFloat] = [:]
    /// Ephemeral stacking order; dragging lifts a card to the top.
    @State private var zTop: [UUID] = []
    /// N-key monitor token.
    @State private var keyMonitor: Any?

    static let margin: CGFloat = DS.Space.lg
    static let gutter: CGFloat = DS.Space.lg
    static let topInset: CGFloat = 76      // room for the floating pill
    private static let estimatedHeight: CGFloat = 96

    var body: some View {
        GeometryReader { geo in
            let tasks = mode == .board ? session.canvasTasks() : session.inboxCanvasTasks()
            let positions = layout(tasks, width: geo.size.width)
            let contentHeight = max(geo.size.height,
                                    (positions.values.map { $0.y }.max() ?? 0) + 260)

            ZStack {
                ScrollView(.vertical) {
                    ZStack(alignment: .topLeading) {
                        DotGrid()
                            .frame(width: geo.size.width, height: contentHeight)

                        if tasks.isEmpty {
                            emptyState
                                .frame(width: geo.size.width, height: geo.size.height)
                        }

                        ForEach(tasks) { task in
                            TaskCanvasCard(
                                session: session,
                                task: task,
                                origin: positions[task.id] ?? CGPoint(x: Self.margin, y: Self.topInset),
                                onDragEnd: { end in
                                    // Freeze every other auto-placed card at its
                                    // current spot first — dragging one card out
                                    // of the flow must not reflow the rest.
                                    for other in tasks
                                    where other.id != task.id && other.canvasPosition == nil {
                                        if let p = positions[other.id] {
                                            store.setCanvasPosition(other.id, x: p.x, y: p.y)
                                        }
                                    }
                                    let x = min(max(end.x, DS.Space.xs),
                                                geo.size.width - TaskCanvasCard.width - DS.Space.xs)
                                    let y = max(end.y, DS.Space.xs)
                                    store.setCanvasPosition(task.id, x: x, y: y)
                                },
                                onDragStart: { lift(task.id) }
                            )
                            .background(heightReader(task.id))
                            .zIndex(zIndex(task.id))
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.6).combined(with: .opacity),
                                removal: .scale(scale: 0.85).combined(with: .opacity)))
                        }

                        if mode == .board {
                            ConfettiOverlay(bursts: session.confettiBursts)
                                .frame(width: geo.size.width, height: contentHeight)
                        }
                    }
                    .frame(width: geo.size.width, height: contentHeight, alignment: .topLeading)
                }
                .onPreferenceChange(CardHeightKey.self) { cardHeights = $0 }
                .animation(reduceMotion ? nil : DS.spring,
                           value: tasks.map(\.id))
                .animation(reduceMotion ? nil : DS.spring,
                           value: store.tasks.map { "\($0.id)\($0.canvasX ?? -1),\($0.canvasY ?? -1)" })

                overlays
            }
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    // MARK: - Flow layout

    /// Masonry columns for undragged cards; persisted positions win (x clamped
    /// to the viewport at render time — never written back).
    private func layout(_ tasks: [TaskItem], width: CGFloat) -> [UUID: CGPoint] {
        var result: [UUID: CGPoint] = [:]
        let usable = width - Self.margin * 2
        let cols = max(1, Int((usable + Self.gutter) / (TaskCanvasCard.width + Self.gutter)))
        var colY = [CGFloat](repeating: Self.topInset, count: cols)

        // Pass 1 — pinned-in-place (dragged) cards: clamp to viewport and
        // advance their column's floor so flowed cards don't stack under them.
        for task in tasks {
            guard let pos = task.canvasPosition else { continue }
            let x = min(max(pos.x, DS.Space.xs), max(DS.Space.xs, width - TaskCanvasCard.width - DS.Space.xs))
            let y = max(pos.y, DS.Space.xs)
            result[task.id] = CGPoint(x: x, y: y)
            let col = min(cols - 1, max(0, Int(round((x - Self.margin) / (TaskCanvasCard.width + Self.gutter)))))
            let bottom = y + (cardHeights[task.id] ?? Self.estimatedHeight) + DS.Space.lg - 4
            colY[col] = max(colY[col], bottom)
        }

        // Pass 2 — flow the rest into the shortest column.
        for task in tasks where task.canvasPosition == nil {
            let col = colY.enumerated().min { $0.element < $1.element }?.offset ?? 0
            result[task.id] = CGPoint(x: Self.margin + CGFloat(col) * (TaskCanvasCard.width + Self.gutter),
                                      y: colY[col])
            colY[col] += (cardHeights[task.id] ?? Self.estimatedHeight) + DS.Space.lg - 4
        }
        return result
    }

    private func lift(_ id: UUID) {
        zTop.removeAll { $0 == id }
        zTop.append(id)
    }

    private func zIndex(_ id: UUID) -> Double {
        if let idx = zTop.firstIndex(of: id) { return Double(idx) + 1 }
        return 0
    }

    private func heightReader(_ id: UUID) -> some View {
        GeometryReader { g in
            Color.clear.preference(key: CardHeightKey.self, value: [id: g.size.height])
        }
    }

    // MARK: - Overlays (viewport-fixed)

    @ViewBuilder private var overlays: some View {
        // Hint pill, bottom-left (mockup); momentum meter on board only.
        VStack {
            Spacer()
            HStack {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                    Text(mode == .board
                         ? "Drag to arrange · click a title to open details"
                         : "New work lands here · accept to move it onto Todo")
                        .font(DS.Typo.caption)
                        .foregroundStyle(DS.textSecondary)
                }
                .padding(.horizontal, DS.Space.sm)
                .padding(.vertical, DS.Space.xs)
                .background(Capsule().fill(DS.bg))
                .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))

                Spacer()

                if mode == .board {
                    MomentumMeter(store: store)
                } else if session.inboxCanvasTasks().count > 1 {
                    // Bulk triage twin of the old list's "Accept all" bar.
                    Button(action: {
                        for t in session.inboxCanvasTasks() { store.acceptFromInbox(t.id) }
                    }) {
                        Label("Accept all \(session.inboxCanvasTasks().count)",
                              systemImage: "checkmark.circle")
                            .font(DS.Typo.label)
                    }
                    .buttonStyle(DSSecondaryButtonStyle())
                    .foregroundStyle(DS.accentText)
                    .help("Move everything in the Inbox onto the canvas")
                }
            }
            .padding(DS.Space.md)
        }

        // Undo toast, bottom-center.
        if mode == .board, let toast = session.undoToast {
            VStack {
                Spacer()
                HStack(spacing: DS.Space.sm) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(DS.success)
                    Text(toast.title)
                        .font(DS.Typo.label)
                        .foregroundStyle(DS.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: 260)
                    Button("Undo") { session.undoComplete() }
                        .buttonStyle(.plain)
                        .font(DS.Typo.headline)
                        .foregroundStyle(DS.accentText)
                }
                .padding(.horizontal, DS.Space.md)
                .padding(.vertical, DS.Space.xs + 2)
                .background(Capsule().fill(DS.bg)
                    .shadow(color: DS.Shadow.card, radius: DS.Shadow.cardHoverRadius, y: DS.Shadow.cardY))
                .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
                .padding(.bottom, DS.Space.xl + DS.Space.md)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .animation(reduceMotion ? nil : DS.spring, value: session.undoToast)
        }

        // Quick capture, top-center (board only — capture creates board tasks).
        if mode == .board, session.showCapture {
            CaptureCard(session: session)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, Self.topInset + DS.Space.md)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: DS.Space.sm) {
            if mode == .board {
                Text("All done.")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                (Text("Everything's done, or nothing's captured yet.\nPress ")
                 + Text(" N ").font(DS.Typo.mono).foregroundColor(DS.textSecondary)
                 + Text(" to drop a task."))
                    .font(.system(size: 16))
                    .foregroundStyle(DS.textTertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Inbox zero.")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(DS.textPrimary)
                Text("Pulled work from Jira, Slack, Granola and Calendar\nlands here for your accept.")
                    .font(.system(size: 16))
                    .foregroundStyle(DS.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
    }

    // MARK: - N key (quick capture)

    private func installKeyMonitor() {
        guard mode == .board, keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "n",
                  event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
                  let window = event.window, window.isKeyWindow,
                  !(window.firstResponder is NSTextView),   // not typing in a field
                  !session.showCapture,
                  session.tab == .board,
                  session.selectedTask == nil,
                  !session.showSettings,
                  !session.decomposeMode
            else { return event }
            session.showCapture = true
            return nil // swallow the keystroke
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Dot grid

/// The mockup's dot-grid paper. One Canvas pass, GPU-cached.
private struct DotGrid: View {
    var body: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 24
            let r: CGFloat = 1
            var y: CGFloat = pitch
            while y < size.height {
                var x: CGFloat = pitch
                while x < size.width {
                    ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                             with: .color(DS.dot))
                    x += pitch
                }
                y += pitch
            }
        }
        .drawingGroup()
        .allowsHitTesting(false)
    }
}

// MARK: - Height preference

private struct CardHeightKey: PreferenceKey {
    static var defaultValue: [UUID: CGFloat] = [:]
    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
