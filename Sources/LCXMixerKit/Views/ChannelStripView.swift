import SwiftUI

struct ChannelStripView: View {
    /// Strip width at Default text size; the mixer window's minimum width is built from it.
    static let width: CGFloat = 136

    @ObservedObject var core: MixerCore
    let index: Int
    @Environment(\.uiScale) private var scale
    @State private var isTargeted = false

    private var source: Source? { core.source(onChannel: index) }
    private var status: ChannelStatus { core.status(ofChannel: index) }
    private var isMaster: Bool { core.masterActive && index == 0 }

    var body: some View {
        draggableStrip
            .dropDestination(for: String.self) { items, _ in
                guard !isMaster, let id = items.first else { return false }
                core.move(id, to: index)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    /// The whole strip can be dragged onto another channel (the volume bar and buttons keep their own behaviour).
    @ViewBuilder
    private var draggableStrip: some View {
        if let s = source, !isMaster {
            strip
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .draggable(s.id) {
                    HStack(spacing: 6) {
                        SourceIcon(source: s, size: 20 * scale)
                        Text("\(index + 1) · \(s.name)").scaledFont(13, weight: .semibold)
                    }
                    .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
                }
                .contextMenu { channelMenu(s) }
                .accessibilityHint("Drag onto another channel, or use Move to channel in the context menu. If that channel is in use, the two swap.")
        } else {
            strip
        }
    }

    /// Right-click menu: the non-mouse way to move a channel (also reachable with VoiceOver).
    @ViewBuilder
    private func channelMenu(_ s: Source) -> some View {
        Menu("Move to channel") {
            ForEach(core.firstSourceChannel..<MixerCore.channelCount, id: \.self) { ch in
                if ch != index {
                    Button(menuLabel(forChannel: ch)) { core.move(s.id, to: ch) }
                }
            }
        }
        Button("Bring \(s.name) to the front") { core.focus(s.id) }
        Divider()
        Button("Unassign") { core.unassign(channel: index) }
        Button("Always mute \(s.name)") { core.alwaysMute(s.id) }
    }

    private func menuLabel(forChannel ch: Int) -> String {
        if let other = core.source(onChannel: ch) {
            return "\(ch + 1) · swap with \(other.name)"
        }
        return "\(ch + 1) · Free"
    }

    private var strip: some View {
        VStack(spacing: 8) {
            Text(isMaster ? "Master" : "\(index + 1)")
                .scaledFont(12, weight: .semibold, design: .rounded)
                .foregroundStyle(.secondary)

            if isMaster {
                masterBody
            } else if let source {
                occupied(source)
            } else {
                empty
            }
        }
        .padding(10 * scale)
        .frame(width: Self.width * scale, height: 430 * scale)
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
    }

    // MARK: Occupied

    @ViewBuilder
    private func occupied(_ s: Source) -> some View {
        VStack(spacing: 4) {
            SourceIcon(source: s, size: 22 * scale)
                .padding(.vertical, 6 * scale)
            Text(s.nameWithBrowser)
                .scaledFont(13, weight: .semibold)
                .lineLimit(1)
            Text(s.detail.isEmpty ? " " : s.detail)
                .scaledFont(AppText.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 26 * scale, alignment: .top)
        }
        // A tap rather than a Button, so a drag that starts here moves the channel instead of being swallowed.
        .contentShape(Rectangle())
        .onTapGesture { core.focus(s.id) }
        .help("Click to bring \(s.name) to the front. Drag the channel to move it.")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { core.focus(s.id) }

        StatusBadge(status: status)
        if s.kind == .tab && s.needsReload {
            // The extension lost this page (usually after an update): a reload brings it back.
            Button { core.reloadTab(s.id) } label: {
                Label("Reload tab", systemImage: "arrow.clockwise")
                    .scaledFont(AppText.status, weight: .medium)
            }
            .buttonStyle(.link)
            .foregroundStyle(Color.warningText)
            .help("Reload this tab to reconnect it. On the controller, hold its play button for 3 seconds.")
        } else if s.kind == .tab && !s.canSetVolume {
            Text("Mute only").scaledFont(AppText.status, weight: .medium).foregroundStyle(Color.errorText)
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
                       tint: s.isMuted ? Color.errorText : nil) {
                core.toggleMute(s.id)
            }
            iconButton("xmark", help: "Unassign from this channel") {
                core.unassign(channel: index)
            }
        }
    }

    private var empty: some View {
        VStack {
            Spacer()
            Text("Free").scaledFont(AppText.callout).foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var masterBody: some View {
        VStack(spacing: 8) {
            Image(systemName: "speaker.wave.3.fill")
                .scaledFont(15)
                .frame(width: 22 * scale, height: 22 * scale)
                .padding(.vertical, 6 * scale)
                .foregroundStyle(Color.accentColor)
            Text("Master").scaledFont(13, weight: .semibold)
            Text(core.outputName).scaledFont(AppText.caption2).foregroundStyle(.secondary).lineLimit(2)
                .multilineTextAlignment(.center).frame(height: 26 * scale, alignment: .top)
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
            Color.clear.frame(height: 22 * scale)
        }
    }

    private func iconButton(_ symbol: String, help: String, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        SmallIconButton(symbol: symbol, help: help, tint: tint ?? Color.primary, action: action)
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
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(spacing: 6 * scale) {
            HStack(spacing: 6 * scale) {
                bar
                if let levels {
                    LevelMeter(levels: levels, id: meterID)
                }
            }
            Text(hint ?? "\(Int((position * 100).rounded()))%")
                .scaledFont(hint == nil ? 12 : AppText.status, weight: .medium, monospacedDigit: true)
                .foregroundStyle(hint == nil ? Color.primary : Color.warningText)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .frame(height: 28 * scale)
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
        .frame(width: 26 * scale)
    }
}
