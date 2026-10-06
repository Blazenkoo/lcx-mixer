import SwiftUI

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
    @State private var newIgnore = ""
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
            ignoreSection

            Section("Chrome") {
                HStack {
                    Circle().fill(core.chromeConnected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    SettingLabel(title: core.chromeConnected ? "Extension connected" : "Extension not connected",
                                 description: "In Chrome open chrome://extensions, turn on Developer mode, choose Load unpacked and select the extension folder.")
                    Spacer()
                    Button("Show extension folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder])
                    }
                }
            }
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
            Text("App groups")
        } footer: {
            Text("Apps whose bundle ID starts with one of a group's prefixes share one channel, for example the League client and game. Changes apply to apps that start playing afterwards.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func addGroup() {
        guard canAddGroup else { return }
        settings.groups.append(GroupRule(name: newGroupNameTrimmed,
                                         prefixes: newGroupPrefixes.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
        newGroupName = ""
        newGroupPrefixes = ""
    }

    // MARK: - Ignore list

    private var ignoreSection: some View {
        Section("Ignore list") {
            ForEach(settings.ignoreList, id: \.self) { item in
                HStack {
                    Text(item).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button {
                        settings.ignoreList.removeAll { $0 == item }
                    } label: {
                        Image(systemName: "minus.circle")
                            .frame(width: 20, height: 20)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Stop ignoring \(item)")
                    .accessibilityLabel("Remove \(item) from the ignore list")
                }
            }
            HStack {
                TextField("Add to ignore list", text: $newIgnore, prompt: Text("Bundle ID or website, e.g. zoom.us"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Bundle ID or website to ignore")
                    .onSubmit(addIgnore)
                Button("Add", action: addIgnore)
                    .disabled(newIgnore.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addIgnore() {
        let value = newIgnore.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty && !settings.ignoreList.contains(value) { settings.ignoreList.append(value) }
        newIgnore = ""
    }
}
