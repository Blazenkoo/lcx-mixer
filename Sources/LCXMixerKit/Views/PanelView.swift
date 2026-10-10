import SwiftUI

/// Menu-bar dropdown: one row per channel, then the unassigned list and app actions.
struct PanelView: View {
    @ObservedObject var core: MixerCore
    let openMixer: () -> Void
    let openSettings: () -> Void
    var openAbout: () -> Void = {}
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(spacing: 6 * scale) {
                Circle().fill(core.controllerConnected ? Color.green : Color.red).frame(width: 7 * scale, height: 7 * scale)
                Text(core.controllerConnected ? "Controller connected" : "Controller not connected")
                    .scaledFont(AppText.caption).foregroundStyle(core.controllerConnected ? Color.secondary : Color.errorText)
                Spacer()
                if core.muteAll {
                    Label("Media muted", systemImage: "speaker.slash.fill").scaledFont(AppText.status, weight: .medium).foregroundStyle(Color.errorText)
                }
                if core.micMuted {
                    Label("Mic muted", systemImage: "mic.slash.fill").scaledFont(AppText.status, weight: .medium).foregroundStyle(Color.errorText)
                }
            }

            if core.wrongExtensionFolder && core.browserConnected {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                } label: {
                    Label("Browser extension loaded from the wrong folder", systemImage: "exclamationmark.triangle.fill")
                        .scaledFont(AppText.caption)
                }
                .buttonStyle(.link)
                .foregroundStyle(Color.warningText)
            }

            VStack(spacing: 2) {
                ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                    PanelRow(core: core, index: i)
                }
            }

            Divider()
            SourceListsView(core: core, compact: true)
            Divider()

            HStack {
                Button("Open mixer", action: openMixer)
                Spacer()
                Button("About", action: openAbout)
                Button("Settings", action: openSettings)
                Button("Quit") { NSApp.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .scaledFont(AppText.callout)
        }
        .padding(12 * scale)
        .frame(width: 400 * scale)
    }
}

private struct PanelRow: View {
    @ObservedObject var core: MixerCore
    let index: Int
    @State private var hovering = false
    @Environment(\.uiScale) private var scale

    var body: some View {
        let status = core.status(ofChannel: index)
        let source = core.source(onChannel: index)
        HStack(spacing: 8 * scale) {
            Text("\(index + 1)")
                .scaledFont(12, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 14 * scale)
            Circle().fill(status.color).frame(width: 8 * scale, height: 8 * scale)

            if status == .master {
                Text("Master").scaledFont(12, weight: .medium)
                Spacer()
                Text("\(Int((core.masterVolume * 100).rounded()))%")
                    .scaledFont(12, monospacedDigit: true).foregroundStyle(.secondary)
            } else if let s = source {
                Text(s.displayName)
                    .scaledFont(12, weight: .medium)
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
                        .foregroundStyle(status == .muted ? Color.errorText : Color.primary)
                }
                .buttonStyle(.borderless)
                Text("\(Int((core.position(of: s) * 100).rounded()))%")
                    .scaledFont(12, monospacedDigit: true)
                    .foregroundStyle(.secondary)
                    .frame(width: 38 * scale, alignment: .trailing)
            } else {
                Text("Free").scaledFont(12).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .scaledFont(11)
        .padding(.horizontal, 6 * scale)
        .frame(height: 26 * scale)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering && source != nil ? Color.secondary.opacity(0.1) : Color.clear))
        .onHover { hovering = $0 }
    }
}
