import XCTest
@testable import LCXMixerKit

/// Stands in for a hardware controller: always connected, and records every set of lights it gets.
@MainActor
final class FakeController: ControllerDriver {
    let displayName = "Test controller"
    var isConnected = true
    var hasMotorisedFaders = false
    var onAction: ((ControllerAction) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNeedsLights: (() -> Void)?
    private(set) var shown: [ControllerLights] = []

    var lastLights: ControllerLights? { shown.last }

    func start() {}
    func show(_ lights: ControllerLights) { shown.append(lights) }
    func clearLights() {}
    func stop() {}
}

/// A settings store of its own, so tests never touch the app's real settings. Emptied before
/// and after every test.
enum TestStore {
    static let name = "org.lcxmixer.tests"

    static func fresh(for test: XCTestCase) -> UserDefaults {
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        test.addTeardownBlock {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        return store
    }
}

/// A mixer core wired to a fake controller and a throwaway store, plus a pretend browser that
/// reports tabs. Native apps aren't used: they need real audio processes.
@MainActor
final class TestMixer {
    let store: UserDefaults
    let settings: AppSettings
    let controller = FakeController()
    let core: MixerCore
    /// The browser the tabs come from. It has no bundle ID, so its tab IDs read "tab:browser:<n>".
    let browser = BrowserConnection(id: 1, browser: nil, browserPID: nil)
    private(set) var popUps: [OSDMessage] = []

    init(_ test: XCTestCase, configure: (AppSettings) -> Void = { _ in }) {
        store = TestStore.fresh(for: test)
        settings = AppSettings(defaults: store)
        configure(settings)
        core = MixerCore(settings: settings, controller: controller, layoutStore: store)
        core.onOSD = { [weak self] message in self?.popUps.append(message) }
    }

    /// One report from the browser: every tab it has right now. Tabs left out count as closed.
    func report(_ tabs: TabReport...) { core.handleTabs(tabs, from: browser) }
    func report(_ tabs: [TabReport]) { core.handleTabs(tabs, from: browser) }

    /// Starts the fake controller, so the core works out lights.
    func connectController() { core.startController() }

    /// Lets queued main-thread work run (delayed refreshes, the 0.8 s blink of a new channel).
    func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func source(_ n: Int) -> Source? { core.sources[tabID(n)] }
}

/// The source ID the core gives tab `n` of the test browser.
func tabID(_ n: Int) -> String { "tab:browser:\(n)" }

/// A tab as the extension reports it. By default: an audible YouTube video at full volume.
func tab(_ n: Int,
         host: String = "www.youtube.com",
         title: String = "Video - YouTube",
         audible: Bool = true,
         playing: Bool = true,
         hasMedia: Bool = true,
         muted: Bool = false,
         canVolume: Bool = true,
         volume: Float? = nil,
         volumeIsPosition: Bool = false,
         canSpeed: Bool = false,
         canSeek: Bool = false,
         speed: Float? = nil,
         needsReload: Bool = false) -> TabReport {
    TabReport(
        tabId: n, windowId: 1, host: host, title: title, audible: audible, muted: muted,
        hasMedia: hasMedia, playing: playing, canVolume: canVolume, canSpeed: canSpeed, canSeek: canSeek,
        speed: speed, reportedVolume: volume, volumeIsPosition: volumeIsPosition, favicon: "",
        windowBounds: nil, needsReload: needsReload
    )
}
