import XCTest
@testable import LCXMixerKit

/// The always-mute and ignore lists.
@MainActor
final class MuteListTests: XCTestCase {

    func testMuteListedSiteIsSilencedAndNeverTakesAChannel() {
        let m = TestMixer(self) { $0.muteList = ["www.youtube.com"] }
        m.report(tab(1))
        XCTAssertEqual(m.core.listMuted, [tabID(1)])
        XCTAssertTrue(m.core.channels.allSatisfy { $0 == nil })
        XCTAssertTrue(m.core.unassigned.isEmpty)
        XCTAssertEqual(m.core.listMutedSources.map(\.id), [tabID(1)])
    }

    func testAlwaysMuteTakesTheTabOffItsChannel() {
        let m = TestMixer(self)
        m.report(tab(1), tab(2, host: "www.twitch.tv"))
        m.core.alwaysMute(tabID(1))
        XCTAssertEqual(m.settings.muteList, ["www.youtube.com"])

        m.core.applyMuteList()
        XCTAssertNil(m.core.channels[0])
        XCTAssertEqual(m.core.channels[1], tabID(2))
        XCTAssertEqual(m.core.listMuted, [tabID(1)])
        XCTAssertEqual(m.popUps.last?.value, "Muted by list")
    }

    func testTakingASiteOffTheMuteListGivesItAChannelAgain() {
        let m = TestMixer(self)
        m.report(tab(1), tab(2, host: "www.twitch.tv"))
        m.core.alwaysMute(tabID(1))
        m.core.applyMuteList()

        m.core.removeFromMuteList(tabID(1))
        XCTAssertTrue(m.settings.muteList.isEmpty)
        m.core.applyMuteList()
        XCTAssertTrue(m.core.listMuted.isEmpty)
        XCTAssertEqual(m.core.channels[0], tabID(1))
    }

    func testIgnoredSiteIsLeftAlone() {
        let m = TestMixer(self) { $0.ignoreList.append("www.youtube.com") }
        m.report(tab(1))
        XCTAssertTrue(m.core.sources.isEmpty)
    }

    func testIgnoreRemovesTheTabAndRemembersTheSite() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.core.ignore(tabID(1))
        XCTAssertTrue(m.settings.ignoreList.contains("www.youtube.com"))
        XCTAssertNil(m.source(1))
        XCTAssertNil(m.core.channels[0])
    }

    func testAnEntryLivesOnOneListOnly() {
        let settings = AppSettings(defaults: TestStore.fresh(for: self))
        settings.ignoreList = ["example.com"]
        settings.muteList = ["example.com"]
        XCTAssertFalse(settings.ignoreList.contains("example.com"))
        settings.ignoreList.append("example.com")
        XCTAssertFalse(settings.muteList.contains("example.com"))
    }

    func testEmptyEntriesNeverMatch() {
        let settings = AppSettings(defaults: TestStore.fresh(for: self))
        settings.muteList = [""]
        XCTAssertFalse(settings.isMuteListed([""]))
        XCTAssertTrue(settings.isIgnored(["com.apple.systemsoundserverd"]), "on the ignore list by default")
    }
}
