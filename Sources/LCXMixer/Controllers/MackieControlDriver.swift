import Foundation

/// Controllers that speak the Mackie Control (MCU) protocol, such as the Behringer X-Touch family.
/// Experimental: written from the protocol, not yet tested on hardware.
///
/// Layout used, per channel strip 1–8:
/// - Fader (pitch bend on MIDI channels 1–8): volume. Motorised faders move to each channel's level.
/// - Select button: play / pause. Mute button: mute, hold 1 s to unassign.
/// - Scribble strip: top row the source's name, bottom row its volume or state.
/// Global: F1 mutes all media, F2 mutes the microphone.
@MainActor
final class MackieControlDriver: ControllerDriver {
    var onAction: ((ControllerAction) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNeedsLights: (() -> Void)?

    let hasMotorisedFaders = true

    private let deviceName: String
    private let midi: MIDIController
    /// Last values sent, so only changes go out. Keys: note numbers, 1000 + fader, 2000/2001 for the two text rows.
    private var sentNotes: [UInt8: UInt8] = [:]
    private var sentFaders: [Int: Int] = [:]
    private var sentRows: [Int: String] = [:]
    private var sentColours: [UInt8] = []
    /// Faders under a finger aren't driven by the motor, so it never fights the hand.
    private var touched = Set<Int>()
    private var lastLights: ControllerLights?

    init(settings: AppSettings) {
        let wanted = settings.midiDevice
        deviceName = wanted
        midi = MIDIController(needsOutput: true) { name in
            wanted.isEmpty ? MackieControlDriver.looksLikeMackie(name) : name == wanted
        }
    }

    var displayName: String { deviceName.isEmpty ? "Mackie Control" : deviceName }
    var isConnected: Bool { midi.isConnected }

    /// Device names that usually mean a Mackie Control surface, for when no device is picked.
    static func looksLikeMackie(_ name: String) -> Bool {
        ["X-Touch", "MCU", "Mackie", "Control Universal", "Platform M", "Platform X"]
            .contains { name.localizedCaseInsensitiveContains($0) }
    }

    func start() {
        midi.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        midi.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.connectionChanged(connected) } }
        midi.start()
    }

    func show(_ lights: ControllerLights) {
        lastLights = lights
        guard midi.isConnected else { return }
        var notes: [(UInt8, UInt8)] = []
        for (ch, c) in lights.channels.prefix(8).enumerated() {
            notes.append((MCU.select + UInt8(ch), Self.led(c.playButton)))
            notes.append((MCU.mute + UInt8(ch), Self.led(c.muteButton)))
        }
        notes.append((MCU.f1, Self.led(lights.muteAll)))
        notes.append((MCU.f2, Self.led(lights.micMute)))
        for (note, value) in notes where sentNotes[note] != value {
            midi.send([0x90, note, value])
            sentNotes[note] = value
        }

        for (ch, c) in lights.channels.prefix(8).enumerated() where !touched.contains(ch) {
            let value = Int(((c.fader ?? 0) * 16383).rounded())
            guard sentFaders[ch] != value else { continue }
            midi.send([0xE0 | UInt8(ch), UInt8(value & 0x7F), UInt8((value >> 7) & 0x7F)])
            sentFaders[ch] = value
        }

        let channels = Array(lights.channels.prefix(8))
        sendRow(0, channels.map(\.name))
        sendRow(1, channels.map(\.detail))

        // Scribble-strip colours (X-Touch; other surfaces ignore the message).
        let colours = channels.map { Self.stripColour($0) }
        if colours != sentColours {
            midi.send([0xF0, 0x00, 0x00, 0x66, MCU.deviceID, 0x72] + colours + [0xF7])
            sentColours = colours
        }
    }

    func clearLights() {
        guard midi.isConnected else { return }
        for note in MCU.allLEDs { midi.send([0x90, note, 0]) }
        for ch in 0..<8 { midi.send([0xE0 | UInt8(ch), 0, 0]) }
        midi.send(Self.textMessage(offset: 0, String(repeating: " ", count: 112)))
        midi.send([0xF0, 0x00, 0x00, 0x66, MCU.deviceID, 0x72] + Array(repeating: 0, count: 8) + [0xF7])
        forgetSent()
    }

    func stop() {
        clearLights()
        midi.stop()
    }

    // MARK: - Private

    private func forgetSent() {
        sentNotes.removeAll()
        sentFaders.removeAll()
        sentRows.removeAll()
        sentColours = []
    }

    private func connectionChanged(_ connected: Bool) {
        forgetSent()
        touched.removeAll()
        onConnectionChange?(connected)
        guard connected else { return }
        after(0.2) { [weak self] in
            guard let self else { return }
            self.clearLights()
            self.onNeedsLights?()
        }
    }

    private func handle(_ m: MIDIMessage) {
        switch m.kind {
        case .pitchBend:
            let ch = Int(m.channel)
            guard ch < 8 else { return } // channel 9 is the master fader: not used yet
            // Some surfaces echo the motor's own moves: a value at the position just sent isn't the user.
            // (Surfaces without touch sensing still work, since any other value counts as a move.)
            if !touched.contains(ch), let sent = sentFaders[ch], abs(sent - m.value) < 96 { return }
            sentFaders[ch] = m.value // it's there now; don't send it back
            onAction?(.fader(channel: ch, position: Float(m.value) / 16383))
        case .noteOn, .noteOff:
            let pressed = m.kind == .noteOn && m.value > 0
            let n = m.number
            if (MCU.touch..<MCU.touch + 8).contains(n) {
                let ch = Int(n - MCU.touch)
                if pressed {
                    touched.insert(ch)
                } else {
                    touched.remove(ch)
                    // Let go: settle the fader on the channel's real level.
                    sentFaders[ch] = nil
                    if let lights = lastLights { show(lights) }
                }
            } else if (MCU.select..<MCU.select + 8).contains(n) {
                onAction?(.playButton(channel: Int(n - MCU.select), pressed: pressed))
            } else if (MCU.mute..<MCU.mute + 8).contains(n) {
                onAction?(.muteButton(channel: Int(n - MCU.mute), pressed: pressed))
            } else if n == MCU.f1 {
                if pressed { onAction?(.muteAll) }
            } else if n == MCU.f2 {
                if pressed { onAction?(.micMute) }
            }
        case .controlChange:
            break // V-Pots: not used yet
        }
    }

    /// One row of the scribble strips: 7 characters per channel, the last one a gap between strips.
    private func sendRow(_ row: Int, _ texts: [String]) {
        var line = ""
        for i in 0..<8 {
            let text = i < texts.count ? Self.ascii(texts[i]) : ""
            line += String(text.prefix(6)).padding(toLength: 7, withPad: " ", startingAt: 0)
        }
        guard sentRows[row] != line else { return }
        midi.send(Self.textMessage(offset: UInt8(row * 56), line))
        sentRows[row] = line
    }

    private static func textMessage(offset: UInt8, _ text: String) -> [UInt8] {
        [0xF0, 0x00, 0x00, 0x66, MCU.deviceID, 0x12, offset] + text.utf8.map { $0 & 0x7F } + [0xF7]
    }

    /// The displays show plain ASCII: accents are dropped, anything else becomes a space.
    private static func ascii(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .init(identifier: "en_US"))
        return String(folded.unicodeScalars.map { $0.isASCII && $0.value >= 32 ? Character($0) : " " })
    }

    /// Button LEDs are one colour: on, blinking or off.
    private static func led(_ c: LightColor) -> UInt8 {
        switch c {
        case .off, .greenDim, .amber, .redDim: return 0x00
        case .green, .red, .yellow: return 0x7F
        case .greenBlink, .redBlink, .amberBlink: return 0x01
        }
    }

    /// X-Touch strip colours: 0 off, 1 red, 2 green, 3 yellow, 7 white.
    private static func stripColour(_ c: ChannelLights) -> UInt8 {
        if c.name.isEmpty { return 0 }
        if c.muteButton == .red || c.muteButton == .redBlink { return 1 }
        switch c.playButton {
        case .green, .greenBlink: return 2
        case .amber: return 3
        default: return 7
        }
    }
}

/// Mackie Control note numbers (MIDI channel 1) and the main unit's SysEx device ID.
enum MCU {
    static let deviceID: UInt8 = 0x14
    static let mute: UInt8 = 0x10
    static let select: UInt8 = 0x18
    static let f1: UInt8 = 0x36
    static let f2: UInt8 = 0x37
    static let touch: UInt8 = 0x68
    static let allLEDs: [UInt8] = Array(0x00...0x1F) + [f1, f2]
}
