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
        .defaultSize(width: 1100, height: 700)
        .commands {
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("New Project…") { model.isPresentingNewProject = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.startupError != nil)
            }
        }

        Settings {
            SettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}
