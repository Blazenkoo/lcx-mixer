import XCTest
@testable import LCXMixerKit

/// TabMerger on its own: tab reports in, source values out.
final class TabMergerTests: XCTestCase {
    private let browser = BrowserConnection(id: 1, browser: nil, browserPID: nil)

    private func existing(_ t: TabReport) -> Source {
        TabMerger.newSource(t, id: TabMerger.sourceID(of: t, from: browser), from: browser, gain: t.reportedVolume)
    }

    func testIDsIncludeTheBrowser() {
        XCTAssertEqual(TabMerger.sourceID(of: tab(7), from: browser), "tab:browser:7")
        let chrome = BrowserConnection(id: 2, browser: Browsers.chrome, browserPID: nil)
        XCTAssertEqual(TabMerger.sourceID(of: tab(7), from: chrome), "tab:com.google.Chrome:7")
    }

    func testWhoJoins() {
        XCTAssertTrue(TabMerger.joins(tab(1), held: false, ignored: false))
        XCTAssertFalse(TabMerger.joins(tab(1), held: false, ignored: true))
        XCTAssertFalse(TabMerger.joins(tab(1, audible: false, playing: false), held: false, ignored: false))
        XCTAssertTrue(TabMerger.joins(tab(1, audible: false, playing: false), held: true, ignored: false))
        XCTAssertFalse(TabMerger.joins(tab(1, audible: false, hasMedia: false), held: true, ignored: false))
    }

    func testNewSourceWithoutVolumeControlStaysAtFull() {
        let s = TabMerger.newSource(tab(1, canVolume: false, volume: 0.3), id: "tab:browser:1", from: browser, gain: 0.3)
        XCTAssertEqual(s.volume, 1)
        XCTAssertFalse(s.canSetVolume)
        XCTAssertEqual(s.browserConnection, 1)
    }

    func testReportedGainUsesTheCurveForSliderPositions() {
        let square: (Float) -> Float = { $0 * $0 }
        XCTAssertEqual(TabMerger.reportedGain(tab(1, volume: 0.5), gainForPosition: square), 0.5)
        XCTAssertEqual(TabMerger.reportedGain(tab(1, volume: 0.5, volumeIsPosition: true), gainForPosition: square), 0.25)
        XCTAssertNil(TabMerger.reportedGain(tab(1), gainForPosition: square))
    }

    func testRecentMixerChangesAreNotUndoneByAnOldReport() {
        let old = existing(tab(1, volume: 0.5, canSpeed: true, speed: 1))
        let now = Date()
        let justSent = TabMerger.Recent(now: now, volumeSentAt: now, speedSentAt: now, muteSentAt: now)
        let stale = tab(1, muted: true, volume: 0.2, canSpeed: true, speed: 2)
        let u = TabMerger.update(old, with: stale, from: browser, gain: 0.2, recent: justSent)
        XCTAssertEqual(u.source.volume, 0.5)
        XCTAssertEqual(u.source.speed, 1)
        XCTAssertFalse(u.source.isMuted)
        XCTAssertFalse(u.volumeChangedInPage || u.speedChangedInPage)

        let later = TabMerger.Recent(now: now.addingTimeInterval(2), volumeSentAt: now, speedSentAt: now, muteSentAt: now)
        let v = TabMerger.update(old, with: stale, from: browser, gain: 0.2, recent: later)
        XCTAssertEqual(v.source.volume, 0.2)
        XCTAssertEqual(v.source.speed, 2)
        XCTAssertTrue(v.source.isMuted)
        XCTAssertTrue(v.volumeChangedInPage && v.speedChangedInPage)
    }

    func testMuteHeldByTheMixerWins() {
        let old = existing(tab(1))
        let u = TabMerger.update(old, with: tab(1, muted: true), from: browser, gain: nil, recent: .init(muteHeld: true))
        XCTAssertFalse(u.source.isMuted)
    }

    func testPendingVolumeIsSentOnceThePageCanTakeIt() {
        let old = existing(tab(1, canVolume: false))
        XCTAssertFalse(TabMerger.update(old, with: tab(1, canVolume: false), from: browser, gain: nil, recent: .init(volumePending: true)).sendPendingVolume)
        XCTAssertTrue(TabMerger.update(old, with: tab(1), from: browser, gain: nil, recent: .init(volumePending: true)).sendPendingVolume)
    }

    func testClosedTabsAreOnlyThisBrowsersUnreportedOnes() {
        var other = existing(tab(2))
        other.browserConnection = 9
        let sources = ["tab:browser:1": existing(tab(1)), "tab:browser:2": other, "tab:browser:3": existing(tab(3))]
        XCTAssertEqual(TabMerger.closed(in: sources, connection: browser, seen: ["tab:browser:1"]), ["tab:browser:3"])
    }

    func testBrowserLabelsOnlyWithMoreThanOneBrowser() {
        var chromeTab = existing(tab(2))
        chromeTab.browserKey = "com.google.Chrome"
        let one = TabMerger.browserLabels(for: ["a": existing(tab(1))])
        XCTAssertNil(one.first?.label ?? nil)
        let two = Dictionary(uniqueKeysWithValues: TabMerger.browserLabels(for: ["tab:browser:1": existing(tab(1)), "tab:browser:2": chromeTab]).map { ($0.id, $0.label) })
        XCTAssertEqual(two["tab:browser:2"], "Chrome")
        XCTAssertEqual(two["tab:browser:1"], "Browser")
    }
}
