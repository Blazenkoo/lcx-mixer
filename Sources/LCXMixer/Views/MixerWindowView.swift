import SwiftUI

struct MixerWindowView: View {
    @ObservedObject var core: MixerCore
    let openSettings: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack {
                HeaderStatus(core: core)
                Spacer()
                Text("Output: \(core.outputName)").scaledFont(AppText.caption).foregroundStyle(.secondary)
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            HStack(spacing: 8 * scale) {
                ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                    ChannelStripView(core: core, index: i)
                }
            }

            UnassignedListView(core: core, compact: false)
                .padding(.top, 16 * scale)
        }
        .padding(16 * scale)
        // The content decides the window's size: exactly eight strips wide, as tall as what's inside.
        .frame(width: (8 * ChannelStripView.width + 7 * 8 + 32) * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct UnassignedListView: View {
    @ObservedObject var core: MixerCore
    let compact: Bool
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unassigned Audio Sources")
                .scaledFont(compact ? AppText.caption : AppText.headline, weight: compact ? .semibold : .bold)
                .foregroundStyle(compact ? .secondary : .primary)
            if core.unassigned.isEmpty {
                Text("Nothing waiting").scaledFont(AppText.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(core.unassigned) { s in
                    row(s)
                }
            }
        }
    }

    @ViewBuilder
    private func row(_ s: Source) -> some View {
        HStack(spacing: 8) {
            if !compact { SourceIcon(source: s, size: 22 * scale) }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayName).scaledFont(12, weight: .medium).lineLimit(1).truncationMode(.tail)
                if s.permissionNeeded {
                    Text("Permission needed").scaledFont(AppText.status, weight: .medium).foregroundStyle(Color.warningText)
                } else if core.isListMuted(s.id) {
                    Text("Muted by list").scaledFont(AppText.status, weight: .medium).foregroundStyle(Color.errorText)
                } else if !compact {
                    Text(core.isManuallyUnassigned(s.id) ? "Unassigned by you" : "Waiting for a free channel")
                        .scaledFont(AppText.caption2).foregroundStyle(.secondary)
                }
            }
            if !compact {
                HorizontalMeter(levels: core.levels, id: s.id).frame(width: 60 * scale)
            }
            Spacer()
            if s.permissionNeeded {
                Button("Open Settings") { AudioCapturePermission.openSystemSettings() }
                    .controlSize(.small)
            } else if core.isListMuted(s.id) {
                Button("Unmute") { core.removeFromMuteList(s.id) }
                    .controlSize(.small)
                    .help("Take \(s.name) off the mute list")
            } else {
                Button("Assign") { core.assign(s.id) }
                    .controlSize(.small)
                    .disabled(!core.hasFreeChannel)
                    .help(core.hasFreeChannel ? "Put on the first free channel" : "No free channel")
            }
            Menu {
                if !core.isListMuted(s.id) {
                    Button("Always mute") { core.alwaysMute(s.id) }
                }
                Button("Always ignore") { core.ignore(s.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22 * scale)
        }
        .padding(.vertical, (compact ? 1 : 3) * scale)
        .draggable(s.id) {
            HStack { SourceIcon(source: s, size: 20 * scale); Text(s.name) }.padding(6 * scale)
        }
    }
}
