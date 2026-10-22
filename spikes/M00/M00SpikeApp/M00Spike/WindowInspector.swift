import AppKit

/// Launch with `-inspectWindow YES`: reports what each material mode actually installs in the window, then quits.
/// Used because the verification environment cannot take screenshots (no Screen Recording permission).
enum WindowInspector {
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: "inspectWindow") }

    static func reportAndExit() async {
        try? await Task.sleep(for: .seconds(1.5))
        let defaults = UserDefaults.standard
        print("mode=\(defaults.string(forKey: "windowMaterial") ?? "opaque") appearance=\(defaults.string(forKey: "appearance") ?? "system")")
        print("reduceTransparency=\(NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)")
        for window in NSApp.windows where window.isVisible {
            let alpha = window.backgroundColor.usingColorSpace(.sRGB)?.alphaComponent ?? -1
            print("window '\(window.title)' isOpaque=\(window.isOpaque) backgroundAlpha=\(alpha) effectiveAppearance=\(window.effectiveAppearance.name.rawValue)")
            let root = window.contentView?.superview ?? window.contentView
            for view in views(in: root) {
                let size = "\(Int(view.frame.width))x\(Int(view.frame.height))"
                if let effect = view as? NSVisualEffectView {
                    let blending = effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow"
                    print("  NSVisualEffectView material=\(effect.material.rawValue) blending=\(blending) state=\(effect.state.rawValue) frame=\(size)")
                } else if className(of: view).contains("Glass") {
                    print("  \(className(of: view)) frame=\(size)")
                }
            }
            let backdrops = layers(in: root?.layer).filter { className(of: $0).contains("Backdrop") }
            for layer in backdrops {
                let groupName = (layer.value(forKey: "groupName") as? String).map { " group=\($0)" } ?? ""
                print("  \(className(of: layer)) frame=\(Int(layer.bounds.width))x\(Int(layer.bounds.height))\(groupName)")
            }
        }
        exit(0)
    }

    private static func className(of object: AnyObject) -> String {
        String(describing: type(of: object))
    }

    private static func views(in root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { views(in: $0) }
    }

    private static func layers(in root: CALayer?) -> [CALayer] {
        guard let root else { return [] }
        return [root] + (root.sublayers ?? []).flatMap { layers(in: $0) }
    }
}
