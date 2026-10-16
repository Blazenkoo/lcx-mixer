import SwiftUI

/// The right-click menu for an occupied channel, shared by the mixer window's strips and the
/// menu-bar panel's rows. It's the non-drag way to move a channel, and works with VoiceOver.
@MainActor
enum ChannelMenu {
    static let dragHint = "Drag onto another channel, or use Move to channel in the context menu. If that channel is in use, the two swap."

    @ViewBuilder
    static func items(core: MixerCore, index: Int, source s: Source) -> some View {
        Menu("Move to channel") {
            ForEach(targets(core: core, from: index), id: \.self) { ch in
                Button(label(core: core, channel: ch)) { core.move(s.id, to: ch) }
            }
        }
        Button("Bring \(s.name) to the front") { core.focus(s.id) }
        Divider()
        Button("Unassign") { core.unassign(channel: index) }
        Button("Always mute \(s.name)") { core.alwaysMute(s.id) }
    }

    /// Channels a source on `index` can be moved to. Without a controller the free channels all
    /// sit at the end, so they're offered once.
    static func targets(core: MixerCore, from index: Int) -> [Int] {
        let all = (core.firstSourceChannel..<MixerCore.channelCount).filter { $0 != index }
        guard !core.hardwarePresent else { return all }
        let occupied = all.filter { core.source(onChannel: $0) != nil }
        let firstFree = all.first { core.source(onChannel: $0) == nil }
        return occupied + (firstFree.map { [$0] } ?? [])
    }

    static func label(core: MixerCore, channel ch: Int) -> String {
        if let other = core.source(onChannel: ch) {
            return "\(ch + 1) · swap with \(other.name)"
        }
        return "\(ch + 1) · Free"
    }

    /// What a drag shows under the pointer.
    static func dragPreview(_ s: Source, channel index: Int, scale: CGFloat) -> some View {
        HStack(spacing: 6) {
            SourceIcon(source: s, size: 20 * scale)
            Text("\(index + 1) · \(s.name)").scaledFont(13, weight: .semibold)
        }
        .padding(.horizontal, 10 * scale).padding(.vertical, 6 * scale)
    }
}
