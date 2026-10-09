import Foundation

/// What a control on the hardware asks the mixer to do, independent of the device.
/// Channels are zero-based; positions are 0…1.
enum ControllerAction {
    case fader(channel: Int, position: Float)
    /// The per-channel play/pause button went down or up (held for 3 s = reload the tab).
    case playButton(channel: Int, pressed: Bool)
    /// The per-channel mute button went down or up (held for 1 s = unassign).
    case muteButton(channel: Int, pressed: Bool)
    /// The mute-all button was pressed (silences all media playback).
    case muteAll
    /// The microphone button was pressed (silences the Mac's current microphone).
    case micMute
    case speedKnob(channel: Int, position: Float)
    case seekKnob(channel: Int, position: Float)
}

/// A device-independent light colour. Each driver maps these to what its hardware can show.
enum LightColor: Equatable {
    case off, green, greenDim, amber, red, redDim, yellow, greenBlink, redBlink, amberBlink
}

/// The lights for one channel column.
struct ChannelLights: Equatable {
    var playButton: LightColor = .off
    var muteButton: LightColor = .off
    var seekKnob: LightColor = .off
    var speedKnob: LightColor = .off
    /// Where a motorised fader should sit (0…1); devices without motors ignore it.
    var fader: Float?
    /// Short texts for devices with displays: the source's name, and its volume or state.
    var name = ""
    var detail = ""
}

/// Everything a controller can light up, as the mixer wants it right now.
struct ControllerLights: Equatable {
    var channels: [ChannelLights]
    var muteAll: LightColor = .off
    var micMute: LightColor = .off
}

/// A piece of hardware the mixer can be controlled from. Callbacks arrive on the main thread.
@MainActor
protocol ControllerDriver: AnyObject {
    /// Shown in the UI, e.g. "Launch Control XL".
    var displayName: String { get }
    var isConnected: Bool { get }
    var onAction: ((ControllerAction) -> Void)? { get set }
    var onConnectionChange: ((Bool) -> Void)? { get set }
    /// The device was (re)initialised and needs every light sent again.
    var onNeedsLights: (() -> Void)? { get set }
    func start()
    /// Shows the lights; drivers send only what changed since last time.
    func show(_ lights: ControllerLights)
    /// Turns every light off (used when the app quits).
    func clearLights()
    /// Lets go of the device (used when switching to another controller).
    func stop()
    /// Motorised faders follow each channel's volume, so they never need soft takeover.
    var hasMotorisedFaders: Bool { get }
}

extension ControllerDriver {
    var hasMotorisedFaders: Bool { false }
}
