import SwiftUI

/// Which list shows below the channels.
enum SourceTab: Hashable {
    case unassigned, muted
}

/// The tab you last chose, shared by the mixer window and the menu-bar panel while the app runs.
@MainActor
final class SourceTabState: ObservableObject {
    static let shared = SourceTabState()
    @Published var tab: SourceTab = .unassigned
}

/// Below the channels: the Unassigned and Muted tabs, each with its count, and the chosen list.
/// Both lists use the same row: icon, name, status line, meter, main action and ⋯ menu.
struct SourceListsView: View {
    @ObservedObject var core: MixerCore
    let compact: Bool
    /// Opens Settings at the mute list, from a Muted row's ⋯ menu. Nil leaves that item out.
    var openMuteList: (() -> Void)? = nil
    @ObservedObject private var state = SourceTabState.shared
    @Environment(\.uiScale) private var scale
    /// One row's height, measured, so a long list can stop growing and scroll instead.
    @State private var rowHeight: CGFloat = 0

    /// Rows shown before a list scrolls.
    static let maxRows = 6

    var body: some View {
        let muted = core.listMutedSources
        VStack(alignment: .leading, spacing: (compact ? 6 : 10) * scale) {
            SourceTabsControl(
                tab: $state.tab,
                unassigned: core.unassigned.count,
                muted: muted.count,
                tryingToPlay: muted.filter { core.tryingToPlay.contains($0.id) }.count,
                compact: compact
            )
            // Both lists are laid out, the other one invisibly, without meters and switched off,
            // so the area is as tall as the longer one and switching tabs never resizes the window.
            ZStack(alignment: .topLeading) {
                list(state.tab, live: true)
                list(state.tab == .unassigned ? .muted : .unassigned, live: false)
                    .opacity(0)
                    .disabled(true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .onPreferenceChange(RowHeightKey.self) { rowHeight = $0 }
    }

    // MARK: - Lists

    @ViewBuilder
    private func list(_ tab: SourceTab, live: Bool) -> some View {
        let items = tab == .unassigned ? core.unassigned : core.listMutedSources
        if items.isEmpty {
            Text(tab == .unassigned
                 ? "Nothing waiting."
                 : "Nothing muted right now. Sources you set to Always mute show here while they're open.")
                .scaledFont(AppText.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 4 * scale)
        } else if items.count > Self.maxRows && rowHeight > 0 {
            ScrollView {
                rows(items, tab: tab, live: live)
            }
            .frame(height: (rowHeight + 1) * CGFloat(Self.maxRows))
        } else {
            rows(items, tab: tab, live: live)
        }
    }

    private func rows(_ items: [Source], tab: SourceTab, live: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(items) { s in
                if s.id != items.first?.id { Divider() }
                row(s, tab: tab, live: live)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: RowHeightKey.self, value: g.size.height)
                    })
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func row(_ s: Source, tab: SourceTab, live: Bool) -> some View {
        let muted = tab == .muted
        let trying = muted && core.tryingToPlay.contains(s.id)
        let content = HStack(spacing: 8 * scale) {
            SourceIcon(source: s, size: (compact ? 16 : 22) * scale)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4 * scale) {
                    if compact && trying { amberDot }
                    Text(s.displayName)
                        .scaledFont(12, weight: .medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .accessibilityElement(children: .combine)
                .accessibilityValue(compact && trying ? "Trying to play, muted by your list" : "")
                if !compact {
                    statusLine(s, muted: muted, trying: trying)
                } else if s.permissionNeeded && !muted {
                    Text("Permission needed")
                        .scaledFont(AppText.status, weight: .medium)
                        .foregroundStyle(Color.warningText)
                }
            }
            if !compact {
                Group {
                    if muted || !live {
                        // Nothing is heard from a muted source: an empty bar keeps the rows lined up.
                        Capsule().fill(Color.secondary.opacity(0.15)).frame(height: 4)
                    } else {
                        HorizontalMeter(levels: core.levels, id: s.id)
                    }
                }
                .frame(width: 60 * scale)
                .accessibilityHidden(true)
            }
            Spacer(minLength: 8)
            mainAction(s, muted: muted)
            moreMenu(s, muted: muted)
        }
        .padding(.vertical, (compact ? 3 : 6) * scale)

        if muted || !live {
            content
        } else {
            // Unassigned sources can be dragged onto a channel.
            content.draggable(s.id) {
                HStack { SourceIcon(source: s, size: 20 * scale); Text(s.name) }.padding(6 * scale)
            }
        }
    }

    @ViewBuilder
    private func statusLine(_ s: Source, muted: Bool, trying: Bool) -> some View {
        if trying {
            HStack(spacing: 4 * scale) {
                amberDot
                Text("Trying to play · muted by your list")
            }
            .scaledFont(AppText.status, weight: .medium)
            .foregroundStyle(Color.warningText)
        } else if muted {
            Text(core.muteListEntry(s.id).map { "Muted by your list · \($0)" } ?? "Muted by your list")
                .scaledFont(AppText.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else if s.permissionNeeded {
            Text("Permission needed")
                .scaledFont(AppText.status, weight: .medium)
                .foregroundStyle(Color.warningText)
        } else {
            Text(core.isManuallyUnassigned(s.id) ? "Unassigned by you" : "Waiting for a free channel")
                .scaledFont(AppText.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var amberDot: some View {
        Circle()
            .fill(Color.warningText)
            .frame(width: 6 * scale, height: 6 * scale)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func mainAction(_ s: Source, muted: Bool) -> some View {
        if muted {
            Button("Unmute") { core.removeFromMuteList(s.id) }
                .controlSize(.small)
                .help("Take \(s.name) off the mute list")
        } else if s.permissionNeeded {
            Button("Open Settings") { AudioCapturePermission.openSystemSettings() }
                .controlSize(.small)
        } else {
            Button("Assign") { core.assign(s.id) }
                .controlSize(.small)
                .disabled(!core.hasFreeChannel)
                .help(core.hasFreeChannel ? "Put on the first free channel" : "No free channel")
        }
    }

    private func moreMenu(_ s: Source, muted: Bool) -> some View {
        Menu {
            if muted {
                Button("Unmute") { core.removeFromMuteList(s.id) }
                Button("Always ignore instead") { core.ignoreInstead(s.id) }
                if let openMuteList {
                    Divider()
                    Button("Edit mute list…", action: openMuteList)
                }
            } else {
                Button("Always mute") { core.alwaysMute(s.id) }
                Button("Always ignore") { core.ignore(s.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22 * scale)
        .help("More actions")
        .accessibilityLabel("More actions for \(s.name)")
    }
}

private struct RowHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Tabs

/// Two tabs in a segmented control, each with its count in a rounded tag. It's drawn here because a
/// native segmented control can only show plain text, but to VoiceOver it is one, and with keyboard
/// focus the arrow keys switch tabs.
struct SourceTabsControl: View {
    @Binding var tab: SourceTab
    let unassigned: Int
    let muted: Int
    /// Muted sources trying to play: the Muted tag turns amber.
    let tryingToPlay: Int
    let compact: Bool
    @Environment(\.uiScale) private var scale
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 2 * scale) {
            segment(.unassigned, "Unassigned", count: unassigned, alert: false)
            segment(.muted, "Muted", count: muted, alert: tryingToPlay > 0)
        }
        .padding(2 * scale)
        .background(
            RoundedRectangle(cornerRadius: 7 * scale, style: .continuous)
                .fill(Color.primary.opacity(0.07))
        )
        .fixedSize()
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: tab = .unassigned
            case .right: tab = .muted
            default: break
            }
        }
        .accessibilityRepresentation {
            Picker("Sources", selection: $tab) {
                Text(label("Unassigned", unassigned)).tag(SourceTab.unassigned)
                Text(label("Muted", muted) + (tryingToPlay > 0 ? ", \(tryingToPlay) trying to play" : ""))
                    .tag(SourceTab.muted)
            }
            .pickerStyle(.segmented)
        }
    }

    private func label(_ name: String, _ count: Int) -> String {
        "\(name), \(count) \(count == 1 ? "source" : "sources")"
    }

    private func segment(_ value: SourceTab, _ title: String, count: Int, alert: Bool) -> some View {
        let selected = tab == value
        return HStack(spacing: 6 * scale) {
            Text(title)
                .scaledFont(compact ? AppText.callout : AppText.body, weight: selected ? .semibold : .regular)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Text("\(count)")
                .scaledFont(AppText.status, weight: .semibold, monospacedDigit: true)
                .foregroundStyle(alert ? Color.warningText : Color.primary)
                .padding(.horizontal, 6 * scale)
                .frame(minWidth: 20 * scale, minHeight: 16 * scale)
                .background(Capsule().fill(tagFill(selected: selected, alert: alert)))
        }
        .padding(.horizontal, 10 * scale)
        .padding(.vertical, 3 * scale)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 5 * scale, style: .continuous)
                    .fill(colorScheme == .dark ? Color.white.opacity(0.16) : Color.white)
                    .shadow(color: .black.opacity(colorScheme == .dark ? 0 : 0.15), radius: 1, y: 0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tab = value }
    }

    private func tagFill(selected: Bool, alert: Bool) -> Color {
        if alert { return Color.warningText.opacity(0.2) }
        return selected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.1)
    }
}
