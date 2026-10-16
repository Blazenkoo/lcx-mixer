import AppKit
import CoreAudio
import SwiftUI

extension ChannelStatus {
    var color: Color {
        switch self {
        case .empty: return Color.gray.opacity(0.5)
        case .master: return Color.accentColor
        case .playing, .appActive: return Color(red: 0.20, green: 0.75, blue: 0.35)
        case .paused: return Color(red: 0.95, green: 0.65, blue: 0.10)
        case .muted: return Color(red: 0.90, green: 0.25, blue: 0.22)
        }
    }
}

struct StatusBadge: View {
    let status: ChannelStatus
    var showLabel = true
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 5 * scale) {
            Circle().fill(status.color).frame(width: 8 * scale, height: 8 * scale)
            if let symbol = status.symbol {
                Image(systemName: symbol).scaledFont(10, weight: .semibold).foregroundStyle(.secondary)
            }
            if showLabel {
                Text(status.label).scaledFont(AppText.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.label)
    }
}

struct SourceIcon: View {
    let source: Source?
    var size: CGFloat = 40

    var body: some View {
        Group {
            if let image = source?.icon {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if let source {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(
                        Text(String(source.name.prefix(1)).uppercased())
                            .font(.system(size: size * 0.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                    )
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Vertical level meter.
struct LevelMeter: View {
    @ObservedObject var levels: LevelStore
    let id: String?
    /// The channel's volume on the fader's scale: activity drops stay below it.
    var zone: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let value = CGFloat(min(1, max(0, id.flatMap { levels.values[$0] } ?? 0)))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.15))
                if let id, id.hasPrefix("tab:") || levels.activity.contains(id) {
                    // No measurable level (tabs, untouched native apps): show activity, not a fake meter.
                    ActivityRain(active: value > 0, zone: zone)
                } else {
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * value)
                    .animation(.linear(duration: 0.04), value: value)
                }
            }
        }
        .frame(width: 5)
    }
}

/// Horizontal meter for compact rows.
struct HorizontalMeter: View {
    @ObservedObject var levels: LevelStore
    let id: String
    /// The source's volume on the fader's scale: activity drops stay below it.
    var zone: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            let value = CGFloat(min(1, max(0, levels.values[id] ?? 0)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                if id.hasPrefix("tab:") || levels.activity.contains(id) {
                    ActivityRain(active: value > 0, zone: zone, axis: .horizontal)
                } else {
                    Capsule().fill(Color.green.opacity(0.8)).frame(width: geo.size.width * value)
                }
            }
        }
        .frame(height: 4)
    }
}

struct HeaderStatus: View {
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 12 * scale) {
            // Without a controller the mixer simply works on screen; nothing calls it a mode.
            Label {
                Text(core.hardwarePresent ? "\(core.controllerName) connected" : "Media mixer active")
            } icon: {
                Circle().fill(Color.green).frame(width: 7 * scale, height: 7 * scale)
            }
            .foregroundStyle(Color.secondary)

            HeaderDivider()
            HStack(spacing: 6 * scale) {
                Text("Output").foregroundStyle(.secondary).accessibilityHidden(true)
                DevicePicker(title: "Output", devices: core.outputDevices, selected: core.outputDeviceID) { core.selectOutput($0) }
                MediaMuteButton(core: core)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Output")

            HeaderDivider()
            HStack(spacing: 6 * scale) {
                Text("Input").foregroundStyle(.secondary).accessibilityHidden(true)
                DevicePicker(title: "Input", devices: core.inputDevices, selected: core.inputDeviceID) { core.selectInput($0) }
                MicMuteButton(core: core)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Input")
            if core.chromeProblem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("Browser extension not connected", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(Color.warningText)
                .help("Load the extension from this folder: open the browser's extensions page, turn on Developer mode, choose Load unpacked")
            }
            if core.wrongExtensionFolder && core.browserConnected {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("A browser is using an outdated extension folder", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(Color.warningText)
                .help("On the browser's extensions page remove Media Mixer, then Load unpacked from this folder so it updates itself")
            }
            if core.permissionStatus == .denied {
                Button {
                    AudioCapturePermission.openSystemSettings()
                } label: {
                    Label("Audio permission needed", systemImage: "lock.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(Color.warningText)
            }
        }
        .scaledFont(AppText.status)
        .labelStyle(.titleAndIcon)
    }
}

/// The menu-bar panel's top line: "Mute:", then Media and Microphone (no device pickers there).
struct MuteToggles: View {
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 6 * scale) {
            Text("Mute:").scaledFont(AppText.status).foregroundStyle(.secondary).accessibilityHidden(true)
            MediaMuteButton(core: core)
            MicMuteButton(core: core)
        }
    }
}

/// Media: mutes all media playback (what you hear), like the controller's side Mute button.
/// Solid red while on.
struct MediaMuteButton: View {
    @ObservedObject var core: MixerCore

    var body: some View {
        MuteButton(title: "Media", symbol: "speaker.wave.2.fill", mutedSymbol: "speaker.slash.fill",
                   isOn: core.muteAll, enabled: true,
                   help: core.muteAll ? "All media is muted" : "Mute all media",
                   accessibilityName: "Mute all media") { core.toggleMuteAll() }
    }
}

/// Microphone: mutes the selected input (what others hear), like Solo. Dimmed rather than hidden
/// when that input can't be muted by apps, so the row doesn't shift when you switch microphones.
struct MicMuteButton: View {
    @ObservedObject var core: MixerCore

    var body: some View {
        MuteButton(title: "Microphone", symbol: "mic.fill", mutedSymbol: "mic.slash.fill",
                   isOn: core.micMuted, enabled: core.micMutable,
                   help: core.micMutable ? (core.micMuted ? "The microphone is muted" : "Mute the microphone") : "Can't be muted by apps",
                   accessibilityName: "Mute the microphone") { core.toggleMicrophone() }
    }
}

/// A thin vertical line between the header's groups.
struct HeaderDivider: View {
    @Environment(\.uiScale) private var scale

    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.35)).frame(width: 1, height: 18 * scale).accessibilityHidden(true)
    }
}

/// The header's Output or Input picker. macOS draws pop-up menus lower than the app's buttons, so
/// the button is drawn like them (with a chevron), and opens the standard macOS menu with the
/// current device ticked.
struct DevicePicker: View {
    let title: String
    let devices: [AudioDeviceChoice]
    let selected: AudioObjectID
    let choose: (AudioObjectID) -> Void
    @State private var anchor = MenuAnchor()
    @Environment(\.uiScale) private var scale

    private var name: String { devices.first { $0.id == selected }?.name ?? "None" }

    var body: some View {
        Button { anchor.show(devices: devices, selected: selected, choose: choose) } label: {
            HStack(spacing: 5 * scale) {
                Text(name).lineLimit(1).truncationMode(.tail)
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(.secondary)
            }
            .scaledFont(AppText.status, weight: .medium)
            .frame(height: 22 * scale)
            // As wide as the device's name, up to a cap; longer names are cut short with "…".
            .frame(maxWidth: 220 * scale)
            .fixedSize(horizontal: true, vertical: false)
        }
        .buttonStyle(AppButtonStyle())
        .background(MenuAnchorView(anchor: anchor))
        .disabled(devices.isEmpty)
        .help(name)
        .accessibilityLabel(title)
        .accessibilityValue(name)
        .accessibilityHint("Opens a menu to choose the \(title.lowercased()) device")
    }
}

/// Holds the picker's view so the menu can open right below it.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
    private var target: MenuTarget?

    func show(devices: [AudioDeviceChoice], selected: AudioObjectID, choose: @escaping (AudioObjectID) -> Void) {
        guard let view else { return }
        let menu = NSMenu()
        let target = MenuTarget(choose: choose)
        for d in devices {
            let item = NSMenuItem(title: d.name, action: #selector(MenuTarget.pick(_:)), keyEquivalent: "")
            item.target = target
            item.tag = Int(d.id)
            item.state = d.id == selected ? .on : .off
            menu.addItem(item)
        }
        self.target = target
        menu.minimumWidth = view.bounds.width
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.isFlipped ? view.bounds.maxY + 4 : -4), in: view)
    }
}

@MainActor
private final class MenuTarget: NSObject {
    let choose: (AudioObjectID) -> Void
    init(choose: @escaping (AudioObjectID) -> Void) { self.choose = choose }
    @objc func pick(_ sender: NSMenuItem) { choose(AudioObjectID(sender.tag)) }
}

private struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }
}

/// A button that turns solid red while its mute is on; VoiceOver reads it as a toggle.
private struct MuteButton: View {
    let title: String
    let symbol: String
    let mutedSymbol: String
    let isOn: Bool
    let enabled: Bool
    let help: String
    let accessibilityName: String
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5 * scale) {
                // A fixed-width icon, so swapping to the muted symbol never changes the button's size.
                Image(systemName: isOn ? mutedSymbol : symbol)
                    .frame(width: 16 * scale)
                Text(title)
            }
            .scaledFont(AppText.status, weight: .medium)
            .frame(height: 22 * scale)
        }
        .buttonStyle(AppButtonStyle(isOn: isOn))
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(accessibilityName)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityHint(enabled ? "" : "Can't be muted by apps")
    }
}

/// The app's small bordered buttons (channel strips, the window header, Settings), drawn by hand
/// so they all share one size and a mute that's on can turn solid red without changing it. macOS's
/// own prominent style greys out whenever the window isn't active, and the mute state has to read
/// at a glance even then.
struct AppButtonStyle: ButtonStyle {
    var isOn = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.uiScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        let dark = colorScheme == .dark
        let shape = RoundedRectangle(cornerRadius: 6 * scale, style: .continuous)
        let fill: Color = isOn
            ? Color.red.opacity(configuration.isPressed ? 0.7 : 0.85)
            : dark ? Color.white.opacity(configuration.isPressed ? 0.24 : 0.15)
                   : Color.white.opacity(configuration.isPressed ? 0.7 : 1)
        configuration.label
            .foregroundStyle(isOn ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            // The same padding as macOS's small bordered buttons (it doesn't grow with text size),
            // so these stay exactly the size the 2.3 buttons were.
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(shape.fill(fill))
            .overlay(shape.strokeBorder(Color.black.opacity(dark || isOn ? 0 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark || isOn ? 0 : 0.08), radius: 0.5, y: 0.5)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(shape)
    }
}

/// The small symbol button used on the strips (Play, Mute, Unassign) and for Settings. `isOn`
/// makes it a toggle that turns solid red, for Mute.
struct SmallIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    var isOn: Bool? = nil
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(11, weight: .semibold)
                .frame(width: 24 * scale, height: 22 * scale)
                .foregroundStyle(isOn == true ? Color.white : tint)
        }
        .buttonStyle(AppButtonStyle(isOn: isOn == true))
        .help(help)
        .accessibilityLabel(help)
        .modifier(ToggleTraits(isOn: isOn))
    }
}

private struct ToggleTraits: ViewModifier {
    let isOn: Bool?

    func body(content: Content) -> some View {
        if let isOn {
            content.accessibilityAddTraits(.isToggle).accessibilityValue(isOn ? "On" : "Off")
        } else {
            content
        }
    }
}
