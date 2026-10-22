import AppKit
import SwiftUI

/// Window background treatment (ADR 0006). Translucent uses AppKit behind-window blending, which kept all
/// text readable in M00; SwiftUI's ultra-thin material did not.
enum WindowMaterial: String, CaseIterable, Identifiable {
    case opaque
    case translucent

    var id: Self { self }

    var title: String {
        switch self {
        case .opaque: "Opaque"
        case .translucent: "Translucent"
        }
    }
}

extension View {
    func windowMaterial(_ material: WindowMaterial) -> some View {
        modifier(WindowMaterialModifier(material: material))
    }
}

/// Reduce Transparency and Increase Contrast always force the opaque background.
private struct WindowMaterialModifier: ViewModifier {
    let material: WindowMaterial
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if material == .translucent && !reduceTransparency && contrast == .standard {
            content.containerBackground(for: .window) { BehindWindowMaterial() }
        } else {
            content.containerBackground(Color(nsColor: .windowBackgroundColor), for: .window)
        }
    }
}

private struct BehindWindowMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
