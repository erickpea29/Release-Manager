import SwiftUI

/// Every keyboard shortcut in Relvora, in one place. Menu commands take their keys from here
/// (`.keyboardShortcut(.newTask)`), and Help › Keyboard Shortcuts lists every case, so the two can't drift apart.
/// Keys a view handles itself (the board's arrows, the Backlog's Return) are listed too; their handlers stay in
/// those views (`BoardView.handle`, `BacklogView`, `QuickActionsView`).
enum KeyCommand: String, CaseIterable, Identifiable {
    // General
    case settings, toggleSidebar, keyboardShortcuts
    // File
    case newTask, newProject, newGroup, exportBackup
    // Go
    case quickActions, dashboard, releaseHistory, backlogTab, boardTab, releasesTab, gitHubTab
    // Task menu
    case openTask, moveTaskLeft, moveTaskRight, moveTaskUp, moveTaskDown, deleteTask
    // Board
    case selectCard, openCard, deleteCard
    // Backlog
    case openBacklogTask, deleteBacklogTask
    // GitHub
    case refreshRepository
    // Quick Actions
    case chooseQuickAction, runQuickAction, closeQuickActions

    var id: Self { self }

    /// The keys that run it. More than one means any of them; a menu uses the first.
    var keys: [KeyboardShortcut] {
        switch self {
        case .settings: [KeyboardShortcut(",")]  // The Settings scene's own key; listed, not set here.
        case .toggleSidebar: [KeyboardShortcut("s", modifiers: [.control, .command])]
        case .keyboardShortcuts: [KeyboardShortcut("/")]
        case .newTask: [KeyboardShortcut("n")]
        case .newProject: [KeyboardShortcut("n", modifiers: [.shift, .command])]
        // Not ⌥⌘N: ⌥N is a dead key on many keyboards, and the shortcut never fires.
        case .newGroup: [KeyboardShortcut("n", modifiers: [.control, .command])]
        case .exportBackup: [KeyboardShortcut("e", modifiers: [.shift, .command])]
        case .quickActions: [KeyboardShortcut("k")]
        case .dashboard: [KeyboardShortcut("1")]
        case .releaseHistory: [KeyboardShortcut("2")]
        case .backlogTab: [KeyboardShortcut("1", modifiers: [.option, .command])]
        case .boardTab: [KeyboardShortcut("2", modifiers: [.option, .command])]
        case .releasesTab: [KeyboardShortcut("3", modifiers: [.option, .command])]
        case .gitHubTab: [KeyboardShortcut("4", modifiers: [.option, .command])]
        case .openTask: [KeyboardShortcut("o")]
        case .moveTaskLeft: [KeyboardShortcut(.leftArrow, modifiers: [.option, .command])]
        case .moveTaskRight: [KeyboardShortcut(.rightArrow, modifiers: [.option, .command])]
        case .moveTaskUp: [KeyboardShortcut(.upArrow, modifiers: [.option, .command])]
        case .moveTaskDown: [KeyboardShortcut(.downArrow, modifiers: [.option, .command])]
        case .deleteTask: [KeyboardShortcut(.delete)]
        case .selectCard: [.upArrow, .downArrow, .leftArrow, .rightArrow].map(Self.plain)
        case .openCard: [Self.plain(.return), Self.plain(.space)]
        case .deleteCard, .deleteBacklogTask: [Self.plain(.delete)]
        case .openBacklogTask, .runQuickAction: [Self.plain(.return)]
        case .refreshRepository: [KeyboardShortcut("r")]
        case .chooseQuickAction: [Self.plain(.upArrow), Self.plain(.downArrow)]
        case .closeQuickActions: [Self.plain(.escape)]
        }
    }

    /// The menu's key.
    var shortcut: KeyboardShortcut { keys[0] }

    /// The menu's key as a menu shows it: "⇧⌘N".
    var glyphs: String { shortcut.glyphs }

    /// The menu item's name, or what the keys do when they aren't a menu command.
    var title: String {
        switch self {
        case .settings: "Settings…"
        case .toggleSidebar: "Show or Hide Sidebar"
        case .keyboardShortcuts: "Keyboard Shortcuts"
        case .newTask: "New Task"
        case .newProject: "New Project…"
        case .newGroup: "New Group…"
        case .exportBackup: "Export Backup…"
        case .quickActions: "Quick Actions…"
        case .dashboard: "Dashboard"
        case .releaseHistory: "Release History"
        case .backlogTab: WorkspaceTab.backlog.title
        case .boardTab: WorkspaceTab.board.title
        case .releasesTab: WorkspaceTab.releases.title
        case .gitHubTab: WorkspaceTab.github.title
        case .openTask: "Open Task"
        case .moveTaskLeft: "Move to Previous Column"
        case .moveTaskRight: "Move to Next Column"
        case .moveTaskUp: "Move Up"
        case .moveTaskDown: "Move Down"
        case .deleteTask: "Delete Task…"
        case .selectCard: "Select a card"
        case .openCard: "Open the selected card"
        case .deleteCard: "Delete the selected card"
        case .openBacklogTask: "Open the selected task"
        case .deleteBacklogTask: "Delete the selected task"
        case .refreshRepository: "Refresh from GitHub"
        case .chooseQuickAction: "Choose an action"
        case .runQuickAction: "Run the chosen action"
        case .closeQuickActions: "Close Quick Actions"
        }
    }

    var group: KeyCommandGroup {
        switch self {
        case .settings, .toggleSidebar, .keyboardShortcuts: .general
        case .newTask, .newProject, .newGroup, .exportBackup: .file
        case .quickActions, .dashboard, .releaseHistory, .backlogTab, .boardTab, .releasesTab, .gitHubTab: .go
        case .openTask, .moveTaskLeft, .moveTaskRight, .moveTaskUp, .moveTaskDown, .deleteTask: .task
        case .selectCard, .openCard, .deleteCard: .board
        case .openBacklogTask, .deleteBacklogTask: .backlog
        case .refreshRepository: .gitHub
        case .chooseQuickAction, .runQuickAction, .closeQuickActions: .quickActions
        }
    }

    /// What VoiceOver reads after the title: "Command N", "Return or Space", "Arrow keys".
    var spokenKeys: String {
        if keys.count == 4 && keys.allSatisfy(\.isPlainArrow) { return "Arrow keys" }
        return keys.map(\.spokenName).formatted(.list(type: .or))
    }

    /// Go › Backlog, Board, Releases, or GitHub.
    static func tab(_ tab: WorkspaceTab) -> KeyCommand {
        switch tab {
        case .backlog: .backlogTab
        case .board: .boardTab
        case .releases: .releasesTab
        case .github: .gitHubTab
        }
    }

    private static func plain(_ key: KeyEquivalent) -> KeyboardShortcut { KeyboardShortcut(key, modifiers: []) }
}

/// The sections of Help › Keyboard Shortcuts, in menu order, then the keys that work inside a view.
enum KeyCommandGroup: CaseIterable, Identifiable {
    case general, file, go, task, board, backlog, gitHub, quickActions

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .file: "File"
        case .go: "Go"
        case .task: "Task"
        case .board: "Board"
        case .backlog: "Backlog"
        case .gitHub: "GitHub"
        case .quickActions: "Quick Actions"
        }
    }

    /// Where the keys work, when it isn't everywhere.
    var note: String? {
        switch self {
        case .general, .file: nil
        case .go: "Backlog, Board, Releases, and GitHub switch the open project’s tab."
        case .task: "For the selected card, while the board has focus."
        case .board: "While the board has focus. Press Tab to move the focus to it."
        case .backlog: "In the Backlog tab. Double-clicking a task also opens it."
        case .gitHub: "On a repository in a project’s GitHub tab."
        case .quickActions: "In the Quick Actions panel (\(KeyCommand.quickActions.glyphs))."
        }
    }

    var commands: [KeyCommand] { KeyCommand.allCases.filter { $0.group == self } }
}

extension View {
    /// The command's key from `KeyCommand`, the one list of shortcuts.
    func keyboardShortcut(_ command: KeyCommand) -> some View {
        keyboardShortcut(command.shortcut)
    }
}

extension KeyboardShortcut {
    /// The keys as a menu shows them, one string per key: ["⇧", "⌘", "N"].
    var keyCaps: [String] {
        Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.glyph) + [key.names.glyph]
    }

    /// "⇧⌘N", as in a menu.
    var glyphs: String { keyCaps.joined() }

    /// "Shift Command N", as VoiceOver reads a menu's shortcut.
    var spokenName: String {
        (Self.modifierNames.filter { modifiers.contains($0.modifier) }.map(\.spoken) + [key.names.spoken])
            .joined(separator: " ")
    }

    /// An arrow key on its own.
    var isPlainArrow: Bool {
        modifiers.isEmpty && [.upArrow, .downArrow, .leftArrow, .rightArrow].contains(key)
    }

    /// In the order menus show them.
    private static let modifierNames: [(modifier: EventModifiers, glyph: String, spoken: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"), (.command, "⌘", "Command"),
    ]
}

extension KeyEquivalent {
    /// How a menu shows the key, and how VoiceOver reads it.
    fileprivate var names: (glyph: String, spoken: String) {
        switch self {
        case .upArrow: ("↑", "Up Arrow")
        case .downArrow: ("↓", "Down Arrow")
        case .leftArrow: ("←", "Left Arrow")
        case .rightArrow: ("→", "Right Arrow")
        case .return: ("↩", "Return")
        case .space: ("Space", "Space")
        case .tab: ("⇥", "Tab")
        case .escape: ("Esc", "Escape")
        case .delete: ("⌫", "Delete")
        case .deleteForward: ("⌦", "Forward Delete")
        case ",": (",", "Comma")
        case ".": (".", "Period")
        case "/": ("/", "Slash")
        default: (String(character).uppercased(), String(character).uppercased())
        }
    }
}
