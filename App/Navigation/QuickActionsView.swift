import RelvoraCore
import SwiftUI

/// ⌘K: go to any view or project, or run a common action, by typing.
/// ↑↓ choose, Return runs, Escape closes.
struct QuickActionsView: View {
    struct Item: Identifiable {
        let id: String
        let title: String
        var subtitle: String?
        let symbol: String
        var shortcut: String?
        let run: @MainActor (AppModel) -> Void
    }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isSearchFocused: Bool

    private var items: [Item] {
        var items = [
            Item(id: "dashboard", title: "Dashboard", symbol: "square.grid.2x2", shortcut: "⌘1") {
                $0.navigationRequest = .dashboard
            },
            Item(id: "history", title: "Release History", symbol: "clock.arrow.circlepath", shortcut: "⌘2") {
                $0.navigationRequest = .history
            },
        ]
        for project in app.projectSections.flatMap(\.projects) {
            // "Pilou · Board": the group, so typing a company's name lists its projects.
            let kind = app.group(of: project)?.name ?? "Project"
            items.append(
                Item(
                    id: "project-\(project.id)", title: project.name, subtitle: "\(kind) · Board", symbol: "shippingbox"
                ) { $0.openProject(project.id, tab: .board) })
            items.append(
                Item(
                    id: "backlog-\(project.id)", title: "\(project.name) Backlog", subtitle: "\(kind) · Backlog",
                    symbol: "list.bullet"
                ) { $0.openProject(project.id, tab: .backlog) })
            items.append(
                Item(
                    id: "releases-\(project.id)", title: "\(project.name) Releases", subtitle: "\(kind) · Releases",
                    symbol: "doc.badge.clock"
                ) { $0.openProject(project.id, tab: .releases) })
            items.append(
                Item(
                    id: "github-\(project.id)", title: "\(project.name) GitHub", subtitle: "\(kind) · GitHub",
                    symbol: "link"
                ) { $0.openProject(project.id, tab: .github) })
        }
        if let current = app.currentProjectID, let project = app.projects.first(where: { $0.id == current }) {
            items.append(
                Item(id: "new-task", title: "New Task", subtitle: "in \(project.name)", symbol: "plus", shortcut: "⌘N")
                {
                    $0.openProject(current, action: .newTask)
                })
            items.append(
                Item(
                    id: "new-plan", title: "New Release Plan…", subtitle: "in \(project.name)",
                    symbol: "calendar.badge.plus"
                ) { $0.openProject(current, action: .newReleasePlan) })
        }
        let settings = openSettings
        items += [
            Item(id: "new-project", title: "New Project…", symbol: "plus.square", shortcut: "⇧⌘N") {
                $0.projectEditor = .new
            },
            Item(id: "new-group", title: "New Group…", symbol: "folder.badge.plus", shortcut: "⌃⌘N") {
                $0.groupEditor = .new(moving: nil)
            },
            Item(id: "export", title: "Export Backup…", symbol: "square.and.arrow.up", shortcut: "⇧⌘E") { model in
                Task { await model.beginBackupExport() }
            },
            Item(id: "restore", title: "Restore from Backup…", symbol: "arrow.uturn.backward.circle") {
                $0.isChoosingBackup = true
            },
            Item(id: "settings", title: "Settings…", symbol: "gearshape", shortcut: "⌘,") { _ in settings() },
        ]
        return items
    }

    private var matches: [Item] {
        items.filter { TextSearch.matches(query, fields: [$0.title, $0.subtitle]) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.s) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Go to a project or run an action", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit(runSelection)
                    .onKeyPress(.downArrow) { moveSelection(1) }
                    .onKeyPress(.upArrow) { moveSelection(-1) }
                    .accessibilityLabel("Quick actions search")
                    .accessibilityIdentifier("quickActionsSearch")
            }
            .padding(Spacing.m)
            Divider()
            ScrollViewReader { proxy in
                List {
                    ForEach(Array(matches.enumerated()), id: \.element.id) { index, item in
                        row(item, isSelected: index == selection)
                            .id(item.id)
                            .contentShape(.rect)
                            .onTapGesture {
                                selection = index
                                runSelection()
                            }
                    }
                }
                .listStyle(.plain)
                .onChange(of: selection) { _, index in
                    if matches.indices.contains(index) { proxy.scrollTo(matches[index].id) }
                }
            }
            .overlay {
                if matches.isEmpty {
                    Text("No matches").foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 520, height: 380)
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { selection = 0 }
        .onExitCommand { dismiss() }
    }

    private func row(_ item: Item, isSelected: Bool) -> some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: item.symbol)
                .frame(width: 20)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                }
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.callout.monospaced())
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.tertiary))
            }
        }
        .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
        .padding(.vertical, Spacing.xxs)
        .padding(.horizontal, Spacing.xs)
        .background(
            isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: Radius.control)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func moveSelection(_ step: Int) -> KeyPress.Result {
        guard !matches.isEmpty else { return .handled }
        selection = (selection + step + matches.count) % matches.count
        return .handled
    }

    private func runSelection() {
        guard matches.indices.contains(selection) else { return }
        let item = matches[selection]
        dismiss()
        item.run(app)
    }
}
