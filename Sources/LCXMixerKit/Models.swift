import AppKit
import CoreAudio

enum SourceKind: Equatable { case app, tab }

struct Source: Identifiable, Equatable {
    let id: String          // "app:<groupKey>" or "tab:<browser bundle ID>:<tabId>"
    let kind: SourceKind
    var name: String
    var detail: String
    var icon: NSImage?
    var rememberKey: String // group key for apps, host for tabs
    var isPlaying: Bool     // tabs: player playing; apps: producing sound
    var isAudible: Bool
    var isMuted: Bool
    var volume: Float       // gain 0…1
    var canPlayPause: Bool
    var canSetVolume: Bool
    var permissionNeeded = false
    /// Browser tabs: the page lost its connection to the extension and needs a reload.
    var needsReload = false
    var speed: Float = 1
    var canSpeed = false
    var canSeek = false
    var firstSeen = Date()

    // Native apps
    var processObjects: [AudioObjectID] = []
    var pids: [pid_t] = []
    var bundleIDs: [String] = []

    // Browser tabs
    var tabId: Int?
    var windowId: Int?
    /// The extension connection the tab was last reported on (commands go back through it).
    var browserConnection: Int32?
    /// The browser's bundle ID, e.g. "com.brave.Browser".
    var browserKey: String = ""
    /// "Brave", shown only while tabs from more than one browser are in the mixer.
    var browserLabel: String?
    var host: String = ""
    /// Chrome window frame in screen points, top-left origin (as Chrome reports it).
    var windowBounds: CGRect?

    var isTwitch: Bool { host.hasSuffix("twitch.tv") }

    /// The site name, plus the browser when several are in use ("YouTube · Brave").
    var nameWithBrowser: String {
        guard kind == .tab, let browserLabel else { return name }
        return "\(name) · \(browserLabel)"
    }

    /// "YouTube – Video title" for tabs; just the app name for native apps.
    var displayName: String {
        guard kind == .tab, !detail.isEmpty, detail != name else { return nameWithBrowser }
        return "\(nameWithBrowser) – \(detail)"
    }
}

extension Source {
    /// Playing or paused, leaving mute aside. Native apps have no play/pause: they're just "on".
    var unmutedStatus: ChannelStatus {
        if kind == .app { return .appActive }
        if canPlayPause { return isPlaying ? .playing : .paused }
        return isAudible ? .playing : .paused
    }
}

enum ChannelStatus: Equatable {
    case empty, master, playing, paused, appActive, muted

    var label: String {
        switch self {
        case .empty: return "Free"
        case .master: return "Master"
        case .playing: return "Playing"
        case .paused: return "Paused"
        case .appActive: return "On"
        case .muted: return "Muted"
        }
    }

    var symbol: String? {
        switch self {
        case .empty: return nil
        case .master: return "speaker.wave.3"
        case .playing: return "play.fill"
        case .paused: return "pause.fill"
        case .appActive: return "speaker.wave.2.fill"
        case .muted: return "speaker.slash.fill"
        }
    }
}

struct FaderState {
    var position: Float?    // last physical position 0…1
    var attached = false
}

/// What the on-screen pop-up shows.
struct OSDMessage: Equatable {
    var channel: String
    var title: String
    var value: String
    var icon: NSImage? = nil
    var duration: TimeInterval = 2.0
    /// A point (Cocoa screen coordinates) on the screen where the source is playing.
    var screenPoint: CGPoint? = nil
}

enum SiteNames {
    static func name(forHost host: String) -> String {
        let h = host.lowercased()
        if h == "open.spotify.com" || h.hasSuffix(".spotify.com") { return "Spotify" }
        if h == "music.youtube.com" { return "YouTube Music" }
        if h.hasSuffix("youtube.com") || h.hasSuffix("youtube-nocookie.com") { return "YouTube" }
        if h.hasSuffix("twitch.tv") { return "Twitch" }
        if h.hasSuffix("soundcloud.com") { return "SoundCloud" }
        if h.hasSuffix("netflix.com") { return "Netflix" }
        var short = h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
        if short.isEmpty { short = "Tab" }
        return short
    }

    static func cleanTitle(_ title: String, host: String) -> String {
        var t = title
        for suffix in [" - YouTube", " - YouTube Music", " - Twitch", " | Spotify"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        if t.hasPrefix("(") , let close = t.firstIndex(of: ")"), t.distance(from: t.startIndex, to: close) < 6 {
            t = String(t[t.index(after: close)...]).trimmingCharacters(in: .whitespaces)
        }
        return t
    }
}
