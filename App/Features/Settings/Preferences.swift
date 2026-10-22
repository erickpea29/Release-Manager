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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.string(forKey: Key.appearance).flatMap(AppearancePreference.init) ?? .system
        accent = defaults.string(forKey: Key.accent).flatMap(AccentPreference.init) ?? .system
        windowMaterial = defaults.string(forKey: Key.windowMaterial).flatMap(WindowMaterial.init) ?? .opaque
        sidebarVisible = defaults.object(forKey: Key.sidebarVisible) as? Bool ?? true
        let columns = Self.load([ColumnTemplate].self, from: defaults, forKey: Key.newProjectColumns)
        newProjectColumns = columns.flatMap { try? ProjectRules.validatedTemplate($0) } ?? ProjectRules.defaultTemplate
        changelogLabelRules = ChangelogLabelRule.normalized(
            Self.load([ChangelogLabelRule].self, from: defaults, forKey: Key.changelogLabelRules) ?? [])
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
            newProjectColumns: newProjectColumns, changelogLabelRules: changelogLabelRules)
    }

    /// Applies restored settings. Unknown or invalid values are skipped, keeping the current ones.
    func apply(_ record: BackupDocument.PreferencesRecord) {
        if let value = record.appearance.flatMap(AppearancePreference.init) { appearance = value }
        if let value = record.accentColor.flatMap(AccentPreference.init) { accent = value }
        if let value = record.windowMaterial.flatMap(WindowMaterial.init) { windowMaterial = value }
        if let columns = record.newProjectColumns, let valid = try? ProjectRules.validatedTemplate(columns) {
            newProjectColumns = valid
        }
        if let rules = record.changelogLabelRules { changelogLabelRules = ChangelogLabelRule.normalized(rules) }
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
