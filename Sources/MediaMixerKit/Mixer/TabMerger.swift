import Foundation

/// Turns one browser's tab reports into sources. It only works out the new values: MixerCore
/// adds, updates and removes the sources, and sends whatever needs sending.
enum TabMerger {
    /// Tab numbers are only unique within one browser, so the browser is part of the ID.
    static func sourceID(of t: TabReport, from connection: BrowserConnection) -> String {
        "tab:\(connection.key):\(t.tabId)"
    }

    /// The page's volume as gain. Spotify reports its slider position, which the app's curve turns into gain.
    static func reportedGain(_ t: TabReport, gainForPosition: (Float) -> Float) -> Float? {
        t.reportedVolume.map { t.volumeIsPosition ? gainForPosition($0) : $0 }
    }

    /// A tab the mixer doesn't have yet joins when it makes sound, or when it's a paused player
    /// that held a channel before the restart; never when its website is on the ignore list.
    static func joins(_ t: TabReport, held: Bool, ignored: Bool) -> Bool {
        (t.audible || (t.hasMedia && held)) && !ignored
    }

    /// The source for a tab that joins the mixer. MixerCore adds its icon.
    static func newSource(_ t: TabReport, id: String, from connection: BrowserConnection, gain: Float?) -> Source {
        var s = Source(
            id: id, kind: .tab, name: SiteNames.name(forHost: t.host),
            detail: SiteNames.cleanTitle(t.title, host: t.host), icon: nil, rememberKey: t.host,
            isPlaying: t.playing || !t.hasMedia, isAudible: t.audible, isMuted: t.muted,
            volume: t.canVolume ? (gain ?? 1) : 1, canPlayPause: t.hasMedia, canSetVolume: t.canVolume
        )
        s.tabId = t.tabId
        s.windowId = t.windowId
        s.browserConnection = connection.id
        s.browserKey = connection.key
        s.windowBounds = t.windowBounds
        s.canSpeed = t.canSpeed
        s.canSeek = t.canSeek
        s.needsReload = t.needsReload
        if let speed = t.speed { s.speed = speed }
        s.host = t.host
        return s
    }

    /// What the mixer itself did to a tab lately. The page's next reports may not show it yet,
    /// so they mustn't undo it.
    struct Recent {
        var now = Date()
        var volumeSentAt: Date?
        var speedSentAt: Date?
        var muteSentAt: Date?
        /// A remembered volume is waiting until the page can take one.
        var volumePending = false
        /// The mixer holds the tab's mute itself: mute all on a channel, or the mute list.
        var muteHeld = false
    }

    /// An existing source brought up to date, and what else that means.
    struct Update {
        var source: Source
        /// The page changed its own speed (e.g. YouTube's menu): the speed knob must pick it up again.
        var speedChangedInPage = false
        /// The page changed its own volume: the fader must pick it up again.
        var volumeChangedInPage = false
        /// The page can take the waiting remembered volume now.
        var sendPendingVolume = false
    }

    static func update(_ old: Source, with t: TabReport, from connection: BrowserConnection, gain: Float?, recent: Recent) -> Update {
        var s = old
        if s.host != t.host {
            s.icon = nil
            s.rememberKey = t.host
        }
        s.host = t.host
        s.name = SiteNames.name(forHost: t.host)
        s.detail = SiteNames.cleanTitle(t.title, host: t.host)
        s.isAudible = t.audible
        s.isPlaying = t.hasMedia ? t.playing : t.audible
        s.canPlayPause = t.hasMedia
        s.canSetVolume = t.canVolume
        s.needsReload = t.needsReload
        s.windowId = t.windowId
        s.browserConnection = connection.id
        if let bounds = t.windowBounds { s.windowBounds = bounds }
        s.canSpeed = t.canSpeed
        s.canSeek = t.canSeek

        var update = Update(source: s)
        if let speed = t.speed, abs(speed - old.speed) > 0.01, since(recent.speedSentAt, recent.now) > 1.5 {
            update.source.speed = speed
            update.speedChangedInPage = true
        }
        if since(recent.muteSentAt, recent.now) > 1.0 && !recent.muteHeld {
            update.source.isMuted = t.muted
        }
        if t.canVolume, recent.volumePending {
            update.sendPendingVolume = true
        } else if t.canVolume, let v = gain, abs(v - old.volume) > 0.01, since(recent.volumeSentAt, recent.now) > 1.5 {
            update.source.volume = v
            update.volumeChangedInPage = true
        }
        return update
    }

    /// Tabs this browser no longer reports: closed, or no longer playing anything.
    static func closed(in sources: [String: Source], connection: BrowserConnection, seen: Set<String>) -> [String] {
        var ids: [String] = []
        for (id, s) in sources where s.kind == .tab && s.browserConnection == connection.id && !seen.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// Each tab's browser label. Tabs show their browser's name only while tabs from more than
    /// one browser are in the mixer.
    static func browserLabels(for sources: [String: Source]) -> [(id: String, label: String?)] {
        let tabs = sources.values.filter { $0.kind == .tab }
        let several = Set(tabs.map(\.browserKey)).count > 1
        return tabs.map { s -> (id: String, label: String?) in
            let label: String? = several ? (Browsers.info(forBundleID: s.browserKey)?.name ?? "Browser") : nil
            return (s.id, label)
        }
    }

    private static func since(_ date: Date?, _ now: Date) -> TimeInterval {
        now.timeIntervalSince(date ?? .distantPast)
    }
}
