import SwiftUI

struct MixerWindowView: View {
    @ObservedObject var core: MixerCore
    let openSettings: () -> Void
    /// Opens Settings at the mute list (from a Muted row's ⋯ menu).
    var openMuteList: (() -> Void)? = nil
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            HStack {
                HeaderStatus(core: core)
                Spacer()
                Text("Output: \(core.outputName)").scaledFont(AppText.caption).foregroundStyle(.secondary)
                // A real button, like the strips' own, with a quieter symbol so it doesn't compete with them.
                SmallIconButton(symbol: "gearshape", help: "Settings (⌘,)", tint: .secondary, action: openSettings)
                    .accessibilityLabel("Settings")
            }

            HStack(spacing: 8 * scale) {
                ForEach(0..<MixerCore.channelCount, id: \.self) { i in
                    ChannelStripView(core: core, index: i)
                }
            }
            // The same gap above the channels as below them.
            .padding(.top, 16 * scale)

            SourceListsView(core: core, compact: false, openMuteList: openMuteList)
                .padding(.top, 16 * scale)
        }
        .padding(16 * scale)
        // The content decides the window's size: exactly eight strips wide, as tall as what's inside.
        .frame(width: (8 * ChannelStripView.width + 7 * 8 + 32) * scale, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }
}
