import AppKit
import XCTest
@testable import Glance

/// Several overlay chats at once: each keeps its own transcript and CLI, and
/// keeps working while the user is in another one.
@MainActor
final class MultiChatTests: XCTestCase {
    private var made: [ChatBackendSpy] = []
    private var resumed: [ResumePoint] = []
    private var overlay: OverlayController!
    private var coordinator: AppCoordinator!
    private var directory: URL!
    private var previousBackend: AskBackendKind!
    private var previousPreflight: (() -> Bool)!
    private var previousProbe = false

    override func setUp() async throws {
        _ = NSApplication.shared
        previousBackend = Preferences.shared.askBackend
        Preferences.shared.askBackend = .codex
        // No real capture on summon: one finishing late flips the shared
        // permission cache under later suites.
        previousPreflight = ScreenCaptureService.preflight
        previousProbe = ScreenCaptureService.probedGranted
        ScreenCaptureService.preflight = { false }
        ScreenCaptureService.probedGranted = false
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("glance-multichat-\(UUID().uuidString)")
        overlay = OverlayController()
        let factory = AskBackendFactory(
            makeClaude: { [unowned self] _ in self.makeBackend() },
            makeCodex: { [unowned self] _ in self.makeBackend() },
            makeResumedClaude: { [unowned self] _, point in
                self.resumed.append(point)
                return self.makeBackend()
            },
            claudeStatus: { .ok(path: "/fixture/claude", version: "test") },
            codexStatus: { .ok(path: "/fixture/codex", version: "test") })
        coordinator = AppCoordinator(
            backendLifecycle: AskBackendLifecycle(), overlay: overlay,
            automationProviderFactory: AutomationProviderFactory(claudeStatus: { .notFound },
                                                                 codexStatus: { .notFound }),
            askBackendFactory: factory, taskStore: TaskStore(directory: directory))
        coordinator.replaceProviderServices(for: .codex)
        coordinator.summon()
        await waitUntil { self.overlay.session.submitHandler != nil }
    }

    override func tearDown() async throws {
        overlay.dismiss()
        coordinator.shutdown()
        Preferences.shared.askBackend = previousBackend
        ScreenCaptureService.preflight = previousPreflight
        ScreenCaptureService.probedGranted = previousProbe
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeBackend() -> ChatBackendSpy {
        let backend = ChatBackendSpy()
        made.append(backend)
        return backend
    }

    private func ask(_ text: String) {
        overlay.session.input = text
        overlay.session.submit()
    }

    private func settle() async {
        try? await Task.sleep(nanoseconds: 30_000_000)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), "did not settle")
    }

    /// Ask in the current chat and let the answer finish.
    private func answeredChat(_ question: String, answer: String) async {
        ask(question)
        let backend = made.last!
        backend.emit(.token(answer))
        backend.emit(.completed)
        await waitUntil { !self.overlay.session.isWorking }
    }

    // MARK: -

    func testNewChatStartsFreshWhileTheFirstKeepsAnswering() async {
        let first = overlay.session
        ask("long question")
        let firstBackend = made[0]
        firstBackend.emit(.token("partial "))
        await waitUntil { first.turns.last?.answer == "partial " }

        coordinator.newChat()

        let second = overlay.session
        XCTAssertFalse(second === first, "a new chat is a new conversation")
        XCTAssertTrue(second.turns.isEmpty)
        XCTAssertEqual(made.count, 2, "with its own CLI process")
        XCTAssertEqual(firstBackend.shutdownCount, 0, "the first chat keeps running")

        firstBackend.emit(.token("rest"))
        firstBackend.emit(.completed)
        await waitUntil { !first.isWorking }
        XCTAssertEqual(first.turns.last?.answer, "partial rest")
        XCTAssertTrue(second.turns.isEmpty, "background events never reach the chat on screen")

        await waitUntil { self.overlay.chats.backgroundNeedsAttention }
        XCTAssertEqual(overlay.chats.rows.first { !$0.isActive }?.status, .unseenReply)
        XCTAssertEqual(overlay.chats.rows.first { !$0.isActive }?.title, "long question")
    }

    func testSwitchingBackShowsTheConversationAndDropsTheEmptyChat() async {
        let first = overlay.session
        await answeredChat("first", answer: "one")
        coordinator.newChat()
        let emptyBackend = made[1]
        let firstId = try! XCTUnwrap(overlay.chats.rows.first { !$0.isActive }).id

        coordinator.switchToChat(firstId)

        XCTAssertTrue(overlay.session === first)
        XCTAssertEqual(overlay.session.turns.map(\.answer), ["one"])
        XCTAssertEqual(emptyBackend.shutdownCount, 1, "an empty chat left behind is dropped")
        await settle()
        XCTAssertEqual(overlay.chats.rows.count, 1)
        XCTAssertFalse(overlay.chats.backgroundNeedsAttention)
    }

    func testFollowUpsGoToEachChatsOwnProcess() async {
        await answeredChat("about A", answer: "A")
        coordinator.newChat()
        await answeredChat("about B", answer: "B")
        let firstId = try! XCTUnwrap(overlay.chats.rows.first { !$0.isActive }).id

        coordinator.switchToChat(firstId)
        ask("more on A")

        XCTAssertEqual(made[0].questions, ["about A", "more on A"])
        XCTAssertEqual(made[1].questions, ["about B"])
    }

    func testNewChatFromAnEmptyChatDoesNothing() {
        let session = overlay.session
        coordinator.newChat()
        XCTAssertTrue(overlay.session === session)
        XCTAssertEqual(made.count, 1)
    }

    func testClosingABackgroundChatStopsItsProcess() async {
        await answeredChat("keep", answer: "1")
        coordinator.newChat()
        await answeredChat("other", answer: "2")
        await settle()
        let background = try! XCTUnwrap(overlay.chats.rows.first { !$0.isActive })

        coordinator.closeChat(background.id)

        XCTAssertEqual(made[0].shutdownCount, 1)
        XCTAssertEqual(overlay.chats.rows.map(\.title), ["other"])
    }

    func testClosingTheChatOnScreenShowsTheOtherOne() async {
        let first = overlay.session
        await answeredChat("first", answer: "1")
        coordinator.newChat()
        await answeredChat("second", answer: "2")
        await settle()
        let active = try! XCTUnwrap(overlay.chats.rows.first { $0.isActive })

        coordinator.closeChat(active.id)

        XCTAssertTrue(overlay.session === first)
        XCTAssertEqual(made[1].shutdownCount, 1)
    }

    func testIdleChatsPastTheCapCloseTheirProcessAndResumeWhenReopened() async {
        Preferences.shared.askBackend = .claude
        coordinator.replaceProviderServices(for: .claude)
        coordinator.endSession()
        made.removeAll()
        coordinator.summon()
        await waitUntil { self.overlay.session.submitHandler != nil }

        var firstId: UUID?
        for n in 1...(AppCoordinator.maxLiveChats + 1) {
            if n > 1 { coordinator.newChat() }
            await answeredChat("chat \(n)", answer: "answer \(n)")
            made.last!.resumePoint = ResumePoint(sessionId: "session-\(n)", cwd: "/tmp/glance-\(n)")
            if n == 1 { firstId = overlay.chats.rows.first { $0.isActive }?.id }
        }
        // Creating the newest chat pushed the oldest idle one past the cap.
        coordinator.newChat()
        XCTAssertEqual(made[0].shutdownCount, 1, "least recently used idle chat parked")
        XCTAssertEqual(made[1].shutdownCount, 0)

        coordinator.switchToChat(try! XCTUnwrap(firstId))

        XCTAssertEqual(resumed, [ResumePoint(sessionId: "session-1", cwd: "/tmp/glance-1")])
        XCTAssertEqual(overlay.session.turns.map(\.answer), ["answer 1"], "the transcript was kept")
        ask("follow-up")
        XCTAssertEqual(made.last!.questions, ["follow-up"], "the resumed process takes the follow-up")
    }

    func testProviderSwitchClosesBackgroundChats() async {
        await answeredChat("one", answer: "1")
        coordinator.newChat()
        await answeredChat("two", answer: "2")

        coordinator.replaceProviderServices(for: .codex)

        XCTAssertEqual(made[0].shutdownCount, 1)
        XCTAssertEqual(made[1].shutdownCount, 1)
        await settle()
        XCTAssertEqual(overlay.chats.rows.count, 1)
    }

    func testUpArrowRecallsMessagesSentInOtherChats() async {
        await answeredChat("asked in the first chat", answer: "1")
        coordinator.newChat()
        XCTAssertTrue(overlay.session.recallOlderMessage())
        XCTAssertEqual(overlay.session.input, "asked in the first chat")
    }

    func testBackgroundApprovalRequestShowsInTheMenu() async {
        ask("needs a tool")
        let backend = made[0]
        coordinator.newChat()
        backend.emit(.permissionRequest(PermissionRequest(
            id: "r1", toolName: "Bash", displayName: "Bash", inputJSON: Data("{}".utf8),
            detail: "ls", reason: nil, plan: nil)))
        await waitUntil { self.overlay.chats.rows.contains { $0.status == .needsApproval } }
        XCTAssertTrue(overlay.chats.backgroundNeedsAttention)
    }

    func testChatTitleIsTheFirstLineOfTheFirstMessage() {
        XCTAssertEqual(ChatListModel.title(from: "Fix the login bug\nmore detail"), "Fix the login bug")
        XCTAssertEqual(ChatListModel.title(from: String(repeating: "a", count: 70)).count, 61)
    }
}

private final class ChatBackendSpy: AskBackend {
    var firstTokenTimeout: TimeInterval = 30
    var resumePoint: ResumePoint?
    private(set) var questions: [String] = []
    private(set) var shutdownCount = 0
    private var handler: ((AskBackendEvent) -> Void)?

    func startWarm() {}
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void) {
        questions.append(question)
        handler = onEvent
    }
    func shutdown() { shutdownCount += 1 }
    func emit(_ event: AskBackendEvent) { handler?(event) }
}
