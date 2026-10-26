import RelvoraCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            BoardSettingsView()
                .tabItem { Label("Board", systemImage: "rectangle.split.3x1") }
            ReleaseSettingsView()
                .tabItem { Label("Releases", systemImage: "shippingbox") }
            GitHubSettingsView()
                .tabItem { Label("GitHub", systemImage: "link") }
            ClaudeSettingsView()
                .tabItem { Label("Claude", systemImage: "sparkles") }
        }
        .frame(width: 560)
    }
}

private struct GeneralSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Picker("Appearance", selection: $preferences.appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            LabeledContent("Accent color") {
                AccentPicker(selection: $preferences.accent)
            }
            Picker("Window", selection: $preferences.windowMaterial) {
                ForEach(WindowMaterial.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if reduceTransparency || contrast == .increased {
                Text(
                    "\(reduceTransparency ? "Reduce Transparency" : "Increase Contrast") is on in System Settings, so "
                        + "the window stays opaque."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if preferences.windowMaterial == .translucent {
                Text("Cards, columns, and editors keep opaque backgrounds, so text stays readable.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped)
    }
}

/// Color swatches like System Settings' accent picker. Each swatch is a labeled button.
private struct AccentPicker: View {
    @Binding var selection: AccentPreference

    var body: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(AccentPreference.allCases) { accent in
                Button {
                    selection = accent
                } label: {
                    Circle()
                        .fill(accent.color ?? Color(nsColor: .controlAccentColor))
                        .overlay {
                            if accent == .system {
                                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.white).font(.caption2)
                            }
                        }
                        .frame(width: 18, height: 18)
                        .padding(3)
                        .overlay {
                            if selection == accent { Circle().strokeBorder(.primary.opacity(0.6), lineWidth: 2) }
                        }
                }
                .buttonStyle(.plain)
                .help(accent.title)
                .accessibilityLabel("\(accent.title) accent")
                .accessibilityAddTraits(selection == accent ? .isSelected : [])
            }
        }
    }
}

/// The board new projects start with.
private struct BoardSettingsView: View {
    @Environment(Preferences.self) private var preferences
    @State private var draft: [ColumnTemplate] = []
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                ForEach(draft.indices, id: \.self) { index in
                    HStack {
                        TextField("Column \(index + 1)", text: $draft[index].name)
                            .labelsHidden()
                        Toggle("Completion", isOn: completionBinding(index))
                            .toggleStyle(.checkbox)
                            .help("Tasks in the completion column count as done")
                        Button("Move Up", systemImage: "chevron.up") { draft.swapAt(index, index - 1) }
                            .disabled(index == 0)
                        Button("Move Down", systemImage: "chevron.down") { draft.swapAt(index, index + 1) }
                            .disabled(index == draft.count - 1)
                        Button("Remove", systemImage: "minus.circle") { draft.remove(at: index) }
                            .disabled(draft.count == 1)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
                HStack {
                    Button("Add Column", systemImage: "plus") {
                        draft.append(ColumnTemplate(name: "Column \(draft.count + 1)", isCompletion: false))
                    }
                    Spacer()
                    Button("Restore Defaults") {
                        preferences.resetNewProjectColumns()
                        draft = preferences.newProjectColumns
                    }
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Columns for new projects")
            } footer: {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.circle").foregroundStyle(.red)
                    }
                    Text("Existing projects keep their columns; change those on each board.")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = preferences.newProjectColumns }
        .onChange(of: draft) { _, template in save(template) }
    }

    private func completionBinding(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { draft[index].isCompletion },
            set: { isOn in
                guard isOn else { return }
                for other in draft.indices { draft[other].isCompletion = other == index }
            })
    }

    /// Valid templates are saved as you edit; an invalid one shows why and keeps the last valid one.
    private func save(_ template: [ColumnTemplate]) {
        do {
            try preferences.setNewProjectColumns(template)
            errorMessage = nil
        } catch {
            errorMessage = "Not saved: " + AppAlert.message(for: error)
        }
    }
}

/// Label rules for generated release notes.
private struct ReleaseSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                ForEach(preferences.changelogLabelRules.indices, id: \.self) { index in
                    HStack {
                        TextField(
                            "Label", text: $preferences.changelogLabelRules[index].label,
                            prompt: Text("Pull request label")
                        )
                        .labelsHidden()
                        Picker("Section", selection: $preferences.changelogLabelRules[index].category) {
                            ForEach(ChangelogCategory.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button("Remove", systemImage: "minus.circle") {
                            preferences.changelogLabelRules.remove(at: index)
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                    }
                }
                Button("Add Rule", systemImage: "plus") {
                    preferences.changelogLabelRules.append(ChangelogLabelRule(label: "", category: .improvements))
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Pull request labels")
            } footer: {
                Text(
                    "Generated release notes put pull requests with these labels in the chosen section. Labels match "
                        + "ignoring case. Without a rule, common labels (bug, feature, docs, dependencies…) and "
                        + "Conventional Commits prefixes (feat:, fix:…) decide the section."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onDisappear {
            preferences.changelogLabelRules = ChangelogLabelRule.normalized(preferences.changelogLabelRules)
        }
    }
}

private struct GitHubSettingsView: View {
    @Environment(Preferences.self) private var preferences

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Picker("Refresh repositories", selection: $preferences.githubRefresh) {
                    ForEach(GitHubRefreshInterval.allCases) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("githubRefreshInterval")
            } footer: {
                Text(
                    "While a repository is open in a project’s GitHub tab and Relvora is the active app. A failed "
                        + "refresh waits for the next one. Refresh now at any time with ⌘R."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section {
                GitHubConnectionPanel()
            } footer: {
                Text(
                    "Relvora reads repository metadata, releases, tags, commits, and pull requests through the Relvora "
                        + "GitHub App, only for repositories you install it on. It writes only draft releases you "
                        + "confirm. Your sign-in is stored in the Keychain and never leaves this Mac except to talk to "
                        + "GitHub."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
