import Foundation

/// Input or an action the user can correct. Messages are shown in the UI as-is.
public enum ValidationError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case nameTooLong(maximum: Int)
    case emptyTitle
    case titleTooLong(maximum: Int)
    case invalidVersion(String)
    case duplicateVersion(String)
    case activeReleasePlanExists(version: String)
    case releasePlanLocked(ReleasePlanStatus)
    case columnNotEmpty(taskCount: Int)
    case cannotDeleteCompletionColumn
    case cannotDeleteLastColumn
    case unknownColumn

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A name is required."
        case .nameTooLong(let maximum): "Names can be at most \(maximum) characters."
        case .emptyTitle: "A title is required."
        case .titleTooLong(let maximum): "Titles can be at most \(maximum) characters."
        case .invalidVersion(let text): "“\(text)” isn’t a usable version."
        case .duplicateVersion(let version): "This project already has a release plan for \(version)."
        case .activeReleasePlanExists(let version): "Version \(version) is still being planned."
        case .releasePlanLocked: "This release plan can no longer be changed."
        case .columnNotEmpty(let count): "This column still has \(count) \(count == 1 ? "task" : "tasks")."
        case .cannotDeleteCompletionColumn: "The completion column can’t be deleted."
        case .cannotDeleteLastColumn: "A board needs at least one column."
        case .unknownColumn: "That column doesn’t belong to this project."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyName: "Enter a name."
        case .nameTooLong: "Shorten the name."
        case .emptyTitle: "Enter a title."
        case .titleTooLong: "Shorten the title."
        case .invalidVersion: "Use a semantic version such as 1.4.0 or 2.0.0-beta.1, or a short label."
        case .duplicateVersion: "Choose a different version, or edit the existing plan."
        case .activeReleasePlanExists: "Finish or cancel the current plan before starting another."
        case .releasePlanLocked(let status): "Plans that are \(status.title.lowercased()) are kept as a record."
        case .columnNotEmpty: "Choose a column to move its tasks to."
        case .cannotDeleteCompletionColumn: "Make another column the completion column first."
        case .cannotDeleteLastColumn: "Add another column before deleting this one."
        case .unknownColumn: "Reload the board and try again."
        }
    }
}

/// Failures of the local store. `reason` carries technical detail for logs, never for display.
public enum PersistenceError: Error, Sendable, Equatable, LocalizedError {
    case storeUnavailable(reason: String)
    case notFound(entity: String, id: UUID)
    case integrityViolation(String)
    case fetchFailed(reason: String)
    case saveFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .storeUnavailable: "Relvora couldn’t open its data."
        case .notFound(let entity, _): "The \(entity) no longer exists."
        case .integrityViolation: "That change would leave your data inconsistent, so it wasn’t saved."
        case .fetchFailed: "Relvora couldn’t read your data."
        case .saveFailed: "Relvora couldn’t save your changes."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .storeUnavailable: "Quit and reopen Relvora. If this keeps happening, restore from a backup."
        case .notFound: "It may have been deleted. Refresh and try again."
        case .integrityViolation, .fetchFailed, .saveFailed: "Try again. If this keeps happening, restart Relvora."
        }
    }
}

/// Problems with a backup file. Nothing is changed when any of these is thrown.
public enum BackupError: Error, Sendable, Equatable, LocalizedError {
    case unreadable(reason: String)
    case unsupportedFormatVersion(found: Int, supported: Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable: "This file isn’t a Relvora backup."
        case .unsupportedFormatVersion: "This backup was made by a newer version of Relvora."
        case .invalid(let detail): "This backup is damaged: \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .unreadable: "Choose a .json file created with File › Export Backup."
        case .unsupportedFormatVersion: "Update Relvora, then restore again."
        case .invalid: "Your current data was not changed. Try another backup."
        }
    }
}
