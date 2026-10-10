import SwiftUI

// MARK: - Sections

/// The sections of Settings, in sidebar order: Mixer, then Sources, then About.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, controller, browsers, groups, muteList, ignoreList, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .controller: return "Controller"
        case .browsers: return "Browsers"
        case .groups: return "App groups"
        case .muteList: return "Mute list"
        case .ignoreList: return "Ignore list"
        case .about: return "About"
        }
    }

    static let mixer: [SettingsSection] = [.general, .controller, .browsers]
    static let sources: [SettingsSection] = [.groups, .muteList, .ignoreList]
}

/// The section Settings shows, remembered across launches.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()
    private static let key = "settingsSection"

    @Published var section: SettingsSection {
        didSet { UserDefaults.standard.set(section.rawValue, forKey: Self.key) }
    }

    private init() {
        section = UserDefaults.standard.string(forKey: Self.key).flatMap(SettingsSection.init(rawValue:)) ?? .general
    }
}

// MARK: - Window content

/// Settings: a sidebar of sections on the left, the chosen section on the right.
struct SettingsView: View {
    /// The window can't be made smaller than this, times the text size.
    static let minimumSize = CGSize(width: 680, height: 460)

    @ObservedObject var settings: AppSettings
    @ObservedObject var core: MixerCore
    var openAbout: () -> Void = {}
    var openSetup: () -> Void = {}
    @ObservedObject private var nav = SettingsNavigation.shared
    @Environment(\.uiScale) private var scale

    var body: some View {
        // A plain sidebar and content side by side. (A NavigationSplitView in this AppKit-hosted
        // window stopped drawing when the section changed.)
        HStack(spacing: 0) {
            sidebar
                // Wide enough for every name with its status beside it, at every text size.
                .frame(width: 220 * scale)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(nav.section)
        }
        .frame(minWidth: Self.minimumSize.width * scale, minHeight: Self.minimumSize.height * scale)
        .scaledFont(AppText.body)
    }

    // MARK: Sidebar

    /// The list reports a new selection while it updates itself, so the section changes just
    /// after, never in the middle of drawing.
    private var selection: Binding<SettingsSection?> {
        Binding(
            get: { nav.section },
            set: { new in
                guard let new, new != nav.section else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { SettingsNavigation.shared.section = new } }
            }
        )
    }

    /// Three groups that always stay open, with a thin line between them: Mixer, Sources, and
    /// About on its own.
    private var sidebar: some View {
        List(selection: selection) {
            Section {
                ForEach(SettingsSection.mixer) { sidebarRow($0) }
            } header: {
                Text("Mixer")
            }
            .collapsible(false)
            Section {
                ForEach(SettingsSection.sources) { sidebarRow($0) }
            } header: {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    sidebarSeparator
                    Text("Sources")
                }
            }
            .collapsible(false)
            Section {
                sidebarRow(.about)
            } header: {
                sidebarSeparator
            }
            .collapsible(false)
        }
        .listStyle(.sidebar)
    }

    /// A thin horizontal line. (In the stack, since a header on its own lays a divider out
    /// vertically.)
    private var sidebarSeparator: some View {
        VStack(spacing: 0) {
            Divider()
        }
        .padding(.top, 4 * scale)
        .accessibilityHidden(true)
    }

    /// A section's name, with its status on the right where one is worth seeing at a glance.
    private func sidebarRow(_ section: SettingsSection) -> some View {
        let status = self.status(of: section)
        let selected = nav.section == section
        return HStack(spacing: 8 * scale) {
            Text(section.title)
            Spacer(minLength: 8 * scale)
            if let status {
                Text(status.text)
                    .scaledFont(AppText.caption, monospacedDigit: true)
                    .foregroundStyle(status.alert && !selected ? Color.errorText : Color.secondary)
            }
        }
        .tag(section)
        .accessibilityElement(children: .combine)
    }

    private struct SidebarStatus {
        let text: String
        var alert = false
    }

    private func status(of section: SettingsSection) -> SidebarStatus? {
        switch section {
        case .controller:
            return core.controllerConnected ? nil : SidebarStatus(text: "Not connected", alert: true)
        case .browsers:
            let rows = BrowsersPage.rows(core: core)
            guard !rows.isEmpty else { return nil }
            return SidebarStatus(text: "\(rows.filter { $0.connections > 0 }.count) of \(rows.count)")
        case .groups:
            return SidebarStatus(text: "\(settings.groups.count)")
        case .muteList:
            return SidebarStatus(text: "\(settings.muteList.count)")
        case .ignoreList:
            return SidebarStatus(text: "\(settings.ignoreList.count)")
        case .general, .about:
            return nil
        }
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch nav.section {
        case .general: GeneralPage(settings: settings, core: core)
        case .controller: ControllerPage(settings: settings, core: core)
        case .browsers: BrowsersPage(core: core)
        case .groups: GroupsPage(settings: settings)
        case .muteList: EntryListPage(settings: settings, kind: .mute)
        case .ignoreList: EntryListPage(settings: settings, kind: .ignore)
        case .about: AboutPage(core: core, openAbout: openAbout, openSetup: openSetup)
        }
    }
}

// MARK: - Shared pieces

/// The title at the top of each section, read by VoiceOver as a heading, with an optional description.
struct PageHeader: View {
    let title: String
    var description: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .scaledFont(AppText.headline + 5, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            if let description {
                Text(description)
                    .scaledFont(AppText.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A group's title inside a section, such as Volume in General.
private struct GroupTitle: View {
    let title: String
    @Environment(\.uiScale) private var scale

    var body: some View {
        Text(title)
            .scaledFont(AppText.headline, weight: .semibold)
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .padding(.top, 6 * scale)
    }
}

/// A setting's title with an optional description underneath, inside the same row.
struct SettingLabel: View {
    let title: String
    let description: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let description {
                Text(description)
                    .scaledFont(AppText.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Forms keep a comfortable reading width however wide the window is.
private extension View {
    func readingWidth(_ scale: CGFloat) -> some View {
        frame(maxWidth: 640 * scale, alignment: .leading)
    }
}

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $settings.masterMode) {
                    SettingLabel(
                        title: "Use fader 1 as master volume",
                        description: core.masterSupported
                            ? nil
                            : "\(core.outputName) sets its volume in hardware, so macOS can't control it. This turns on automatically when you switch to an output that supports it."
                    )
                }
                .disabled(!core.masterSupported)

                Picker(selection: $settings.naturalCurve) {
                    Text("Natural (gentle at the low end)").tag(true)
                    Text("Linear").tag(false)
                } label: {
                    SettingLabel(title: "Volume curve", description: nil)
                }

                HStack(alignment: .center, spacing: 16) {
                    SettingLabel(title: "How loud it sounds",
                                 description: "Fader position across, loudness up. A straight line means every bit of fader travel changes the sound by the same amount.")
                    Spacer()
                    VolumeCurveGraph(natural: settings.naturalCurve)
                }

                Toggle(isOn: $settings.rememberVolumes) {
                    SettingLabel(title: "Remember volume per app and website",
                                 description: "Each website or app plays at the last volume you set for it. Set one YouTube tab to 40%, and every YouTube tab you open later also plays at 40%.")
                }
            } header: {
                VStack(alignment: .leading, spacing: 10 * scale) {
                    PageHeader(title: "General")
                    GroupTitle(title: "Volume")
                }
            }

            Section {
                Picker(selection: $settings.textSize) {
                    ForEach(TextSize.allCases) { size in Text(size.label).tag(size) }
                } label: {
                    SettingLabel(title: "Text size",
                                 description: "Scales the mixer window, menu-bar panel, pop-up and Settings. In the mixer window and Settings, ⌘− and ⌘+ step it, and ⌘0 resets it.")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $settings.showOSD) {
                    SettingLabel(title: "Show on-screen pop-up",
                                 description: "A short pop-up when you touch a control, a source gets a channel, or a muted source tries to play.")
                }
                Toggle(isOn: $settings.alwaysInDock) {
                    SettingLabel(title: "Always show in the Dock",
                                 description: "When off, the Dock icon appears only while the mixer window is open.")
                }
                Toggle(isOn: $settings.launchAtLogin) {
                    SettingLabel(title: "Launch at login", description: nil)
                }
            } header: {
                GroupTitle(title: "Window and startup")
            }
        }
        .formStyle(.grouped)
        .readingWidth(scale)
    }
}

// MARK: - Controller

private struct ControllerPage: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale
    @State private var midiDevices: [String] = []

    private var description: String? {
        switch settings.controllerKind {
        case .launchControlXL:
            return nil
        case .mackieControl:
            return "For surfaces in Mackie Control mode, such as the Behringer X-Touch. Faders set volume and motorised ones follow it; Select plays and pauses, Mute mutes (hold to unassign); F1 mutes all media, F2 the microphone. Experimental: not yet tested on hardware."
        case .midiLearn:
            return "Click Learn, then move the fader or press the button on your controller. Right-click an assignment to clear it. MIDI learn has no light feedback."
        }
    }

    /// Available devices, plus the saved one even while it's unplugged.
    private var deviceChoices: [String] {
        var names = midiDevices
        if !settings.midiDevice.isEmpty && !names.contains(settings.midiDevice) { names.append(settings.midiDevice) }
        return names
    }

    var body: some View {
        Form {
            Section {
                Picker(selection: $settings.controllerKind) {
                    ForEach(ControllerKind.allCases) { kind in Text(kind.label).tag(kind) }
                } label: {
                    SettingLabel(title: "Controller", description: core.controllerConnected
                                 ? "\(core.controllerName) is connected."
                                 : "\(core.controllerName) isn't connected.")
                }

                if settings.controllerKind != .launchControlXL {
                    Picker(selection: $settings.midiDevice) {
                        Text(settings.controllerKind == .mackieControl ? "Find automatically" : "Choose a device").tag("")
                        ForEach(deviceChoices, id: \.self) { name in Text(name).tag(name) }
                    } label: {
                        SettingLabel(title: "MIDI device", description: nil)
                    }
                    .onAppear { midiDevices = MIDIController.sourceNames() }
                }
            } header: {
                PageHeader(title: "Controller", description: description)
            }

            if settings.controllerKind == .midiLearn {
                Section {
                    MIDILearnTable(settings: settings, core: core)
                } header: {
                    GroupTitle(title: "Assignments")
                }
            }
        }
        .formStyle(.grouped)
        .readingWidth(scale)
    }
}

// MARK: - Browsers

struct BrowsersPage: View {
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale

    struct Row: Identifiable {
        let browser: BrowserInfo
        let connections: Int
        var id: String { browser.bundleID }
    }

    /// Browsers that are open or connected, with how many extension connections each has.
    @MainActor
    static func rows(core: MixerCore) -> [Row] {
        let running = Set(Browsers.running)
        return Browsers.all.compactMap { browser in
            let count = core.browserConnections.filter { $0.browser == browser }.count
            return (count > 0 || running.contains(browser)) ? Row(browser: browser, connections: count) : nil
        }
    }

    var body: some View {
        Form {
            Section {
                let rows = Self.rows(core: core)
                if rows.isEmpty {
                    Text("No supported browser is open.").foregroundStyle(.secondary)
                }
                ForEach(rows) { row in
                    HStack {
                        Circle().fill(row.connections > 0 ? Color.green : Color.secondary).frame(width: 7, height: 7)
                            .accessibilityHidden(true)
                        Text(row.browser.name)
                        Spacer()
                        Text(row.connections == 0 ? "Extension not connected"
                             : row.connections == 1 ? "Connected" : "Connected (\(row.connections) profiles)")
                            .foregroundStyle(row.connections > 0 ? Color.primary : Color.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                PageHeader(title: "Browsers", description: "Each tab in a connected browser gets its own channel. Until its extension first connects, a browser other than Chrome appears as one whole app.")
            }
            Section {
                HStack {
                    SettingLabel(title: "Add the extension to a browser",
                                 description: "Open the browser's extensions page, turn on Developer mode, choose Load unpacked and select the extension folder. Works in Chrome, Edge, Brave, Arc, Vivaldi and Chromium.")
                    Spacer()
                    Button("Show extension folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                    }
                }
            }
        }
        .formStyle(.grouped)
        .readingWidth(scale)
    }
}

// MARK: - About

private struct AboutPage: View {
    @ObservedObject var core: MixerCore
    let openAbout: () -> Void
    let openSetup: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: 18 * scale) {
            PageHeader(title: "About")
            SettingsCredits(core: core, openAbout: openAbout)
            Button("Show the setup steps", action: openSetup)
                .buttonStyle(.link)
            Spacer()
        }
        .padding(24 * scale)
        .readingWidth(scale)
    }
}

/// "How loud it sounds" for both volume curves: fader position across, perceived loudness up.
/// Perceived loudness roughly doubles every 10 dB, so it grows with gain^0.6. Natural (gain = position²)
/// therefore comes out close to a straight line; Linear changes quickly near the bottom and slowly near the top.
/// Plotting raw gain instead would make Natural look like the extreme curve, the opposite of how it feels.
struct VolumeCurveGraph: View {
    let natural: Bool
    @Environment(\.uiScale) private var scale

    private static let naturalExponent = 2 * 0.6
    private static let linearExponent = 1 * 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Canvas { ctx, size in
                let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
                var axes = Path()
                axes.move(to: CGPoint(x: r.minX, y: r.minY))
                axes.addLine(to: CGPoint(x: r.minX, y: r.maxY))
                axes.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
                ctx.stroke(axes, with: .color(.secondary.opacity(0.5)), lineWidth: 1)

                func curve(_ exponent: Double) -> Path {
                    var p = Path()
                    for i in 0...48 {
                        let x = Double(i) / 48
                        let point = CGPoint(x: r.minX + x * r.width, y: r.maxY - pow(x, exponent) * r.height)
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                    return p
                }
                let selected = natural ? Self.naturalExponent : Self.linearExponent
                let other = natural ? Self.linearExponent : Self.naturalExponent
                ctx.stroke(curve(other), with: .color(.secondary.opacity(0.55)), style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                ctx.stroke(curve(selected), with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            }
            .frame(width: 150 * scale, height: 76 * scale)

            HStack(spacing: 12) {
                legend("Natural", selected: natural)
                legend("Linear", selected: !natural)
            }
            .scaledFont(AppText.caption2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(natural
            ? "Graph: with the Natural curve, loudness rises evenly along the whole fader."
            : "Graph: with the Linear curve, loudness changes quickly near the bottom of the fader and slowly in the top half.")
    }

    private func legend(_ name: String, selected: Bool) -> some View {
        HStack(spacing: 4) {
            Capsule()
                .fill(selected ? Color.accentColor : Color.secondary.opacity(0.55))
                .frame(width: 12, height: selected ? 2.5 : 1.5)
            Text(name).foregroundStyle(selected ? Color.primary : Color.secondary)
        }
    }
}

/// MIDI learn assignments: volume, play/pause and mute for each channel, then mute-all and microphone.
private struct MIDILearnTable: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var core: MixerCore
    @Environment(\.uiScale) private var scale
    @State private var confirmingClearAll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            table
            Divider()
            // Kept apart from the assignment buttons: it removes every assignment at once.
            // Confirmation happens right here in the row, in the app's own legible styles,
            // rather than in a system dialog.
            HStack(spacing: 8 * scale) {
                if confirmingClearAll {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningText)
                        .accessibilityHidden(true)
                    Text("Clear all \(settings.midiBindings.count) assignments? Each control will need to be learned again.")
                        .scaledFont(AppText.status, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Cancel") { confirmingClearAll = false }
                        .keyboardShortcut(.cancelAction)
                    Button {
                        core.clearAllBindings()
                        confirmingClearAll = false
                    } label: {
                        Label {
                            Text("Clear all")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(Color.errorText)
                        }
                    }
                } else {
                    Text(settings.midiBindings.isEmpty
                         ? "No assignments yet."
                         : "\(settings.midiBindings.count) of \(MIDILearnDriver.allTargets.count) controls assigned.")
                        .scaledFont(AppText.status)
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Plain, fully legible text; the red bin icon marks it as destructive.
                    Button { confirmingClearAll = true } label: {
                        Label {
                            Text("Clear all assignments…")
                        } icon: {
                            Image(systemName: "trash").foregroundStyle(Color.errorText)
                        }
                    }
                    .disabled(settings.midiBindings.isEmpty)
                    .help("Remove every MIDI learn assignment")
                }
            }
            .controlSize(.regular)
        }
    }

    private var table: some View {
        Grid(alignment: .leading, horizontalSpacing: 10 * scale, verticalSpacing: 6 * scale) {
            GridRow {
                Text("Channel")
                Text("Volume")
                Text("Play/pause")
                Text("Mute")
            }
            .scaledFont(AppText.caption, weight: .semibold)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)

            ForEach(0..<MixerCore.channelCount, id: \.self) { ch in
                GridRow {
                    Text("\(ch + 1)").monospacedDigit()
                    learnButton(.fader(ch))
                    learnButton(.playPause(ch))
                    learnButton(.mute(ch))
                }
            }
            GridRow {
                Text("Mute all media").gridCellColumns(2)
                learnButton(.muteAll).gridCellColumns(2)
            }
            GridRow {
                Text("Microphone mute").gridCellColumns(2)
                learnButton(.microphone).gridCellColumns(2)
            }
        }
    }

    private func learnButton(_ target: LearnTarget) -> some View {
        let binding = settings.midiBindings[target.key]
        let waiting = core.learning == target
        return Button {
            if waiting { core.cancelLearning() } else { core.startLearning(target) }
        } label: {
            Text(waiting ? "Move a control…" : (binding?.summary ?? "Learn"))
                .scaledFont(AppText.caption, design: binding == nil || waiting ? .default : .monospaced)
                .lineLimit(1)
                .frame(minWidth: 96 * scale)
        }
        .buttonStyle(.bordered)
        .tint(waiting ? Color.accentColor : nil)
        .contextMenu {
            if binding != nil { Button("Clear") { core.clearBinding(target) } }
        }
        .help(waiting ? "Cancel learning" : "Assign \(target.label)")
        .accessibilityLabel(waiting ? "\(target.label): waiting for a control. Activate to cancel."
                            : "\(target.label): \(binding?.summary ?? "not assigned"). Activate to learn.")
    }
}
