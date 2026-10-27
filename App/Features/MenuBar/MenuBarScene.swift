import AppKit
import RelvoraCore
import SwiftUI

/// Relvora's menu bar icon (ADR 0022): versions in progress and drafts waiting, each one click from opening.
/// - It appears once the projects have loaded. An icon already there at launch stops SwiftUI from opening the main
///   window.
/// - Settings › General turns it off. If the system removes it from the menu bar, the switch follows.
struct MenuBarScene: Scene {
    let model: AppModel

    var body: some Scene {
        MenuBarExtra("Relvora", image: "MenuBarIcon", isInserted: isInserted) {
            MenuBarMenu()
                .environment(model)
        }
        .menuBarExtraStyle(.menu)
    }

    private var isInserted: Binding<Bool> {
        Binding(
            get: { model.preferences.showsMenuBarIcon && model.hasLoaded },
            set: { isInserted in
                if model.hasLoaded { model.preferences.showsMenuBarIcon = isInserted }
            })
    }
}

/// The icon's menu: drafts waiting, then versions in progress, each opening its project's Releases tab; then Open
/// Relvora, Settings, and Quit. Sections bring their own separators.
private struct MenuBarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let overview = ReleaseOverview(
            sections: model.projectSections, activePlans: model.stats.compactMapValues(\.activePlan))
        if !overview.drafts.isEmpty {
            Section("Drafts Waiting") {
                ForEach(overview.drafts) { versionButton($0) }
            }
        }
        ForEach(overview.versions) { section in
            Section(section.title) {
                ForEach(section.items) { versionButton($0) }
            }
        }
        if overview.isEmpty {
            Section {
                Button {
                } label: {
                    Text("No Versions in Progress")
                    Text("Plan one in a project’s Releases tab.")
                }
                .disabled(true)
            }
        }
        Section {
            Button("Open Relvora") { showMainWindow() }
            Button("Settings…") {
                NSApp.activate()
                openSettings()
            }
            .keyboardShortcut(",")
        }
        Section {
            Button("Quit Relvora") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
    }

    /// The project and version, with its status icon; the status and progress on a second line.
    private func versionButton(_ item: ReleaseOverview.Item) -> some View {
        Button {
            showMainWindow()
            model.openProject(item.project.id, tab: .releases)
        } label: {
            Label("\(item.project.name) \(item.plan.version)", systemImage: item.plan.status.symbol)
            Text(detail(item))
        }
    }

    private func detail(_ item: ReleaseOverview.Item) -> String {
        switch item.plan.status {
        case .draftCreated:
            return "Draft created · not published yet"
        case .reconciliationNeeded:
            return "Needs reconciliation · check GitHub"
        default:
            let status = item.plan.plannedDate.map {
                "Planned for \($0.formatted(.dateTime.month(.abbreviated).day()))"
            }
            let stats = model.stats[item.project.id] ?? ProjectStats()
            let tasks =
                stats.versionTaskCount == 0
                ? "No tasks yet" : "\(stats.versionCompletedCount) of \(stats.versionTaskCount) tasks done"
            return "\(status ?? item.plan.status.title) · \(tasks)"
        }
    }

    /// Brings Relvora forward with its main window, opening the window again if it was closed.
    private func showMainWindow() {
        NSApp.activate()
        openWindow(id: "main")
    }
}

/// Settings › General: the menu bar icon's switch.
struct MenuBarSettingsSection: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Show Relvora in the menu bar", isOn: $preferences.showsMenuBarIcon)
                // A grouped form's switch has no label of its own for VoiceOver.
                .accessibilityLabel("Show Relvora in the menu bar")
                .accessibilityIdentifier("showsMenuBarIcon")
        } footer: {
            Text(
                "Versions in progress and drafts waiting, each one click from opening. The icon is there while Relvora "
                    + "is open."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
