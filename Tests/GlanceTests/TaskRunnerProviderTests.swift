import Darwin
import XCTest
@testable import Glance

@MainActor
final class TaskRunnerProviderTests: XCTestCase {
    /// Break protected: a Codex task run must use the task-safe Codex command,
    /// persist the selected provider, and retain its generic CLI session ID.
    func testCodexRunUsesWorktreeSandboxAndStoresGenericSessionID() throws {
        let workspace = try makeFixtureDirectory().appendingPathComponent("workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let (_, invocation, run) = try startCodexRun(workspace: workspace.path)

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

    /// Break protected: planning must never launch Codex in the task's source
    /// checkout. It gets a dedicated scratch directory plus the read-only,
    /// network-disabled Codex command policy before execution is approved.
    func testCodexPlanningUsesReadOnlyScratchWithoutOriginalWorkspaceAccess() throws {
        let workspace = try makeFixtureDirectory().appendingPathComponent("original-workspace", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace.deletingLastPathComponent()) }

        let (planningInvocation, _, _) = try startCodexRun(workspace: workspace.path)

        XCTAssertEqual(Array(planningInvocation.arguments.prefix(5)),
                       ["exec", "--json", "--skip-git-repo-check", "--sandbox", "read-only"])
        XCTAssertTrue(planningInvocation.arguments.contains("--approve-for-me"))
        XCTAssertTrue(planningInvocation.arguments.contains("sandbox_workspace_write.network_access=false"))
        XCTAssertNotEqual(argument(after: "--cd", in: planningInvocation.arguments), workspace.path)
        XCTAssertNotEqual(planningInvocation.workingDirectory, workspace.path)
        XCTAssertTrue(planningInvocation.workingDirectory.contains("glance-task-plan-"))
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

    /// Break protected: cancellation must reach the provider handle that owns
    /// an active execution child, not just the completed/planning handle.
    func testProviderCancellationCancelsActiveExecutionHandle() throws {
        let (store, storeDirectory) = try makeTestStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let provider = PlanThenHoldAutomationProvider(kind: .codex)
        let runner = TaskRunner(store: store, provider: provider)
        let task = store.add(TaskItem(title: "Execution cancellation", status: .ready, taskKind: .other))
        let planGate = expectation(description: "plan reaches approval gate")
        var runID: UUID?
        runner.onGate = { gate, _, _, id in
            if gate == .plan {
                runID = id
                planGate.fulfill()
            }
        }

        runner.startRun(taskId: task.id)
        provider.emitPlan()
        wait(for: [planGate], timeout: 1)
        runner.approvePlan(runId: try XCTUnwrap(runID))
        XCTAssertEqual(provider.executionRequestCount, 1)

        runner.cancelAll(reason: "AI provider changed.")

        XCTAssertEqual(provider.executionCancellationCount, 1)
        XCTAssertEqual(store.run(try XCTUnwrap(runID))?.state, .cancelled)
    }

    /// Break protected: a delayed action from a no-longer-visible plan gate
    /// cannot resurrect a cancelled run or launch provider execution.
    func testStalePlanApprovalDoesNotRestartCancelledRun() throws {
        let (store, storeDirectory) = try makeTestStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let provider = PlanThenHoldAutomationProvider(kind: .codex)
        let runner = TaskRunner(store: store, provider: provider)
        let task = store.add(TaskItem(title: "Stale approval", status: .ready, taskKind: .other))
        let planGate = expectation(description: "plan reaches approval gate")
        var runID: UUID?
        runner.onGate = { gate, _, _, id in
            if gate == .plan {
                runID = id
                planGate.fulfill()
            }
        }

        runner.startRun(taskId: task.id)
        provider.emitPlan()
        wait(for: [planGate], timeout: 1)
        let id = try XCTUnwrap(runID)
        runner.cancelAll(reason: "AI provider changed.")
        runner.approvePlan(runId: id)

        XCTAssertEqual(store.run(id)?.state, .cancelled)
        XCTAssertEqual(store.task(task.id)?.status, .ready)
        XCTAssertEqual(provider.executionRequestCount, 0)
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

    /// Break protected: an optimistic JSON terminal must not package a task or
    /// unlock its queue before the child has cleanly exited and both pipes have
    /// drained. A late non-zero exit is a failure, never a reviewable success.
    func testLateNonzeroAfterCodexTerminalDoesNotReachReview() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        let releaseURL = fixtureDirectory.appendingPathComponent("release")
        defer {
            FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let executable = try makeLateFailureCodexExecutable(in: fixtureDirectory)
        let (store, storeDirectory) = try makeTestStore()
        defer { try? FileManager.default.removeItem(at: storeDirectory) }
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let runner = TaskRunner(store: store, provider: provider)
        let task = store.add(TaskItem(title: "Late exit", status: .ready, taskKind: .other))
        let review = expectation(description: "late terminal must not open review")
        review.isInverted = true
        let failed = expectation(description: "late nonzero fails task")
        var runID: UUID?
        runner.onGate = { gate, _, _, id in
            switch gate {
            case .plan:
                runID = id
                runner.approvePlan(runId: id)
            case .review:
                review.fulfill()
            }
        }
        runner.onEvent = { _, _ in failed.fulfill() }

        runner.startRun(taskId: task.id)
        XCTAssertTrue(waitForFile(fixtureDirectory.appendingPathComponent("terminal-written")))
        wait(for: [review], timeout: 0.2)
        FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
        wait(for: [failed], timeout: 2)

        XCTAssertEqual(store.run(try XCTUnwrap(runID))?.state, .failed)
        XCTAssertEqual(store.task(task.id)?.status, .failed)
    }

    /// Break protected: terminal JSON does not disable the provider timeout;
    /// an otherwise hanging child is stopped and reported as failed instead of
    /// producing a success callback.
    func testCodexTerminalThenHangTimesOutInsteadOfCompleting() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeTerminalThenHangCodexExecutable(in: fixtureDirectory)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let failed = expectation(description: "hanging terminal fails on timeout")
        let completed = expectation(description: "hanging terminal never completes")
        completed.isInverted = true

        provider.startRun(AutomationRunRequest(prompt: "Work", workingDirectory: fixtureDirectory, timeout: 0.15)) { event in
            switch event {
            case .completed:
                completed.fulfill()
            case .failed:
                failed.fulfill()
            case .text, .sessionID:
                break
            }
        }
        XCTAssertTrue(waitForFile(fixtureDirectory.appendingPathComponent("terminal-written")))
        wait(for: [failed, completed], timeout: 1.5)
        provider.cancelAll()
    }

    /// Break protected: terminal success waits for stderr EOF as well as
    /// stdout/process exit. Diagnostics can still arrive after the terminal
    /// JSON line, so opening review before that drain would be unsafe.
    func testCodexTerminalWaitsForStderrDrain() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        let releaseURL = fixtureDirectory.appendingPathComponent("release")
        var stderrChildPID: pid_t?
        defer {
            FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
            if let stderrChildPID, !waitForProcessExit(stderrChildPID, timeout: 1) {
                Darwin.kill(stderrChildPID, SIGKILL)
            }
            try? FileManager.default.removeItem(at: fixtureDirectory)
        }
        let executable = try makeStderrDrainCodexExecutable(in: fixtureDirectory)
        let provider = CodexAutomationProvider(binaryPath: executable.path, version: "test")
        let completed = expectation(description: "completion follows stderr EOF")
        let earlyCompletion = expectation(description: "terminal waits for stderr EOF")
        earlyCompletion.isInverted = true
        var released = false

        provider.startRun(AutomationRunRequest(prompt: "Work", workingDirectory: fixtureDirectory)) { event in
            if event == .completed {
                if released {
                    completed.fulfill()
                } else {
                    earlyCompletion.fulfill()
                }
            }
        }
        XCTAssertTrue(waitForFile(fixtureDirectory.appendingPathComponent("terminal-written")))
        let parentPID = try processID(from: fixtureDirectory.appendingPathComponent("parent-pid"))
        stderrChildPID = try processID(from: fixtureDirectory.appendingPathComponent("stderr-child-pid"))
        XCTAssertTrue(waitForProcessExit(parentPID, timeout: 1),
                      "The CLI parent must have exited while the stderr holder remains alive")
        XCTAssertFalse(waitForProcessExit(try XCTUnwrap(stderrChildPID), timeout: 0.05),
                       "The background child must retain the stderr descriptor until release")
        wait(for: [earlyCompletion], timeout: 0.2)
        released = true
        FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
        wait(for: [completed], timeout: 2)
        XCTAssertTrue(waitForProcessExit(try XCTUnwrap(stderrChildPID), timeout: 1),
                      "The fixture must release its background stderr holder")
    }

    /// Break protected: provider-wide cancellation includes the streaming
    /// handle used by Claude task execution, not only one-shot text work.
    func testClaudeCancelAllStopsStreamingExecution() throws {
        let fixtureDirectory = try makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }
        let executable = try makeHoldingClaudeExecutable(in: fixtureDirectory)
        let provider = ClaudeAutomationProvider(binaryPath: executable.path, version: "test")

        provider.startRun(AutomationRunRequest(prompt: "Work", workingDirectory: fixtureDirectory)) { _ in }
        let pidURL = fixtureDirectory.appendingPathComponent("pid")
        XCTAssertTrue(waitForFile(pidURL))
        let pid = try processID(from: pidURL)
        defer { Darwin.kill(pid, SIGKILL) }

        provider.cancelAll()

        XCTAssertTrue(waitForProcessExit(pid, timeout: 1.5), "streaming Claude child should be cancelled")
    }

    private func startCodexRun(workspace: String) throws -> (FakeInvocation, FakeInvocation, TaskRun) {
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
        let planningInvocation = try readInvocation(number: 1, from: fixtureDirectory)
        let invocation = try readInvocation(number: 2, from: fixtureDirectory)
        let transcriptPath = try XCTUnwrap(run.transcriptPath)
        XCTAssertTrue(try String(contentsOfFile: transcriptPath, encoding: .utf8).contains("Draft complete"))
        runner.rejectReview(runId: run.id, reason: "test cleanup")
        try? FileManager.default.removeItem(atPath: transcriptPath)
        if run.workspacePath.hasPrefix(FileManager.default.temporaryDirectory.path) {
            try? FileManager.default.removeItem(atPath: run.workspacePath)
        }
        return (planningInvocation, invocation, run)
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
        pwd > "$fixture_dir/cwd-$count"
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

    private func makeLateFailureCodexExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("late-failure-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        count_file="$fixture_dir/invocation-count"
        count=0
        if [ -f "$count_file" ]; then count=$(cat "$count_file"); fi
        count=$((count + 1))
        printf '%s' "$count" > "$count_file"
        cat >/dev/null
        if [ "$count" -eq 1 ]; then
          printf '%s\n' '{"type":"item.completed","item":{"type":"agent_message","text":"## Plan\n1. Work\n## Touches\n- scratch\n## Boundary actions\n- publish after review"}}'
          printf '%s\n' '{"type":"turn.completed"}'
          exit 0
        fi
        printf '%s\n' '{"type":"turn.completed"}'
        : > "$fixture_dir/terminal-written"
        while [ ! -f "$fixture_dir/release" ]; do sleep 0.01; done
        exit 7
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeTerminalThenHangCodexExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("terminal-hang-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        cat >/dev/null
        printf '%s\n' '{"type":"turn.completed"}'
        : > "$fixture_dir/terminal-written"
        trap '' TERM
        while :; do sleep 0.02; done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeStderrDrainCodexExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("stderr-drain-codex")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        cat >/dev/null
        printf '%s' "$$" > "$fixture_dir/parent-pid"
        (
          exec 1>&-
          while [ ! -f "$fixture_dir/release" ]; do sleep 0.01; done
          printf '%s\n' 'late diagnostic' >&2
        ) &
        printf '%s' "$!" > "$fixture_dir/stderr-child-pid"
        printf '%s\n' '{"type":"turn.completed"}'
        : > "$fixture_dir/terminal-written"
        exit 0
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func makeHoldingClaudeExecutable(in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent("holding-claude")
        let script = #"""
        #!/bin/sh
        fixture_dir="$(dirname "$0")"
        cat >/dev/null
        printf '%s' "$$" > "$fixture_dir/pid"
        trap '' TERM
        while :; do sleep 0.02; done
        """#
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return executable
    }

    private func readInvocation(number: Int, from directory: URL) throws -> FakeInvocation {
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments-\(number)"),
                                   encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let standardInput = try String(contentsOf: directory.appendingPathComponent("stdin-\(number)"),
                                       encoding: .utf8)
        let workingDirectory = try String(contentsOf: directory.appendingPathComponent("cwd-\(number)"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FakeInvocation(arguments: arguments, standardInput: standardInput, workingDirectory: workingDirectory)
    }

    private func readFlatInvocation(from directory: URL) throws -> FakeInvocation {
        let arguments = try String(contentsOf: directory.appendingPathComponent("arguments"), encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)
        let standardInput = try String(contentsOf: directory.appendingPathComponent("stdin"), encoding: .utf8)
        return FakeInvocation(arguments: arguments, standardInput: standardInput, workingDirectory: "")
    }

    private func argument(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 1) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return FileManager.default.fileExists(atPath: url.path)
    }

    private func processID(from url: URL) throws -> pid_t {
        let value = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return try XCTUnwrap(pid_t(value))
    }

    private func waitForProcessExit(_ pid: pid_t, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Darwin.kill(pid, 0) == -1, errno == ESRCH { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return Darwin.kill(pid, 0) == -1 && errno == ESRCH
    }
}

private struct FakeInvocation {
    let arguments: [String]
    let standardInput: String
    let workingDirectory: String
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

private final class PlanThenHoldAutomationProvider: AutomationProvider {
    let descriptor: AutomationProviderDescriptor
    private(set) var executionRequestCount = 0
    private(set) var executionCancellationCount = 0
    private var planningHandler: ((AutomationEvent) -> Void)?

    init(kind: AskBackendKind) {
        descriptor = AutomationProviderDescriptor(kind: kind, version: "test")
    }

    func runText(_ request: AutomationRequest,
                 onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        planningHandler = onEvent
        return AutomationCancellation()
    }

    func emitPlan() {
        planningHandler?(.text("## Plan\n1. Work\n## Touches\n- scratch\n## Boundary actions\n- publish after review"))
        planningHandler?(.completed)
    }

    func startRun(_ request: AutomationRunRequest,
                  onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        executionRequestCount += 1
        return AutomationCancellation { [weak self] in self?.executionCancellationCount += 1 }
    }

    func runComposio(_ request: ComposioAutomationRequest, token: String,
                     onEvent: @escaping (AutomationEvent) -> Void) -> AutomationCancellation {
        AutomationCancellation()
    }

    func cancelAll() {}
}
