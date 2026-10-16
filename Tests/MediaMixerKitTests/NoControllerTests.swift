import XCTest
@testable import MediaMixerKit

/// Without a controller: channels close up when a source leaves, keep their order, wait while the
/// pointer is over the mixer, and a missing controller only counts after a grace period.
@MainActor
final class NoControllerTests: XCTestCase {

    // MARK: The bookkeeping

    func testClosingGapsMovesSourcesUpInOrder() {
        var a = ChannelAssignment(channels: 8)
        a.place("a", on: 0); a.place("c", on: 2); a.place("d", on: 5)
        let changed = a.closeGaps(from: 0)
        XCTAssertEqual(Array(a.channels.prefix(4)), ["a", "c", "d", nil])
        XCTAssertEqual(changed, [1, 2, 5])
    }

    func testClosingGapsLeavesChannelOneAloneInMasterMode() {
        var a = ChannelAssignment(channels: 8)
        a.place("b", on: 3)
        a.closeGaps(from: 1)
        XCTAssertNil(a.channels[0])
        XCTAssertEqual(a.channels[1], "b")
    }

    func testShiftDownMakesRoomAndReturnsWhatFellOff() {
        var a = ChannelAssignment(channels: 8)
        for (i, id) in ["1", "2", "3", "4", "5", "6", "7", "8"].enumerated() { a.place(id, on: i) }
        XCTAssertEqual(a.shiftDown(from: 0), "8")
        XCTAssertEqual(a.channels, [nil, "1", "2", "3", "4", "5", "6", "7"])
    }

    // MARK: The mixer

    func testClosedTabsChannelIsTakenByTheOnesBelow() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...4).map { tab($0) })
        m.report([1, 3, 4].map { tab($0) })
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [tabID(1), tabID(3), tabID(4), nil])
    }

    func testWithAControllerTheGapStays() {
        let m = TestMixer(self)
        m.report((1...4).map { tab($0) })
        m.report([1, 3, 4].map { tab($0) })
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [tabID(1), nil, tabID(3), tabID(4)])
    }

    func testAWaitingTabJoinsAtTheEnd() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...9).map { tab($0) })
        m.report((1...9).filter { $0 != 3 }.map { tab($0) })
        m.wait(0.05)
        XCTAssertEqual(m.core.channels, [1, 2, 4, 5, 6, 7, 8, 9].map { tabID($0) })
        XCTAssertTrue(m.core.waiting.isEmpty)
    }

    func testNothingMovesWhileThePointerIsOverTheMixer() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.core.pointer(inside: true, area: "panel")
        m.report([1, 3].map { tab($0) })
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), nil, tabID(3)])
        m.core.pointer(inside: false, area: "panel")
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), tabID(3), nil])
    }

    func testUnassigningClosesTheGap() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.core.unassign(channel: 0)
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(2), tabID(3), nil])
    }

    func testDroppingOnAFreeChannelPlacesTheSourceAtTheEnd() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.core.move(tabID(1), to: 6)
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [tabID(2), tabID(3), tabID(1), nil])
    }

    func testDroppingOnAnOccupiedChannelStillSwaps() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.core.move(tabID(1), to: 2)
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(3), tabID(2), tabID(1)])
    }

    func testMissingControllerCountsOnlyAfterTheGracePeriod() {
        let m = TestMixer(self, controllerPresent: false)
        m.core.controllerGrace = 0.2
        m.connectController()
        XCTAssertTrue(m.core.hardwarePresent)
        m.report((1...3).map { tab($0) })
        m.controller.isConnected = false
        m.controller.onConnectionChange?(false)
        m.report([1, 3].map { tab($0) })
        m.wait(0.05)
        XCTAssertTrue(m.core.hardwarePresent, "a loose cable changes nothing straight away")
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), nil, tabID(3)])
        m.wait(0.3)
        XCTAssertFalse(m.core.hardwarePresent)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), tabID(3), nil])
    }

    func testAControllerBackInTimeKeepsEverything() {
        let m = TestMixer(self, controllerPresent: false)
        m.core.controllerGrace = 0.2
        m.connectController()
        m.report((1...3).map { tab($0) })
        m.report([1, 3].map { tab($0) })
        m.controller.onConnectionChange?(false)
        m.wait(0.05)
        m.controller.onConnectionChange?(true)
        m.wait(0.3)
        XCTAssertTrue(m.core.hardwarePresent)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), nil, tabID(3)])
    }

    func testPluggingAControllerInKeepsTheOrder() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.report([1, 3].map { tab($0) })
        m.wait(0.05)
        m.connectController()
        m.report([3].map { tab($0) })
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(2)), [nil, tabID(3)], "with a controller, gaps stay")
    }

    func testMasterIsOnByDefaultWithAndWithoutAController() {
        let m = TestMixer(self)
        XCTAssertTrue(m.settings.masterMode)
        XCTAssertTrue(m.settings.masterModeWithoutController)
    }

    func testShiftUpIsTheReverseOfShiftDown() {
        var a = ChannelAssignment(channels: 8)
        a.place("a", on: 0); a.place("b", on: 1); a.place("c", on: 3)
        _ = a.shiftDown(from: 0)
        a.shiftUp(into: 0)
        XCTAssertEqual(Array(a.channels.prefix(4)), ["a", "b", nil, "c"])
    }

    func testMasterOnAndOffWithAControllerReturnsTheSameLayout() {
        let m = TestMixer(self)
        m.report((1...3).map { tab($0) })
        m.core.updateMasterSupport(true)   // e.g. the MacBook speakers
        XCTAssertNil(m.core.channels[0])
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [nil, tabID(1), tabID(2), tabID(3)])
        m.core.updateMasterSupport(false)  // back to the Scarlett
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [tabID(1), tabID(2), tabID(3), nil])
    }

    func testMasterOnWithEightSourcesMakesTheLastOneWait() {
        let m = TestMixer(self)
        m.report((1...8).map { tab($0) })
        m.core.updateMasterSupport(true)
        XCTAssertEqual(m.core.waiting, [tabID(8)])
        m.core.updateMasterSupport(false)
        m.wait(0.05)
        XCTAssertEqual(m.core.channels, (1...8).map { tabID($0) }, "the one that waited comes back at the end")
    }

    func testMasterOnAndOffWithoutAController() {
        let m = TestMixer(self, controllerPresent: false)
        m.report((1...3).map { tab($0) })
        m.core.updateMasterSupport(true)
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [nil, tabID(1), tabID(2), tabID(3)])
        m.core.updateMasterSupport(false)
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [tabID(1), tabID(2), tabID(3), nil])
    }

    func testALayoutSavedWithMasterOnComesBackWithoutAGapOnAnotherOutput() {
        let m = TestMixer(self)
        m.core.updateMasterSupport(true)              // the MacBook speakers
        m.report((1...3).map { tab($0) })
        XCTAssertEqual(Array(m.core.channels.prefix(4)), [nil, tabID(1), tabID(2), tabID(3)])
        // The app restarts on the Scarlett: a fresh core reading the same saved layout.
        let again = MixerCore(settings: m.settings, controller: FakeController(), layoutStore: m.store)
        again.setHardwarePresent(true)
        again.loadLayout()
        again.handleTabs((1...3).map { tab($0) }, from: m.browser)
        XCTAssertEqual(Array(again.channels.prefix(4)), [tabID(1), tabID(2), tabID(3), nil])
    }

    func testALayoutSavedWithMasterOnComesBackShiftedWhenMasterIsOnAgain() {
        let m = TestMixer(self)
        m.core.updateMasterSupport(true)
        m.report((1...3).map { tab($0) })
        let again = MixerCore(settings: m.settings, controller: FakeController(), layoutStore: m.store)
        again.setHardwarePresent(true)
        again.loadLayout()
        again.updateMasterSupport(true)               // still on the speakers
        again.handleTabs((1...3).map { tab($0) }, from: m.browser)
        XCTAssertEqual(Array(again.channels.prefix(4)), [nil, tabID(1), tabID(2), tabID(3)])
    }

    func testTurningTheSettingOffMovesChannelsBackUp() {
        let m = TestMixer(self)
        m.report((1...2).map { tab($0) })
        m.core.updateMasterSupport(true)
        m.settings.masterMode = false
        m.core.updateMasterSupport(true)   // the app reacts to the setting the same way
        m.wait(0.05)
        XCTAssertEqual(Array(m.core.channels.prefix(3)), [tabID(1), tabID(2), nil])
    }
}

/// Holding play: 2 s on every controller; on Spotify it adds the song to Liked Songs unless set
/// otherwise or the tab needs a reload.
@MainActor
final class PlayHoldTests: XCTestCase {

    private func spotify(needsReload: Bool = false) -> Source {
        let m = TestMixer(self)
        m.report(tab(1, host: "open.spotify.com", title: "Song - Spotify", needsReload: needsReload))
        return m.source(1)!
    }

    func testHoldIsTwoSeconds() {
        XCTAssertEqual(MixerCore.playHoldSeconds, 2)
    }

    func testSpotifyHoldAddsToLikedSongs() {
        XCTAssertEqual(MixerCore.holdAction(for: spotify(), spotifyHold: .likeSong), .likeSong)
        XCTAssertEqual(MixerCore.HoldAction.likeSong.hint, "Keep holding to add to Liked Songs")
    }

    func testSpotifyHoldCanStillReload() {
        XCTAssertEqual(MixerCore.holdAction(for: spotify(), spotifyHold: .reloadTab), .reloadTab)
    }

    func testATabThatNeedsAReloadAlwaysReloads() {
        XCTAssertEqual(MixerCore.holdAction(for: spotify(needsReload: true), spotifyHold: .likeSong), .reloadTab)
    }

    func testOtherSitesReload() {
        let m = TestMixer(self)
        m.report(tab(1))
        XCTAssertEqual(MixerCore.holdAction(for: m.source(1)!, spotifyHold: .likeSong), .reloadTab)
        XCTAssertEqual(MixerCore.HoldAction.reloadTab.hint, "Keep holding to reload the tab")
    }

    func testLikeMessages() {
        XCTAssertEqual(MixerCore.likeMessage("added"), "Added to Liked Songs")
        XCTAssertEqual(MixerCore.likeMessage("already"), "Already in Liked Songs")
        XCTAssertEqual(MixerCore.likeMessage("unavailable"), "Can't add this to Liked Songs")
        XCTAssertEqual(MixerCore.likeMessage("something new"), "Can't add this to Liked Songs")
    }

    func testLikedSongsIsTheDefault() {
        let m = TestMixer(self)
        XCTAssertEqual(m.settings.spotifyHold, .likeSong)
    }
}

/// The header's Output and Input pickers list devices as Sound settings does.
final class DeviceListTests: XCTestCase {

    private func device(_ id: UInt32, _ name: String, uid: String? = nil, hidden: Bool = false,
                        inputs: Int = 0, outputs: Int = 0) -> RawAudioDevice {
        RawAudioDevice(id: id, uid: uid ?? "uid-\(id)", name: name, hidden: hidden, inputStreams: inputs, outputStreams: outputs)
    }

    func testOutputsAndInputsAreListedByName() {
        let raw = [
            device(1, "Scarlett 2i2 4th Gen", inputs: 1, outputs: 1),
            device(2, "MacBook Pro Speakers", outputs: 1),
            device(3, "MacBook Pro Microphone", inputs: 1),
        ]
        XCTAssertEqual(CA.visibleDevices(raw, input: false).map(\.name), ["MacBook Pro Speakers", "Scarlett 2i2 4th Gen"])
        XCTAssertEqual(CA.visibleDevices(raw, input: true).map(\.name), ["MacBook Pro Microphone", "Scarlett 2i2 4th Gen"])
    }

    func testHiddenDevicesAndTheAppsOwnTapDevicesAreLeftOut() {
        let raw = [
            device(1, "MacBook Pro Speakers", outputs: 1),
            device(2, "Media Mixer", uid: "lcxmixer-1234", inputs: 1, outputs: 1),
            device(3, "Hidden", hidden: true, outputs: 1),
        ]
        XCTAssertEqual(CA.visibleDevices(raw, input: false).map(\.name), ["MacBook Pro Speakers"])
        XCTAssertEqual(CA.visibleDevices(raw, input: true), [])
    }
}
