import SwiftUI

struct ChannelStripView: View {
    @ObservedObject var core: MixerCore
    let index: Int
    @State private var isTargeted = false

    private var source: Source? { core.source(onChannel: index) }
    private var status: ChannelStatus { core.status(ofChannel: index) }
    private var isMaster: Bool { core.masterActive && index == 0 }

    var body: some View {
        VStack(spacing: 8) {
            Text(isMaster ? "Master" : "\(index + 1)")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            if isMaster {
                masterBody
            } else if let source {
                occupied(source)
            } else {
                empty
            }
        }
        .padding(10)
        .frame(width: 136, height: 430)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isMaster ? Color.accentColor.opacity(0.10) : Color.secondary.opacity(source == nil ? 0.0 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(source == nil && !isMaster ? 0.35 : 0.12),
                    style: StrokeStyle(lineWidth: isTargeted ? 2 : 1, dash: source == nil && !isMaster ? [5, 4] : [])
                )
        )
        .dropDestination(for: String.self) { items, _ in
            guard !isMaster, let id = items.first else { return false }
            core.move(id, to: index)
            return true
        } isTargeted: { isTargeted = $0 }
    }

    // MARK: Occupied

    @ViewBuilder
    private func occupied(_ s: Source) -> some View {
        Button { core.focus(s.id) } label: {
            VStack(spacing: 4) {
                SourceIcon(source: s, size: 22)
                    .padding(.vertical, 6)
                Text(s.name)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                Text(s.detail.isEmpty ? " " : s.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(height: 26, alignment: .top)
            }
        }
        .buttonStyle(.plain)
        .help("Bring \(s.name) to the front")

        StatusBadge(status: status)
        if s.kind == .tab && !s.canSetVolume {
            Text("Mute only").font(.caption2).foregroundStyle(.red)
        }

        VolumeBar(
            position: core.position(of: s),
            ghost: core.faders[index].position,
            hint: core.takeoverHint(channel: index),
            enabled: s.canSetVolume,
            levels: core.levels,
            meterID: s.id
        ) { core.setVolumeFromUI(s.id, position: $0) }
        .frame(maxHeight: .infinity)
        .padding(.vertical, 10)

        HStack(spacing: 6) {
            if s.kind == .tab {
                iconButton(s.isPlaying && s.canPlayPause ? "pause.fill" : "play.fill", help: "Play / pause") {
                    core.togglePlay(s.id)
                }
                .disabled(!s.canPlayPause)
            }
            iconButton(s.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", help: s.isMuted ? "Unmute" : "Mute",
                       tint: s.isMuted ? .red : nil) {
                core.toggleMute(s.id)
            }
            iconButton("xmark", help: "Unassign from this channel") {
                core.unassign(channel: index)
            }
        }
        .draggable(s.id) {
            HStack { SourceIcon(source: s, size: 20); Text(s.name) }.padding(6)
        }
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text("Free").font(.callout).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var masterBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 15))
                .frame(width: 22, height: 22)
                .padding(.vertical, 6)
                .foregroundStyle(Color.accentColor)
            Text("Master").font(.system(size: 13, weight: .semibold))
            Text(core.outputName).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center).frame(height: 26, alignment: .top)
            StatusBadge(status: .master)
            VolumeBar(
                position: core.masterVolume,
                ghost: core.faders[0].position,
                hint: core.takeoverHint(channel: 0),
                enabled: true,
                levels: nil,
                meterID: nil
            ) { core.setMasterFromUI($0) }
            .frame(maxHeight: .infinity)
            .padding(.vertical, 10)
            Color.clear.frame(height: 22)
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 24, height: 22)
                .foregroundStyle(tint ?? Color.primary)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help(help)
    }
}

/// Vertical volume bar (with the level meter beside it, same height) and its value label underneath.
struct VolumeBar: View {
    let position: Float
    let ghost: Float?
    let hint: String?
    let enabled: Bool
    let levels: LevelStore?
    let meterID: String?
    let onChange: (Float) -> Void

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                bar
                if let levels {
                    LevelMeter(levels: levels, id: meterID)
                }
            }
            Text(hint ?? "\(Int((position * 100).rounded()))%")
                .font(.system(size: hint == nil ? 12 : 10, weight: .medium).monospacedDigit())
                .foregroundStyle(hint == nil ? Color.primary : Color.orange)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 28)
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 5).fill(Color.secondary.opacity(0.15))
                RoundedRectangle(cornerRadius: 5)
                    .fill(enabled ? Color.accentColor.opacity(0.75) : Color.secondary.opacity(0.35))
                    .frame(height: h * CGFloat(position))
                if let ghost {
                    Rectangle()
                        .fill(Color.primary.opacity(0.55))
                        .frame(height: 2)
                        .offset(y: -h * CGFloat(ghost) + 1)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard enabled else { return }
                        let p = Float(1 - value.location.y / max(h, 1))
                        onChange(max(0, min(1, p)))
                    }
            )
        }
        .frame(width: 26)
    }
}
