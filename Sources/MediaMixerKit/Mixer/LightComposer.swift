import Foundation

/// Works out what every light on the controller shows. Plain values in, lights out: MixerCore
/// gathers what sits on each channel and hands the result to the controller driver.
enum LightComposer {
    /// What sits on one channel, as far as the lights are concerned.
    enum Channel {
        case empty
        /// Master mode: channel 1 is the output device's volume.
        case master(volume: Float)
        /// `position`: the fader position for the source's volume. `blinking`: just placed on the
        /// channel. `seeking`: how far the seek knob is turned while it's seeking, else nil.
        case source(Source, position: Float, blinking: Bool, seeking: Float?)
    }

    static func lights(for channels: [Channel], muteAll: Bool, micMuted: Bool) -> ControllerLights {
        var lights = ControllerLights(channels: channels.map { light(for: $0, muteAll: muteAll) })
        lights.muteAll = muteAll ? .yellow : .off
        lights.micMute = micMuted ? .red : .off
        return lights
    }

    static func light(for channel: Channel, muteAll: Bool) -> ChannelLights {
        var c = ChannelLights()
        switch channel {
        case .empty:
            break
        case let .master(volume):
            c.fader = volume
            c.name = "Master"
            c.detail = percent(volume)
        case let .source(s, position, blinking, seeking):
            c.fader = position
            c.name = s.displayName
            c.detail = s.isMuted || muteAll ? "Muted" : percent(position)
            if s.canSpeed {
                if s.speed > 1.001 { c.speedKnob = .green } else if s.speed < 0.999 { c.speedKnob = .red }
            }
            if s.canSeek, let seeking {
                c.seekKnob = seeking > 0 ? .green : .red
            }
            if s.kind == .tab {
                c.playButton = s.unmutedStatus == .playing ? .green : .amber
            } else {
                // Native apps have no play/pause; dim green says "in use" without promising one.
                c.playButton = .greenDim
            }
            if blinking { c.playButton = .greenBlink }
            // Lost its connection to the extension: blink, so a 3-second hold of play reloads it.
            if s.needsReload {
                c.playButton = .amberBlink
                c.detail = "Reload"
            }
            if muteAll {
                c.muteButton = .redBlink
            } else if s.isMuted {
                c.muteButton = .red
            } else if s.kind == .tab && !s.canSetVolume {
                c.muteButton = .redDim
            }
        }
        return c
    }
}
