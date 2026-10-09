import Foundation

/// Novation Launch Control XL mk2 on Factory Template 1: everything specific to this device lives here.
@MainActor
final class LaunchControlXLDriver: ControllerDriver {
    let displayName = "Launch Control XL"
    var onAction: ((ControllerAction) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNeedsLights: (() -> Void)?

    private let midi = MIDIController()
    /// Last value sent per LED, so only changes go out. Buttons are keyed by note, knobs by 1000 + index.
    private var sent: [Int: UInt8] = [:]

    var isConnected: Bool { midi.isConnected }

    func start() {
        midi.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
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

    // MARK: - Private

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

    private func handle(_ event: ControllerEvent) {
        switch event {
        case let .fader(index, value):
            onAction?(.fader(channel: index, position: Float(value) / 127))
        case let .topButton(index, pressed):
            if pressed { onAction?(.playPause(channel: index)) }
        case let .bottomButton(index, pressed):
            onAction?(.muteButton(channel: index, pressed: pressed))
        case let .sideMute(pressed):
            if pressed { onAction?(.muteAll) }
        case let .sideSolo(pressed):
            if pressed { onAction?(.micMute) }
        case let .speedKnob(index, value):
            onAction?(.speedKnob(channel: index, position: Float(value) / 127))
        case let .seekKnob(index, value):
            onAction?(.seekKnob(channel: index, position: Float(value) / 127))
        }
    }

    private static func sideColor(_ c: LightColor) -> LCXL.Color {
        c == .off ? .off : .yellow
    }

    private static func color(_ c: LightColor) -> LCXL.Color {
        switch c {
        case .off: return .off
        case .green: return .green
        case .greenDim: return .greenLow
        case .amber: return .amber
        case .red: return .red
        case .redDim: return .redLow
        case .yellow: return .yellow
        case .greenBlink: return .greenFlash
        case .redBlink: return .redFlash
        }
    }
}
