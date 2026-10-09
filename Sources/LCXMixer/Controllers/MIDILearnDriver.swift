import Foundation

/// Something a control can be assigned to with MIDI learn.
enum LearnTarget: Hashable, Identifiable {
    case fader(Int)
    case playPause(Int)
    case mute(Int)
    case muteAll
    case microphone

    var id: String { key }

    /// Stable key for saving an assignment.
    var key: String {
        switch self {
        case .fader(let ch): return "fader.\(ch)"
        case .playPause(let ch): return "play.\(ch)"
        case .mute(let ch): return "mute.\(ch)"
        case .muteAll: return "muteAll"
        case .microphone: return "microphone"
        }
    }

    var label: String {
        switch self {
        case .fader(let ch): return "Channel \(ch + 1) volume"
        case .playPause(let ch): return "Channel \(ch + 1) play/pause"
        case .mute(let ch): return "Channel \(ch + 1) mute"
        case .muteAll: return "Mute all media"
        case .microphone: return "Microphone mute"
        }
    }

    var isFader: Bool { if case .fader = self { return true } else { return false } }
}

/// One learned control: which kind of message, on which MIDI channel, with which number.
struct MIDIBinding: Codable, Equatable {
    enum Kind: String, Codable { case controlChange, note, pitchBend }
    let kind: Kind
    let channel: UInt8
    let number: UInt8

    init?(_ m: MIDIMessage) {
        switch m.kind {
        case .controlChange: kind = .controlChange
        case .noteOn: kind = .note
        case .pitchBend: kind = .pitchBend
        case .noteOff: return nil // a release says nothing new
        }
        channel = m.channel
        number = m.kind == .pitchBend ? 0 : m.number
    }

    func matches(_ m: MIDIMessage) -> Bool {
        guard m.channel == channel else { return false }
        switch kind {
        case .controlChange: return m.kind == .controlChange && m.number == number
        case .note: return (m.kind == .noteOn || m.kind == .noteOff) && m.number == number
        case .pitchBend: return m.kind == .pitchBend
        }
    }

    /// Short text for the Settings table, e.g. "CC 7 · ch 1".
    var summary: String {
        switch kind {
        case .controlChange: return "CC \(number) · ch \(channel + 1)"
        case .note: return "Note \(number) · ch \(channel + 1)"
        case .pitchBend: return "Pitch bend · ch \(channel + 1)"
        }
    }
}

/// Any MIDI controller, set up by MIDI learn: each fader or button is assigned by moving it.
/// There's no light feedback, because every device lights its buttons differently.
@MainActor
final class MIDILearnDriver: ControllerDriver {
    var onAction: ((ControllerAction) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    var onNeedsLights: (() -> Void)?
    /// While set, the next control moved is assigned to this target instead of acting.
    var learning: LearnTarget?
    var onLearned: ((LearnTarget, MIDIBinding) -> Void)?

    private let settings: AppSettings
    private let deviceName: String
    private let midi: MIDIController

    init(settings: AppSettings) {
        self.settings = settings
        let wanted = settings.midiDevice
        self.deviceName = wanted
        self.midi = MIDIController(needsOutput: false) { name in !wanted.isEmpty && name == wanted }
    }

    var displayName: String { deviceName.isEmpty ? "MIDI controller" : deviceName }
    var isConnected: Bool { midi.isConnected }

    func start() {
        midi.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handle(message) } }
        midi.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.onConnectionChange?(connected) } }
        midi.start()
    }

    func show(_ lights: ControllerLights) {}
    func clearLights() {}
    func stop() { midi.stop() }

    private func handle(_ m: MIDIMessage) {
        if let target = learning {
            guard let binding = MIDIBinding(m) else { return }
            // A fader needs something continuous; a short tap of a button can't be a fader.
            if target.isFader && binding.kind == .note { return }
            learning = nil
            onLearned?(target, binding)
            return
        }
        for (key, binding) in settings.midiBindings where binding.matches(m) {
            guard let target = Self.target(forKey: key) else { continue }
            act(target, m)
        }
    }

    private func act(_ target: LearnTarget, _ m: MIDIMessage) {
        // Buttons: a note-on, or a controller value of 64 or more, is a press.
        let pressed: Bool
        switch m.kind {
        case .noteOn: pressed = true
        case .noteOff: pressed = false
        case .controlChange: pressed = m.value >= 64
        case .pitchBend: pressed = m.value >= 8192
        }
        switch target {
        case .fader(let ch):
            let position = m.kind == .pitchBend ? Float(m.value) / 16383 : Float(m.value) / 127
            onAction?(.fader(channel: ch, position: position))
        case .playPause(let ch):
            if pressed { onAction?(.playPause(channel: ch)) }
        case .mute(let ch):
            onAction?(.muteButton(channel: ch, pressed: pressed))
        case .muteAll:
            if pressed { onAction?(.muteAll) }
        case .microphone:
            if pressed { onAction?(.micMute) }
        }
    }

    static let allTargets: [LearnTarget] =
        (0..<8).flatMap { [LearnTarget.fader($0), .playPause($0), .mute($0)] } + [.muteAll, .microphone]

    static func target(forKey key: String) -> LearnTarget? {
        allTargets.first { $0.key == key }
    }
}
