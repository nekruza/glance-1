import Foundation

enum AskBackendKind: String, CaseIterable {
    case claude
    case codex

    static let defaultValue: AskBackendKind = .claude
}

enum AskBackendEvent {
    case token(String)
    case completed
    case failed(String)
}

protocol AskBackend: AnyObject {
    var firstTokenTimeout: TimeInterval { get set }
    func startWarm()
    func ask(question: String, imagePNG: Data?, onEvent: @escaping (AskBackendEvent) -> Void)
    func shutdown()
}
