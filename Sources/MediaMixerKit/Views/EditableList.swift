import AppKit
import SwiftUI

/// A column of an `EditableList`.
struct ListColumn: Identifiable {
    /// The column's place, from 0: its index in each row's values.
    let id: Int
    let title: String
    /// Shown in the field while you edit an empty value.
    let prompt: String
    /// Shown, dimmed, in place of an empty value.
    var placeholder = ""
    var monospaced = false
    /// A fixed width at the standard text size; nil takes the rest of the row.
    var width: CGFloat? = nil
}

/// One row of an `EditableList`.
struct ListRow: Identifiable, Equatable {
    let id: String
    /// One per column.
    let values: [String]
    /// What VoiceOver reads for the row.
    let accessibilityName: String
    /// Shown as a warning sign at the end of the row, with this as its explanation.
    var warning: String? = nil
}

/// Something to do with rows, offered in the right-click menu and to VoiceOver.
struct ListAction {
    let title: String
    let perform: (Set<String>) -> Void
}

/// A Settings list in a rounded box. It's only as tall as its rows and scrolls only once the window
/// can't show them all; with no rows it says so instead.
///
/// It works like a Finder list: click, ⌘-click and ⇧-click select, as do the arrow keys and ⌘A;
/// double-click a value or press Return to edit it in place (Return saves, Esc goes back); Delete
/// removes the selection; clicking a column title sorts by it.
struct EditableList: View {
    let label: String
    let columns: [ListColumn]
    let rows: [ListRow]
    /// Shown in place of the rows when there are none.
    let emptyText: String
    @Binding var selection: Set<String>
    /// Saves an edit. Returns false if the value can't be used; the old value then stays.
    let commit: (_ id: String, _ column: Int, _ value: String) -> Bool
    let remove: (Set<String>) -> Void
    var actions: [ListAction] = []

    @Environment(\.uiScale) private var scale
    @FocusState private var focused: Bool
    @State private var editing: Cell?
    /// Where a ⇧-click selection starts.
    @State private var anchor: String?
    @State private var sort: Sort?
    @State private var scrollTarget: String?

    private struct Cell: Equatable {
        let row: String
        let column: Int
    }

    private struct Sort: Equatable {
        let column: Int
        let ascending: Bool
    }

    private var rowHeight: CGFloat { 28 * scale }
    private var inset: CGFloat { 10 * scale }
    private var spacing: CGFloat { 12 * scale }
    private var corner: CGFloat { 8 * scale }

    /// The rows in the order shown.
    private var shown: [ListRow] {
        guard let sort else { return rows }
        return rows.sorted { a, b in
            let order = a.values[sort.column].localizedStandardCompare(b.values[sort.column])
            return sort.ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    var body: some View {
        let shown = self.shown
        VStack(spacing: 0) {
            if rows.isEmpty {
                Text(emptyText)
                    .scaledFont(AppText.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 18 * scale)
                    .padding(.horizontal, 24 * scale)
            } else {
                header
                Divider()
                CappedHeight(minimum: rowHeight * 3) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { Divider().padding(.leading, inset) }
                                    self.row(row, in: shown)
                                        .id(row.id)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        .onChange(of: scrollTarget) { _, target in
                            guard let target else { return }
                            proxy.scrollTo(target)
                            scrollTarget = nil
                        }
                    }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: corner, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor))
                .allowsHitTesting(false)
        }
        // Keyboard focus: a rounded ring that follows the box (the system one would be square).
        .focusable(!rows.isEmpty)
        .focused($focused)
        .focusEffectDisabled()
        .overlay {
            RoundedRectangle(cornerRadius: corner + 3 * scale, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 2.5)
                .padding(-3 * scale)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .onMoveCommand(perform: move)
        .onDeleteCommand {
            guard editing == nil, !selection.isEmpty else { return }
            remove(selection)
        }
        .onKeyPress(.return) {
            guard editing == nil, selection.count == 1, let id = selection.first else { return .ignored }
            beginEditing(id, column: columns.first?.id ?? 0)
            return .handled
        }
        .onCommand(#selector(NSResponder.selectAll(_:))) {
            guard editing == nil else { return }
            selection = Set(shown.map(\.id))
        }
        // Rows that went away (removed, moved or filtered out) are no longer selected.
        .onChange(of: rows.map(\.id)) { _, ids in
            let kept = selection.intersection(ids)
            if kept != selection { selection = kept }
            if let editing, !ids.contains(editing.row) { self.editing = nil }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: spacing) {
            ForEach(columns) { column in
                Button { cycleSort(column.id) } label: {
                    HStack(spacing: 4 * scale) {
                        Text(column.title)
                        if let sort, sort.column == column.id {
                            Image(systemName: sort.ascending ? "chevron.up" : "chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .scaledFont(AppText.subheadline, weight: .medium)
                .foregroundStyle(.secondary)
                .frame(width: column.width.map { $0 * scale }, alignment: .leading)
                .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                .help("Sort by \(column.title.lowercased())")
                .accessibilityLabel(column.title)
                .accessibilityValue(sortDescription(column.id))
                .accessibilityHint("Sorts the list by this column")
            }
        }
        .padding(.horizontal, inset)
        .padding(.vertical, 5 * scale)
    }

    /// Ascending, then descending, then back to the list's own order.
    private func cycleSort(_ column: Int) {
        if let sort, sort.column == column {
            self.sort = sort.ascending ? Sort(column: column, ascending: false) : nil
        } else {
            sort = Sort(column: column, ascending: true)
        }
    }

    private func sortDescription(_ column: Int) -> String {
        guard let sort, sort.column == column else { return "" }
        return sort.ascending ? "Sorted ascending" : "Sorted descending"
    }

    // MARK: Rows

    private func row(_ row: ListRow, in shown: [ListRow]) -> some View {
        let selected = selection.contains(row.id)
        let editingHere = editing?.row == row.id
        let emphasized = selected && focused
        return HStack(spacing: spacing) {
            ForEach(columns) { column in
                cell(row, column, emphasized: emphasized)
                    .frame(width: column.width.map { $0 * scale }, alignment: .leading)
                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
            }
            if let warning = row.warning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(emphasized ? Color.white : Color.warningText)
                    .help(warning)
            }
        }
        .padding(.horizontal, inset)
        // Every value sits in the middle of its row, whatever its font.
        .frame(maxWidth: .infinity, minHeight: rowHeight, alignment: .leading)
        .background(selected && !editingHere ? selectionColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { click(row.id, in: shown) }
        .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { tap in
            beginEditing(row.id, column: column(at: tap.location.x))
        })
        .contextMenu { menu(for: row.id) }
        .accessibilityElement(children: editingHere ? AccessibilityChildBehavior.contain : .ignore)
        .accessibilityLabel(row.accessibilityName)
        .accessibilityValue(row.warning ?? "")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction {
            selection = [row.id]
            anchor = row.id
        }
        .accessibilityActions {
            ForEach(columns) { column in
                Button(editTitle(column)) { beginEditing(row.id, column: column.id) }
            }
            ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
                Button(action.title) { action.perform(targets(row.id)) }
            }
            Button("Remove") { remove(targets(row.id)) }
        }
    }

    @ViewBuilder
    private func cell(_ row: ListRow, _ column: ListColumn, emphasized: Bool) -> some View {
        let value = row.values[column.id]
        if editing == Cell(row: row.id, column: column.id) {
            InlineEditor(value: value, prompt: column.prompt, monospaced: column.monospaced) { end in
                finishEditing(row.id, column.id, end)
            }
        } else {
            Text(value.isEmpty ? column.placeholder : value)
                .scaledFont(AppText.body, design: column.monospaced ? .monospaced : .default)
                .foregroundStyle(textColor(empty: value.isEmpty, emphasized: emphasized))
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var selectionColor: Color {
        Color(nsColor: focused ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
    }

    private func textColor(empty: Bool, emphasized: Bool) -> Color {
        if emphasized { return empty ? Color.white.opacity(0.75) : Color.white }
        return empty ? Color(nsColor: .placeholderTextColor) : Color.primary
    }

    private func editTitle(_ column: ListColumn) -> String {
        columns.count == 1 ? "Edit" : "Edit \(column.title.lowercased())"
    }

    /// The rows an action on `id` applies to: the selection if `id` is in it, otherwise just `id`.
    private func targets(_ id: String) -> Set<String> {
        selection.contains(id) ? selection : [id]
    }

    @ViewBuilder
    private func menu(for id: String) -> some View {
        let chosen = targets(id)
        if chosen.count == 1 {
            ForEach(columns) { column in
                Button(editTitle(column)) { beginEditing(id, column: column.id) }
            }
            Divider()
        }
        ForEach(Array(actions.enumerated()), id: \.offset) { _, action in
            Button(action.title) { action.perform(chosen) }
        }
        Button("Remove") { remove(chosen) }
    }

    // MARK: Selection

    private func click(_ id: String, in shown: [ListRow]) {
        // A click inside the value being edited belongs to the text field.
        if editing?.row == id { return }
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        } else if flags.contains(.shift), let anchor,
                  let from = shown.firstIndex(where: { $0.id == anchor }),
                  let to = shown.firstIndex(where: { $0.id == id }) {
            selection = Set(shown[min(from, to)...max(from, to)].map(\.id))
        } else {
            selection = [id]
            anchor = id
        }
        focused = true
    }

    private func move(_ direction: MoveCommandDirection) {
        guard editing == nil else { return }
        let ids = shown.map(\.id)
        guard !ids.isEmpty else { return }
        let next: Int
        switch direction {
        case .up: next = max(0, (ids.firstIndex { selection.contains($0) } ?? ids.count) - 1)
        case .down: next = min(ids.count - 1, (ids.lastIndex { selection.contains($0) } ?? -1) + 1)
        default: return
        }
        selection = [ids[next]]
        anchor = ids[next]
        scrollTarget = ids[next]
    }

    /// Which column a point along a row falls in.
    private func column(at x: CGFloat) -> Int {
        var edge = inset
        for column in columns.dropLast() {
            guard let width = column.width else { return column.id }
            edge += width * scale + spacing / 2
            if x < edge { return column.id }
            edge += spacing / 2
        }
        return columns.last?.id ?? 0
    }

    // MARK: Editing

    private func beginEditing(_ id: String, column: Int) {
        let cell = Cell(row: id, column: column)
        guard editing != cell else { return }
        selection = [id]
        anchor = id
        editing = cell
    }

    private func finishEditing(_ id: String, _ column: Int, _ end: InlineEditor.End) {
        guard editing == Cell(row: id, column: column) else { return }
        editing = nil
        let old = rows.first { $0.id == id }?.values[column]
        switch end {
        case .saved(let value), .left(let value):
            if let old, value != old { _ = commit(id, column, value) }
        case .cancelled:
            break
        }
        // Return and Esc hand the keyboard back to the list; clicking elsewhere leaves it there.
        if case .left = end { return }
        focused = true
    }
}

/// The field for editing one value in place.
private struct InlineEditor: View {
    enum End {
        /// Return.
        case saved(String)
        /// Esc.
        case cancelled
        /// Focus moved elsewhere: the edit is kept.
        case left(String)
    }

    let value: String
    let prompt: String
    let monospaced: Bool
    let done: (End) -> Void
    @Environment(\.uiScale) private var scale
    @State private var draft = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $draft, prompt: Text(prompt))
            .labelsHidden()
            .textFieldStyle(.plain)
            .scaledFont(AppText.body, design: monospaced ? .monospaced : .default)
            .focused($focused)
            .padding(.horizontal, 4 * scale)
            .padding(.vertical, 3 * scale)
            .background(RoundedRectangle(cornerRadius: 4 * scale).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 4 * scale).strokeBorder(Color.accentColor, lineWidth: 1.5))
            // The text stays exactly where it was before editing.
            .padding(.horizontal, -4 * scale)
            .onAppear {
                draft = value
                DispatchQueue.main.async { focused = true }
            }
            .onSubmit { finish(.saved(draft)) }
            .onExitCommand { finish(.cancelled) }
            .onChange(of: focused) { was, now in
                if was && !now { finish(.left(draft)) }
            }
    }

    private func finish(_ end: End) {
        guard !finished else { return }
        finished = true
        done(end)
    }
}

/// Shows its content at the content's own height, or at the height offered if that's less (the
/// content then scrolls), but not less than `minimum` while the content is taller than that.
private struct CappedHeight: Layout {
    var minimum: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let natural = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        let offered = proposal.height ?? natural.height
        let height = max(min(natural.height, offered), min(natural.height, minimum))
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? natural.width
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
