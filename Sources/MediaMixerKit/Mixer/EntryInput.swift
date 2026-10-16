import Foundation

/// What a typed list entry becomes, and whether it can be added: the rules behind Settings' Add
/// sheets and in-place edits, kept apart so they can be tested on their own.
enum EntryInput {
    /// Trims spaces, and turns a pasted web address into its website:
    /// "https://web.whatsapp.com/send" becomes "web.whatsapp.com".
    static func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let host = URL(string: trimmed)?.host, !host.isEmpty {
            return host
        }
        return trimmed
    }

    /// Why `value` (already normalized) can't go on `list`, or nil if it can. An empty value has no
    /// message: the Add button simply stays dimmed.
    static func problem(_ value: String, list: [String], listName: String,
                        other: [String] = [], otherName: String = "") -> String? {
        if value.isEmpty { return nil }
        if value.contains(where: { $0.isWhitespace }) {
            return "No spaces: use a bundle ID such as com.example.app, or a website such as example.com."
        }
        if list.contains(value) { return "It's already on the \(listName)." }
        if other.contains(value) { return "It's on the \(otherName). Select it there and use Move instead." }
        return nil
    }

    /// Bundle ID prefixes typed with commas, without the empty ones.
    static func prefixes(_ raw: String) -> [String] {
        raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Why a new app group can't be added, or nil if it can (or isn't filled in yet).
    static func groupProblem(name: String, prefixes raw: String, existing: [GroupRule]) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty, existing.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(name) == .orderedSame }) {
            return "There's already a group called \(name)."
        }
        if prefixes(raw).contains(where: { $0.contains(where: { $0.isWhitespace }) }) {
            return "No spaces inside a prefix. Separate prefixes with commas."
        }
        return nil
    }
}
