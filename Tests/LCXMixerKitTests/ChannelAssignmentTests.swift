import XCTest
@testable import LCXMixerKit

/// Where sources land: first free channel, the waiting list, unassigning, moving, and getting
/// channels back after a restart.
@MainActor
final class ChannelAssignmentTests: XCTestCase {

    func testAudibleTabTakesTheFirstFreeChannel() {
        let m = TestMixer(self)
        m.report(tab(1))
        XCTAssertEqual(m.core.channels[0], tabID(1))
        XCTAssertEqual(m.core.source(onChannel: 0)?.name, "YouTube")
        XCTAssertEqual(m.popUps.last?.value, "On channel 1")
    }

    func testSilentTabIsLeftOut() {
        let m = TestMixer(self)
        m.report(tab(1, audible: false, hasMedia: false), tab(2, audible: false, playing: false))
        XCTAssertTrue(m.core.sources.isEmpty, "a tab joins only once it makes sound")
    }

    func testNinthTabWaitsForAChannel() {
        let m = TestMixer(self)
        m.report((1...9).map { tab($0) })
        for ch in 0..<8 { XCTAssertEqual(m.core.channels[ch], tabID(ch + 1)) }
        XCTAssertEqual(m.core.waiting, [tabID(9)])
        XCTAssertEqual(m.popUps.last?.value, "Waiting for a channel")
    }

    func testClosedTabGivesItsChannelToTheWaitingTab() {
        let m = TestMixer(self)
        m.report((1...9).map { tab($0) })
        m.report((1...9).filter { $0 != 3 }.map { tab($0) })
        XCTAssertNil(m.source(3))
        XCTAssertEqual(m.core.channels[2], tabID(9))
        XCTAssertTrue(m.core.waiting.isEmpty)
    }

    func testUnassignedTabStaysOffItsChannel() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.core.unassign(channel: 0)
        XCTAssertNil(m.core.channels[0])
        XCTAssertEqual(m.core.manual, [tabID(1)])

        m.report(tab(1))
        XCTAssertNil(m.core.channels[0], "the next report doesn't put it back")
        XCTAssertTrue(m.core.isManuallyUnassigned(tabID(1)))
    }

    func testUnassigningLetsTheWaitingTabIn() {
        let m = TestMixer(self)
        m.report((1...9).map { tab($0) })
        m.core.unassign(channel: 0)
        XCTAssertEqual(m.core.channels[0], tabID(9))
        XCTAssertEqual(m.core.manual, [tabID(1)])
    }

    func testAssignUsesTheFirstFreeChannel() {
        let m = TestMixer(self)
        m.report(tab(1), tab(2))
        m.core.unassign(channel: 0)
        m.core.assign(tabID(1))
        XCTAssertEqual(m.core.channels[0], tabID(1))
        XCTAssertTrue(m.core.manual.isEmpty)
    }

    func testMovingSwapsTwoChannels() {
        let m = TestMixer(self)
        m.report(tab(1), tab(2))
        m.core.move(tabID(1), to: 1)
        XCTAssertEqual(m.core.channels[0], tabID(2))
        XCTAssertEqual(m.core.channels[1], tabID(1))
    }

    func testMovingAnUnassignedTabBumpsTheOccupant() {
        let m = TestMixer(self)
        m.report(tab(1), tab(2))
        m.core.unassign(channel: 0)
        m.core.move(tabID(1), to: 1)
        XCTAssertEqual(m.core.channels[1], tabID(1))
        XCTAssertNil(m.core.channels[0])
        XCTAssertEqual(m.core.manual, [tabID(2)])
    }

    // MARK: - After a restart

    /// Writes the layout the app would have saved before quitting.
    private func saveLayout(_ m: TestMixer, channel: Int, id: String, host: String) {
        var slots: [Any] = Array(repeating: NSNull(), count: 8)
        slots[channel] = ["id": id, "host": host]
        let data = try! JSONSerialization.data(withJSONObject: slots)
        m.store.set(data, forKey: "channelLayout")
        m.core.loadLayout()
    }

    func testReturningTabGetsItsChannelBack() {
        let m = TestMixer(self)
        saveLayout(m, channel: 3, id: tabID(5), host: "www.youtube.com")
        m.report(tab(7), tab(5))
        XCTAssertEqual(m.core.channels[0], tabID(7), "new tabs skip the held channel")
        XCTAssertEqual(m.core.channels[3], tabID(5))
    }

    func testPausedTabWithAPlayerAlsoGetsItsChannelBack() {
        let m = TestMixer(self)
        saveLayout(m, channel: 3, id: tabID(5), host: "www.youtube.com")
        m.report(tab(5, audible: false, playing: false))
        XCTAssertEqual(m.core.channels[3], tabID(5))
    }

    func testReusedTabNumberOnAnotherSiteDoesNotTakeTheHeldChannel() {
        let m = TestMixer(self)
        saveLayout(m, channel: 3, id: tabID(5), host: "www.youtube.com")
        m.report(tab(5, host: "open.spotify.com"))
        XCTAssertEqual(m.core.channels[0], tabID(5))
        XCTAssertNil(m.core.channels[3])
    }

    func testLayoutIsSavedWithTheTabsWebsite() throws {
        let m = TestMixer(self)
        m.report(tab(1))
        let data = try XCTUnwrap(m.store.data(forKey: "channelLayout"))
        let slots = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(slots.count, 8)
        XCTAssertEqual(slots[0] as? [String: String], ["id": tabID(1), "host": "www.youtube.com"])
        XCTAssertTrue(slots[1] is NSNull)
    }
}
