import Foundation

/// Novation Launch Control XL mk2 on Factory Template 1: everything specific to this device lives here.
@MainActor
final class LaunchControlXLDriver: ControllerDriver {
    let displayName = "Launch Control XL"
    var onAction: ((ControllerAction) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNeedsLights: (() -> Void)?

    private let midi = MIDIController(needsOutput: true) { $0.localizedCaseInsensitiveContains("Launch Control XL") }
    /// Last value sent per LED, so only changes go out. Buttons are keyed by note, knobs by 1000 + index.
    private var sent: [Int: UInt8] = [:]

    var isConnected: Bool { midi.isConnected }

    func start() {
        midi.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        midi.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.connectionChanged(connected) } }
        midi.start()
    }

    func show(_ lights: ControllerLights) {
        guard midi.isConnected else { return }
        var buttons: [(UInt8, LCXL.Color)] = []
        var knobs: [(UInt8, LCXL.Color)] = []
        for (ch, c) in lights.channels.enumerated() where ch < LCXL.topButtonNotes.count {
            knobs.append((UInt8(8 + ch), Self.color(c.seekKnob)))
            knobs.append((UInt8(16 + ch), Self.color(c.speedKnob)))
            buttons.append((LCXL.topButtonNotes[ch], Self.color(c.playButton)))
            buttons.append((LCXL.bottomButtonNotes[ch], Self.color(c.muteButton)))
        }
        // The side buttons (Device, Mute, Solo, Record Arm) only have a yellow LED: any colour shows as yellow.
        buttons.append((LCXL.muteNote, Self.sideColor(lights.muteAll)))
        buttons.append((LCXL.soloNote, Self.sideColor(lights.micMute)))
        for (note, color) in buttons where sent[Int(note)] != color.rawValue {
            midi.send(LCXL.led(note: note, color))
            sent[Int(note)] = color.rawValue
        }
        for (index, color) in knobs where sent[1000 + Int(index)] != color.rawValue {
            midi.send(LCXL.knobLED(index: index, color))
            sent[1000 + Int(index)] = color.rawValue
        }
    }

    func clearLights() {
        if midi.isConnected { midi.send(LCXL.resetLEDs) }
    }

    func stop() {
        clearLights()
        midi.stop()
    }

    // MARK: - Device handling

    private func connectionChanged(_ connected: Bool) {
        sent.removeAll()
        onConnectionChange?(connected)
        guard connected else { return }
        midi.send(LCXL.selectFactoryTemplate1)
        after(0.15) { [weak self] in
            guard let self else { return }
            self.midi.send(LCXL.resetLEDs)
            self.midi.send(LCXL.enableFlashing)
            self.sent.removeAll()
            self.onNeedsLights?()
        }
    }

    /// Factory Template 1 map. The MIDI channel isn't checked, as before.
    /// Internal rather than private so tests can feed it messages.
    func handle(_ m: MIDIMessage) {
        switch m.kind {
        case .controlChange:
            let p = Float(m.value) / 127
            if let ch = LCXL.faderCCs.firstIndex(of: m.number) {
                onAction?(.fader(channel: ch, position: p))
            } else if let ch = LCXL.seekKnobCCs.firstIndex(of: m.number) {
                onAction?(.seekKnob(channel: ch, position: p))
            } else if let ch = LCXL.speedKnobCCs.firstIndex(of: m.number) {
                onAction?(.speedKnob(channel: ch, position: p))
            }
        case .noteOn, .noteOff:
            let pressed = m.kind == .noteOn
            if let ch = LCXL.topButtonNotes.firstIndex(of: m.number) {
                onAction?(.playButton(channel: ch, pressed: pressed))
            } else if let ch = LCXL.bottomButtonNotes.firstIndex(of: m.number) {
                onAction?(.muteButton(channel: ch, pressed: pressed))
            } else if m.number == LCXL.muteNote {
                if pressed { onAction?(.muteAll) }
            } else if m.number == LCXL.soloNote {
                if pressed { onAction?(.micMute) }
            }
        case .pitchBend:
            break
        }
    }

    static func sideColor(_ c: LightColor) -> LCXL.Color {
        c == .off ? .off : .yellow
    }

    static func color(_ c: LightColor) -> LCXL.Color {
        switch c {
        case .off: return .off
        case .green: return .green
        case .greenDim: return .greenLow
        case .amber: return .amber
        case .amberBlink: return .amberFlash
        case .red: return .red
        case .redDim: return .redLow
        case .yellow: return .yellow
        case .greenBlink: return .greenFlash
        case .redBlink: return .redFlash
        }
    }
}
