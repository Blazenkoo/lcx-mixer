import SwiftUI

struct MixerWindowView: View {
    @ObservedObject var core: MixerCore
    let openSettings: () -> Void
    /// Opens Settings at the mute list (from a Muted row's ⋯ menu).
    var openMuteList: (() -> Void)? = nil
    @Environment(\.uiScale) private var scale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct Slot: Identifiable {
        let id: String
        let index: Int
    }

    /// Strips are identified by their source, so VoiceOver focus stays on a source when channels close up.
    private var slots: [Slot] {
        (0..<MixerCore.channelCount).map { ch in
            let id = core.masterActive && ch == 0 ? "master" : core.channels[ch] ?? "free-\(ch)"
            return Slot(id: id, index: ch)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack {
                HeaderStatus(core: core)
                Spacer()
                // A real button, like the strips' own, with a quieter symbol so it doesn't compete with them.
                SmallIconButton(symbol: "gearshape", help: "Settings (⌘,)", tint: .secondary, action: openSettings)
                    .accessibilityLabel("Settings")
            }

            HStack(spacing: 8 * scale) {
                ForEach(slots) { slot in
                    ChannelStripView(core: core, index: slot.index)
                }
            }
            // Without a controller, strips slide up when one leaves (in place with Reduce Motion).
            .animation(core.hardwarePresent || reduceMotion ? nil : .easeInOut(duration: 0.25), value: core.channels)
            // The same gap above the channels as below them.
            .padding(.top, 16 * scale)

            SourceListsView(core: core, compact: false, openMuteList: openMuteList)
                .padding(.top, 16 * scale)
        }
        .padding(16 * scale)
        // The content decides the window's size: exactly eight strips wide, as tall as what's inside.
        .frame(width: (8 * ChannelStripView.width + 7 * 8 + 32) * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .onHover { core.pointer(inside: $0, area: "window") }
        .onDisappear { core.pointer(inside: false, area: "window") }
    }
}
