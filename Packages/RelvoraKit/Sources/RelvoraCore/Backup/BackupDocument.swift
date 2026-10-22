import Foundation

/// The on-disk backup format: versioned JSON, independent of the database schema.
/// Enum values are stored as strings so the format stays readable and stable.
public struct BackupDocument: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var projects: [ProjectRecord]

    public struct ProjectRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var details: String?
        public var iconName: String?
        public var accentColor: String?
        public var createdAt: Date
        public var updatedAt: Date
        public var archivedAt: Date?
        public var columns: [ColumnRecord]
        public var tasks: [TaskRecord]
        public var releasePlans: [ReleasePlanRecord]
    }

    public struct ColumnRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var name: String
        public var sortOrder: Double
        public var isCompletionColumn: Bool
        public var createdAt: Date
        public var updatedAt: Date
    }

    public struct TaskRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var columnID: UUID
        public var releasePlanID: UUID?
        public var title: String
        public var details: String?
        public var priority: String
        public var type: String
        public var labels: [String]
        public var checklist: [ChecklistRecord]
        public var sortOrder: Double
        public var createdAt: Date
        public var updatedAt: Date
        public var completedAt: Date?
    }

    public struct ChecklistRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var title: String
        public var isDone: Bool
        public var sortOrder: Double
    }

    public struct ReleasePlanRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var version: String
        public var title: String?
        public var details: String?
        public var status: String
        public var targetBranch: String?
        public var targetCommitSHA: String?
        public var plannedDate: Date?
        public var changelogMarkdown: String
        public var createdAt: Date
        public var updatedAt: Date
        public var releasedAt: Date?
    }
}

// MARK: - Encoding

extension BackupDocument {
    /// Pretty-printed, key-sorted JSON with ISO 8601 dates (millisecond precision).
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.timestamp(date))
        }
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws(BackupError) -> BackupDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            // Accept dates with or without fractional seconds (hand-edited files often omit them).
            if let date = (try? dateStyle.parse(text)) ?? (try? Date.ISO8601FormatStyle().parse(text)) {
                return date
            }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
        }
        // Read the version first so newer formats get a precise error instead of a decoding failure.
        struct Header: Decodable { var formatVersion: Int }
        let header: Header
        do {
            header = try decoder.decode(Header.self, from: data)
        } catch {
            throw .unreadable(reason: String(describing: error))
        }
        guard header.formatVersion <= currentFormatVersion, header.formatVersion >= 1 else {
            throw .unsupportedFormatVersion(found: header.formatVersion, supported: currentFormatVersion)
        }
        do {
            return try decoder.decode(BackupDocument.self, from: data)
        } catch {
            throw .unreadable(reason: String(describing: error))
        }
    }

    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    /// ISO 8601 rounded to the nearest millisecond. Formatting styles truncate, and binary fractions such as
    /// .123 are stored as .12299…, so plain formatting would lose a millisecond on every export/restore cycle.
    static func timestamp(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let whole = Date(timeIntervalSince1970: seconds).formatted(.iso8601)
        return whole.dropLast() + String(format: ".%03dZ", Int(milliseconds - seconds * 1000))
    }
}

// MARK: - Mapping

extension BackupDocument {
    public init(bundles: [ProjectBundle], exportedAt: Date, appVersion: String?) {
        self.init(
            formatVersion: Self.currentFormatVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            projects: bundles.map(ProjectRecord.init)
        )
    }

    /// Converts records to domain values. Call `BackupValidator.validate` first.
    public func bundles() throws(BackupError) -> [ProjectBundle] {
        try projects.map { record throws(BackupError) in try record.bundle() }
    }
}

extension BackupDocument.ProjectRecord {
    init(_ bundle: ProjectBundle) {
        let project = bundle.project
        self.init(
            id: project.id,
            name: project.name,
            details: project.details,
            iconName: project.iconName,
            accentColor: project.accentColor,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt,
            archivedAt: project.archivedAt,
            columns: bundle.columns.sorted { $0.sortOrder < $1.sortOrder }.map {
                .init(
                    id: $0.id, name: $0.name, sortOrder: $0.sortOrder, isCompletionColumn: $0.isCompletionColumn,
                    createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            tasks: bundle.tasks.sorted { $0.sortOrder < $1.sortOrder }.map {
                .init(
                    id: $0.id, columnID: $0.columnID, releasePlanID: $0.releasePlanID, title: $0.title,
                    details: $0.details, priority: $0.priority.rawValue, type: $0.type.rawValue, labels: $0.labels,
                    checklist: $0.checklist.map {
                        .init(id: $0.id, title: $0.title, isDone: $0.isDone, sortOrder: $0.sortOrder)
                    },
                    sortOrder: $0.sortOrder, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    completedAt: $0.completedAt)
            },
            releasePlans: bundle.releasePlans.sorted { $0.createdAt < $1.createdAt }.map {
                .init(
                    id: $0.id, version: $0.version, title: $0.title, details: $0.details, status: $0.status.rawValue,
                    targetBranch: $0.targetBranch, targetCommitSHA: $0.targetCommitSHA, plannedDate: $0.plannedDate,
                    changelogMarkdown: $0.changelogMarkdown, createdAt: $0.createdAt, updatedAt: $0.updatedAt,
                    releasedAt: $0.releasedAt)
            }
        )
    }

    func bundle() throws(BackupError) -> ProjectBundle {
        let project = Project(
            id: id, name: name, details: details, iconName: iconName, accentColor: accentColor,
            createdAt: createdAt, updatedAt: updatedAt, archivedAt: archivedAt)
        let columns = columns.map {
            BoardColumn(
                id: $0.id, projectID: id, name: $0.name, sortOrder: $0.sortOrder,
                isCompletionColumn: $0.isCompletionColumn, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        var tasks: [ProjectTask] = []
        for record in self.tasks {
            guard let priority = TaskPriority(rawValue: record.priority), let type = TaskType(rawValue: record.type)
            else { throw .invalid("task “\(record.title)” has an unknown priority or type.") }
            tasks.append(
                ProjectTask(
                    id: record.id, projectID: id, columnID: record.columnID, releasePlanID: record.releasePlanID,
                    title: record.title, details: record.details, priority: priority, type: type, labels: record.labels,
                    checklist: record.checklist.map {
                        ChecklistItem(id: $0.id, title: $0.title, isDone: $0.isDone, sortOrder: $0.sortOrder)
                    },
                    sortOrder: record.sortOrder, createdAt: record.createdAt, updatedAt: record.updatedAt,
                    completedAt: record.completedAt))
        }
        var plans: [ReleasePlan] = []
        for record in releasePlans {
            guard let status = ReleasePlanStatus(rawValue: record.status) else {
                throw .invalid("release plan \(record.version) has an unknown status.")
            }
            plans.append(
                ReleasePlan(
                    id: record.id, projectID: id, version: record.version, title: record.title,
                    details: record.details, status: status, targetBranch: record.targetBranch,
                    targetCommitSHA: record.targetCommitSHA, plannedDate: record.plannedDate,
                    changelogMarkdown: record.changelogMarkdown, createdAt: record.createdAt,
                    updatedAt: record.updatedAt, releasedAt: record.releasedAt))
        }
        return ProjectBundle(project: project, columns: columns, tasks: tasks, releasePlans: plans)
    }
}
