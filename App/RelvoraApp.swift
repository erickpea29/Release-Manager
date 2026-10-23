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
            CommandGroup(replacing: .sidebar) {
                SidebarToggleCommand(preferences: model.preferences)
            }
            CommandGroup(after: .newItem) {
                NewTaskCommand()
                Button("New Project…") { model.projectEditor = .new }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.startupError != nil)
            }
            CommandMenu("Go") {
                Button("Quick Actions…") { model.isShowingQuickActions = true }
                    .keyboardShortcut("k")
                    .disabled(model.startupError != nil)
                Divider()
                Button("Dashboard") { model.navigationRequest = .dashboard }
                    .keyboardShortcut("1")
                Button("Release History") { model.navigationRequest = .history }
                    .keyboardShortcut("2")
                Divider()
                WorkspaceTabCommands()
            }
            CommandMenu("Task") {
                TaskCommands()
            }
            CommandGroup(replacing: .importExport) {
                Button("Export Backup…") { Task { await model.beginBackupExport() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.startupError != nil)
                Button("Restore from Backup…") { model.isChoosingBackup = true }
                    .disabled(model.startupError != nil)
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
    }
}

/// Go › Backlog / Board / Releases / GitHub for the open project (⌥⌘1–4).
private struct WorkspaceTabCommands: View {
    @FocusedValue(\.workspaceTab) private var tab

    var body: some View {
        ForEach(Array(WorkspaceTab.allCases.enumerated()), id: \.element) { index, item in
            Button(item.title) { tab?.wrappedValue = item.rawValue }
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                .disabled(tab == nil)
        }
    }
}

/// Keyboard commands for the board's selected card.
private struct TaskCommands: View {
    @FocusedValue(\.boardActions) private var actions

    var body: some View {
        Button("Open Task") { actions?.open() }
            .keyboardShortcut("o")
            .disabled(actions?.hasSelection != true)
        Divider()
        move("Move to Previous Column", .left, .leftArrow)
        move("Move to Next Column", .right, .rightArrow)
        move("Move Up", .up, .upArrow)
        move("Move Down", .down, .downArrow)
        Divider()
        Button("Delete Task…") { actions?.requestDelete() }
            .keyboardShortcut(.delete)
            .disabled(actions?.hasSelection != true)
    }

    private func move(_ title: String, _ direction: WorkspaceModel.Direction, _ key: KeyEquivalent) -> some View {
        Button(title) { actions?.move(direction) }
            .keyboardShortcut(key, modifiers: [.command, .option])
            .disabled(actions?.canMove(direction) != true)
    }
}

private struct NewTaskCommand: View {
    @FocusedValue(\.newTaskAction) private var newTask

    var body: some View {
        Button("New Task") { newTask?() }
            .keyboardShortcut("n")
            .disabled(newTask == nil)
    }
}
