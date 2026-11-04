import Darwin
import Foundation

extension IntegrationService {
    /// Serializes helper requests and Mac app transactions against the same
    /// support directory. The existing recursive lock makes nested use safe.
    func withOperationLock<T>(_ operation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try acquireOperationLock(); defer { releaseOperationLock() }
        return try operation()
    }

    func acquireOperationLock() throws {
        if operationLockDepth > 0 { operationLockDepth += 1; return }
        try privateDirectory(applicationSupport)
        let url = applicationSupport.appendingPathComponent(".operation.lock")
        let descriptor = Darwin.open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw AgentMixError.invalid("AgentMix could not open its private operation lock.") }
        var information = stat()
        guard fstat(descriptor, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), information.st_uid == getuid() else {
            Darwin.close(descriptor)
            throw AgentMixError.invalid("AgentMix's operation lock is not a private regular file.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw AgentMixError.conflict("Another AgentMix operation is in progress. Wait for it to finish, then try again.")
        }
        guard fchmod(descriptor, 0o600) == 0 else {
            flock(descriptor, LOCK_UN); Darwin.close(descriptor)
            throw AgentMixError.invalid("AgentMix could not protect its operation lock.")
        }
        operationLockDescriptor = descriptor
        operationLockDepth = 1
    }

    func releaseOperationLock() {
        operationLockDepth -= 1
        guard operationLockDepth == 0 else { return }
        flock(operationLockDescriptor, LOCK_UN)
        Darwin.close(operationLockDescriptor)
        operationLockDescriptor = -1
    }

    func checkPreviewInputs(_ preview: IntegrationPreview) throws {
        guard try installationText() == preview.installationBefore else {
            throw AgentMixError.conflict("AgentMix installation changed after preview. Generate a fresh preview before applying.")
        }
        guard Set(preview.changes.map(\.path)).count == preview.changes.count else { throw AgentMixError.invalid("Preview contains duplicate files.") }
        for input in preview.preconditions + preview.changes.map({ FilePrecondition(path: $0.path, before: $0.before) }) {
            let url = URL(fileURLWithPath: input.path)
            try checkAllowed(url)
            guard try readText(url) == input.before else {
                throw AgentMixError.conflict("\(input.path) changed after preview. Generate a fresh preview before applying.")
            }
        }
    }
}
