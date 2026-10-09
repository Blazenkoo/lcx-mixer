import XCTest
@testable import LCXMixerKit

/// How the browser's tab reports become sources.
@MainActor
final class TabMergeTests: XCTestCase {

    func testSiteNameAndCleanTitle() {
        let m = TestMixer(self)
        m.report(tab(1, title: "(3) Lo-fi beats - YouTube"))
        XCTAssertEqual(m.source(1)?.name, "YouTube")
        XCTAssertEqual(m.source(1)?.detail, "Lo-fi beats")
        XCTAssertEqual(m.source(1)?.displayName, "YouTube – Lo-fi beats")
    }

    func testSiteNames() {
        XCTAssertEqual(SiteNames.name(forHost: "open.spotify.com"), "Spotify")
        XCTAssertEqual(SiteNames.name(forHost: "music.youtube.com"), "YouTube Music")
        XCTAssertEqual(SiteNames.name(forHost: "www.youtube-nocookie.com"), "YouTube")
        XCTAssertEqual(SiteNames.name(forHost: "www.twitch.tv"), "Twitch")
        XCTAssertEqual(SiteNames.name(forHost: "www.example.org"), "example.org")
        XCTAssertEqual(SiteNames.name(forHost: ""), "Tab")
        XCTAssertEqual(SiteNames.cleanTitle("Song | Spotify", host: "open.spotify.com"), "Song")
    }

    func testTitleChangesAreFollowed() {
        let m = TestMixer(self)
        m.report(tab(1, title: "First - YouTube"))
        m.report(tab(1, title: "Second - YouTube"))
        XCTAssertEqual(m.source(1)?.detail, "Second")
    }

    func testVolumeChangedInThePageIsFollowed() {
        let m = TestMixer(self)
        m.report(tab(1, volume: 0.5))
        m.report(tab(1, volume: 0.3))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.3, accuracy: 0.0001)
    }

    func testPageVolumeJustAfterAFaderMoveIsIgnored() {
        let m = TestMixer(self)
        m.report(tab(1, volume: 0.25))
        m.core.handle(.fader(channel: 0, position: 0.3))
        m.report(tab(1, volume: 0.25)) // sent before the page heard the new volume
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.09, accuracy: 0.0001)
    }

    func testSpotifyReportsItsSliderPosition() {
        let m = TestMixer(self)
        m.report(tab(1, host: "open.spotify.com", volume: 0.5, volumeIsPosition: true))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.25, accuracy: 0.0001, "position 0.5 is gain 0.25 on the natural curve")
    }

    func testNewWebsiteInTheSameTabStartsFresh() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.report(tab(1, host: "www.twitch.tv", title: "Stream"))
        XCTAssertEqual(m.source(1)?.name, "Twitch")
        XCTAssertEqual(m.source(1)?.rememberKey, "www.twitch.tv")
        XCTAssertEqual(m.core.channels[0], tabID(1), "it keeps its channel")
    }

    func testMuteInThePageIsFollowedUnlessTheMixerJustSentOne() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.report(tab(1, muted: true))
        XCTAssertEqual(m.source(1)?.isMuted, true)

        m.core.toggleMute(tabID(1))
        XCTAssertEqual(m.source(1)?.isMuted, false)
        m.report(tab(1, muted: true)) // the page hasn't caught up yet
        XCTAssertEqual(m.source(1)?.isMuted, false)
    }

    func testTabThatNeedsAReloadIsMarked() {
        let m = TestMixer(self)
        m.report(tab(1, needsReload: true))
        XCTAssertEqual(m.source(1)?.needsReload, true)
        m.report(tab(1))
        XCTAssertEqual(m.source(1)?.needsReload, false)
    }

    func testTabsFromTwoBrowsersAreKeptApartAndLabelled() {
        let m = TestMixer(self)
        let chrome = BrowserConnection(id: 2, browser: Browsers.chrome, browserPID: nil)
        m.report(tab(1))
        m.core.handleTabs([tab(1)], from: chrome)
        let chromeTab = "tab:com.google.Chrome:1"
        XCTAssertNotNil(m.source(1))
        XCTAssertNotNil(m.core.sources[chromeTab])
        XCTAssertEqual(m.core.sources[chromeTab]?.nameWithBrowser, "YouTube · Chrome")

        m.report() // the first browser closed its tab
        XCTAssertNil(m.source(1))
        XCTAssertNotNil(m.core.sources[chromeTab], "the other browser's tab stays")
        XCTAssertNil(m.core.sources[chromeTab]?.browserLabel, "one browser left: no label")
    }
}
