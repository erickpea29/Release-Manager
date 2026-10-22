import SwiftUI

struct SettingsView: View {
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
        .frame(width: 460)
    }
}
