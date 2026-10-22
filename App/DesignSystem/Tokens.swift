import SwiftUI

/// Spacing scale (points). Use these instead of literals.
enum Spacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
}

enum Radius {
    static let control: CGFloat = 6
    static let card: CGFloat = 10
    static let panel: CGFloat = 14
}

enum PreferenceKey {
    static let appearance = "appearance"
    static let windowMaterial = "windowMaterial"
    static let sidebarVisible = "sidebarVisible"
}

enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

extension View {
    /// Opaque reading surface for cards and board columns. Readable over any window material.
    func panel(padding: CGFloat = Spacing.m) -> some View {
        self
            .padding(padding)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6))
            }
    }
}
