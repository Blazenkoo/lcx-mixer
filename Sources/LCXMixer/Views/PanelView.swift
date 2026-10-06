import SwiftUI

/// Menu-bar dropdown: one row per channel, then the unassigned list and app actions.
struct PanelView: View {
    @ObservedObject var core: MixerCore
    let openMixer: () -> Void
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(core.controllerConnected ? Color.green : Color.red).frame(width: 7, height: 7)
                Text(core.controllerConnected ? "Controller connected" : "Controller not connected")
                    .font(.caption).foregroundStyle(core.controllerConnected ? Color.secondary : Color.red)
                Spacer()
                if core.muteAll {
                    Label("Mute all", systemImage: "speaker.slash.fill").font(.caption).foregroundStyle(.red)
                }
            }

            if core.wrongExtensionFolder && core.chromeConnected {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("Chrome extension loaded from the wrong folder", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                }
                .buttonStyle(.link)
                .foregroundStyle(.orange)
            }

            VStack(spacing: 2) {
                ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                    PanelRow(core: core, index: i)
                }
            }

            Divider()
            UnassignedListView(core: core, compact: true)
            Divider()

            HStack {
                Button("Open mixer", action: openMixer)
                Spacer()
                Button("Settings", action: openSettings)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 400)
    }
}

private struct PanelRow: View {
    @ObservedObject var core: MixerCore
    let index: Int
    @State private var hovering = false

    var body: some View {
        let status = core.status(ofChannel: index)
        let source = core.source(onChannel: index)
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Circle().fill(status.color).frame(width: 8, height: 8)

            if status == .master {
                Text("Master").font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int((core.masterVolume * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
            } else if let s = source {
                Text(s.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(s.displayName)
                Spacer(minLength: 4)
                if hovering {
                    Button { core.unassign(channel: index) } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .help("Unassign")
                }
                if s.kind == .tab {
                    Button { core.togglePlay(s.id) } label: {
                        Image(systemName: s.isPlaying && s.canPlayPause ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!s.canPlayPause)
                }
                Button { core.toggleMute(s.id) } label: {
                    Image(systemName: status == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(status == .muted ? Color.red : Color.primary)
                }
                .buttonStyle(.borderless)
                Text("\(Int((core.position(of: s) * 100).rounded()))%")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            } else {
                Text("Free").font(.system(size: 12)).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && source != nil ? Color.secondary.opacity(0.1) : Color.clear))
        .onHover { hovering = $0 }
    }
}
