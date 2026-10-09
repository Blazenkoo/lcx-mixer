import SwiftUI

/// A Settings section title, optionally with a description right under it.
/// Use this for every section that has a description, so they all look the same.
/// Text aligns to the leading edge, which follows the reading direction: left for left-to-right
/// languages, flipping automatically for right-to-left ones. (Left to the system's defaults,
/// grouped forms on macOS align footers to the trailing edge, which is what put them on the right.)
struct SectionHeader: View {
    let title: String
    let description: String?

    init(_ title: String, description: String? = nil) {
        self.title = title
        self.description = description
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).scaledFont(AppText.headline, weight: .bold)
            if let description {
                Text(description)
                    .scaledFont(AppText.caption)
                    .fontWeight(.regular)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, description == nil ? 0 : 6)
    }
}

/// A setting's title with an optional description underneath, inside the same row (no separator between them).
private struct SettingLabel: View {
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

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var core: MixerCore
    @State private var newGroupName = ""
    @State private var newGroupPrefixes = ""
    @Environment(\.uiScale) private var scale

    var body: some View {
        Form {
            controllerSection

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
            } header: {
                SectionHeader("Volume")
            }

            Section {
                Picker(selection: $settings.textSize) {
                    ForEach(TextSize.allCases) { size in Text(size.label).tag(size) }
                } label: {
                    SettingLabel(title: "Text size",
                                 description: "Scales the mixer window, menu-bar panel, pop-up and Settings. In the mixer window and Settings, ⌘− and ⌘+ step it, and ⌘0 resets it.")
                }
                .pickerStyle(.menu)
                Toggle(isOn: $settings.launchAtLogin) {
                    SettingLabel(title: "Launch at login", description: nil)
                }
                Toggle(isOn: $settings.alwaysInDock) {
                    SettingLabel(title: "Always show in the Dock",
                                 description: "When off, the Dock icon appears only while the mixer window is open.")
                }
                Toggle(isOn: $settings.showOSD) {
                    SettingLabel(title: "Show on-screen pop-up",
                                 description: "A short pop-up when you touch a control or a source gets a channel.")
                }
                Toggle(isOn: $settings.rememberVolumes) {
                    SettingLabel(title: "Remember volume per app and website",
                                 description: "Each website or app plays at the last volume you set for it. Set one YouTube tab to 40%, and every YouTube tab you open later also plays at 40%.")
                }
            } header: {
                SectionHeader("General")
            }

            groupsSection
            muteSection
            ignoreSection

            browsersSection
        }
        .formStyle(.grouped)
        .scaledFont(AppText.body)
        .frame(width: 560 * scale, height: 700)
    }

    // MARK: - Controller

    @State private var midiDevices: [String] = []

    private var controllerSection: some View {
        Section {
            Picker(selection: $settings.controllerKind) {
                ForEach(ControllerKind.allCases) { kind in Text(kind.label).tag(kind) }
            } label: {
                SettingLabel(title: "Controller", description: core.controllerConnected
                             ? "\(core.controllerName) is connected."
                             : "\(core.controllerName) isn't connected.")
            }

            if settings.controllerKind == .midiLearn {
                Picker(selection: $settings.midiDevice) {
                    Text("Choose a device").tag("")
                    ForEach(deviceChoices, id: \.self) { name in Text(name).tag(name) }
                } label: {
                    SettingLabel(title: "MIDI device", description: nil)
                }
                .onAppear { midiDevices = MIDIController.sourceNames() }

                MIDILearnTable(settings: settings, core: core)
            }
        } header: {
            SectionHeader("Controller", description: settings.controllerKind == .midiLearn
                          ? "Click Learn, then move the fader or press the button on your controller. Right-click an assignment to clear it. MIDI learn has no light feedback."
                          : nil)
        }
    }

    /// Available devices, plus the saved one even while it's unplugged.
    private var deviceChoices: [String] {
        var names = midiDevices
        if !settings.midiDevice.isEmpty && !names.contains(settings.midiDevice) { names.append(settings.midiDevice) }
        return names
    }

    // MARK: - App groups

    private var newGroupNameTrimmed: String { newGroupName.trimmingCharacters(in: .whitespaces) }
    private var newGroupHasPrefix: Bool {
        !newGroupPrefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.isEmpty
    }
    private var canAddGroup: Bool { !newGroupNameTrimmed.isEmpty && newGroupHasPrefix }

    /// Shown only when exactly one of the two fields is filled in.
    private var newGroupHint: String? {
        switch (newGroupNameTrimmed.isEmpty, newGroupHasPrefix) {
        case (false, false): return "Add at least one bundle ID prefix."
        case (true, true): return "Add a group name."
        default: return nil
        }
    }

    private var groupsSection: some View {
        Section {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    Text("Group name")
                    Text("Bundle ID prefixes (comma separated)")
                    Color.clear.frame(width: 44 * scale, height: 1)
                }
                .scaledFont(AppText.caption, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach($settings.groups) { $group in
                    GridRow(alignment: .center) {
                        TextField("Group name", text: $group.name, prompt: Text("e.g. League"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140 * scale)
                            .accessibilityLabel("Group name")
                        TextField("Bundle ID prefixes", text: $group.prefixesText, prompt: Text("e.g. com.riotgames."))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .scaledFont(AppText.body, design: .monospaced)
                            .accessibilityLabel("Bundle ID prefixes for \(group.name.isEmpty ? "unnamed group" : group.name)")
                        Button {
                            settings.groups.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 44 * scale)
                        .help("Remove this group")
                        .accessibilityLabel("Remove group \(group.name.isEmpty ? "without a name" : group.name)")
                    }
                    if !group.isComplete {
                        GridRow {
                            Text(group.name.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "This group needs a name."
                                 : "This group needs at least one prefix.")
                                .scaledFont(AppText.caption)
                                .foregroundStyle(Color.warningText)
                                .gridCellColumns(3)
                        }
                    }
                }

                // New group: same pattern as the ignore list. Add stays disabled until both fields are filled.
                GridRow(alignment: .center) {
                    TextField("New group name", text: $newGroupName, prompt: Text("e.g. League"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140 * scale)
                        .accessibilityLabel("New group name")
                        .onSubmit(addGroup)
                    TextField("New group bundle ID prefixes", text: $newGroupPrefixes, prompt: Text("e.g. com.riotgames."))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(AppText.body, design: .monospaced)
                        .accessibilityLabel("Bundle ID prefixes for the new group")
                        .onSubmit(addGroup)
                    Button("Add", action: addGroup)
                        .disabled(!canAddGroup)
                        .frame(width: 44 * scale)
                        .accessibilityLabel("Add group")
                }
                if let hint = newGroupHint {
                    GridRow {
                        Text(hint)
                            .scaledFont(AppText.caption)
                            .foregroundStyle(Color.warningText)
                            .gridCellColumns(3)
                    }
                }
            }
        } header: {
            SectionHeader("App groups", description: "Apps whose bundle ID starts with one of a group's prefixes share one channel, for example the League client and game. Changes apply to apps that start playing afterwards.")
        }
    }

    private func addGroup() {
        guard canAddGroup else { return }
        settings.groups.append(GroupRule(name: newGroupNameTrimmed,
                                         prefixes: newGroupPrefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        newGroupName = ""
        newGroupPrefixes = ""
    }

    // MARK: - Browsers

    private var browsersSection: some View {
        Section {
            let rows = browserRows
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
            HStack {
                SettingLabel(title: "Add the extension to a browser",
                             description: "Open the browser's extensions page, turn on Developer mode, choose Load unpacked and select the extension folder. Works in Chrome, Edge, Brave, Arc, Vivaldi and Chromium.")
                Spacer()
                Button("Show extension folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                }
            }
        } header: {
            SectionHeader("Browsers", description: "Each tab in a connected browser gets its own channel. Until its extension first connects, a browser other than Chrome appears as one whole app.")
        }
    }

    private struct BrowserRow: Identifiable {
        let browser: BrowserInfo
        let connections: Int
        var id: String { browser.bundleID }
    }

    /// Browsers that are open or connected, with how many extension connections each has.
    private var browserRows: [BrowserRow] {
        let running = Set(Browsers.running)
        return Browsers.all.compactMap { browser in
            let count = core.browserConnections.filter { $0.browser == browser }.count
            return (count > 0 || running.contains(browser)) ? BrowserRow(browser: browser, connections: count) : nil
        }
    }

    // MARK: - Mute list and ignore list

    private var muteSection: some View {
        Section {
            KeyListEditor(
                items: $settings.muteList,
                listName: "mute list",
                prompt: "e.g. slack.com",
                moveLabel: "Move to ignore list",
                move: { item in settings.ignoreList.append(item) }
            )
        } header: {
            SectionHeader("Mute list", description: "Always silenced and kept off the channels. They still show under Unassigned Audio Sources, where Unmute takes them off this list.")
        }
    }

    private var ignoreSection: some View {
        Section {
            KeyListEditor(
                items: $settings.ignoreList,
                listName: "ignore list",
                prompt: "e.g. zoom.us",
                moveLabel: "Move to mute list",
                move: { item in settings.muteList.append(item) }
            )
        } header: {
            SectionHeader("Ignore list", description: "Left completely alone: they play as normal and never appear in the mixer.")
        }
    }
}

/// An editable list of bundle IDs or websites, laid out like App groups: one block, no separators.
/// Entries sit in code-font fields, so they can be edited, selected and copied. Each row can be moved
/// to the other list or removed; the last row adds a new entry.
private struct KeyListEditor: View {
    @Environment(\.uiScale) private var scale
    @Binding var items: [String]
    let listName: String
    let prompt: String
    let moveLabel: String
    let move: (String) -> Void
    @State private var newItem = ""

    private var trimmedNew: String { newItem.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                GridRow(alignment: .center) {
                    TextField("Entry", text: binding(at: index), prompt: Text(prompt))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .scaledFont(AppText.body, design: .monospaced)
                        .accessibilityLabel("\(item) on the \(listName)")
                        .onSubmit { tidy() }
                    HStack(spacing: 2) {
                        Menu {
                            Button(moveLabel) { move(item) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                        .help(moveLabel)
                        .accessibilityLabel("More actions for \(item)")
                        Button {
                            items.removeAll { $0 == item }
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .help("Remove from the \(listName)")
                        .accessibilityLabel("Remove \(item) from the \(listName)")
                    }
                    .frame(width: 52 * scale)
                }
            }
            GridRow(alignment: .center) {
                TextField("New entry", text: $newItem, prompt: Text("Bundle ID or website, \(prompt)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(AppText.body, design: .monospaced)
                    .accessibilityLabel("Bundle ID or website to add to the \(listName)")
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmedNew.isEmpty)
                    .frame(width: 52 * scale)
            }
        }
    }

    private func binding(at index: Int) -> Binding<String> {
        Binding(
            get: { items.indices.contains(index) ? items[index] : "" },
            set: { value in if items.indices.contains(index) { items[index] = value } }
        )
    }

    private func add() {
        let value = trimmedNew
        if !value.isEmpty && !items.contains(value) { items.append(value) }
        newItem = ""
    }

    /// After editing: trim spaces, drop empty entries and duplicates.
    private func tidy() {
        var seen = Set<String>()
        let cleaned = items
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        if cleaned != items { items = cleaned }
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
