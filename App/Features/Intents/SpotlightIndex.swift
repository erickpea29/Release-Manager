import AppIntents
import CoreSpotlight
import Foundation
import RelvoraCore
import SwiftUI
import UniformTypeIdentifiers

/// Keeps Relvora's projects and tasks in Spotlight (ADR 0023).
/// - What: active projects, and the tasks of their version being planned and of their Backlog (`SystemSearch`).
/// - When: a moment after each change, sending only what changed. Deleted and archived projects, deleted tasks, and
///   tasks finished outside the version are removed.
/// - Never from a test copy (in-memory store, sample data, test settings), and nothing while Settings › General has
///   it off. Spotlight's index stays on this Mac.
final class SpotlightIndex {
    static let delay: Duration = .seconds(2)
    /// Notes beyond this aren't searched.
    nonisolated static let maximumNotesLength = 2_000

    /// False in test copies, which never touch Spotlight or Siri.
    let isAvailable: Bool
    private let environment: AppEnvironment?
    private let preferences: Preferences
    /// What this run put in Spotlight; `nil` until the first update, since what earlier runs left is unknown.
    private var indexed: [String: SearchableItem]?
    /// The project names Siri last learned for the App Shortcuts' phrases.
    private var phraseProjectNames: [String]?
    private var pending: Task<Void, Never>?
    private var isUpdating = false
    private var updateAgain = false

    init(environment: AppEnvironment?, preferences: Preferences, isAvailable: Bool) {
        self.environment = environment
        self.preferences = preferences
        self.isAvailable = isAvailable
    }

    /// Data changed: Spotlight follows a moment later, once for several changes.
    func setNeedsUpdate() {
        guard isAvailable else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            await self?.update()
        }
    }

    /// Brings Spotlight up to date now, or empties it when the switch is off. Updates never overlap.
    func update() async {
        guard isAvailable, let environment else { return }
        guard !isUpdating else {
            updateAgain = true
            return
        }
        isUpdating = true
        defer { isUpdating = false }
        repeat {
            updateAgain = false
            await updateOnce(environment)
        } while updateAgain
    }

    private func updateOnce(_ environment: AppEnvironment) async {
        let index = CSSearchableIndex.default()
        do {
            let items = try await environment.searchableItems()
            updatePhrases(items)
            guard preferences.spotlightEnabled else {
                if indexed != [:] { try await index.deleteAllSearchableItems() }
                indexed = [:]
                return
            }
            if indexed == nil {
                try await index.deleteAllSearchableItems()
                indexed = [:]
            }
            let changes = SystemSearch.changes(from: indexed ?? [:], to: items)
            if !changes.remove.isEmpty { try await index.deleteSearchableItems(withIdentifiers: changes.remove) }
            if !changes.index.isEmpty { try await index.indexSearchableItems(changes.index.map(Self.searchableItem)) }
            indexed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        } catch {
            // The next update starts over.
            indexed = nil
        }
    }

    /// Siri learns the projects' names, for phrases such as "What's the next release of Relvora in Relvora".
    private func updatePhrases(_ items: [SearchableItem]) {
        let names = items.compactMap { item -> String? in
            if case .project(let project) = item { project.name } else { nil }
        }
        guard names != phraseProjectNames else { return }
        phraseProjectNames = names
        RelvoraShortcuts.updateAppShortcutParameters()
    }

    // MARK: Items

    /// The item, linked to its App Intents entity, so Spotlight can open it with Open Project or Open Task.
    nonisolated static func searchableItem(_ item: SearchableItem) -> CSSearchableItem {
        let domain =
            switch item {
            case .project: "projects"
            case .task: "tasks"
            }
        let entry = CSSearchableItem(
            uniqueIdentifier: item.id, domainIdentifier: domain, attributeSet: attributes(item))
        switch item {
        case .project(let project): entry.associateAppEntity(ProjectEntity(project), priority: 1)
        case .task(let task): entry.associateAppEntity(TaskEntity(task))
        }
        return entry
    }

    /// What Spotlight shows and searches.
    nonisolated static func attributes(_ item: SearchableItem) -> CSSearchableItemAttributeSet {
        let attributes = CSSearchableItemAttributeSet(contentType: .content)
        switch item {
        case .project(let project):
            attributes.title = project.name
            attributes.contentDescription = [project.subtitle, project.details ?? ""].filter { !$0.isEmpty }
                .joined(separator: "\n")
            attributes.keywords = [project.groupName, project.version].compactMap(\.self)
        case .task(let task):
            attributes.title = task.title
            attributes.contentDescription = task.subtitle
            attributes.textContent = task.notes.map { String($0.prefix(maximumNotesLength)) }
            attributes.keywords = task.labels + [task.projectName, task.type.title, task.priority.title]
        }
        return attributes
    }
}

/// Settings › General: whether projects and tasks show in Spotlight.
struct SpotlightSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Show projects and tasks in Spotlight", isOn: $preferences.spotlightEnabled)
                // A grouped form's switch has no label of its own for VoiceOver.
                .accessibilityLabel("Show projects and tasks in Spotlight")
                .accessibilityIdentifier("spotlightEnabled")
        } header: {
            Text("Spotlight")
        } footer: {
            Text(
                model.spotlight.isAvailable
                    ? "Active projects, and the tasks of their version being planned and their Backlog. Spotlight’s "
                        + "index stays on this Mac. Turning this off removes them from it."
                    : "This copy of Relvora uses test data, so it stays out of Spotlight."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .onChange(of: preferences.spotlightEnabled) {
            Task { await model.spotlight.update() }
        }
    }
}
