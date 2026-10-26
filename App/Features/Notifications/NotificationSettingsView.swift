import AppKit
import RelvoraCore
import SwiftUI

/// Settings › Notifications: macOS's permission, and a switch for each kind.
struct NotificationSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences

    private var notifier: Notifier { model.notifier }

    var body: some View {
        Form {
            Section {
                LabeledContent("macOS") {
                    HStack(spacing: Spacing.xs) {
                        Text(permissionText)
                            .foregroundStyle(notifier.permission == .denied ? .orange : .secondary)
                            .accessibilityIdentifier("notificationPermission")
                        switch notifier.permission {
                        case .notAsked:
                            Button("Allow Notifications…") { Task { await notifier.requestPermission() } }
                        case .denied:
                            Button("Open System Settings") { openSystemSettings() }
                        default:
                            EmptyView()
                        }
                    }
                }
            } footer: {
                Text(
                    "A banner appears only when Relvora isn’t the active app. Otherwise the notification goes "
                        + "straight to Notification Center, because the window already shows what happened."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Notify me when") {
                ForEach(NotificationKind.allCases) { kind in
                    Toggle(isOn: binding(kind)) {
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(kind.title)
                            Text(kind.explanation)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    // A grouped form's switch has no label of its own for VoiceOver.
                    .accessibilityLabel(kind.title)
                    .accessibilityIdentifier("notify-\(kind.rawValue)")
                }
            }

            #if DEBUG
                if model.options.defaultsSuite != nil {
                    Section("Recorded instead of shown (test settings)") {
                        if notifier.recorded.isEmpty { Text("None yet").foregroundStyle(.secondary) }
                        ForEach(Array(notifier.recorded.enumerated()), id: \.offset) { _, content in
                            Text("\(content.title) — \(content.body)")
                                .accessibilityIdentifier("recordedNotification")
                        }
                    }
                }
            #endif
        }
        .formStyle(.grouped)
        .task { await notifier.refreshPermission() }
    }

    private var permissionText: String {
        switch notifier.permission {
        case .unknown: "Checking…"
        case .notAsked: "Relvora asks the first time it has something to tell you."
        case .allowed: "Allowed"
        case .denied: "Turned off for Relvora in System Settings"
        }
    }

    private func binding(_ kind: NotificationKind) -> Binding<Bool> {
        Binding(
            get: { preferences.notifies(kind) },
            set: { isOn in
                preferences.setNotifies(kind, isOn)
                Task { await model.notificationSettingsChanged() }
            })
    }

    private func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}
