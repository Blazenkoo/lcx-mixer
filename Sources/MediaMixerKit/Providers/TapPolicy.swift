/// What a native app's tap should do, worked out from plain values so it can be tested on its own.
enum TapPolicy {
    enum Need: Equatable {
        /// Below 100% or muted: the tap sets the volume.
        case control
        /// At 100%, playing, with a meter on screen: the tap only listens, to measure the level.
        case listen
        /// At 100% with no meter on screen, or quiet: no tap, the app plays untouched.
        case untouched
    }

    static func need(gain: Float, wantsMeter: Bool) -> Need {
        if gain < 0.999 { return .control }
        return wantsMeter ? .listen : .untouched
    }

    enum Settle: Equatable {
        /// Still needed as it is.
        case keep
        /// Back at 100% with a meter on screen: hand the sound back, keep listening.
        case listen
        /// Not needed any more: hand the sound back and remove the tap.
        case remove
    }

    /// Decided a moment after a tap went back to 100%, after the last meter left the screen, or
    /// after the app went quiet. `wantsMeter`: a meter is on screen and the app is playing.
    static func settle(controlling: Bool, gain: Float, wantsMeter: Bool) -> Settle {
        if controlling {
            if gain < 0.999 { return .keep }   // turned down again meanwhile
            return wantsMeter ? .listen : .remove
        }
        return wantsMeter ? .keep : .remove
    }
}
