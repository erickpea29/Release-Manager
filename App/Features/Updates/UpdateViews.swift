import AppKit
import RelvoraCore
import SwiftUI

/// The result of Check for Updates, the update offered, and its installation.
struct UpdateSheet: View {
    @Environment(AppModel.self) private var model

    private var updates: UpdateModel { model.updates }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            HStack(alignment: .top, spacing: Spacing.m) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(title).font(.title2.bold())
                    if let subtitle {
                        Text(subtitle)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content
            buttons
        }
        .padding(Spacing.l)
        .frame(width: 560)
        .interactiveDismissDisabled(updates.isInstalling)
        .accessibilityIdentifier("updateSheet")
    }

    private var current: String { updates.currentVersion?.description ?? "unknown" }

    private var title: String {
        switch updates.phase {
        case .idle, .checking: "Checking for Updates…"
        case .upToDate: "Relvora is up to date"
        case .building(let version): "Relvora \(version) is on its way"
        case .available(let update): "Relvora \(update.version) is available"
        case .installing(let update, _): "Installing Relvora \(update.version)"
        case .failed(let update?, _): "Relvora \(update.version) wasn’t installed"
        case .failed(nil, _): "Couldn’t check for updates"
        case .unavailable: "Updates aren’t available"
        }
    }

    private var subtitle: String? {
        switch updates.phase {
        case .idle, .checking: "Reading Relvora’s releases on GitHub."
        case .upToDate(let latest):
            latest.map { $0 == updates.currentVersion ? "You have \($0), the latest version." : nil }
                ?? "You have \(current). There’s no newer version."
        case .building:
            "It’s published, and GitHub is still building and notarizing it. That takes a few minutes; check again soon."
        case .available(let update):
            "You have \(current). The download is "
                + "\(ByteCountFormatter.string(fromByteCount: update.archive.size, countStyle: .file))."
        case .installing: "Relvora opens again when it’s done."
        case .failed: nil
        case .unavailable(let reason): reason
        }
    }

    @ViewBuilder
    private var content: some View {
        switch updates.phase {
        case .idle, .checking:
            ProgressView().controlSize(.small)
        case .available(let update):
            notes(update)
            Text(
                "Before installing, Relvora saves a backup of your data. It installs the update only if Apple "
                    + "notarized it and it’s signed by the same developer as this copy. The current version goes to "
                    + "the Trash."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        case .installing(let update, let step):
            InstallSteps(current: step, size: update.archive.size)
        case .failed(_, let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.primary)
                .symbolRenderingMode(.multicolor)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        default:
            EmptyView()
        }
    }

    private func notes(_ update: AppUpdate) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("What’s new").font(.headline)
            ScrollView {
                if (update.release.notes ?? "").isBlank {
                    Text("No release notes.").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    MarkdownPreview(markdown: update.release.notes ?? "")
                }
            }
            .frame(height: 220)
            .panel(padding: Spacing.s)
        }
    }

    @ViewBuilder
    private var buttons: some View {
        HStack {
            switch updates.phase {
            case .available(let update):
                Button("Skip This Version") { updates.skip(update) }
                Spacer()
                Button("Later", role: .cancel) { updates.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install and Relaunch") {
                    Task { await updates.install(update) { try await model.saveUpdateBackup(for: update.version) } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            case .installing:
                Spacer()
            case .failed(let update, _):
                if let update {
                    Button("Open Release Page") { NSWorkspace.shared.open(update.release.htmlURL) }
                }
                Spacer()
                Button("Close", role: .cancel) { updates.dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Try Again") {
                    Task {
                        if let update {
                            await updates.install(update) { try await model.saveUpdateBackup(for: update.version) }
                        } else {
                            await updates.check(manual: true)
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
            default:
                Spacer()
                Button("OK") { updates.dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// Each install step: done, in progress, or still to come.
private struct InstallSteps: View {
    let current: UpdateModel.Step
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(UpdateModel.Step.allCases) { step in
                HStack(spacing: Spacing.xs) {
                    Group {
                        if step.rawValue < current.rawValue {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        } else if step == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                    }
                    .frame(width: 18)
                    Text(title(of: step))
                        .foregroundStyle(step.rawValue > current.rawValue ? .secondary : .primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(
                    step.rawValue < current.rawValue ? "Done" : step == current ? "In progress" : "Not started")
            }
        }
        .panel(padding: Spacing.s)
    }

    private func title(of step: UpdateModel.Step) -> String {
        guard step == .downloading else { return step.title }
        return "Downloading (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
    }
}

/// "Relvora 0.2.0 is available" above the sidebar's buttons, after an automatic check found it.
struct UpdateAvailableButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = model.updates.offered {
            Button {
                model.updates.showOffered()
            } label: {
                Label("Relvora \(update.version.description) is available", systemImage: "arrow.down.circle.fill")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .help("Show what’s new and install it")
            .accessibilityIdentifier("updateAvailable")
        }
    }
}

/// Settings › General.
struct UpdateSettingsSection: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var preferences
    @Environment(\.openWindow) private var openWindow

    private var updates: UpdateModel { model.updates }

    var body: some View {
        @Bindable var preferences = preferences
        Section {
            Toggle("Check for updates automatically", isOn: $preferences.checksForUpdates)
                // A grouped form's switch has no label of its own for VoiceOver.
                .accessibilityLabel("Check for updates automatically")
                .accessibilityIdentifier("checksForUpdates")
            LabeledContent("Relvora version") {
                HStack(spacing: Spacing.xs) {
                    Text(updates.currentVersion?.description ?? "Unknown").monospacedDigit()
                    Button("Check Now") {
                        openWindow(id: "main")
                        Task { await updates.check(manual: true) }
                    }
                    .disabled(updates.isInstalling)
                }
            }
            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Updates")
        } footer: {
            Text(
                "Relvora reads its releases from \(updates.repository ?? "its GitHub repository") with your GitHub "
                    + "sign-in, at launch and once a day. It installs an update only when you choose to, after saving "
                    + "a backup of your data and checking that the update is notarized by Apple and signed by the "
                    + "same developer."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var status: String? {
        if let reason = updates.unavailableReason { return reason }
        if let offered = updates.offered { return "Relvora \(offered.version) is available." }
        if let problem = updates.lastProblem { return "The last check failed: \(problem)" }
        return updates.lastChecked.map {
            "Last checked \($0.formatted(.relative(presentation: .named)))."
        }
    }
}
