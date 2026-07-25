import Foundation

@MainActor
final class SidecarGitModel: ObservableObject {
    @Published private(set) var snapshot: SidecarGitSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isOperating = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var operationMessage: String?

    private let service = SidecarGitService()
    private var workingDirectory: URL?
    private var operationTask: Task<Void, Never>?
    private var activeClients: Set<UUID> = []
    private var hasCompletedRefresh = false

    deinit {
        operationTask?.cancel()
    }

    func activate(clientID: UUID) {
        activeClients.insert(clientID)
    }

    func deactivate(clientID: UUID) {
        activeClients.remove(clientID)
        if activeClients.isEmpty {
            cancelOperation()
        }
    }

    func setWorkingDirectory(_ url: URL) {
        let standardized = url.standardizedFileURL
        guard standardized != workingDirectory else { return }
        cancelOperation()
        workingDirectory = standardized
        snapshot = nil
        hasCompletedRefresh = false
        isLoading = false
        errorMessage = nil
        operationMessage = nil
    }

    @discardableResult
    func refresh() async -> Bool {
        guard let workingDirectory, !isOperating else { return false }
        if !hasCompletedRefresh {
            isLoading = true
        }

        let changed: Bool
        do {
            let value = try await service.snapshot(workingDirectory: workingDirectory)
            guard !Task.isCancelled else { return false }
            changed = snapshot != value
            if changed {
                snapshot = value
            }
            if errorMessage != nil {
                errorMessage = nil
            }
        } catch {
            guard !Task.isCancelled else { return false }
            let message = error.localizedDescription
            changed = errorMessage != message
            if changed {
                errorMessage = message
            }
        }
        hasCompletedRefresh = true
        if isLoading {
            isLoading = false
        }
        return changed
    }

    func perform(_ operation: SidecarGitOperation, label: String) {
        guard let repository = snapshot?.repositoryRoot, !isOperating else { return }

        operationTask?.cancel()
        isOperating = true
        errorMessage = nil
        operationMessage = label
        operationTask = Task { [weak self, service] in
            do {
                try await service.perform(operation, repository: repository)
                guard !Task.isCancelled else { return }
                self?.isOperating = false
                self?.operationMessage = nil
                await self?.refresh()
            } catch {
                guard !Task.isCancelled else { return }
                self?.isOperating = false
                self?.operationMessage = nil
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    private func cancelOperation() {
        operationTask?.cancel()
        operationTask = nil
        isOperating = false
        operationMessage = nil
    }

    func diff(for change: SidecarGitChange, isStaged: Bool) async throws -> String {
        guard let repository = snapshot?.repositoryRoot else {
            throw SidecarGitError(message: "The Git repository is no longer available.")
        }
        return try await service.diff(
            for: change,
            repository: repository,
            isStaged: isStaged
        )
    }
}
