import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            GitHubSettingsView()
                .tabItem { Label("GitHub", systemImage: "link") }
        }
        .frame(width: 520)
    }
}

private struct GeneralSettingsView: View {
    @AppStorage(PreferenceKey.appearance) private var appearance = AppearancePreference.system
    @AppStorage(PreferenceKey.windowMaterial) private var windowMaterial = WindowMaterial.opaque
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
            }
            Picker("Window material", selection: $windowMaterial) {
                ForEach(WindowMaterial.allCases) { Text($0.title).tag($0) }
            }
            if reduceTransparency {
                Text("Reduce Transparency is on in System Settings, so windows stay opaque.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct GitHubSettingsView: View {
    var body: some View {
        Form {
            Section {
                GitHubConnectionPanel()
            } footer: {
                Text(
                    "Relvora reads repository metadata, releases, tags, commits, and pull requests through the Relvora "
                        + "GitHub App, only for repositories you install it on. Your sign-in is stored in the Keychain and "
                        + "never leaves this Mac except to talk to GitHub."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
