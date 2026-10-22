import SwiftUI

@main
struct RelvoraApp: App {
    @State private var model = AppModel()
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system

    var body: some Scene {
        Window("Relvora", id: "main") {
            RootView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                NewTaskCommand()
                Button("New Project…") { model.projectEditor = .new }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.startupError != nil)
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
                }
            #endif
        }

        Settings {
            SettingsView()
                .environment(model)
                .preferredColorScheme(appearance.colorScheme)
        }
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
