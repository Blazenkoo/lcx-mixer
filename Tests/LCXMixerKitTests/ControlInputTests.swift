import XCTest
@testable import LCXMixerKit

/// Faders (soft takeover), the speed knob, and the fader curve.
@MainActor
final class ControlInputTests: XCTestCase {

    /// One YouTube tab on channel 1 at gain 0.25, which the natural curve shows at fader position 0.5.
    private func mixerWithQuietTab() -> TestMixer {
        let m = TestMixer(self)
        m.report(tab(1, volume: 0.25))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.25, accuracy: 0.0001)
        return m
    }

    // MARK: - Soft takeover

    func testFaderAboveTheLevelWaitsAndSaysSo() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 0, position: 0.9))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.25, accuracy: 0.0001, "no jump in volume")
        XCTAssertFalse(m.core.faders[0].attached)
        XCTAssertEqual(m.core.takeoverHint(channel: 0), "Move fader down")
        XCTAssertEqual(m.popUps.last?.value, "Move fader down · 50%")
    }

    func testFaderMovedDownPastTheLevelTakesOver() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 0, position: 0.9))
        m.core.handle(.fader(channel: 0, position: 0.4))
        XCTAssertTrue(m.core.faders[0].attached)
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.16, accuracy: 0.0001)
        XCTAssertEqual(m.popUps.last?.value, "40%")
    }

    func testFaderBelowTheLevelTakesOverAtOnce() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 0, position: 0.3))
        XCTAssertTrue(m.core.faders[0].attached)
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.09, accuracy: 0.0001)
    }

    func testFaderCloseToTheLevelTakesOver() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 0, position: 0.52))
        XCTAssertTrue(m.core.faders[0].attached)
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.2704, accuracy: 0.0001)
    }

    func testMotorisedFadersAreAlwaysInCharge() {
        let m = mixerWithQuietTab()
        m.controller.hasMotorisedFaders = true
        m.core.handle(.fader(channel: 0, position: 0.9))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.81, accuracy: 0.0001)
    }

    func testFaderOnAnEmptyChannelOnlyRemembersWhereItIs() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 3, position: 0.7))
        XCTAssertEqual(m.core.faders[3].position, 0.7)
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.25, accuracy: 0.0001)
    }

    func testVolumeIsRememberedForTheWebsite() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 0, position: 0.3))
        XCTAssertEqual(m.settings.rememberedVolume(for: "www.youtube.com") ?? -1, 0.09, accuracy: 0.0001)
    }

    func testChannelsBeyondEightAreIgnored() {
        let m = mixerWithQuietTab()
        m.core.handle(.fader(channel: 8, position: 0.1))
        m.core.handle(.muteButton(channel: 9, pressed: true))
        XCTAssertEqual(m.source(1)?.volume ?? -1, 0.25, accuracy: 0.0001)
    }

    // MARK: - Speed knob

    func testSpeedKnobSteps() {
        let cases: [(knob: Float, speed: Float)] = [
            (0, 0.5), (0.1, 0.5), (0.13, 0.75), (0.25, 0.75), (0.5, 1), (0.51, 1),
            (0.625, 1.25), (0.75, 1.5), (0.875, 1.75), (1, 2),
        ]
        for c in cases {
            XCTAssertEqual(MixerCore.speed(forKnob: c.knob), c.speed, "knob at \(c.knob)")
        }
    }

    func testSpeedKnobTakesOverAtTheCurrentSpeed() {
        let m = TestMixer(self)
        m.report(tab(1, canSpeed: true, speed: 1))
        m.core.handle(.speedKnob(channel: 0, position: 0))
        XCTAssertEqual(m.source(1)?.speed, 1, "not taken over yet")
        XCTAssertEqual(m.popUps.last?.value, "Turn to 1× to take over")

        m.core.handle(.speedKnob(channel: 0, position: 0.5))
        m.core.handle(.speedKnob(channel: 0, position: 1))
        XCTAssertEqual(m.source(1)?.speed, 2)
        XCTAssertEqual(m.popUps.last?.value, "Speed 2×")
    }

    func testSpeedKnobOnAPageWithoutSpeedSaysSo() {
        let m = TestMixer(self)
        m.report(tab(1, canSpeed: false))
        m.core.handle(.speedKnob(channel: 0, position: 1))
        XCTAssertEqual(m.popUps.last?.value, "Speed not available")
    }

    // MARK: - Fader curve

    func testNaturalCurveSquaresThePosition() {
        let settings = AppSettings(defaults: TestStore.fresh(for: self))
        XCTAssertTrue(settings.naturalCurve, "on by default")
        XCTAssertEqual(settings.gain(forPosition: 0.5), 0.25, accuracy: 0.00001)
        XCTAssertEqual(settings.position(forGain: 0.25), 0.5, accuracy: 0.00001)
        XCTAssertEqual(settings.gain(forPosition: 1.5), 1)
        XCTAssertEqual(settings.gain(forPosition: -1), 0)
    }

    func testLinearCurveKeepsThePosition() {
        let settings = AppSettings(defaults: TestStore.fresh(for: self))
        settings.naturalCurve = false
        XCTAssertEqual(settings.gain(forPosition: 0.3), 0.3, accuracy: 0.00001)
        XCTAssertEqual(settings.position(forGain: 0.3), 0.3, accuracy: 0.00001)
    }

    func testCurveRoundTripsWithoutDrift() {
        let settings = AppSettings(defaults: TestStore.fresh(for: self))
        for step in 0...20 {
            let p = Float(step) / 20
            XCTAssertEqual(settings.position(forGain: settings.gain(forPosition: p)), p, accuracy: 0.00001)
        }
    }
}
