import XCTest
@testable import Glance

final class ModelPickerTests: XCTestCase {
    // MARK: - Catalog

    func testInitializeResponseCarriesTheModelList() throws {
        let line = #"{"type":"control_response","response":{"subtype":"success","request_id":"glance-init","response":{"commands":[],"models":[{"value":"default","resolvedModel":"claude-opus-5-5","displayName":"Default (recommended)","description":"Opus 5.5 · Best for everyday, complex tasks"},{"value":"fable","resolvedModel":"claude-fable-5-1","displayName":"Fable 5.1","description":"For your toughest challenges"},{"value":"claude-opus-4-8","resolvedModel":"claude-opus-4-8","displayName":"Opus 4.8"}]}}}"#
        let catalog = try XCTUnwrap(JSONDecoder().decode(StreamLine.self, from: Data(line.utf8)).catalog)
        XCTAssertEqual(catalog.models?.map(\.value), ["default", "fable", "claude-opus-4-8"])
        XCTAssertEqual(catalog.defaultModel, "claude-opus-5-5")
    }

    func testOptionLabelsAndGrouping() {
        let byDefault = ModelOption(value: "default", resolvedModel: "claude-opus-5-5", displayName: "Default (recommended)")
        let fable = ModelOption(value: "fable", resolvedModel: "claude-fable-5-1", displayName: "Fable 5.1")
        let pinned = ModelOption(value: "claude-opus-4-8", resolvedModel: "claude-opus-4-8", displayName: "Opus 4.8")
        XCTAssertEqual(byDefault.label, "Opus 5.5", "the default reads as the model it picks")
        XCTAssertEqual(fable.label, "Fable 5.1")
        XCTAssertTrue(fable.isAlias)
        XCTAssertFalse(pinned.isAlias, "pinned versions go under Other versions")
    }

    // MARK: - Session

    @MainActor
    func testSelectingAModelSwitchesTheLabelAndTellsTheCoordinator() {
        let session = OverlaySession()
        session.modelOptions = [
            ModelOption(value: "default", resolvedModel: "claude-opus-5-5"),
            ModelOption(value: "haiku", resolvedModel: "claude-haiku-5-5", displayName: "Haiku 5.5"),
        ]
        var picked: [String] = []
        session.modelHandler = { picked.append($0) }
        XCTAssertEqual(session.modelMenuLabel, "Opus 5.5", "before any reply: the chosen model")

        session.selectModel(session.modelOptions[1])
        XCTAssertEqual(session.selectedModel, "haiku")
        XCTAssertEqual(session.modelMenuLabel, "Haiku 5.5")
        session.selectModel(session.modelOptions[1])
        XCTAssertEqual(picked, ["haiku"], "re-picking the current model does nothing")
    }

    @MainActor
    func testProviderChangeDropsTheModelList() {
        let session = OverlaySession()
        session.modelOptions = [ModelOption(value: "default")]
        session.modelHandler = { _ in }
        session.resetForBackendChange(to: .codex)
        XCTAssertTrue(session.modelOptions.isEmpty)
        XCTAssertNil(session.modelHandler)
    }

    // MARK: - Claude backend

    private func fakeCLI(in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent("fake-claude")
        let script = #"""
        #!/bin/sh
        dir="$(dirname "$0")"
        n=$(ls "$dir" | grep -c '^args\.')
        printf '%s\n' "$@" > "$dir/args.$((n+1))"
        while IFS= read -r line; do printf '%s\n' "$line" >> "$dir/stdin.log"; done
        """#
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    private func waitFor(_ condition: () -> Bool, timeout: TimeInterval = 2) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    func testChosenModelIsPassedOnSpawnAndSwitchedLive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = ClaudeBackend(binaryPath: try fakeCLI(in: dir).path)
        defer { backend.shutdown() }

        backend.setModel("haiku")
        backend.startWarm()
        let args = dir.appendingPathComponent("args.1")
        waitFor { FileManager.default.fileExists(atPath: args.path) }
        let launched = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(launched.firstIndex(of: "--model").map { launched[$0 + 1] }, "haiku")

        backend.setModel("fable")
        let stdin = dir.appendingPathComponent("stdin.log")
        waitFor { ((try? String(contentsOf: stdin, encoding: .utf8)) ?? "").contains("set_model") }
        let log = try String(contentsOf: stdin, encoding: .utf8)
        let request = try XCTUnwrap(log.split(separator: "\n").first { $0.contains("set_model") })
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "control_request")
        let body = try XCTUnwrap(json["request"] as? [String: Any])
        XCTAssertEqual(body["subtype"] as? String, "set_model")
        XCTAssertEqual(body["model"] as? String, "fable")
    }

    func testDefaultModelLaunchesWithoutTheFlag() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("model-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = ClaudeBackend(binaryPath: try fakeCLI(in: dir).path)
        defer { backend.shutdown() }

        backend.setModel("default")
        backend.startWarm()
        let args = dir.appendingPathComponent("args.1")
        waitFor { FileManager.default.fileExists(atPath: args.path) }
        XCTAssertFalse(try String(contentsOf: args, encoding: .utf8).contains("--model"))
    }
}
