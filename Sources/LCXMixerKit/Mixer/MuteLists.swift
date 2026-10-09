import Foundation

/// The always-mute and ignore lists: which entries a source matches, and what a changed list
/// means for the sources already in the mixer. MixerCore carries the changes out.
struct MuteLists {
    var muteList: [String]
    var ignoreList: [String]

    /// What a changed mute list means for one source.
    enum Change: Hashable {
        /// Newly listed: take it off its channel and silence it.
        case silence(String)
        /// No longer listed: give its sound back and find it a channel.
        case release(String)
    }

    /// Keys a list entry can match: the app's group key and bundle IDs, or the tab's website.
    static func keys(of s: Source) -> [String] {
        s.kind == .app ? [String(s.id.dropFirst(4))] + s.bundleIDs : [s.host]
    }

    /// The key written to a list when the user picks "Always ignore" or "Always mute".
    static func primaryKey(of s: Source) -> String {
        s.kind == .app ? String(s.id.dropFirst(4)) : s.host
    }

    /// Whether any of `keys` is on `list`. Empty entries never match.
    static func list(_ list: [String], contains keys: [String]) -> Bool {
        keys.contains { key in list.contains(where: { !$0.isEmpty && $0 == key }) }
    }

    func isMuted(_ s: Source) -> Bool { Self.list(muteList, contains: Self.keys(of: s)) }
    func isIgnored(_ s: Source) -> Bool { Self.list(ignoreList, contains: Self.keys(of: s)) }

    /// Sources whose place on the mute list changed, in the order they're met. Ignored sources
    /// are left out: they leave the mixer instead.
    func changes(in sources: [String: Source], listMuted: [String]) -> [Change] {
        var changes: [Change] = []
        for (id, s) in sources where !isIgnored(s) {
            let listed = isMuted(s)
            let muted = listMuted.contains(id)
            if listed && !muted {
                changes.append(.silence(id))
            } else if !listed && muted {
                changes.append(.release(id))
            }
        }
        return changes
    }

    /// Sources now on the ignore list, which leave the mixer, in the order they're met.
    func ignored(in sources: [String: Source]) -> [String] {
        var ids: [String] = []
        for (id, s) in sources where isIgnored(s) { ids.append(id) }
        return ids
    }
}
