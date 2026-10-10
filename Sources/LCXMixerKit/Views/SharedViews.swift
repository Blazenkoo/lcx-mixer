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

    var body: some View {
        GeometryReader { geo in
            let value = CGFloat(min(1, max(0, id.flatMap { levels.values[$0] } ?? 0)))
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.secondary.opacity(0.15))
                if let id, id.hasPrefix("tab:") || levels.activity.contains(id) {
                    // No measurable level (tabs, untouched native apps): show activity, not a fake meter.
                    ActivityRain(active: value > 0)
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

    var body: some View {
        GeometryReader { geo in
            let value = CGFloat(min(1, max(0, levels.values[id] ?? 0)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                if id.hasPrefix("tab:") || levels.activity.contains(id) {
                    ActivityRain(active: value > 0, axis: .horizontal)
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
            Label {
                Text(core.controllerConnected ? "\(core.controllerName) connected" : "Controller not connected")
            } icon: {
                Circle().fill(core.controllerConnected ? Color.green : Color.red).frame(width: 7 * scale, height: 7 * scale)
            }
            .foregroundStyle(core.controllerConnected ? Color.secondary : Color.errorText)

            if core.muteAll {
                Label("All media muted", systemImage: "speaker.slash.fill").foregroundStyle(Color.errorText).fontWeight(.medium)
            }
            if core.micMuted {
                Label("Microphone muted", systemImage: "mic.slash.fill").foregroundStyle(Color.errorText).fontWeight(.medium)
            }
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
                .help("On the browser's extensions page remove LCX Mixer, then Load unpacked from this folder so it updates itself")
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

/// The small bordered symbol button used on the strips (Play, Mute, Unassign) and for Settings.
struct SmallIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .primary
    let action: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .scaledFont(11, weight: .semibold)
                .frame(width: 24 * scale, height: 22 * scale)
                .foregroundStyle(tint)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}
