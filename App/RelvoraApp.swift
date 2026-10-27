import SwiftUI

@main
struct RelvoraApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Relvora", id: "main") {
            RootView()
                .environment(model)
                .environment(model.preferences)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
                .tint(model.preferences.accent.color)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { Task { await model.updates.check(manual: true) } }
                    .disabled(model.startupError != nil || model.updates.isInstalling)
            }
            CommandGroup(replacing: .sidebar) {
                SidebarToggleCommand(preferences: model.preferences)
            }
            CommandGroup(after: .newItem) {
                NewTaskCommand()
                Button("New Project…") { model.projectEditor = .new }
                    .keyboardShortcut(.newProject)
                    .disabled(model.startupError != nil)
                Button("New Group…") { model.groupEditor = .new(moving: nil) }
                    .keyboardShortcut(.newGroup)
                    .disabled(model.startupError != nil)
            }
            CommandMenu("Go") {
                Button("Quick Actions…") { model.isShowingQuickActions = true }
                    .keyboardShortcut(.quickActions)
                    .disabled(model.startupError != nil)
                Divider()
                Button("Dashboard") { model.navigationRequest = .dashboard }
                    .keyboardShortcut(.dashboard)
                Button("Release History") { model.navigationRequest = .history }
                    .keyboardShortcut(.releaseHistory)
                Divider()
                WorkspaceTabCommands()
            }
            CommandMenu("Task") {
                TaskCommands()
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Backup…") { Task { await model.beginBackupExport() } }
                    .keyboardShortcut(.exportBackup)
                    .disabled(model.startupError != nil)
                Button("Restore from Backup…") { model.isChoosingBackup = true }
                    .disabled(model.startupError != nil)
            }
            CommandGroup(replacing: .help) {
                KeyboardShortcutsCommand()
            }
            #if DEBUG
                CommandMenu("Demo GitHub") {
                    Button("Publish Drafts on Demo GitHub") { Task { await DemoGitHub.shared.publishAll() } }
                        .disabled(!model.options.demoGitHub)
                    Button("Go Offline") { Task { await DemoGitHub.shared.setOffline(true) } }
                        .disabled(!model.options.demoGitHub)
                    Button("Go Online") { Task { await DemoGitHub.shared.setOffline(false) } }
                        .disabled(!model.options.demoGitHub)
                }
            #endif
        }

        Settings {
            SettingsView()
                .environment(model)
                .environment(model.preferences)
                .preferredColorScheme(model.preferences.appearance.colorScheme)
                .tint(model.preferences.accent.color)
        }

        KeyboardShortcutsWindow(preferences: model.preferences)
    }
}

/// Go › Backlog / Board / Releases / GitHub for the open project (⌥⌘1–4).
private struct WorkspaceTabCommands: View {
    @FocusedValue(\.workspaceTab) private var tab

    var body: some View {
        ForEach(WorkspaceTab.allCases) { item in
            Button(item.title) { tab?.wrappedValue = item.rawValue }
                .keyboardShortcut(KeyCommand.tab(item))
                .disabled(tab == nil)
        }
    }
}

/// Keyboard commands for the board's selected card.
private struct TaskCommands: View {
    @FocusedValue(\.boardActions) private var actions

    var body: some View {
        Button("Open Task") { actions?.open() }
            .keyboardShortcut(.openTask)
            .disabled(actions?.hasSelection != true)
        Divider()
        move("Move to Previous Column", .left, .moveTaskLeft)
        move("Move to Next Column", .right, .moveTaskRight)
        move("Move Up", .up, .moveTaskUp)
        move("Move Down", .down, .moveTaskDown)
        Divider()
        Button("Delete Task…") { actions?.requestDelete() }
            .keyboardShortcut(.deleteTask)
            .disabled(actions?.hasSelection != true)
    }

    private func move(_ title: String, _ direction: WorkspaceModel.Direction, _ command: KeyCommand) -> some View {
        Button(title) { actions?.move(direction) }
            .keyboardShortcut(command)
            .disabled(actions?.canMove(direction) != true)
    }
}

private struct NewTaskCommand: View {
    @FocusedValue(\.newTaskAction) private var newTask

    var body: some View {
        Button("New Task") { newTask?() }
            .keyboardShortcut(.newTask)
            .disabled(newTask == nil)
    }
}
