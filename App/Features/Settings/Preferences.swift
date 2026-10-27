import Foundation
import Observation
import RelvoraCore
import SwiftUI

/// App accent: the system's, or one of a fixed palette that stays readable in light and dark appearance.
enum AccentPreference: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, green, graphite

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .graphite: "Graphite"
        default: rawValue.capitalized
        }
    }

    /// `nil` follows the system accent.
    var color: Color? {
        switch self {
        case .system: nil
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        case .red: .red
        case .orange: .orange
        case .green: .green
        case .graphite: .gray
        }
    }
}

/// How often a repository open in the GitHub tab refreshes from GitHub, while Relvora is the active app.
enum GitHubRefreshInterval: String, CaseIterable, Identifiable {
    case fiveMinutes = "5m"
    case fifteenMinutes = "15m"
    case hourly = "1h"
    case never

    var id: Self { self }

    var title: String {
        switch self {
        case .fiveMinutes: "Every 5 minutes"
        case .fifteenMinutes: "Every 15 minutes"
        case .hourly: "Every hour"
        case .never: "Never"
        }
    }

    /// `nil` when repositories refresh only on request.
    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: 5 * 60
        case .fifteenMinutes: 15 * 60
        case .hourly: 60 * 60
        case .never: nil
        }
    }
}

/// App settings, stored in `UserDefaults`. Views use this store rather than `@AppStorage`, so the same values drive
/// the window, new projects, release notes, and backups (PRODUCT_SPEC G12). Keys from M01–M04 are unchanged.
@Observable
final class Preferences {
    private enum Key {
        static let appearance = PreferenceKey.appearance
        static let windowMaterial = PreferenceKey.windowMaterial
        static let sidebarVisible = PreferenceKey.sidebarVisible
        static let accent = "accentColor"
        static let newProjectColumns = "newProjectColumns"
        static let changelogLabelRules = "changelogLabelRules"
        static let githubRefresh = "githubRefreshInterval"
        static let checksForUpdates = "checksForUpdates"
        static let claudeEnabled = "claudeEnabled"
        static let claudePort = "claudePort"
        static let notificationsOff = "notificationsOff"
        static let mergeMethod = "mergeMethod"
        static let showsMenuBarIcon = "showsMenuBarIcon"
    }

    @ObservationIgnored let defaults: UserDefaults

    var appearance: AppearancePreference {
        didSet { defaults.set(appearance.rawValue, forKey: Key.appearance) }
    }
    var accent: AccentPreference {
        didSet { defaults.set(accent.rawValue, forKey: Key.accent) }
    }
    var windowMaterial: WindowMaterial {
        didSet { defaults.set(windowMaterial.rawValue, forKey: Key.windowMaterial) }
    }
    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Key.sidebarVisible) }
    }
    /// The board new projects start with. Always valid: edits are validated before they are stored.
    private(set) var newProjectColumns: [ColumnTemplate] {
        didSet { store(newProjectColumns, forKey: Key.newProjectColumns) }
    }
    /// Label → section rules for generated release notes.
    var changelogLabelRules: [ChangelogLabelRule] {
        didSet { store(changelogLabelRules, forKey: Key.changelogLabelRules) }
    }
    var githubRefresh: GitHubRefreshInterval {
        didSet { defaults.set(githubRefresh.rawValue, forKey: Key.githubRefresh) }
    }
    /// Versions in progress and drafts waiting in the menu bar (ADR 0022). On until turned off; in backups.
    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }
    /// Looks for a newer Relvora at launch and once a day (ADR 0017). Kept per Mac: not in backups.
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }
    /// Claude Code can read projects and add tasks through the MCP server on 127.0.0.1 (ADR 0018). Off until the user
    /// turns it on; kept per Mac, not in backups.
    var claudeEnabled: Bool {
        didSet { defaults.set(claudeEnabled, forKey: Key.claudeEnabled) }
    }
    /// The notification kinds turned off in Settings › Notifications; every kind is on until turned off. Per Mac.
    private(set) var notificationsOff: Set<NotificationKind> {
        didSet { defaults.set(notificationsOff.map(\.rawValue).sorted(), forKey: Key.notificationsOff) }
    }

    func notifies(_ kind: NotificationKind) -> Bool { !notificationsOff.contains(kind) }

    func setNotifies(_ kind: NotificationKind, _ isOn: Bool) {
        if isOn { notificationsOff.remove(kind) } else { notificationsOff.insert(kind) }
    }

    /// How Relvora last merged a pull request; the merge sheet starts with it. Per Mac.
    var mergeMethod: MergeMethod {
        didSet { defaults.set(mergeMethod.rawValue, forKey: Key.mergeMethod) }
    }

    var claudePort: Int {
        didSet {
            let valid = min(max(claudePort, 1024), 65_535)
            if valid != claudePort { claudePort = valid }
            defaults.set(claudePort, forKey: Key.claudePort)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init) ?? .system
        accent = defaults.string(forKey: Key.accent).flatMap(AccentPreference.init) ?? .system
        windowMaterial = defaults.string(forKey: Key.windowMaterial).flatMap(WindowMaterial.init) ?? .opaque
        sidebarVisible = defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true
        let columns = Self.load([ColumnTemplate].self, from: defaults, forKey: Key.newProjectColumns)
        // A template saved before the Backlog tab loses its Backlog column.
        newProjectColumns =
            columns.flatMap { try? ProjectRules.validatedTemplate(ProjectRules.withoutBacklog($0)) }
            ?? ProjectRules.defaultTemplate
        changelogLabelRules = ChangelogLabelRule.normalized(
            Self.load([ChangelogLabelRule].self, from: defaults, forKey: Key.changelogLabelRules) ?? [])
        githubRefresh = defaults.string(forKey: Key.githubRefresh).flatMap(GitHubRefreshInterval.init) ?? .fiveMinutes
        showsMenuBarIcon = defaults.object(forKey: Key.showsMenuBarIcon) as? Bool ?? true
        checksForUpdates = defaults.object(forKey: Key.checksForUpdates) as? Bool ?? true
        claudeEnabled = defaults.bool(forKey: Key.claudeEnabled)
        notificationsOff = Set(
            (defaults.stringArray(forKey: Key.notificationsOff) ?? []).compactMap(NotificationKind.init))
        claudePort = (defaults.object(forKey: Key.claudePort) as? Int) ?? Int(ClaudeConnection.defaultPort)
        mergeMethod = defaults.string(forKey: Key.mergeMethod).flatMap(MergeMethod.init) ?? .merge
    }

    /// Validates and stores the board template for new projects.
    func setNewProjectColumns(_ template: [ColumnTemplate]) throws {
        newProjectColumns = try ProjectRules.validatedTemplate(template)
    }

    func resetNewProjectColumns() {
        newProjectColumns = ProjectRules.defaultTemplate
    }

    // MARK: Backups

    var record: BackupDocument.PreferencesRecord {
        BackupDocument.PreferencesRecord(
            appearance: appearance.rawValue, accentColor: accent.rawValue, windowMaterial: windowMaterial.rawValue,
            newProjectColumns: newProjectColumns, changelogLabelRules: changelogLabelRules,
            githubRefreshInterval: githubRefresh.rawValue, showsMenuBarIcon: showsMenuBarIcon)
    }

    /// Applies restored settings. Unknown or invalid values are skipped, keeping the current ones.
    func apply(_ record: BackupDocument.PreferencesRecord) {
        if let value = record.appearance.flatMap(AppearancePreference.init) { appearance = value }
        if let value = record.accentColor.flatMap(AccentPreference.init) { accent = value }
        if let value = record.windowMaterial.flatMap(WindowMaterial.init) { windowMaterial = value }
        if let columns = record.newProjectColumns,
            let valid = try? ProjectRules.validatedTemplate(ProjectRules.withoutBacklog(columns))
        {
            newProjectColumns = valid
        }
        if let rules = record.changelogLabelRules { changelogLabelRules = ChangelogLabelRule.normalized(rules) }
        if let value = record.githubRefreshInterval.flatMap(GitHubRefreshInterval.init) { githubRefresh = value }
        if let value = record.showsMenuBarIcon { showsMenuBarIcon = value }
    }

    // MARK: Storage

    private func store<Value: Encodable>(_ value: Value, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private static func load<Value: Decodable>(_ type: Value.Type, from defaults: UserDefaults, forKey key: String)
        -> Value?
    {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
