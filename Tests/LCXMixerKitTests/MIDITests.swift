import XCTest
@testable import LCXMixerKit

/// Reading MIDI, the Launch Control XL and Mackie Control maps, and MIDI learn bindings.
@MainActor
final class MIDITests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ bytes: [UInt8]) -> [String] {
        var messages: [MIDIMessage] = []
        MIDIController.parse(bytes, into: &messages)
        return messages.map { "\($0.kind) \($0.channel) \($0.number) \($0.value)" }
    }

    private func describe(_ a: ControllerAction) -> String {
        func amount(_ p: Float) -> String { String(format: "%.3f", Double(p)) }
        switch a {
        case let .fader(ch, p): return "fader \(ch) \(amount(p))"
        case let .playButton(ch, pressed): return "play \(ch) \(pressed ? "down" : "up")"
        case let .muteButton(ch, pressed): return "mute \(ch) \(pressed ? "down" : "up")"
        case .muteAll: return "muteAll"
        case .micMute: return "micMute"
        case let .speedKnob(ch, p): return "speed \(ch) \(amount(p))"
        case let .seekKnob(ch, p): return "seek \(ch) \(amount(p))"
        }
    }

    private func cc(_ ch: UInt8, _ n: UInt8, _ v: Int) -> MIDIMessage { MIDIMessage(kind: .controlChange, channel: ch, number: n, value: v) }
    private func on(_ ch: UInt8, _ n: UInt8) -> MIDIMessage { MIDIMessage(kind: .noteOn, channel: ch, number: n, value: 127) }
    private func off(_ ch: UInt8, _ n: UInt8) -> MIDIMessage { MIDIMessage(kind: .noteOff, channel: ch, number: n, value: 0) }
    private func bend(_ ch: UInt8, _ v: Int) -> MIDIMessage { MIDIMessage(kind: .pitchBend, channel: ch, number: 0, value: v) }

    // MARK: - Reading MIDI

    func testControlChangeAndNotes() {
        XCTAssertEqual(parse([0xB8, 77, 64]), ["controlChange 8 77 64"])
        XCTAssertEqual(parse([0x98, 41, 127, 0x98, 41, 0, 0x88, 41, 64]),
                       ["noteOn 8 41 127", "noteOff 8 41 0", "noteOff 8 41 64"])
    }

    func testPitchBendIsFourteenBits() {
        XCTAssertEqual(parse([0xE0, 0x00, 0x40]), ["pitchBend 0 0 8192"])
        XCTAssertEqual(parse([0xE3, 0x7F, 0x7F]), ["pitchBend 3 0 16383"])
    }

    func testSysExAndStrayBytesAreSkipped() {
        XCTAssertEqual(parse([0xF0, 0x00, 0x20, 0x29, 0xF7, 0xB0, 7, 100]), ["controlChange 0 7 100"])
        XCTAssertEqual(parse([0x40, 0xB0, 7, 100, 0xB0, 1]), ["controlChange 0 7 100"])
    }

    // MARK: - Launch Control XL

    func testLaunchControlXLMap() {
        let driver = LaunchControlXLDriver()
        var actions: [String] = []
        driver.onAction = { actions.append(self.describe($0)) }
        let input: [MIDIMessage] = [
            cc(8, 77, 127), cc(8, 84, 0), cc(8, 29, 64), cc(8, 56, 127), cc(8, 1, 50),
            on(8, 41), off(8, 60), on(8, 73), off(8, 92),
            on(8, 106), off(8, 106), on(8, 107), bend(8, 100),
        ]
        for message in input { driver.handle(message) }
        XCTAssertEqual(actions, [
            "fader 0 1.000", "fader 7 0.000", "seek 0 0.504", "speed 7 1.000",
            "play 0 down", "play 7 up", "mute 0 down", "mute 7 up",
            "muteAll", "micMute",
        ])
    }

    func testLaunchControlXLColours() {
        XCTAssertEqual(LaunchControlXLDriver.color(.greenDim), .greenLow)
        XCTAssertEqual(LaunchControlXLDriver.color(.amberBlink), .amberFlash)
        XCTAssertEqual(LaunchControlXLDriver.color(.redBlink), .redFlash)
        XCTAssertEqual(LaunchControlXLDriver.sideColor(.red), .yellow, "side buttons only have yellow")
        XCTAssertEqual(LaunchControlXLDriver.sideColor(.off), .off)
        XCTAssertEqual(LCXL.led(note: 41, .green), [0x98, 41, 60])
        XCTAssertEqual(LCXL.knobLED(index: 8, .green), [0xF0, 0x00, 0x20, 0x29, 0x02, 0x11, 0x78, 0x08, 8, 60, 0xF7])
    }

    // MARK: - Mackie Control

    private func mackie() -> MackieControlDriver {
        MackieControlDriver(settings: AppSettings(defaults: TestStore.fresh(for: self)))
    }

    func testMackieFadersAndButtons() {
        let driver = mackie()
        var actions: [String] = []
        driver.onAction = { actions.append(self.describe($0)) }
        let input: [MIDIMessage] = [
            bend(2, 8192), bend(8, 100),
            on(0, 0x18 + 3), off(0, 0x18 + 3), on(0, 0x10),
            on(0, 0x36), on(0, 0x37), MIDIMessage(kind: .noteOn, channel: 0, number: 0x36, value: 0),
        ]
        for message in input { driver.handle(message) }
        XCTAssertEqual(actions, ["fader 2 0.500", "play 3 down", "play 3 up", "mute 0 down", "muteAll", "micMute"])
    }

    func testMackieIgnoresItsOwnMotorEcho() {
        let driver = mackie()
        var actions: [String] = []
        driver.onAction = { actions.append(self.describe($0)) }
        for message in [bend(0, 1000), bend(0, 1050), bend(0, 1200)] { driver.handle(message) }
        XCTAssertEqual(actions, ["fader 0 0.061", "fader 0 0.073"], "a value within 96 of the last one is taken as an echo")

        driver.handle(on(0, 0x68)) // a finger on fader 1
        driver.handle(bend(0, 1210))
        XCTAssertEqual(actions.last, "fader 0 0.074", "under a finger every move counts")
    }

    func testMackieScribbleStrips() {
        let line = MackieControlDriver.stripLine(["Spotify", "YouTube – Lo-fi", "Café"])
        XCTAssertEqual(line, "Spotif " + "YouTub " + "Cafe   " + String(repeating: " ", count: 35))
        XCTAssertEqual(line.count, 56)
        XCTAssertEqual(MackieControlDriver.ascii("Café ♪"), "Cafe  ")
        XCTAssertEqual(MackieControlDriver.textMessage(offset: 56, "AB"),
                       [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 56, 0x41, 0x42, 0xF7])
    }

    func testMackieLights() {
        XCTAssertEqual(MackieControlDriver.led(.green), 0x7F)
        XCTAssertEqual(MackieControlDriver.led(.greenBlink), 0x01)
        XCTAssertEqual(MackieControlDriver.led(.greenDim), 0x00)
        var c = ChannelLights()
        XCTAssertEqual(MackieControlDriver.stripColour(c), 0, "an empty strip is dark")
        c.name = "YouTube"
        c.playButton = .greenDim
        XCTAssertEqual(MackieControlDriver.stripColour(c), 7)
        c.playButton = .greenBlink
        XCTAssertEqual(MackieControlDriver.stripColour(c), 2)
        c.playButton = .amber
        XCTAssertEqual(MackieControlDriver.stripColour(c), 3)
        c.muteButton = .red
        XCTAssertEqual(MackieControlDriver.stripColour(c), 1)
    }

    // MARK: - MIDI learn

    func testLearnedNoteMatchesPressAndReleaseOnItsChannelOnly() throws {
        let binding = try XCTUnwrap(MIDIBinding(on(0, 20)))
        XCTAssertTrue(binding.matches(on(0, 20)))
        XCTAssertTrue(binding.matches(off(0, 20)))
        XCTAssertFalse(binding.matches(on(1, 20)))
        XCTAssertFalse(binding.matches(on(0, 21)))
        XCTAssertNil(MIDIBinding(off(0, 20)), "a release alone isn't learned")
    }

    func testLearnedPitchBendMatchesAnyValue() throws {
        let binding = try XCTUnwrap(MIDIBinding(bend(4, 100)))
        XCTAssertTrue(binding.matches(bend(4, 16000)))
        XCTAssertFalse(binding.matches(bend(5, 100)))
    }
}
