import AppKit
import GitHubIntegration
import RelvoraCore
import SwiftUI

/// GitHub account status, the device-flow sign-in, and disconnecting. Shown in Settings and in projects.
struct GitHubConnectionPanel: View {
    @Environment(AppModel.self) private var app
    @State private var isConfirmingDisconnect = false

    private var github: GitHubModel { app.github }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            switch github.status {
            case .unavailable:
                Label("This build has no GitHub App configured.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            case .checking:
                ProgressView("Checking GitHub sign-in…")
                    .controlSize(.small)
            case .connected(let account):
                connected(account)
            case .disconnected, .needsReauthorization:
                if let step = github.connectStep {
                    connecting(step)
                } else {
                    disconnected
                }
            }
        }
        .alert("Disconnect GitHub?", isPresented: $isConfirmingDisconnect) {
            Button("Disconnect", role: .destructive) { Task { await github.disconnect() } }
            if let url = github.configuration?.authorizationsURL {
                Button("Disconnect and Open GitHub Settings") {
                    Task { await github.disconnect() }
                    NSWorkspace.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "Relvora forgets your GitHub sign-in on this Mac and keeps cached repository data. To revoke its "
                    + "access completely, also remove Relvora under Authorized GitHub Apps on github.com.")
        }
    }

    private func connected(_ account: GitHubAccount) -> some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Label("Connected as @\(account.login)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
                Spacer()
                Button("Disconnect…") { isConfirmingDisconnect = true }
            }
            if let configuration = github.configuration {
                Link("Choose which repositories Relvora can access…", destination: configuration.installURL)
                    .font(.callout)
            }
        }
    }

    private var disconnected: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            if github.status == .needsReauthorization {
                Label("Your GitHub sign-in expired or was revoked.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(
                "Connect GitHub to browse your repositories, releases, tags, commits, and pull requests. Relvora signs "
                    + "in with a one-time code and stores the sign-in in your Keychain."
            )
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button(github.status == .needsReauthorization ? "Reconnect GitHub…" : "Connect GitHub…") {
                github.startConnecting()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private func connecting(_ step: GitHubModel.ConnectStep) -> some View {
        switch step {
        case .requestingCode:
            HStack {
                ProgressView().controlSize(.small)
                Text("Contacting GitHub…")
                Spacer()
                Button("Cancel") { github.cancelConnecting() }
            }
        case .waiting(let code, let url, let expiresAt):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text("Enter this code on GitHub:")
                Text(code)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                    .accessibilityLabel("Code \(code.map(String.init).joined(separator: " "))")
                HStack {
                    Button("Copy Code and Open GitHub") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Cancel") { github.cancelConnecting() }
                }
                HStack(spacing: Spacing.xs) {
                    ProgressView().controlSize(.small)
                    Text(
                        "Waiting for approval. The code expires at \(expiresAt.formatted(date: .omitted, time: .shortened))."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Only approve a code you started here. Relvora never asks for your GitHub password.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: Spacing.s) {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Try Again") { github.startConnecting() }
                    Button("Cancel") { github.cancelConnecting() }
                }
            }
        }
    }
}
