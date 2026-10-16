import Foundation

/// Notices when a source the mute list silences keeps trying to make sound, so the mixer can say
/// so. Say WhatsApp is on the mute list and you play a video in it: you'd hear nothing and not know
/// why. Short sounds, such as the notification pings that are the usual reason to mute an app,
/// don't count.
struct PlayAttempts {
    /// Sound for this long counts as trying to play.
    static let sustained: TimeInterval = 3
    /// How long after the sound stops the state clears.
    static let settle: TimeInterval = 3
    /// The pop-up for one source shows at most this often.
    static let popUpInterval: TimeInterval = 600

    private var soundSince: [String: Date] = [:]
    private var quietSince: [String: Date] = [:]
    private var lastPopUp: [String: Date] = [:]
    /// Silenced sources trying to play right now.
    private(set) var trying: Set<String> = []

    /// Takes which silenced sources are making sound at `now` (every silenced source, sounding or
    /// not). Returns the sources that just started trying to play and are due a pop-up, and how
    /// long until something could change without new input (nil: nothing pending).
    mutating func update(sounding: [String: Bool], now: Date) -> (popUps: [String], recheck: TimeInterval?) {
        var popUps: [String] = []
        var recheck: TimeInterval?
        func soonest(_ t: TimeInterval) { recheck = min(recheck ?? t, t) }

        // Sources no longer silenced are forgotten (the pop-up limit is kept).
        for id in Set(soundSince.keys).union(quietSince.keys).union(trying) where sounding[id] == nil {
            soundSince[id] = nil
            quietSince[id] = nil
            trying.remove(id)
        }

        for (id, isSounding) in sounding {
            if isSounding {
                quietSince[id] = nil
                let since = soundSince[id] ?? now
                soundSince[id] = since
                guard !trying.contains(id) else { continue }
                let elapsed = now.timeIntervalSince(since)
                if elapsed >= Self.sustained {
                    trying.insert(id)
                    if lastPopUp[id].map({ now.timeIntervalSince($0) >= Self.popUpInterval }) ?? true {
                        lastPopUp[id] = now
                        popUps.append(id)
                    }
                } else {
                    soonest(Self.sustained - elapsed)
                }
            } else {
                soundSince[id] = nil
                guard trying.contains(id) else {
                    quietSince[id] = nil
                    continue
                }
                let quiet = quietSince[id] ?? now
                quietSince[id] = quiet
                let elapsed = now.timeIntervalSince(quiet)
                if elapsed >= Self.settle {
                    trying.remove(id)
                    quietSince[id] = nil
                } else {
                    soonest(Self.settle - elapsed)
                }
            }
        }
        return (popUps.sorted(), recheck)
    }
}
