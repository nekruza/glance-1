import Foundation

/// Owns the selected ask backend and invalidates work suspended across an
/// async capture whenever that backend is replaced or shut down.
@MainActor
final class AskBackendLifecycle {
    struct Lease: Equatable {
        fileprivate let generation: UInt
        fileprivate let backendID: ObjectIdentifier
    }

    private(set) var backend: AskBackend?
    private var generation: UInt = 0

    func install(_ newBackend: AskBackend) {
        let previous = backend
        generation &+= 1
        backend = newBackend
        if let previous, previous !== newBackend {
            previous.shutdown()
        }
    }

    func lease(for candidate: AskBackend) -> Lease? {
        guard candidate === backend else { return nil }
        return Lease(generation: generation, backendID: ObjectIdentifier(candidate))
    }

    func isCurrent(_ lease: Lease) -> Bool {
        guard let backend else { return false }
        return lease.generation == generation && lease.backendID == ObjectIdentifier(backend)
    }

    func shutdown() {
        generation &+= 1
        let activeBackend = backend
        backend = nil
        activeBackend?.shutdown()
    }
}
