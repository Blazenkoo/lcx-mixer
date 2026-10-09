import XCTest
@testable import LCXMixerKit

private typealias Slot = ChannelAssignment.SavedSlot

/// ChannelAssignment on its own: the bookkeeping, without pop-ups, volumes or lights.
final class ChannelAssignmentBookTests: XCTestCase {

    private func tabSource(_ n: Int, host: String = "www.youtube.com") -> Source {
        var s = Source(id: tabID(n), kind: .tab, name: "YouTube", detail: "", icon: nil, rememberKey: host,
                       isPlaying: true, isAudible: true, isMuted: false, volume: 1, canPlayPause: true, canSetVolume: true)
        s.host = host
        return s
    }

    func testPlacingTakesASourceOffTheOtherLists() {
        var a = ChannelAssignment(channels: 8)
        a.addWaiting("x")
        a.addManual("x")
        a.place("x", on: 2)
        XCTAssertEqual(a.channel(of: "x"), 2)
        XCTAssertTrue(a.waiting.isEmpty)
        XCTAssertTrue(a.manual.isEmpty)
    }

    func testMasterChannelIsSkipped() {
        var a = ChannelAssignment(channels: 8)
        a.addWaiting("x")
        XCTAssertEqual(a.firstFreeChannel(from: 1), 1)
        XCTAssertNil(a.nextToFill(0, from: 1), "channel 1 is master")
        XCTAssertEqual(a.nextToFill(0, from: 0), "x")
    }

    func testHeldChannelsAreSkippedUntilTheirSourceReturns() {
        var a = ChannelAssignment(channels: 8)
        a.hold([Slot(id: tabID(5), host: "www.youtube.com"), nil])
        a.addWaiting("other")
        XCTAssertEqual(a.firstFreeChannel(from: 0), 1, "automatic placement skips the held channel")
        XCTAssertEqual(a.firstFreeChannel(from: 0, includingHeld: true), 0)
        XCTAssertNil(a.nextToFill(0, from: 0))
        XCTAssertTrue(a.isHeld(tabID(5), host: "www.youtube.com"))
        XCTAssertFalse(a.isHeld(tabID(5), host: "open.spotify.com"), "same tab number, another site")
        XCTAssertEqual(a.heldChannel(for: tabSource(5), from: 0), 0)
        XCTAssertNil(a.heldChannel(for: tabSource(5, host: "open.spotify.com"), from: 0))

        a.place("other", on: 0) // you dragged something else there
        XCTAssertTrue(a.held.isEmpty, "a channel in use is no longer held")
    }

    func testEndingTheHoldFreesTheChannel() {
        var a = ChannelAssignment(channels: 8)
        a.hold([Slot(id: tabID(5), host: "www.youtube.com")])
        a.addWaiting("other")
        a.endHolding()
        XCTAssertEqual(a.nextToFill(0, from: 0), "other")
    }

    func testSwapAndClear() {
        var a = ChannelAssignment(channels: 8)
        a.place("x", on: 0)
        a.place("y", on: 1)
        a.swap(0, 1)
        XCTAssertEqual(a.channels[0], "y")
        XCTAssertEqual(a.channels[1], "x")
        let removed = a.clear(1)
        XCTAssertEqual(removed, "x")
        XCTAssertNil(a.channels[1])
    }

    func testForgetLeavesNoTrace() {
        var a = ChannelAssignment(channels: 8)
        a.addWaiting("x")
        a.addManual("x")
        a.addListMuted("x")
        a.forget("x")
        XCTAssertTrue(a.waiting.isEmpty && a.manual.isEmpty && a.listMuted.isEmpty)
    }

    func testLayoutKeepsHeldChannelsAndTheTabsWebsite() {
        var a = ChannelAssignment(channels: 3)
        a.hold([nil, nil, Slot(id: "app:Music", host: "")])
        a.place(tabID(1), on: 0)
        let layout = a.layout([tabID(1): tabSource(1)])
        XCTAssertEqual(layout, [Slot(id: tabID(1), host: "www.youtube.com"), nil, Slot(id: "app:Music", host: "")])
    }
}
