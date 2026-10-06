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

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(status.color).frame(width: 8, height: 8)
            if let symbol = status.symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            }
            if showLabel {
                Text(status.label).font(.caption).foregroundStyle(.secondary)
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
                Capsule()
                    .fill(LinearGradient(colors: [.green, .green, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: geo.size.height * value)
                    .animation(.linear(duration: 0.04), value: value)
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
                Capsule().fill(Color.green.opacity(0.8)).frame(width: geo.size.width * value)
            }
        }
        .frame(height: 4)
    }
}

struct HeaderStatus: View {
    @ObservedObject var core: MixerCore

    var body: some View {
        HStack(spacing: 12) {
            Label {
                Text(core.controllerConnected ? "Launch Control XL connected" : "Controller not connected")
            } icon: {
                Circle().fill(core.controllerConnected ? Color.green : Color.red).frame(width: 7, height: 7)
            }
            .foregroundStyle(core.controllerConnected ? Color.secondary : Color.red)

            if core.muteAll {
                Label("Mute all on", systemImage: "speaker.slash.fill").foregroundStyle(.red)
            }
            if core.chromeProblem {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("Chrome extension not connected", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("Load the extension from this folder in chrome://extensions → Developer mode → Load unpacked")
            }
            if core.wrongExtensionFolder && core.chromeConnected {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("Chrome is using an outdated extension folder", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
                .help("In chrome://extensions remove LCX Mixer, then Load unpacked from this folder so it updates itself")
            }
            if core.permissionStatus == .denied {
                Button {
                    AudioCapturePermission.openSystemSettings()
                } label: {
                    Label("Audio permission needed", systemImage: "lock.fill")
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
            }
        }
        .font(.caption)
        .labelStyle(.titleAndIcon)
    }
}
