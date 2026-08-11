import XCTest
@testable import Glance

@MainActor
final class TaskRunnerProviderTests: XCTestCase {
    /// Break protected: a Codex task run must use the task-safe Codex command,
    /// persist the selected provider, and retain its generic CLI session ID.
    func testCodexRunUsesWorktreeSandboxAndStoresGenericSessionID() throws {
        let workspace = try makeFixtureDirectory().appendingPathComponent("workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let (invocation, run) = try startCodexRun(workspace: workspace.path)

        XCTAssertEqual(Array(invocation.arguments.prefix(5)),
                       ["exec", "--json", "--skip-git-repo-check", "--sandbox", "workspace-write"])
        XCTAssertTrue(invocation.arguments.contains("--approve-for-me"))
        XCTAssertTrue(invocation.arguments.contains("sandbox_workspace_write.network_access=false"))
        XCTAssertFalse(invocation.arguments.contains("opus"),
                       "Codex must not receive a stored Claude model alias")
        XCTAssertFalse(invocation.arguments.contains("--allowedTools"),
                       "Codex must not receive Claude tool aliases")
        XCTAssertEqual(argument(after: "--cd", in: invocation.arguments), run.workspacePath)
        XCTAssertTrue(invocation.standardInput.contains("# Approved plan"))
        XCTAssertEqual(run.provider, .codex)
        XCTAssertEqual(run.cliSessionID, "thread-1")
    }

    /// Break protected: cancelling task work owned by a provider must invoke
    /// its handle, persist the supplied interruption reason, and leave queued
    /// work dormant for the replacement provider to own.
    func testProviderCancellationMarksActiveRunInterrupted() throws {
        let (store, storeDirectory) = try makeTestStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let provider = HoldingAutomationProvider(kind: .codex)
        let runner = TaskRunner(store: store, provider: provider)
        let first = store.add(TaskItem(title: "First task", status: .ready,
                                       taskKind: .code, workspacePath: "/tmp/glance-shared-repo"))
        let second = store.add(TaskItem(title: "Second task", status: .ready,
                                        taskKind: .code, workspacePath: "/tmp/glance-shared-repo"))

        runner.startRun(taskId: first.id)
        runner.startRun(taskId: second.id)
        let runID = try XCTUnwrap(store.runs.first?.id)

        runner.cancelAll(reason: "AI provider changed.")

        XCTAssertEqual(provider.runTextCancellationCount, 1)
        XCTAssertEqual(store.run(runID)?.state, .cancelled)
        XCTAssertEqual(store.run(runID)?.failureReason, "AI provider changed.")
        XCTAssertEqual(store.task(second.id)?.status, .ready,
                       "Queued work must wait for the replacement provider")
    }

    /// Break protected: Claude task runs keep their existing explicit tool
    /// policy and stream parsing, without duplicating a final result already
    /// represented by streamed text.
    func testClaudeTaskRunKeepsToolPolicyAndNormalizesStream() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeClaudeExecutable(in: fixtureDirectory)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")
        let terminal = expectation(description: "Claude task run completes")
        var events: [AutomationEvent] = []

        provider.startRun(AutomationRunRequest(
            prompt: "Apply the approved plan",
            model: "sonnet",
            workingDirectory: fixtureDirectory,
            allowedTools: ["Bash", "Read"],
            disallowedTools: ["Write", "Bash(git push:*)"],
            systemPrompt: "Keep changes focused"
        )) { event in
            events.append(event)
            if event == .completed { terminal.fulfill() }
        }
        wait(for: [terminal], timeout: 2)

        let invocation = try readFlatInvocation(from: fixtureDirectory)
        XCTAssertEqual(invocation.arguments,
                       ["-p", "--output-format", "stream-json", "--include-partial-messages", "--verbose",
                        "--allowedTools", "Bash", "Read", "--disallowedTools", "Write", "Bash(git push:*)",
                        "--append-system-prompt", "Keep changes focused", "--model", "sonnet"])
        XCTAssertEqual(invocation.standardInput, "Apply the approved plan")
        XCTAssertEqual(events, [.sessionID("claude-1"), .text("done"), .completed])
    }

    /// Break protected: task progress must reset TaskRunner's stall timer while
    /// the child is still running, not only after it exits.
    func testCodexTaskRunStreamsProgressBeforeProcessExit() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        let releaseURL = fixtureDirectory.appendingPathComponent("release")
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        defer { FileManager.default.createFile(atPath: releaseURL.path, contents: nil) }
        let executable = try makeGateControlledCodexExecutable(in: fixtureDirectory)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let progress = expectation(description: "Codex progress arrives before completion")
        let terminal = expectation(description: "Codex task run completes")
        var completed = false

        provider.startRun(AutomationRunRequest(prompt: "Work", workingDirectory: fixtureDirectory)) { event in
            switch event {
            case .text("working"):
                progress.fulfill()
            case .completed:
                completed = true
                terminal.fulfill()
            case .text, .sessionID, .failed:
                break
            }
        }
        wait(for: [progress], timeout: 2)
        XCTAssertFalse(completed, "The fake CLI cannot complete until this test releases it")
        FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
        wait(for: [terminal], timeout: 2)
    }

    private func startCodexRun(workspace: String) throws -> (FakeInvocation, TaskRun) {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let workspaceURL = URL(fileURLWithPath: workspace, isDirectory: true)
        try FileManager.default.createDirectory(at: workspaceURL, withIntermediateDirectories: true)
        let (store, storeDirectory) = try makeTestStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }

        let executable = try makeCodexExecutable(in: fixtureDirectory)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let runner = TaskRunner(store: store, provider: provider)
        let task = store.add(TaskItem(title: "Draft release notes", status: .ready,
                                      taskKind: .other, workspacePath: workspace))
        let reviewGate = expectation(description: "task reaches review gate")
        reviewGate.assertForOverFulfill = true
        runner.onGate = { gate, _, _, runID in
            switch gate {
            case .plan:
                runner.approvePlan(runId: runID)
            case .review:
                reviewGate.fulfill()
            }
        }

        runner.startRun(taskId: task.id)
        wait(for: [reviewGate], timeout: 3)

        let run = try XCTUnwrap(store.runs(for: task.id).first)
        let invocation = try readInvocation(number: 2, from: fixtureDirectory)
        let transcriptPath = try XCTUnwrap(run.transcriptPath)
        XCTAssertTrue(try String(contentsOfFile: transcriptPath, encoding: .utf8).contains("Draft complete"))
        runner.rejectReview(runId: run.id, reason: "test cleanup")
        try? FileManager.default.removeItem(atPath: transcriptPath)
        if run.workspacePath.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(atPath: run.workspacePath)
        }
        return (invocation, run)
    }

    private func makeTestStore() throws -> (TaskStore, URL) {
        let directory = try makeFixtureDirectory()
        return (TaskStore(directory: directory), directory)
    }

    private func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("task-runner-provider-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeCodexExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        count_file="$fixture_dir/invocation-count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        printf '%s\n' "$@" > "$fixture_dir/arguments-$count"
        cat > "$fixture_dir/stdin-$count"
        if [ "$count" -eq 1 ]; then
          printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"## Plan\n1. Draft notes\n## Touches\n- notes\n## Boundary actions\nnone"}}'
        else
          printf '%s\n' '{"type":"thread.started","thread_id":"thread-1"}'
          printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"Draft complete"}}'
        fi
        printf '%s\n' '{"type":"turn.completed"}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        return executable
    }

    private func makeClaudeExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        printf '%s\n' "$@" > "$fixture_dir/arguments"
        cat > "$fixture_dir/stdin"
        printf '%s\n' '{"type":"system","session_id":"claude-1"}'
        printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"done"}}}'
        printf '%s\n' '{"type":"result","is_error":false,"result":"done"}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        return executable
    }

    private func makeGateControlledCodexExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("gate-controlled-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        cat >/dev/null
        printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"working"}}'
        while [ ! -f "$fixture_dir/release" ]; do sleep 0.01; done
        printf '%s\n' '{"type":"turn.completed"}'
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],
                                              ofItemAtPath: executable.path)
        return executable
    }

    private func readInvocation(number: Int, from directory: URL) throws -> FakeInvocation {
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments-\(number)"),
                                   encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let standardInput = try String(contentsOf: directory.appendingPathComponent("stdin-\(number)"),
                                       encoding: .utf8)
        return FakeInvocation(arguments: arguments, standardInput: standardInput)
    }

    private func readFlatInvocation(from directory: URL) throws -> FakeInvocation {
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let standardInput = try String(contentsOf: directory.appendingPathComponent("stdin"), encoding: .utf8)
        return FakeInvocation(arguments: arguments, standardInput: standardInput)
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private struct FakeInvocation {
    let arguments: [String]
    let standardInput: String
}

private final class HoldingAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var runTextCancellationCount = 0

    init(kind: AskBackendKind) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation { [weak self] in self?.runTextCancellationCount += 1 }
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func cancelAll() {}
}
