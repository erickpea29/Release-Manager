import AppKit
import SwiftUI

/// Settings › Claude: turn the connection on, copy the setup command, see what Claude did.
struct ClaudeSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @State private var isConfirmingNewKey = false
    @State private var didCopy = false

    private var claude: ClaudeConnection { model.claude }

    var body: some View {
        @Bindable var preferences = preferences
        Form {
            Section {
                Toggle("Let Claude read projects and add tasks", isOn: $preferences.claudeEnabled)
                    .accessibilityLabel("Let Claude read projects and add tasks")
                    .accessibilityIdentifier("claudeEnabled")
                LabeledContent("Status") {
                    Label(statusText, systemImage: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityIdentifier("claudeStatus")
                }
                LabeledContent("Port") {
                    TextField("Port", value: $preferences.claudePort, format: .number.grouping(.never))
                        .labelsHidden()
                        .frame(width: 80)
                        .multilineTextAlignment(.trailing)
                }
            } footer: {
                Text(
                    "Claude Code connects to Relvora on this Mac only (127.0.0.1), with a key kept in the Keychain. "
                        + "Relvora must be open."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if preferences.claudeEnabled, let command = claude.setupCommand {
                Section {
                    Text(Self.masked(command))
                        .font(.callout.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Setup command for Claude Code")
                    HStack {
                        Button(didCopy ? "Copied" : "Copy Setup Command", systemImage: "doc.on.doc") { copy(command) }
                        Spacer()
                        Button("New Key…") { isConfirmingNewKey = true }
                    }
                } header: {
                    Text("Set up Claude Code")
                } footer: {
                    Text(
                        "Paste it in Terminal once. Every Claude Code session on this Mac can then use Relvora; one "
                            + "that’s already open picks it up after /mcp or a restart. The command holds the key, so "
                            + "keep it to yourself."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            Section("What Claude can do") {
                Label("Read your projects, the versions being planned, and their tasks", systemImage: "eye")
                Label("Create tasks in a version or the Backlog, labeled “claude”", systemImage: "plus.square")
                Label(
                    "Nothing else: no edits, moves, or deletions, no release plans, nothing on GitHub",
                    systemImage: "hand.raised")
                if let activity = claude.lastActivity {
                    Text(
                        "\(activity.date.formatted(date: .omitted, time: .shortened)): \(activity.summary)"
                    )
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("claudeActivity")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: preferences.claudeEnabled) { claude.apply() }
        .onChange(of: preferences.claudePort) { if preferences.claudeEnabled { claude.apply() } }
        .confirmationDialog(
            "Make a new access key?", isPresented: $isConfirmingNewKey, titleVisibility: .visible
        ) {
            Button("New Key") {
                claude.replaceKey()
                didCopy = false
            }
        } message: {
            Text("The current setup command stops working. Run the new one in Terminal to reconnect Claude Code.")
        }
    }

    private var statusText: String {
        switch claude.status {
        case .off: "Off"
        case .starting: "Starting…"
        case .running(let port): "Running on 127.0.0.1:\(port)"
        case .failed(let reason): "Not running: \(reason)"
        }
    }

    private var statusSymbol: String {
        switch claude.status {
        case .running: "circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        default: "circle"
        }
    }

    private var statusColor: Color {
        switch claude.status {
        case .running: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopy = true
    }

    /// The key is copied, not shown.
    static func masked(_ command: String) -> String {
        guard let range = command.range(of: "Bearer ") else { return command }
        let keyStart = range.upperBound
        let prefixEnd = command.index(keyStart, offsetBy: 4, limitedBy: command.endIndex) ?? command.endIndex
        let keyEnd = command[keyStart...].firstIndex(of: "\"") ?? command.endIndex
        return String(command[..<prefixEnd]) + "••••••••" + String(command[keyEnd...])
    }
}
