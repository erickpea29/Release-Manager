import RelvoraCore
import SwiftUI

/// Help › Keyboard Shortcuts (⌘/): every shortcut in its own small window, beside the main one.
struct KeyboardShortcutsWindow: Scene {
    static let windowID = "keyboard-shortcuts"
    let preferences: Preferences

    var body: some Scene {
        Window("Keyboard Shortcuts", id: Self.windowID) {
            KeyboardShortcutsView()
                .preferredColorScheme(preferences.appearance.colorScheme)
                .tint(preferences.accent.color)
        }
        .defaultSize(width: 480, height: 640)
        .windowResizability(.contentMinSize)
        .restorationBehavior(.disabled)
        // Only in the Help menu, not in the Window menu too.
        .commandsRemoved()
    }
}

/// Help › Keyboard Shortcuts, in place of the Help item macOS adds, which only says that no help is available.
struct KeyboardShortcutsCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Keyboard Shortcuts") { openWindow(id: KeyboardShortcutsWindow.windowID) }
            .keyboardShortcut(.keyboardShortcuts)
    }
}

/// Every `KeyCommand`, grouped like the menus. Type to filter by name or key ("move", "option", "⌘N").
struct KeyboardShortcutsView: View {
    @State private var query = ""
    @FocusState private var isSearchFocused: Bool

    private var sections: [(group: KeyCommandGroup, commands: [KeyCommand])] {
        KeyCommandGroup.allCases.compactMap { group in
            let commands = group.commands.filter { command in
                TextSearch.matches(
                    query,
                    fields: [command.title, group.title, command.spokenKeys] + command.keys.map(\.glyphs))
            }
            return commands.isEmpty ? nil : (group, commands)
        }
    }

    var body: some View {
        Form {
            ForEach(sections, id: \.group) { section in
                Section {
                    ForEach(section.commands) { KeyCommandRow(command: $0) }
                } header: {
                    Text(section.group.title)
                } footer: {
                    if let note = section.group.note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .overlay {
            if sections.isEmpty { ContentUnavailableView.search(text: query) }
        }
        // In the content, not the toolbar: a toolbar search field cut the window's title short.
        .safeAreaBar(edge: .top) {
            TextField("Search shortcuts", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                .onExitCommand { query = "" }
                .accessibilityIdentifier("shortcutsSearch")
                .scenePadding(.horizontal)
                .padding(.top, Spacing.s)
        }
        .frame(minWidth: 400, minHeight: 320)
        .onAppear { isSearchFocused = true }
    }
}

/// "New Task  ⌘ N". VoiceOver reads it as one line: "New Task, Command N".
private struct KeyCommandRow: View {
    let command: KeyCommand

    var body: some View {
        LabeledContent(command.title) {
            HStack(spacing: Spacing.xs) {
                ForEach(Array(command.keys.enumerated()), id: \.offset) { index, shortcut in
                    // "↩ or Space", but the arrow keys side by side: "↑ ↓ ← →".
                    if index > 0 && !(shortcut.isPlainArrow && command.keys[index - 1].isPlainArrow) {
                        Text("or").foregroundStyle(.secondary)
                    }
                    HStack(spacing: 3) {
                        ForEach(Array(shortcut.keyCaps.enumerated()), id: \.offset) { _, key in KeyCap(key) }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(command.title)
        .accessibilityValue(command.spokenKeys)
        .accessibilityIdentifier("shortcut-\(command.rawValue)")
    }
}

/// One key, drawn like a key on the keyboard.
private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.callout)
            .frame(minWidth: 14)
            .padding(.horizontal, Spacing.xxs)
            .padding(.vertical, 2)
            .background(
                .quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor))
            }
    }
}
