import AppKit
import SwiftUI

// MARK: - Layout shared by the list sections

/// A list section: its title and description, a filter once the list is long, the table (the only
/// part that scrolls), and the labelled buttons under it.
private struct ListPageLayout<TableContent: View, Buttons: View>: View {
    let title: String
    let description: String
    let entryCount: Int
    @Binding var filter: String
    @ViewBuilder let table: TableContent
    @ViewBuilder let buttons: Buttons
    @Environment(\.uiScale) private var scale

    /// A filter appears once a list has more than this many entries.
    static var filterThreshold: Int { 8 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12 * scale) {
            PageHeader(title: title, description: description)
            // Stays while it holds text, so a shortened list is never filtered out of sight.
            if entryCount > Self.filterThreshold || !filter.isEmpty {
                HStack(spacing: 6 * scale) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Filter", text: $filter, prompt: Text("Filter"))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Filter the \(title.lowercased())")
                }
                .frame(maxWidth: 280 * scale)
            }
            table
                .frame(minHeight: 160 * scale, maxHeight: .infinity)
            HStack(spacing: 8 * scale) {
                buttons
                Spacer()
            }
            .labelStyle(.titleAndIcon)
        }
        .padding(20 * scale)
    }
}

// MARK: - Mute list and ignore list

/// The mute list or the ignore list, as a table of entries: bundle IDs and websites.
struct EntryListPage: View {
    enum Kind { case mute, ignore }

    @ObservedObject var settings: AppSettings
    let kind: Kind
    @Environment(\.undoManager) private var undoManager
    @State private var selection = Set<String>()
    @State private var filter = ""
    @State private var adding = false
    @State private var sortOrder: [KeyPathComparator<Entry>] = []

    struct Entry: Identifiable, Hashable {
        let value: String
        var id: String { value }
    }

    private var listKey: ReferenceWritableKeyPath<AppSettings, [String]> { kind == .mute ? \.muteList : \.ignoreList }
    private var otherKey: ReferenceWritableKeyPath<AppSettings, [String]> { kind == .mute ? \.ignoreList : \.muteList }
    private var items: [String] { settings[keyPath: listKey] }
    private var title: String { kind == .mute ? "Mute list" : "Ignore list" }
    private var listName: String { kind == .mute ? "mute list" : "ignore list" }
    private var otherName: String { kind == .mute ? "ignore list" : "mute list" }
    private var moveTitle: String { kind == .mute ? "Move to Ignore list" : "Move to Mute list" }
    private var prompt: String { kind == .mute ? "e.g. slack.com" : "e.g. zoom.us" }
    private var description: String {
        kind == .mute
            ? "Apps and websites that are always silenced and kept off the channels. While one is open, it shows in the mixer's Muted tab."
            : "Apps and websites left completely alone: they play as normal and never appear in the mixer."
    }

    private var rows: [Entry] {
        var list = items.map(Entry.init)
        let f = filter.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty { list = list.filter { $0.value.localizedCaseInsensitiveContains(f) } }
        if !sortOrder.isEmpty { list.sort(using: sortOrder) }
        return list
    }

    var body: some View {
        ListPageLayout(title: title, description: description, entryCount: items.count, filter: $filter) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Bundle ID or website", value: \.value) { entry in
                    EntryCell(value: entry.value, prompt: prompt) { rename(entry.value, to: $0) }
                }
            }
            .onDeleteCommand { remove(selection) }
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Remove") { remove(ids) }
                Button(moveTitle) { move(ids) }
            }
            .overlay {
                if items.isEmpty {
                    Text(kind == .mute
                         ? "Nothing on the mute list. Add an app or website, or choose Always mute from a source's ⋯ menu in the mixer."
                         : "Nothing on the ignore list. Add an app or website, or choose Always ignore from a source's ⋯ menu in the mixer.")
                        .scaledFont(AppText.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        } buttons: {
            Button { adding = true } label: { Label("Add…", systemImage: "plus") }
                .help("Add an app or website to the \(listName)")
            Button { remove(selection) } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection.isEmpty)
                .help("Remove the selected entries")
            Button { move(selection) } label: { Label(moveTitle, systemImage: "arrow.right") }
                .disabled(selection.isEmpty)
                .help("Move the selected entries to the \(otherName)")
        }
        .sheet(isPresented: $adding) {
            AddEntrySheet(
                title: "Add to the \(listName)",
                prompt: prompt,
                problem: { EntryInput.problem($0, list: items, listName: listName,
                                              other: settings[keyPath: otherKey], otherName: otherName) },
                add: add
            )
        }
    }

    // MARK: Changes, each undoable with ⌘Z

    private func change(_ name: String, _ apply: () -> Void) {
        let oldList = settings[keyPath: listKey], oldOther = settings[keyPath: otherKey]
        let listKey = self.listKey, otherKey = self.otherKey
        apply()
        undoManager?.registerUndo(withTarget: settings) { s in
            s[keyPath: listKey] = oldList
            s[keyPath: otherKey] = oldOther
        }
        undoManager?.setActionName(name)
    }

    private func add(_ value: String) {
        change("Add") { settings[keyPath: listKey].append(value) }
        selection = [value]
    }

    private func remove(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        change("Remove") { settings[keyPath: listKey].removeAll { ids.contains($0) } }
        selection = []
    }

    /// The other list gets the entries first, so a source moving to the ignore list is let go of
    /// without taking a channel on the way.
    private func move(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let moving = items.filter { ids.contains($0) }
        change("Move") {
            let other = settings[keyPath: otherKey]
            settings[keyPath: otherKey] = other + moving.filter { !other.contains($0) }
            settings[keyPath: listKey].removeAll { ids.contains($0) }
        }
        selection = []
    }

    /// An edit in place. Returns false (and the cell goes back) if the new value can't be used.
    private func rename(_ old: String, to raw: String) -> Bool {
        let value = EntryInput.normalize(raw)
        guard value != old else { return true }
        let others = items.filter { $0 != old }
        guard !value.isEmpty,
              EntryInput.problem(value, list: others, listName: listName,
                                 other: settings[keyPath: otherKey], otherName: otherName) == nil,
              let index = items.firstIndex(of: old) else {
            NSSound.beep()
            return false
        }
        change("Edit") { settings[keyPath: listKey][index] = value }
        selection = [value]
        return true
    }
}

/// One entry, edited in place: Return saves, Esc goes back.
private struct EntryCell: View {
    let value: String
    let prompt: String
    let commit: (String) -> Bool
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Entry", text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .scaledFont(AppText.body, design: .monospaced)
            .focused($focused)
            .onAppear { draft = value }
            .onChange(of: value) { _, new in draft = new }
            .onSubmit(finish)
            .onChange(of: focused) { _, isFocused in if !isFocused { finish() } }
            .onExitCommand {
                draft = value
                focused = false
            }
            .accessibilityLabel(value)
    }

    private func finish() {
        if draft != value && !commit(draft) { draft = value }
    }
}

// MARK: - App groups

struct GroupsPage: View {
    @ObservedObject var settings: AppSettings
    @Environment(\.undoManager) private var undoManager
    @Environment(\.uiScale) private var scale
    @State private var selection = Set<UUID>()
    @State private var filter = ""
    @State private var adding = false
    @State private var sortOrder: [KeyPathComparator<GroupRule>] = []

    private var rows: [GroupRule] {
        var list = settings.groups
        let f = filter.trimmingCharacters(in: .whitespaces)
        if !f.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(f) || $0.prefixesText.localizedCaseInsensitiveContains(f) }
        }
        if !sortOrder.isEmpty { list.sort(using: sortOrder) }
        return list
    }

    var body: some View {
        ListPageLayout(
            title: "App groups",
            description: "Apps whose bundle ID starts with one of a group's prefixes share one channel, for example the League client and game. Changes apply to apps that start playing afterwards.",
            entryCount: settings.groups.count,
            filter: $filter
        ) {
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { group in
                    TextField("Name", text: field(group.id, \.name), prompt: Text("e.g. League"))
                        .labelsHidden()
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Group name")
                }
                .width(min: 120 * scale, ideal: 160 * scale)
                TableColumn("Bundle ID prefixes", value: \.prefixesText) { group in
                    HStack(spacing: 6 * scale) {
                        TextField("Bundle ID prefixes", text: field(group.id, \.prefixesText), prompt: Text("e.g. com.riotgames."))
                            .labelsHidden()
                            .textFieldStyle(.plain)
                            .scaledFont(AppText.body, design: .monospaced)
                            .accessibilityLabel("Bundle ID prefixes for \(group.name.isEmpty ? "unnamed group" : group.name)")
                        if !group.isComplete {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.warningText)
                                .help(group.name.trimmingCharacters(in: .whitespaces).isEmpty
                                      ? "This group needs a name." : "This group needs at least one prefix.")
                                .accessibilityLabel(group.name.trimmingCharacters(in: .whitespaces).isEmpty
                                                    ? "Needs a name" : "Needs a prefix")
                        }
                    }
                }
            }
            .onDeleteCommand { remove(selection) }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Remove") { remove(ids) }
            }
            .overlay {
                if settings.groups.isEmpty {
                    Text("No app groups. Add one to put an app's helper processes, such as a game and its launcher, on one channel.")
                        .scaledFont(AppText.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                }
            }
        } buttons: {
            Button { adding = true } label: { Label("Add…", systemImage: "plus") }
                .help("Add an app group")
            Button { remove(selection) } label: { Label("Remove", systemImage: "minus") }
                .disabled(selection.isEmpty)
                .help("Remove the selected groups")
        }
        .sheet(isPresented: $adding) {
            AddGroupSheet(existing: settings.groups) { group in
                change("Add") { settings.groups.append(group) }
                selection = [group.id]
            }
        }
    }

    /// A field of one group, edited in place.
    private func field(_ id: UUID, _ key: WritableKeyPath<GroupRule, String>) -> Binding<String> {
        Binding(
            get: { settings.groups.first { $0.id == id }?[keyPath: key] ?? "" },
            set: { value in
                if let i = settings.groups.firstIndex(where: { $0.id == id }) { settings.groups[i][keyPath: key] = value }
            }
        )
    }

    private func change(_ name: String, _ apply: () -> Void) {
        let old = settings.groups
        apply()
        undoManager?.registerUndo(withTarget: settings) { s in s.groups = old }
        undoManager?.setActionName(name)
    }

    private func remove(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        change("Remove") { settings.groups.removeAll { ids.contains($0.id) } }
        selection = []
    }
}

// MARK: - Add sheets

/// Adds one bundle ID or website: Return adds, Esc cancels, and Add stays dimmed until the entry
/// can be used. A pasted web address becomes its website.
private struct AddEntrySheet: View {
    let title: String
    let prompt: String
    let problem: (String) -> String?
    let add: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uiScale) private var scale
    @State private var text = ""
    @FocusState private var focused: Bool

    private var value: String { EntryInput.normalize(text) }
    private var issue: String? { problem(value) }
    private var canAdd: Bool { !value.isEmpty && issue == nil }

    private var note: String {
        if let issue { return issue }
        if !value.isEmpty && value != text.trimmingCharacters(in: .whitespacesAndNewlines) { return "Adds \(value)." }
        return "A bundle ID, such as com.example.app, or a website, such as example.com."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text(title)
                .scaledFont(AppText.headline, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 5 * scale) {
                Text("Bundle ID or website").scaledFont(AppText.callout, weight: .medium)
                TextField("Bundle ID or website", text: $text, prompt: Text(prompt))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(AppText.body, design: .monospaced)
                    .focused($focused)
                    .onSubmit(submit)
                Text(note)
                    .scaledFont(AppText.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20 * scale)
        .frame(width: 420 * scale)
        .onAppear { focused = true }
    }

    private func submit() {
        guard canAdd else { return }
        add(value)
        dismiss()
    }
}

/// Adds an app group: a name and its bundle ID prefixes.
private struct AddGroupSheet: View {
    let existing: [GroupRule]
    let add: (GroupRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.uiScale) private var scale
    @State private var name = ""
    @State private var prefixes = ""
    @FocusState private var focused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }
    private var issue: String? { EntryInput.groupProblem(name: name, prefixes: prefixes, existing: existing) }
    private var canAdd: Bool { !trimmedName.isEmpty && !EntryInput.prefixes(prefixes).isEmpty && issue == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 14 * scale) {
            Text("Add an app group")
                .scaledFont(AppText.headline, weight: .bold)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 5 * scale) {
                Text("Name").scaledFont(AppText.callout, weight: .medium)
                TextField("Name", text: $name, prompt: Text("e.g. League"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(submit)
            }
            VStack(alignment: .leading, spacing: 5 * scale) {
                Text("Bundle ID prefixes").scaledFont(AppText.callout, weight: .medium)
                TextField("Bundle ID prefixes", text: $prefixes, prompt: Text("e.g. com.riotgames."))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .scaledFont(AppText.body, design: .monospaced)
                    .onSubmit(submit)
                Text(issue ?? "Apps whose bundle ID starts with one of these share a channel. Separate prefixes with commas.")
                    .scaledFont(AppText.caption)
                    .foregroundStyle(issue == nil ? Color.secondary : Color.warningText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20 * scale)
        .frame(width: 420 * scale)
        .onAppear { focused = true }
    }

    private func submit() {
        guard canAdd else { return }
        add(GroupRule(name: trimmedName, prefixes: EntryInput.prefixes(prefixes)))
        dismiss()
    }
}
