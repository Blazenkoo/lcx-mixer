import SwiftUI

struct MixerWindowView: View {
    @ObservedObject var core: MixerCore
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HeaderStatus(core: core)
                Spacer()
                Text("Output: \(core.outputName)").font(.caption).foregroundStyle(.secondary)
                Button(action: openSettings) { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless)
                    .help("Settings")
            }

            HStack(spacing: 8) {
                ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                    ChannelStripView(core: core, index: i)
                }
            }

            UnassignedListView(core: core, compact: false)
                .padding(.top, 16)
        }
        .padding(16)
        .frame(minWidth: 8 * 136 + 7 * 8 + 32)
    }
}

struct UnassignedListView: View {
    @ObservedObject var core: MixerCore
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Unassigned Audio Sources").font(compact ? .caption.weight(.semibold) : .headline)
                .foregroundStyle(compact ? .secondary : .primary)
            if core.unassigned.isEmpty {
                Text("Nothing waiting").font(.caption).foregroundStyle(.tertiary)
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
            if !compact { SourceIcon(source: s, size: 22) }
            VStack(alignment: .leading, spacing: 1) {
                Text(s.displayName).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.tail)
                if s.permissionNeeded {
                    Text("Permission needed").font(.caption2).foregroundStyle(.orange)
                } else if !compact {
                    Text(core.isManuallyUnassigned(s.id) ? "Unassigned by you" : "Waiting for a free channel")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if !compact {
                HorizontalMeter(levels: core.levels, id: s.id).frame(width: 60)
            }
            Spacer()
            if s.permissionNeeded {
                Button("Open Settings") { AudioCapturePermission.openSystemSettings() }
                    .controlSize(.small)
            } else {
                Button("Assign") { core.assign(s.id) }
                    .controlSize(.small)
                    .disabled(!core.hasFreeChannel)
                    .help(core.hasFreeChannel ? "Put on the first free channel" : "No free channel")
            }
            Menu {
                Button("Always ignore") { core.ignore(s.id) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 22)
        }
        .padding(.vertical, compact ? 1 : 3)
        .draggable(s.id) {
            HStack { SourceIcon(source: s, size: 20); Text(s.name) }.padding(6)
        }
    }
}
