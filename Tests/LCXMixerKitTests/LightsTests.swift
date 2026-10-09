import XCTest
@testable import LCXMixerKit

/// What the controller's lights show for each kind of channel.
@MainActor
final class LightsTests: XCTestCase {

    /// A mixer whose controller is connected, so the core works out lights.
    private func connectedMixer() -> TestMixer {
        let m = TestMixer(self)
        m.connectController()
        return m
    }

    /// The lights right after asking the core for them.
    private func lights(_ m: TestMixer) -> ControllerLights {
        m.core.refreshLEDs()
        return m.controller.lastLights ?? ControllerLights(channels: [])
    }

    func testEmptyMixerShowsNoLights() {
        let m = connectedMixer()
        let l = lights(m)
        XCTAssertEqual(l.channels, Array(repeating: ChannelLights(), count: 8))
        XCTAssertEqual(l.muteAll, .off)
        XCTAssertEqual(l.micMute, .off)
    }

    func testNewTabBlinksGreenWithItsNameAndVolume() {
        let m = connectedMixer()
        m.report(tab(1))
        let c = lights(m).channels[0]
        XCTAssertEqual(c.playButton, .greenBlink)
        XCTAssertEqual(c.muteButton, .off)
        XCTAssertEqual(c.name, "YouTube – Video")
        XCTAssertEqual(c.detail, "100%")
        XCTAssertEqual(c.fader, 1)
    }

    func testPlayingTabIsGreenAndPausedTabIsAmber() {
        let m = connectedMixer()
        m.report(tab(1), tab(2))
        m.report(tab(1), tab(2, audible: false, playing: false))
        m.wait(0.9) // past the blink of a newly placed channel
        let l = lights(m)
        XCTAssertEqual(l.channels[0].playButton, .green)
        XCTAssertEqual(l.channels[1].playButton, .amber)
    }

    func testMutedTabShowsRed() {
        let m = connectedMixer()
        m.report(tab(1))
        m.core.toggleMute(tabID(1))
        let c = lights(m).channels[0]
        XCTAssertEqual(c.muteButton, .red)
        XCTAssertEqual(c.detail, "Muted")
    }

    func testMuteAllLightsTheSideButtonAndBlinksEveryMute() {
        let m = connectedMixer()
        m.report(tab(1))
        m.core.handle(.muteAll)
        let l = lights(m)
        XCTAssertEqual(l.muteAll, .yellow)
        XCTAssertEqual(l.channels[0].muteButton, .redBlink)
        XCTAssertEqual(l.channels[0].detail, "Muted")
        XCTAssertEqual(m.popUps.last?.title, "All media")
        XCTAssertEqual(m.popUps.last?.value, "Muted")
    }

    func testTabWithoutVolumeControlShowsDimRed() {
        let m = connectedMixer()
        m.report(tab(1, canVolume: false))
        XCTAssertEqual(lights(m).channels[0].muteButton, .redDim)
    }

    func testTabThatNeedsAReloadBlinksAmber() {
        let m = connectedMixer()
        m.report(tab(1, needsReload: true))
        let c = lights(m).channels[0]
        XCTAssertEqual(c.playButton, .amberBlink)
        XCTAssertEqual(c.detail, "Reload")
    }

    func testSpeedKnobShowsFasterGreenAndSlowerRed() {
        let m = connectedMixer()
        m.report(tab(1, canSpeed: true, speed: 1.5), tab(2, canSpeed: true, speed: 0.75), tab(3, canSpeed: true, speed: 1))
        let l = lights(m)
        XCTAssertEqual(l.channels[0].speedKnob, .green)
        XCTAssertEqual(l.channels[1].speedKnob, .red)
        XCTAssertEqual(l.channels[2].speedKnob, .off)
    }
}
