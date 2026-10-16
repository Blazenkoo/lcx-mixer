import SwiftUI

/// Menu-bar dropdown: the Media and Microphone buttons, the channels, then the unassigned list and app actions.
/// With a controller it lists all 8 channels as the faders sit; without one, only occupied channels,
/// each with a volume slider.
struct PanelView: View {
    @ObservedObject var core: MixerCore
    let openMixer: () -> Void
    let openSettings: () -> Void
    var openAbout: () -> Void = {}
    /// Opens Settings at the mute list (from a Muted row's ⋯ menu).
    var openMuteList: (() -> Void)? = nil
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(spacing: 6 * scale) {
                MuteToggles(core: core)
                Spacer()
            }
            Divider()

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

            if core.hardwarePresent {
                VStack(spacing: 2) {
                    ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                        PanelRow(core: core, index: i, withSlider: false)
                    }
                }
            } else {
                PanelChannelList(core: core)
            }

            Divider()
            SourceListsView(core: core, compact: true, openMuteList: openMuteList)
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
        .onHover { core.pointer(inside: $0, area: "panel") }
        .onDisappear { core.pointer(inside: false, area: "panel") }
    }
}

/// Without a controller: only occupied channels, in order, each with a slider. Dropping below the
/// last row puts a source at the end.
private struct PanelChannelList: View {
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargeted = false

    private struct Row: Identifiable {
        let id: String
        let index: Int
    }

    private var rows: [Row] {
        (0..<MixerCore.channelCount).compactMap { ch in
            if core.masterActive && ch == 0 { return Row(id: "master", index: 0) }
            return core.channels[ch].map { Row(id: $0, index: ch) }
        }
    }

    private var freeChannel: Int? {
        (core.firstSourceChannel..<MixerCore.channelCount).first { core.channels[$0] == nil }
    }

    var body: some View {
        VStack(spacing: 2) {
            ForEach(rows) { row in
                PanelRow(core: core, index: row.index, withSlider: true)
            }
            if !rows.contains(where: { $0.id != "master" }) && !dropTargeted {
                Text("Nothing playing")
                    .scaledFont(12)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 26 * scale)
            }
            if dropTargeted && freeChannel != nil {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .frame(height: 26 * scale)
                    .overlay(Text("Add to the end").scaledFont(12).foregroundStyle(.secondary))
                    .accessibilityHidden(true)
            }
        }
        .padding(.bottom, 6 * scale)
        .contentShape(Rectangle())
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first, let ch = freeChannel else { return false }
            core.move(id, to: ch)
            return true
        } isTargeted: { dropTargeted = $0 }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: core.channels)
    }
}

private struct PanelRow: View {
    @ObservedObject var core: MixerCore
    let index: Int
    /// Two lines with a volume slider (without a controller), or one line with a percentage.
    let withSlider: Bool
    @State private var hovering = false
    @State private var isTargeted = false
    @Environment(\.uiScale) private var scale

    private var isMaster: Bool { core.masterActive && index == 0 }
    private var source: Source? { core.source(onChannel: index) }

    var body: some View {
        content
            .padding(.horizontal, 6 * scale)
            .padding(.vertical, withSlider ? 4 * scale : 0)
            .frame(minHeight: 26 * scale)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.accentColor.opacity(0.15)
                          : hovering && source != nil ? Color.secondary.opacity(0.1) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor, lineWidth: isTargeted ? 2 : 0)
            )
            .onHover { hovering = $0 }
            .modifier(ChannelRowMenu(core: core, index: index, source: isMaster ? nil : source))
            .dropDestination(for: String.self) { items, _ in
                guard !isMaster, let id = items.first else { return false }
                core.move(id, to: index)
                return true
            } isTargeted: { isTargeted = $0 }
    }

    @ViewBuilder
    private var content: some View {
        if withSlider {
            VStack(alignment: .leading, spacing: 2 * scale) {
                draggable(topLine)
                sliderLine
            }
        } else {
            draggable(topLine)
        }
    }

    /// Like the window's strips: a row can be dragged onto another channel. Its buttons keep their
    /// own behaviour, and the slider isn't part of the drag.
    @ViewBuilder
    private func draggable<V: View>(_ v: V) -> some View {
        if let s = source, !isMaster {
            v.contentShape(Rectangle())
                .draggable(s.id) { ChannelMenu.dragPreview(s, channel: index, scale: scale) }
                .accessibilityHint(ChannelMenu.dragHint)
        } else {
            v
        }
    }

    @ViewBuilder
    private var topLine: some View {
        let status = core.status(ofChannel: index)
        HStack(spacing: 8 * scale) {
            Text("\(index + 1)")
                .scaledFont(12, weight: .semibold, design: .rounded, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 14 * scale)
            Circle().fill(status.color).frame(width: 8 * scale, height: 8 * scale)

            if isMaster {
                Text("Master").scaledFont(12, weight: .medium)
                Spacer()
                if !withSlider { percent(core.masterVolume) }
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
                        glyph(s.isPlaying && s.canPlayPause ? "pause.fill" : "play.fill", on: false)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!s.canPlayPause)
                    .help("Play / pause")
                    .accessibilityLabel("Play / pause \(s.name)")
                }
                // Solid red while muted, like the Media and Microphone buttons; the same size either way.
                Button { core.toggleMute(s.id) } label: {
                    glyph(s.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", on: s.isMuted)
                }
                .buttonStyle(.borderless)
                .help("Mute")
                .accessibilityLabel("Mute \(s.name)")
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(s.isMuted ? "On" : "Off")
                if !withSlider { percent(core.position(of: s)) }
            } else {
                Text("Free").scaledFont(12).foregroundStyle(.tertiary)
                Spacer()
            }
        }
        .scaledFont(11)
        .frame(height: 22 * scale)
    }

    @ViewBuilder
    private var sliderLine: some View {
        if isMaster {
            VolumeSlider(name: "Master", channel: index + 1, value: core.masterVolume) { core.setMasterFromUI($0) }
        } else if let s = source {
            VolumeSlider(name: s.name, channel: index + 1, value: core.position(of: s)) { core.setVolumeFromUI(s.id, position: $0) }
        }
    }

    /// A row's play or mute symbol in a fixed box; `on` fills it red with a white symbol.
    private func glyph(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .frame(width: 22 * scale, height: 18 * scale)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 4 * scale, style: .continuous)
                .fill(on ? Color.red.opacity(0.85) : Color.clear))
    }

    private func percent(_ value: Float) -> some View {
        Text("\(Int((value * 100).rounded()))%")
            .scaledFont(12, monospacedDigit: true)
            .foregroundStyle(.secondary)
            .frame(width: 38 * scale, alignment: .trailing)
    }
}

/// A channel's volume in the panel: a slider and its percentage, lined up under the name.
private struct VolumeSlider: View {
    let name: String
    let channel: Int
    let value: Float
    let set: (Float) -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        let percent = Int((value * 100).rounded())
        HStack(spacing: 8 * scale) {
            Slider(value: Binding(get: { Double(value) }, set: { set(Float($0)) }), in: 0...1)
                .controlSize(.small)
                .accessibilityLabel("\(name), channel \(channel), volume")
                .accessibilityValue("\(percent)%")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: set(min(1, value + 0.05))
                    case .decrement: set(max(0, value - 0.05))
                    @unknown default: break
                    }
                }
            Text("\(percent)%")
                .scaledFont(12, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .frame(width: 38 * scale, alignment: .trailing)
                .accessibilityHidden(true)
        }
        // Under the name: past the channel number and the status dot.
        .padding(.leading, (14 + 8 + 8 + 8) * scale)
    }
}

/// Right-click on an occupied channel row opens the window's channel menu.
private struct ChannelRowMenu: ViewModifier {
    @ObservedObject var core: MixerCore
    let index: Int
    let source: Source?

    func body(content: Content) -> some View {
        if let s = source {
            content.contextMenu { ChannelMenu.items(core: core, index: index, source: s) }
        } else {
            content
        }
    }
}
