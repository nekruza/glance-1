import SwiftUI

/// One task card on the spatial canvas (mockup: white, radius 14, soft
/// shadow). Checkbox completes with celebration; the title opens details;
/// dragging the body arranges. Hover reveals the same quick actions the old
/// list rows had (run / pin / snooze / archive) — plus a context menu twin.
struct TaskCanvasCard: View {
    @ObservedObject var session: TaskBoardSession
    let task: TaskItem
    /// Card origin in canvas coordinates (persisted or flow-assigned).
    let origin: CGPoint
    /// Drag ended — new origin, already translated (canvas coords, unclamped).
    let onDragEnd: (CGPoint) -> Void
    let onDragStart: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var checkboxHover = false
    @State private var dragOffset: CGSize = .zero
    @State private var dragging = false

    static let width: CGFloat = 340

    private var completing: Bool { session.completingTaskIds.contains(task.id) }
    private var matches: Bool { session.matchesSearch(task) }
    /// Inbox cards triage instead of complete: the circle accepts onto the board.
    private var isInbox: Bool { task.status == .inbox }
    /// All steps done but the task itself isn't — nudge, never auto-complete.
    private var stepsSuggestDone: Bool {
        !task.stepList.isEmpty && task.stepsDone == task.stepList.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                checkbox
                titleRow
                Spacer(minLength: 0)
            }
            metaRow
                .padding(.leading, 28 + DS.Space.sm)
            if !task.stepList.isEmpty { stepsBar }
        }
        .padding(DS.Space.md)
        .frame(width: Self.width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .fill(DS.bg)
                .shadow(color: DS.Shadow.card,
                        radius: hovering || dragging ? DS.Shadow.cardHoverRadius : DS.Shadow.cardRadius,
                        y: hovering || dragging ? DS.Shadow.cardHoverY : DS.Shadow.cardY)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .strokeBorder(stepsSuggestDone ? DS.accent : DS.border.opacity(0.6),
                              lineWidth: stepsSuggestDone ? 1.5 : 1)
        )
        // Provenance strip: full-height bar on the trailing edge, color by
        // source (grey = added in-app). A card-sized rounded rect masked to its
        // right 4pt so the strip's top/bottom follow the card's corner radius
        // exactly (a 4pt-wide shape can't itself hold the 14pt corner).
        .overlay {
            RoundedRectangle(cornerRadius: DS.Radius.large)
                .fill(DS.sourceAccent(task.source))
                .mask(alignment: .trailing) { Rectangle().frame(width: 4) }
                .help("From \(task.source.displayName)")
        }
        .scaleEffect(cardScale)
        .opacity(matches ? 1 : 0.25)
        .allowsHitTesting(matches)
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.large))
        // Overlay, not a layout row: hover must not change the measured card
        // height (that would reflow neighbouring cards).
        .overlay(alignment: .bottomTrailing) {
            if hovering && !completing {
                hoverActions
                    .padding(DS.Space.xs)
            }
        }
        .onHover { hovering = $0 }
        .contextMenu { menuActions }
        .offset(x: origin.x + dragOffset.width, y: origin.y + dragOffset.height)
        .gesture(dragGesture)
        .animation(reduceMotion ? nil : DS.pop, value: completing)
        .animation(reduceMotion ? nil : DS.spring, value: hovering)
    }

    private var cardScale: CGFloat {
        if completing && !reduceMotion { return 1.04 }
        if dragging { return 1.02 }
        return 1
    }

    // MARK: - Drag to arrange

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                if !dragging {
                    dragging = true
                    onDragStart()
                }
                dragOffset = value.translation
            }
            .onEnded { value in
                dragging = false
                dragOffset = .zero
                onDragEnd(CGPoint(x: origin.x + value.translation.width,
                                  y: origin.y + value.translation.height))
            }
    }

    // MARK: - Checkbox (the satisfying part)

    private var checkbox: some View {
        Button(action: {
            if isInbox {
                session.store.acceptFromInbox(task.id)
                return
            }
            // Burst at the checkbox centre, canvas coords.
            let point = CGPoint(x: origin.x + DS.Space.md + 14,
                                y: origin.y + DS.Space.md + 14)
            session.complete(task, at: point)
        }) {
            ZStack {
                // Filled green when checked; the fill also makes the whole
                // circle hittable (a bare stroke has a transparent, unhittable
                // interior — clicks fell straight through).
                Circle()
                    .fill(completing ? DS.success : DS.bg)
                Circle()
                    .strokeBorder(completing ? DS.success : (checkboxHover ? DS.accentText : DS.border),
                                  lineWidth: 1.5)
                CheckmarkShape()
                    .trim(from: 0, to: completing ? 1 : 0)
                    .stroke(.white, style: StrokeStyle(lineWidth: 2.5,
                                                       lineCap: .round, lineJoin: .round))
                    .frame(width: 13, height: 11)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: completing)
            }
            .frame(width: 28, height: 28)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { checkboxHover = $0 }
        .help(isInbox ? "Accept onto canvas" : "Mark done")
        .accessibilityLabel(isInbox ? "Accept: \(task.title)" : "Complete: \(task.title)")
        .overlay(alignment: .bottom) {
            if stepsSuggestDone && !completing {
                Text("Done?")
                    .font(DS.Typo.overline)
                    .foregroundStyle(DS.accentText)
                    .padding(.horizontal, DS.Space.xxs)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.accentSoft))
                    .offset(y: 16)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Title + meta

    private var titleRow: some View {
        HStack(spacing: DS.Space.xxs + 2) {
            if task.isPinned {
                Image(systemName: "pin.fill").font(DS.Typo.overline).foregroundStyle(DS.accentText)
            }
            Button(action: { session.selectedTaskId = task.id }) {
                Text(task.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
            }
            .buttonStyle(.plain)
            .help("Open details")
            .accessibilityLabel(task.title)
            if task.possibleDuplicateOf != nil {
                dsBadge("dup?", tint: DS.warning, soft: DS.warningSoft)
                    .help("Looks like existing work — open to merge or dismiss")
            }
        }
    }

    private var metaRow: some View {
        // WrapLayout, not HStack: at the fixed 340 card width a single row of
        // fixed-size badges overflows once labels are long, and HStack shrinks
        // the only flexible child (the due-date Text) to one glyph wide — it
        // then wraps vertically ("1 0 J u l"). Wrapping reflows overflow onto a
        // second line and proposes each item its ideal width, so nothing squeezes.
        WrapLayout(spacing: DS.Space.xs, lineSpacing: DS.Space.xxs) {
            priorityTag

            if let due = task.dueAt {
                let d = Self.dueLabel(due)
                HStack(spacing: 3) {
                    Image(systemName: "clock")
                    Text(d.text)
                }
                .font(DS.Typo.caption)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(d.color)
            }

            ForEach(task.labels.prefix(2), id: \.self) { label in
                dsBadge(label, tint: DS.textSecondary, soft: DS.surface)
            }

            if let agent = Preferences.shared.agent(task.agentId) {
                HStack(spacing: 3) {
                    AgentAvatarView(agent: agent, size: 14)
                    Text(agent.displayName)
                        .font(DS.Typo.caption).foregroundStyle(DS.textSecondary)
                        .lineLimit(1).fixedSize()
                }
                .help("\(agent.displayName) · \(agent.name)")
            }

            statusBadge

            Image(systemName: task.source.icon)
                .font(DS.Typo.overline)
                .foregroundStyle(DS.textTertiary)
                .help(task.source.displayName)
        }
    }

    /// Priority as an explicit label (P0/P1/P2/P3) instead of a bare dot —
    /// P0/P1 carry weight (red/amber), P2/P3 stay quiet so they don't shout.
    private var priorityTag: some View {
        let p = task.aiPriority
        let (tint, soft): (Color, Color) = {
            switch p {
            case .p0: return (DS.danger, DS.dangerSoft)
            case .p1: return (DS.warning, DS.warningSoft)
            case .p2, .p3: return (DS.textSecondary, DS.surface)
            }
        }()
        return dsBadge(p.rawValue, tint: tint, soft: soft)
            .help("Priority \(p.rawValue)")
    }

    /// Due-date chip content: "overdue"/"today" demand attention, the rest whisper.
    static func dueLabel(_ due: Date, now: Date = Date()) -> (text: String, color: Color) {
        let cal = Calendar.current
        if cal.isDate(due, inSameDayAs: now) { return ("today", DS.danger) }
        if due < now { return ("overdue", DS.danger) }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now),
           cal.isDate(due, inSameDayAs: tomorrow) { return ("tomorrow", DS.warning) }
        return (due.formatted(.dateTime.month(.abbreviated).day()), DS.textTertiary)
    }

    @ViewBuilder private var statusBadge: some View {
        let (text, tint, soft): (String, Color, Color) = {
            switch task.status {
            case .executing: return ("Running", DS.accentText, DS.accentSoft)
            case .planning: return ("Planning", DS.accentText, DS.accentSoft)
            case .awaitingPlanApproval: return ("Plan review", DS.warning, DS.warningSoft)
            case .awaitingReview: return ("Review", DS.warning, DS.warningSoft)
            case .failed: return ("Failed", DS.danger, DS.dangerSoft)
            case .queued: return ("Queued", DS.textSecondary, DS.surface)
            case .blocked: return ("Blocked", DS.warning, DS.warningSoft)
            case .inbox: return ("New", DS.accentText, DS.accentSoft)
            default: return ("", .clear, .clear)
            }
        }()
        if !text.isEmpty { dsBadge(text, tint: tint, soft: soft) }
    }

    // MARK: - Steps progress (mockup: green bar + "1/2 steps")

    private var stepsBar: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DS.surface)
                    Capsule().fill(DS.accent)
                        .frame(width: geo.size.width
                               * CGFloat(task.stepsDone) / CGFloat(max(1, task.stepList.count)))
                        .animation(reduceMotion ? nil : DS.spring, value: task.stepsDone)
                }
            }
            .frame(height: 4)
            Text("\(task.stepsDone)/\(task.stepList.count) steps")
                .font(DS.Typo.caption)
                .foregroundStyle(DS.textTertiary)
        }
        .padding(.leading, 28 + DS.Space.sm)
    }

    // MARK: - Quick actions (parity with the old list rows)

    @ViewBuilder private var hoverActions: some View {
        HStack(spacing: DS.Space.sm) {
            if task.isRunnable {
                iconButton("play.circle", "Run with AI") { session.run(task) }
            }
            if !isInbox {
                iconButton(task.isPinned ? "pin.slash" : "pin",
                           task.isPinned ? "Unpin" : "Pin to top") { session.togglePin(task) }
            }
            iconButton("moon.zzz", "Snooze 24h") { session.snooze(task) }
            iconButton("archivebox", "Archive") { session.archive(task) }
        }
        .padding(.horizontal, DS.Space.xs + 2)
        .padding(.vertical, DS.Space.xxs + 1)
        .background(Capsule().fill(DS.bg)
            .shadow(color: DS.Shadow.card, radius: 6, y: 2))
        .overlay(Capsule().strokeBorder(DS.border, lineWidth: 1))
        .transition(.opacity)
    }

    @ViewBuilder private var menuActions: some View {
        if isInbox {
            Button("Accept onto canvas") { session.store.acceptFromInbox(task.id) }
        }
        if task.isRunnable {
            Button("Run with AI") { session.run(task) }
        }
        if !isInbox {
            Button(task.isPinned ? "Unpin" : "Pin to top") { session.togglePin(task) }
        }
        Button("Snooze 24h") { session.snooze(task) }
        Button("Archive") { session.archive(task) }
        Divider()
        if !isInbox {
            Button("Mark done") {
                session.complete(task, at: CGPoint(x: origin.x + DS.Space.md + 14,
                                                   y: origin.y + DS.Space.md + 14))
            }
        }
        Button("Open details") { session.selectedTaskId = task.id }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
        Hover { hovering in
            Button(action: action) {
                Image(systemName: symbol).font(DS.Typo.label)
                    .foregroundStyle(hovering ? DS.textPrimary : DS.textSecondary)
                    .padding(DS.Space.xxs)
                    .background(Circle().fill(hovering ? DS.surfaceHover : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
        .help(help)
    }
}

/// The check stroke, drawn 0→1 by trim on completion.
struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.1))
        p.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}
