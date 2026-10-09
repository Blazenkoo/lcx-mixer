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

    func testFaderSweptPastTheLevelTakesOver() {
        let swept = ControlInput.takeover(FaderState(position: 0.2, attached: false), movedTo: 0.8, target: 0.5, motorised: false)
        XCTAssertTrue(swept.attached, "it passed the level on the way")
        let stillAbove = ControlInput.takeover(FaderState(position: 0.9, attached: false), movedTo: 0.8, target: 0.5, motorised: false)
        XCTAssertFalse(stillAbove.attached)
        XCTAssertEqual(stillAbove.position, 0.8)
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
            XCTAssertEqual(ControlInput.speed(forKnob: c.knob), c.speed, "knob at \(c.knob)")
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

    func testSpeedLabels() {
        XCTAssertEqual(ControlInput.speedLabel(1), "1×")
        XCTAssertEqual(ControlInput.speedLabel(1.25), "1.25×")
        XCTAssertEqual(ControlInput.speedLabel(0.5), "0.5×")
    }

    // MARK: - Seek knob

    func testSeekKnobWaitsForCentreThenSeeksFurtherTheMoreItTurns() {
        var controls = ControlInput(channels: 8)
        let first = controls.seekKnob(0, at: 0.9)
        let centre = controls.seekKnob(0, at: 0.5)
        let turned = controls.seekKnob(0, at: 0.9)
        XCTAssertEqual(first, .notArmed, "not centred when the source arrived")
        XCTAssertEqual(centre, .centred)
        XCTAssertEqual(turned, .turned)
        XCTAssertEqual(controls.seekDeflection[0], 0.8, accuracy: 0.0001)
        XCTAssertEqual(ControlInput.seekStep(0.2), 5)
        XCTAssertEqual(ControlInput.seekStep(0.5), 15)
        XCTAssertEqual(ControlInput.seekStep(-0.9), -30)

        controls.reset(0)
        let afterReset = controls.seekKnob(0, at: 0.9)
        XCTAssertEqual(afterReset, .notArmed, "a new source starts over")
    }

    // MARK: - Buttons

    func testTwitchDoublePressIsCountedOnlyWhenAsked() {
        var controls = ControlInput(channels: 8)
        let t = Date()
        let presses = [
            controls.playPressIsDouble(0, at: t, counting: true),
            controls.playPressIsDouble(0, at: t.addingTimeInterval(0.3), counting: true),
            controls.playPressIsDouble(0, at: t.addingTimeInterval(0.5), counting: true),
            controls.playPressIsDouble(1, at: t, counting: false),
            controls.playPressIsDouble(1, at: t.addingTimeInterval(0.1), counting: false),
        ]
        XCTAssertEqual(presses, [false, true, false, false, false], "a third press starts over; not counted means never double")
    }

    func testButtonHoldTellsAPressFromAHold() {
        let hold = ButtonHold()
        var held = 0
        hold.press(0, holdAfter: 0.05) { held += 1; return true }
        XCTAssertTrue(hold.release(0), "let go at once: a short press")
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(held, 0, "the hold was cancelled")

        hold.press(0, holdAfter: 0.05) { held += 1; return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(held, 1)
        XCTAssertFalse(hold.release(0), "the hold already acted")
    }

    func testHoldingMuteUnassignsAndAShortPressMutes() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.core.handle(.muteButton(channel: 0, pressed: true))
        m.core.handle(.muteButton(channel: 0, pressed: false))
        XCTAssertEqual(m.source(1)?.isMuted, true)
        XCTAssertEqual(m.popUps.last?.value, "Muted")

        m.core.handle(.muteButton(channel: 0, pressed: true))
        m.wait(1.1)
        m.core.handle(.muteButton(channel: 0, pressed: false))
        XCTAssertNil(m.core.channels[0])
        XCTAssertEqual(m.source(1)?.isMuted, true, "letting go after the hold doesn't toggle mute")
    }

    func testShortPlayPressTogglesPlay() {
        let m = TestMixer(self)
        m.report(tab(1))
        m.core.handle(.playButton(channel: 0, pressed: true))
        m.core.handle(.playButton(channel: 0, pressed: false))
        XCTAssertEqual(m.source(1)?.isPlaying, false)
        XCTAssertEqual(m.popUps.last?.value, "Paused")
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
