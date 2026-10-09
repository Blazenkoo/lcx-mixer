import AppKit
import SwiftUI

/// The app's text size steps. macOS has no system-wide text size for apps to follow, so the steps are
/// the app's own, anchored on macOS's standard sizes at Default.
enum TextSize: Int, CaseIterable, Identifiable {
    case smaller = -1, standard = 0, larger = 1, largest = 2

    var id: Int { rawValue }

    var scale: CGFloat {
        switch self {
        case .smaller: return 0.88
        case .standard: return 1.0
        case .larger: return 1.15
        case .largest: return 1.3
        }
    }

    var label: String {
        switch self {
        case .smaller: return "Smaller"
        case .standard: return "Default"
        case .larger: return "Larger"
        case .largest: return "Largest"
        }
    }
}

/// macOS's standard text sizes in points, so semantic styles can be scaled like everything else.
enum AppText {
    static let caption2: CGFloat = 10
    static let caption: CGFloat = 10
    static let footnote: CGFloat = 10
    static let subheadline: CGFloat = 11
    static let callout: CGFloat = 12
    static let body: CGFloat = 13
    static let headline: CGFloat = 13
}

private struct UIScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    /// Multiplier for every text size and size-dependent dimension in the app's own views.
    var uiScale: CGFloat {
        get { self[UIScaleKey.self] }
        set { self[UIScaleKey.self] = newValue }
    }
}

private struct ScaledFont: ViewModifier {
    @Environment(\.uiScale) private var scale
    let size: CGFloat
    let weight: Font.Weight
    let design: Font.Design
    let monospacedDigit: Bool

    func body(content: Content) -> some View {
        let font = Font.system(size: (size * scale).rounded(), weight: weight, design: design)
        return content.font(monospacedDigit ? font.monospacedDigit() : font)
    }
}

extension View {
    /// A system font at `size` points, scaled by the Text size setting. Use this instead of fixed fonts.
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default,
                    monospacedDigit: Bool = false) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: design, monospacedDigit: monospacedDigit))
    }
}

/// Root wrapper for every window and the pop-up: applies the Text size setting, and adds the
/// ⌘− / ⌘+ / ⌘0 shortcuts where `shortcuts` is on.
struct ScaledRoot<Content: View>: View {
    @ObservedObject var settings: AppSettings
    var shortcuts = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .environment(\.uiScale, settings.textSize.scale)
            .background {
                if shortcuts {
                    // Invisible buttons that only carry the keyboard shortcuts.
                    Group {
                        Button("Larger text") { settings.stepTextSize(1) }.keyboardShortcut("+", modifiers: .command)
                        Button("Larger text") { settings.stepTextSize(1) }.keyboardShortcut("=", modifiers: .command)
                        Button("Smaller text") { settings.stepTextSize(-1) }.keyboardShortcut("-", modifiers: .command)
                        Button("Default text size") { settings.textSize = .standard }.keyboardShortcut("0", modifiers: .command)
                    }
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true)
                }
            }
    }
}

// MARK: - Status text colours

extension Color {
    /// Text for errors and "muted" states. The system red is made for icons and large text; at small
    /// sizes it falls under 4.5:1 contrast (2.6:1 on a grey button, 3:1 in light mode). These shades
    /// keep at least 5:1 on the app's window and strip backgrounds in both appearances.
    static let errorText = adaptive(dark: 0xFF7A70, light: 0xA8251B, name: "errorText")
    /// Text for warnings and hints. The system orange is 1.9:1 in light mode; these keep at least 4.7:1.
    static let warningText = adaptive(dark: 0xFFB340, light: 0x9A4600, name: "warningText")

    private static func adaptive(dark: UInt32, light: UInt32, name: String) -> Color {
        func rgb(_ v: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
        return Color(nsColor: NSColor(name: NSColor.Name(name)) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        })
    }
}

extension AppText {
    /// Short status labels ("Muted by list", "Permission needed"): never below 11 points.
    static let status: CGFloat = 11
}
