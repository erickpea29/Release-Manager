import PersistenceSpike
import SwiftUI

struct M00SpikeApp: App {
    @AppStorage("appearance") private var appearance: AppearancePreference = .system

    var body: some Scene {
        WindowGroup("M00 Spike") {
            ContentView()
                .preferredColorScheme(appearance.colorScheme)
        }
        .defaultSize(width: 900, height: 560)

        Settings {
            SpikeSettingsView()
                .preferredColorScheme(appearance.colorScheme)
        }
    }
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum WindowMaterialPreference: String, CaseIterable, Identifiable {
    case opaque
    /// SwiftUI-only path: `containerBackground(_:for: .window)`, macOS 15+.
    case swiftUIMaterial
    /// AppKit path: `NSVisualEffectView` with behind-window blending.
    case appKitVisualEffect
    var id: Self { self }

    var label: String {
        switch self {
        case .opaque: "Opaque"
        case .swiftUIMaterial: "Translucent (SwiftUI)"
        case .appKitVisualEffect: "Translucent (AppKit)"
        }
    }
}

struct SpikeSettingsView: View {
    @AppStorage("appearance") private var appearance: AppearancePreference = .system
    @AppStorage("windowMaterial") private var windowMaterial: WindowMaterialPreference = .opaque

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                ForEach(AppearancePreference.allCases) { Text($0.rawValue.capitalized).tag($0) }
            }
            Picker("Window material", selection: $windowMaterial) {
                ForEach(WindowMaterialPreference.allCases) { Text($0.label).tag($0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding()
    }
}
