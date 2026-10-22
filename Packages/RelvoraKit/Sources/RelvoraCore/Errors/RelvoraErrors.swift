import Foundation

/// Input that the user can correct. Messages are shown in the UI as-is.
public enum ValidationError: Error, Sendable, Equatable, LocalizedError {
    case emptyName
    case nameTooLong(maximum: Int)
    case invalidVersion(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: "A name is required."
        case .nameTooLong(let maximum): "Names can be at most \(maximum) characters."
        case .invalidVersion(let text): "“\(text)” isn’t a usable version."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .emptyName: "Enter a name."
        case .nameTooLong: "Shorten the name."
        case .invalidVersion: "Use a semantic version such as 1.4.0 or 2.0.0-beta.1, or a short label."
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
