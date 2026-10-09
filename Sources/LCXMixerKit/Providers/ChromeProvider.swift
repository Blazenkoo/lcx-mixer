import AppKit
import os

/// One audible or media tab, as the extension reported it.
struct TabReport {
    var tabId: Int
    var windowId: Int?
    var host: String
    var title: String
    var audible: Bool
    var muted: Bool
    var hasMedia: Bool
    var playing: Bool
    var canVolume: Bool
    var canSpeed: Bool
    var canSeek: Bool
    var speed: Float?
    /// The page's volume: element gain, or slider position when `volumeIsPosition` (Spotify).
    var reportedVolume: Float?
    var volumeIsPosition: Bool
    var favicon: String
    /// Chrome window frame in screen points, top-left origin.
    var windowBounds: CGRect?
    /// The extension couldn't reconnect to the tab's page; only a reload brings it back.
    var needsReload = false
}

/// One open connection from the extension in a browser (one per browser profile).
struct BrowserConnection: Equatable {
    let id: Int32
    /// nil when the browser couldn't be identified.
    let browser: BrowserInfo?
    /// The browser's own process, used to bring it to the front.
    let browserPID: pid_t?
    var extensionOK = true

    var name: String { browser?.name ?? "Browser" }
    /// Stable across reconnects, so a tab keeps its source ID.
    var key: String { browser?.bundleID ?? "browser" }
}

/// Source provider for browser tabs in Chrome and other Chromium browsers: owns the bridge to the
/// extension, turns its messages into `TabReport`s and carries the mixer's commands back.
/// The mixer core never sees raw messages.
@MainActor
final class ChromeProvider {
    var onTabs: ((_ connection: BrowserConnection, _ tabs: [TabReport]) -> Void)?
    var onConnectionsChange: ((_ connections: [BrowserConnection]) -> Void)?

    private let bridge = ChromeBridgeServer()
    private(set) var connections: [Int32: BrowserConnection] = [:]

    func start() {
        ChromeBridgeServer.registerWithBrowsers()
        bridge.onClient = { [weak self] id, pid, connected in MainActor.assumeIsolated { self?.clientChanged(id, pid: pid, connected: connected) } }
        bridge.onMessage = { [weak self] id, message in MainActor.assumeIsolated { self?.handle(id, message) } }
        bridge.start()
    }

    /// Supported browsers that are open right now.
    static var runningBrowsers: [BrowserInfo] { Browsers.running }

    // MARK: - Commands

    func requestSnapshot(_ connection: Int32) { bridge.send(to: connection, ["type": "requestSnapshot"]) }

    func setVolume(_ connection: Int32, tabId: Int, gain: Float, position: Float) {
        bridge.send(to: connection, ["type": "setVolume", "tabId": tabId, "value": gain, "position": position])
    }

    func setMute(_ connection: Int32, tabId: Int, muted: Bool) {
        bridge.send(to: connection, ["type": "setMute", "tabId": tabId, "muted": muted])
    }

    func togglePlay(_ connection: Int32, tabId: Int) { bridge.send(to: connection, ["type": "togglePlay", "tabId": tabId]) }

    func reloadTab(_ connection: Int32, tabId: Int) { bridge.send(to: connection, ["type": "reloadTab", "tabId": tabId]) }

    func jumpLive(_ connection: Int32, tabId: Int) { bridge.send(to: connection, ["type": "jumpLive", "tabId": tabId]) }

    func setSpeed(_ connection: Int32, tabId: Int, rate: Float) {
        bridge.send(to: connection, ["type": "setSpeed", "tabId": tabId, "rate": rate])
    }

    func seekBy(_ connection: Int32, tabId: Int, seconds: Float) {
        bridge.send(to: connection, ["type": "seekBy", "tabId": tabId, "seconds": seconds])
    }

    /// Brings the tab and its window to the front, then the browser itself.
    func focus(_ connection: Int32, tabId: Int, windowId: Int?) {
        bridge.send(to: connection, ["type": "focus", "tabId": tabId, "windowId": windowId ?? -1])
        let c = connections[connection]
        if let pid = c?.browserPID, let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        } else if let bundleID = c?.browser?.bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
        }
    }

    // MARK: - Connections and messages

    private func clientChanged(_ id: Int32, pid: pid_t, connected: Bool) {
        if connected {
            let found = pid > 0 ? Browsers.identify(bridgePID: pid) : nil
            connections[id] = BrowserConnection(id: id, browser: found?.0, browserPID: found?.1)
            let name = connections[id]?.name ?? "?"
            Log.browser.info("Browser connected: \(name, privacy: .public)")
            bridge.send(to: id, ["type": "requestSnapshot"])
        } else {
            connections[id] = nil
        }
        onConnectionsChange?(Array(connections.values))
    }

    private func handle(_ id: Int32, _ message: [String: Any]) {
        guard var connection = connections[id], let type = message["type"] as? String else { return }
        if type == "tabs", let tabs = message["tabs"] as? [[String: Any]] {
            let build = message["extensionBuild"] as? String ?? ""
            let ok = !(build.isEmpty || build == "__BUILD_ID__")
            if ok != connection.extensionOK {
                connection.extensionOK = ok
                connections[id] = connection
                onConnectionsChange?(Array(connections.values))
            }
            onTabs?(connection, tabs.compactMap(Self.parse))
        }
    }

    private static func parse(_ t: [String: Any]) -> TabReport? {
        guard let tabId = (t["id"] as? NSNumber)?.intValue else { return nil }
        let url = t["url"] as? String ?? ""
        var windowBounds: CGRect?
        if let b = t["windowBounds"] as? [String: Any],
           let l = (b["left"] as? NSNumber)?.doubleValue, let tp = (b["top"] as? NSNumber)?.doubleValue,
           let w = (b["width"] as? NSNumber)?.doubleValue, let h = (b["height"] as? NSNumber)?.doubleValue {
            windowBounds = CGRect(x: l, y: tp, width: w, height: h)
        }
        return TabReport(
            tabId: tabId,
            windowId: (t["windowId"] as? NSNumber)?.intValue,
            host: URL(string: url)?.host ?? "",
            title: t["title"] as? String ?? "",
            audible: t["audible"] as? Bool ?? false,
            muted: t["muted"] as? Bool ?? false,
            hasMedia: t["hasMedia"] as? Bool ?? false,
            playing: t["playing"] as? Bool ?? false,
            canVolume: t["canVolume"] as? Bool ?? false,
            canSpeed: t["canSpeed"] as? Bool ?? false,
            canSeek: t["canSeek"] as? Bool ?? false,
            speed: (t["speed"] as? NSNumber)?.floatValue,
            reportedVolume: (t["volume"] as? NSNumber)?.floatValue,
            volumeIsPosition: t["volumeIsPosition"] as? Bool ?? false,
            favicon: t["favIconUrl"] as? String ?? "",
            windowBounds: windowBounds,
            needsReload: t["needsReload"] as? Bool ?? false
        )
    }
}
