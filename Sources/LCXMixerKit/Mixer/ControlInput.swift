import Foundation

/// Faders, knobs and buttons: soft takeover, the speed and seek knobs, and quick double presses.
/// It keeps each channel's control state and decides what a move means; MixerCore carries it
/// out (volumes, speeds, pop-ups, lights).
struct ControlInput {
    init(channels: Int) {
        speedAttached = Array(repeating: false, count: channels)
        speedPrev = Array(repeating: nil, count: channels)
        seekDeflection = Array(repeating: 0, count: channels)
        seekArmed = Array(repeating: false, count: channels)
    }

    /// A different source on the channel: its knobs start over.
    mutating func reset(_ ch: Int) {
        speedAttached[ch] = false
        speedPrev[ch] = nil
        seekArmed[ch] = false
        seekDeflection[ch] = 0
    }

    // MARK: - Faders

    /// Soft takeover: a fader drives a level only once it has met it, so moving it never makes
    /// the volume jump. Returns the fader's new state.
    static func takeover(_ fader: FaderState, movedTo p: Float, target: Float, motorised: Bool) -> FaderState {
        var f = fader
        // A motorised fader was moved to the real level by the app, so it's always in charge.
        if motorised { f.attached = true }
        if !f.attached {
            if p < target {
                // Fader is below the current level: jumping down is always safe, take over at once.
                f.attached = true
            } else if abs(p - target) < 0.03 {
                f.attached = true
            } else if let prev = f.position, (prev - target) * (p - target) <= 0 {
                f.attached = true
            }
        }
        f.position = p
        return f
    }

    /// Hint shown while a fader waits for soft takeover, nil when it's in charge.
    static func takeoverHint(_ f: FaderState, target: Float) -> String? {
        guard !f.attached, let p = f.position else { return nil }
        // Below the current level the next touch takes over immediately, so only "above" needs a hint.
        if p <= target + 0.03 { return nil }
        return "Move fader down"
    }

    // MARK: - Speed knob (bottom row)

    static let speedSteps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Centre = 1×, left end = 0.5×, right end = 2×, in fixed steps.
    static func speed(forKnob p: Float) -> Float {
        if p <= 0.5 {
            let i = Int((p / 0.5 * 2).rounded())            // 0…2 → 0.5, 0.75, 1
            return speedSteps[max(0, min(2, i))]
        }
        let i = Int(((p - 0.5) / 0.5 * 4).rounded())        // 0…4 → 1 … 2
        return speedSteps[2 + max(0, min(4, i))]
    }

    /// "1×", "1.25×", "0.5×".
    static func speedLabel(_ speed: Float) -> String {
        let text = String(format: "%.2f", speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return text + "×"
    }

    /// What turning the speed knob means.
    enum SpeedMove: Equatable {
        /// Not in charge yet. `hint`: the knob moved to a new step, so say where to turn it.
        case waiting(hint: Bool)
        /// In charge, and the speed is already there.
        case unchanged
        case set(Float)
    }

    private var speedAttached: [Bool]
    private var speedPrev: [Float?]

    /// Like a fader, the knob takes over once it meets or passes the current speed.
    mutating func speedKnob(_ ch: Int, at p: Float, current: Float) -> SpeedMove {
        let speed = Self.speed(forKnob: p)
        if !speedAttached[ch] {
            if abs(speed - current) < 0.01 {
                speedAttached[ch] = true
            } else if let prev = speedPrev[ch], (prev - current) * (speed - current) <= 0 {
                speedAttached[ch] = true
            }
        }
        let previous = speedPrev[ch]
        speedPrev[ch] = speed
        guard speedAttached[ch] else { return .waiting(hint: previous != speed) }
        guard abs(speed - current) > 0.001 else { return .unchanged }
        return .set(speed)
    }

    /// The page changed its own speed: the knob has to pick it up again.
    mutating func detachSpeedKnob(_ ch: Int) { speedAttached[ch] = false }

    // MARK: - Seek knob (middle row)

    /// What turning the seek knob means.
    enum SeekMove: Equatable {
        /// The knob wasn't centred when the source arrived, so it does nothing until it passes centre.
        case notArmed
        /// Back at centre: stop seeking.
        case centred
        /// Turned away from centre: keep seeking while it stays there.
        case turned
    }

    /// How far each seek knob is turned from centre, −1…1 (0 at centre).
    private(set) var seekDeflection: [Float]
    private var seekArmed: [Bool]

    mutating func seekKnob(_ ch: Int, at p: Float) -> SeekMove {
        let d = (p - 0.5) * 2
        let centred = abs(d) < 0.12
        if !seekArmed[ch] {
            // Safety: a knob that wasn't centred when the source arrived does nothing until it passes centre.
            guard centred else { return .notArmed }
            seekArmed[ch] = true
        }
        seekDeflection[ch] = centred ? 0 : d
        return centred ? .centred : .turned
    }

    /// Seconds to jump on each step for a knob turned by `d`: the further, the bigger the jump.
    static func seekStep(_ d: Float) -> Float {
        let magnitude = abs(d)
        let step: Float = magnitude < 0.45 ? 5 : (magnitude < 0.8 ? 15 : 30)
        return d > 0 ? step : -step
    }

    // MARK: - Play button

    private var lastPlayPress: [Int: Date] = [:]

    /// Records a press of the play button. True when it's the second of a quick double press
    /// (within 0.4 s); only counted when `counting` (Twitch, where it jumps to live).
    mutating func playPressIsDouble(_ ch: Int, at now: Date, counting: Bool) -> Bool {
        if counting, let last = lastPlayPress[ch], now.timeIntervalSince(last) < 0.4 {
            lastPlayPress[ch] = nil
            return true
        }
        lastPlayPress[ch] = now
        return false
    }
}

/// Tells a short press of a channel's button from a long hold. While the button is down, an
/// optional hint runs first and the hold action later; letting go before then is a short press.
@MainActor
final class ButtonHold {
    private var pending: [Int: [DispatchWorkItem]] = [:]
    private var held = Set<Int>()

    /// Forgets the channel's last press: whatever was still to run is cancelled.
    func reset(_ ch: Int) {
        pending[ch]?.forEach { $0.cancel() }
        pending[ch] = nil
        held.remove(ch)
    }

    /// The button went down. `onHold` runs after `holdAfter` seconds if it's still down, and returns
    /// whether it did something (then letting go does nothing). `hint` runs after `hintAfter`.
    func press(_ ch: Int, holdAfter: TimeInterval, hintAfter: TimeInterval = 0, hint: (@MainActor () -> Void)? = nil,
               onHold: @escaping @MainActor () -> Bool) {
        reset(ch)
        var items: [DispatchWorkItem] = []
        if let hint {
            let item = DispatchWorkItem { MainActor.assumeIsolated { hint() } }
            DispatchQueue.main.asyncAfter(deadline: .now() + hintAfter, execute: item)
            items.append(item)
        }
        let hold = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                if onHold() { self?.held.insert(ch) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + holdAfter, execute: hold)
        items.append(hold)
        pending[ch] = items
    }

    /// The button came up: what hasn't run yet is cancelled. True for a short press, false when
    /// the hold already did its thing.
    func release(_ ch: Int) -> Bool {
        pending[ch]?.forEach { $0.cancel() }
        pending[ch] = nil
        return held.remove(ch) == nil
    }
}
