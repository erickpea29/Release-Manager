import Foundation

/// The on-disk backup format: versioned JSON, independent of the database schema.
/// Enum values are stored as strings so the format stays readable and stable.
public struct BackupDocument: Codable, Sendable, Equatable {
    /// 1: M02 (projects, boards, tasks, plans). 2: M03 adds repository connections. 3: M04 adds release snapshots and
    /// the plans' repository, tag, and compare base. 4: M05 adds preferences. Older files still restore.
    public static let currentFormatVersion = 4

    public var formatVersion: Int
    public var exportedAt: Date
    public var appVersion: String?
    public var projects: [ProjectRecord]
    /// App settings (format 4). Absent in older files; then the current settings are kept.
    public var preferences: PreferencesRecord?

    /// Settings worth carrying to another Mac. Values are stable strings; unknown ones are ignored on restore.
    public struct PreferencesRecord: Codable, Sendable, Equatable {
        public var appearance: String?
        public var accentColor: String?
        public var windowMaterial: String?
        public var newProjectColumns: [ColumnTemplate]?
        public var changelogLabelRules: [ChangelogLabelRule]?

        public init(
            appearance: String? = nil, accentColor: String? = nil, windowMaterial: String? = nil,
            newProjectColumns: [ColumnTemplate]? = nil, changelogLabelRules: [ChangelogLabelRule]? = nil
        ) {
            self.appearance = appearance
            self.accentColor = accentColor
            self.windowMaterial = windowMaterial
            self.newProjectColumns = newProjectColumns
            self.changelogLabelRules = changelogLabelRules
        }
    }

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
        /// Absent in format 1.
        public var repositoryConnections: [RepositoryConnectionRecord]
        /// Absent before format 3.
        public var releaseSnapshots: [ReleaseSnapshotRecord]
    }

    /// A release snapshot, content and lifecycle, exactly as stored.
    public struct ReleaseSnapshotRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var releasePlanID: UUID?
        public var origin: String
        public var version: String
        public var title: String?
        public var releaseName: String
        public var tagName: String
        public var targetCommitSHA: String
        public var targetBranch: String?
        public var isPrerelease: Bool
        public var releaseNotesMarkdown: String
        public var tasks: [TaskSnapshot]
        public var changes: ReleaseChangeSummary?
        public var githubRepositoryID: Int64
        public var repositoryFullName: String
        public var repositoryURL: URL
        public var snapshotCreatedAt: Date
        public var state: String
        public var githubReleaseID: Int64?
        public var githubReleaseURL: URL?
        public var publishedAt: Date?
        public var publishedNotesMarkdown: String?
        public var publishedTagName: String?
        public var publishedCommitSHA: String?
        public var stateChangedAt: Date
    }

    public struct RepositoryConnectionRecord: Codable, Sendable, Equatable {
        public var id: UUID
        public var githubRepositoryID: Int64
        public var owner: String
        public var name: String
        public var defaultBranch: String?
        public var htmlURL: URL
        public var isPrivate: Bool
        public var lastSyncedAt: Date?
        public var createdAt: Date
        public var updatedAt: Date
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
        /// Absent before format 3.
        public var repositoryConnectionID: UUID?
        public var targetBranch: String?
        public var targetCommitSHA: String?
        public var tagName: String?
        public var compareBaseTag: String?
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
    public init(
        bundles: [ProjectBundle], exportedAt: Date, appVersion: String?, preferences: PreferencesRecord? = nil
    ) {
        self.init(
            formatVersion: Self.currentFormatVersion,
            exportedAt: exportedAt,
            appVersion: appVersion,
            projects: bundles.map(ProjectRecord.init),
            preferences: preferences
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
                    repositoryConnectionID: $0.repositoryConnectionID, targetBranch: $0.targetBranch,
                    targetCommitSHA: $0.targetCommitSHA, tagName: $0.tagName, compareBaseTag: $0.compareBaseTag,
                    plannedDate: $0.plannedDate, changelogMarkdown: $0.changelogMarkdown, createdAt: $0.createdAt,
                    updatedAt: $0.updatedAt, releasedAt: $0.releasedAt)
            },
            repositoryConnections: bundle.repositoryConnections.sorted { $0.createdAt < $1.createdAt }.map {
                .init(
                    id: $0.id, githubRepositoryID: $0.githubRepositoryID, owner: $0.owner, name: $0.name,
                    defaultBranch: $0.defaultBranch, htmlURL: $0.htmlURL, isPrivate: $0.isPrivate,
                    lastSyncedAt: $0.lastSyncedAt, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
            },
            releaseSnapshots: bundle.releaseSnapshots.sorted { $0.snapshotCreatedAt < $1.snapshotCreatedAt }.map(
                BackupDocument.ReleaseSnapshotRecord.init)
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
                    details: record.details, status: status, repositoryConnectionID: record.repositoryConnectionID,
                    targetBranch: record.targetBranch, targetCommitSHA: record.targetCommitSHA,
                    tagName: record.tagName, compareBaseTag: record.compareBaseTag, plannedDate: record.plannedDate,
                    changelogMarkdown: record.changelogMarkdown, createdAt: record.createdAt,
                    updatedAt: record.updatedAt, releasedAt: record.releasedAt))
        }
        let connections = repositoryConnections.map {
            RepositoryConnection(
                id: $0.id, projectID: id, githubRepositoryID: $0.githubRepositoryID, owner: $0.owner, name: $0.name,
                defaultBranch: $0.defaultBranch, htmlURL: $0.htmlURL, isPrivate: $0.isPrivate,
                lastSyncedAt: $0.lastSyncedAt, createdAt: $0.createdAt, updatedAt: $0.updatedAt)
        }
        var snapshots: [ReleaseSnapshot] = []
        for record in releaseSnapshots {
            guard let origin = ReleaseSnapshotOrigin(rawValue: record.origin),
                let state = ReleaseSnapshotState(rawValue: record.state)
            else { throw .invalid("release \(record.version) has an unknown state.") }
            snapshots.append(
                ReleaseSnapshot(
                    id: record.id, projectID: id, releasePlanID: record.releasePlanID, origin: origin,
                    version: record.version, title: record.title, releaseName: record.releaseName,
                    tagName: record.tagName, targetCommitSHA: record.targetCommitSHA, targetBranch: record.targetBranch,
                    isPrerelease: record.isPrerelease, releaseNotesMarkdown: record.releaseNotesMarkdown,
                    tasks: record.tasks, changes: record.changes, githubRepositoryID: record.githubRepositoryID,
                    repositoryFullName: record.repositoryFullName, repositoryURL: record.repositoryURL,
                    snapshotCreatedAt: record.snapshotCreatedAt, state: state, githubReleaseID: record.githubReleaseID,
                    githubReleaseURL: record.githubReleaseURL, publishedAt: record.publishedAt,
                    publishedNotesMarkdown: record.publishedNotesMarkdown, publishedTagName: record.publishedTagName,
                    publishedCommitSHA: record.publishedCommitSHA, stateChangedAt: record.stateChangedAt))
        }
        return ProjectBundle(
            project: project, columns: columns, tasks: tasks, releasePlans: plans, repositoryConnections: connections,
            releaseSnapshots: snapshots)
    }
}

extension BackupDocument.ProjectRecord {
    /// Decodes format 1 and 2 files, which have no `repositoryConnections` (1) or `releaseSnapshots` (1–2).
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        details = try container.decodeIfPresent(String.self, forKey: .details)
        iconName = try container.decodeIfPresent(String.self, forKey: .iconName)
        accentColor = try container.decodeIfPresent(String.self, forKey: .accentColor)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        columns = try container.decode([BackupDocument.ColumnRecord].self, forKey: .columns)
        tasks = try container.decode([BackupDocument.TaskRecord].self, forKey: .tasks)
        releasePlans = try container.decode([BackupDocument.ReleasePlanRecord].self, forKey: .releasePlans)
        repositoryConnections =
            try container.decodeIfPresent(
                [BackupDocument.RepositoryConnectionRecord].self, forKey: .repositoryConnections)
            ?? []
        releaseSnapshots =
            try container.decodeIfPresent([BackupDocument.ReleaseSnapshotRecord].self, forKey: .releaseSnapshots) ?? []
    }
}

extension BackupDocument.ReleaseSnapshotRecord {
    init(_ snapshot: ReleaseSnapshot) {
        self.init(
            id: snapshot.id, releasePlanID: snapshot.releasePlanID, origin: snapshot.origin.rawValue,
            version: snapshot.version, title: snapshot.title, releaseName: snapshot.releaseName,
            tagName: snapshot.tagName, targetCommitSHA: snapshot.targetCommitSHA, targetBranch: snapshot.targetBranch,
            isPrerelease: snapshot.isPrerelease, releaseNotesMarkdown: snapshot.releaseNotesMarkdown,
            tasks: snapshot.tasks, changes: snapshot.changes, githubRepositoryID: snapshot.githubRepositoryID,
            repositoryFullName: snapshot.repositoryFullName, repositoryURL: snapshot.repositoryURL,
            snapshotCreatedAt: snapshot.snapshotCreatedAt, state: snapshot.state.rawValue,
            githubReleaseID: snapshot.githubReleaseID, githubReleaseURL: snapshot.githubReleaseURL,
            publishedAt: snapshot.publishedAt, publishedNotesMarkdown: snapshot.publishedNotesMarkdown,
            publishedTagName: snapshot.publishedTagName, publishedCommitSHA: snapshot.publishedCommitSHA,
            stateChangedAt: snapshot.stateChangedAt)
    }
}
