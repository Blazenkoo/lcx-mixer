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
            Text(title)
            if let description {
                Text(description)
                    .font(.caption)
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
                    .font(.caption)
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

    var body: some View {
        Form {
            Section("Controller") {
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
            }

            Section("General") {
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
            }

            groupsSection
            muteSection
            ignoreSection

            browsersSection
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 700)
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
                    Color.clear.frame(width: 44, height: 1)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

                ForEach($settings.groups) { $group in
                    GridRow(alignment: .center) {
                        TextField("Group name", text: $group.name, prompt: Text("e.g. League"))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .accessibilityLabel("Group name")
                        TextField("Bundle ID prefixes", text: $group.prefixesText, prompt: Text("e.g. com.riotgames."))
                            .labelsHidden()
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .accessibilityLabel("Bundle ID prefixes for \(group.name.isEmpty ? "unnamed group" : group.name)")
                        Button {
                            settings.groups.removeAll { $0.id == group.id }
                        } label: {
                            Image(systemName: "minus.circle")
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .frame(width: 44)
                        .help("Remove this group")
                        .accessibilityLabel("Remove group \(group.name.isEmpty ? "without a name" : group.name)")
                    }
                    if !group.isComplete {
                        GridRow {
                            Text(group.name.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? "This group needs a name."
                                 : "This group needs at least one prefix.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                                .gridCellColumns(3)
                        }
                    }
                }

                // New group: same pattern as the ignore list. Add stays disabled until both fields are filled.
                GridRow(alignment: .center) {
                    TextField("New group name", text: $newGroupName, prompt: Text("e.g. League"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityLabel("New group name")
                        .onSubmit(addGroup)
                    TextField("New group bundle ID prefixes", text: $newGroupPrefixes, prompt: Text("e.g. com.riotgames."))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .accessibilityLabel("Bundle ID prefixes for the new group")
                        .onSubmit(addGroup)
                    Button("Add", action: addGroup)
                        .disabled(!canAddGroup)
                        .frame(width: 44)
                        .accessibilityLabel("Add group")
                }
                if let hint = newGroupHint {
                    GridRow {
                        Text(hint)
                            .font(.caption)
                            .foregroundStyle(.orange)
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
                        .font(.system(.body, design: .monospaced))
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
                    .frame(width: 52)
                }
            }
            GridRow(alignment: .center) {
                TextField("New entry", text: $newItem, prompt: Text("Bundle ID or website, \(prompt)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .accessibilityLabel("Bundle ID or website to add to the \(listName)")
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(trimmedNew.isEmpty)
                    .frame(width: 52)
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
