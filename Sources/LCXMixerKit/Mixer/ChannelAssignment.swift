import Foundation

/// Which source sits on which channel, which sources wait for one, and which are off the
/// channels on purpose. Plain bookkeeping: MixerCore carries out what each change means
/// (pop-ups, volumes, lights, saving the layout).
struct ChannelAssignment: Equatable {
    /// A channel's source as saved between launches: its ID and, for tabs, its website.
    struct SavedSlot: Codable, Equatable {
        var id: String
        var host: String
    }

    private(set) var channels: [String?]
    /// Sources waiting for a free channel, first come, first served.
    private(set) var waiting: [String] = []
    /// Sources unassigned by hand. They stay off the channels until you assign them again.
    private(set) var manual: [String] = []
    /// Sources silenced by the mute list: shown under Unassigned, never on a channel.
    private(set) var listMuted: [String] = []
    /// After a restart, channels held for the source that sat there before, until it returns or
    /// the holding ends.
    private(set) var held: [Int: SavedSlot] = [:]

    init(channels count: Int) {
        channels = Array(repeating: nil, count: count)
    }

    func channel(of id: String) -> Int? { channels.firstIndex(of: id) }

    // MARK: - Finding a channel

    /// The first empty channel from `first` on (channel 1 is master volume in master mode).
    /// Automatic placement skips channels held for a returning source; your own actions
    /// (Assign, drag) may use them.
    func firstFreeChannel(from first: Int, includingHeld: Bool = false) -> Int? {
        (first..<channels.count).first { channels[$0] == nil && (includingHeld || held[$0] == nil) }
    }

    /// The source that should fill channel `ch` now: the first one waiting, unless the channel
    /// isn't empty, is master, or is held.
    func nextToFill(_ ch: Int, from first: Int) -> String? {
        guard ch >= first, channels[ch] == nil, held[ch] == nil else { return nil }
        return waiting.first
    }

    // MARK: - Changes

    /// Puts a source on a channel; it leaves the waiting and unassigned lists.
    mutating func place(_ id: String, on ch: Int) {
        set(ch, id)
        waiting.removeAll { $0 == id }
        manual.removeAll { $0 == id }
    }

    /// Empties a channel and returns who was on it.
    @discardableResult
    mutating func clear(_ ch: Int) -> String? {
        let id = channels[ch]
        set(ch, nil)
        return id
    }

    /// Swaps two channels' sources (either may be empty).
    mutating func swap(_ a: Int, _ b: Int) {
        let onA = channels[a]
        set(a, channels[b])
        set(b, onA)
    }

    /// Joins the waiting list: at the end, or at the front when it just lost its channel.
    mutating func addWaiting(_ id: String, first: Bool = false) {
        if first { waiting.insert(id, at: 0) } else { waiting.append(id) }
    }

    mutating func addManual(_ id: String) { manual.append(id) }
    mutating func removeManual(_ id: String) { manual.removeAll { $0 == id } }
    mutating func addListMuted(_ id: String) { listMuted.append(id) }
    mutating func removeListMuted(_ id: String) { listMuted.removeAll { $0 == id } }

    /// Takes a source off every list. Its channel, if any, is cleared separately.
    mutating func forget(_ id: String) {
        waiting.removeAll { $0 == id }
        manual.removeAll { $0 == id }
        listMuted.removeAll { $0 == id }
    }

    private mutating func set(_ ch: Int, _ id: String?) {
        channels[ch] = id
        // A channel that gets any source is no longer held for the one that sat there before the restart.
        if !held.isEmpty { held = held.filter { channels[$0.key] == nil } }
    }

    // MARK: - Across restarts

    /// Holds each channel saved before the restart for its source.
    mutating func hold(_ slots: [SavedSlot?]) {
        for (ch, slot) in slots.enumerated() where ch < channels.count {
            if let slot { held[ch] = slot }
        }
    }

    /// Whether a channel is held for this source. A tab must also be on the same website, so a
    /// reused tab number can't take another site's channel.
    func isHeld(_ id: String, host: String) -> Bool {
        held.values.contains { $0.id == id && (id.hasPrefix("app:") || $0.host == host) }
    }

    /// The empty channel held for this source, if any.
    func heldChannel(for s: Source, from first: Int) -> Int? {
        held.first { entry in
            entry.value.id == s.id && (s.kind == .app || entry.value.host == s.host)
                && entry.key >= first && channels[entry.key] == nil
        }?.key
    }

    /// Sources that didn't come back in time give up their channels.
    mutating func endHolding() { held.removeAll() }

    /// The layout to save: each channel's source and, for tabs, its website. A channel still
    /// held stays saved as it was.
    func layout(_ sources: [String: Source]) -> [SavedSlot?] {
        (0..<channels.count).map { ch -> SavedSlot? in
            if let id = channels[ch], let s = sources[id] {
                return SavedSlot(id: id, host: s.kind == .tab ? s.host : "")
            }
            return held[ch]
        }
    }
}
