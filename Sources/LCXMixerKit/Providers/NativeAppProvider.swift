import AppKit
import CoreAudio

/// Source provider for native apps: finds which apps are producing sound (grouped by the user's
/// app groups) and controls an app's volume through a Core Audio process tap.
@MainActor
final class NativeAppProvider {
    private let monitor: AudioProcessMonitor
    private let engine: AudioEngine

    init(settings: AppSettings, engine: AudioEngine) {
        self.monitor = AudioProcessMonitor(settings: settings)
        self.engine = engine
    }

    // MARK: - Discovery

    /// Apps with audio processes right now, keyed by app or group key.
    func snapshot() -> [String: NativeAppSnapshot] { monitor.snapshot() }

    /// Keys of every running app (or group), whether or not it plays sound.
    func runningKeys() -> Set<String> { monitor.runningKeys() }

    /// Called when native audio changes (an app starts or stops sound, or quits).
    var onChange: (() -> Void)? {
        get { monitor.onChange }
        set { monitor.onChange = newValue }
    }

    func startListening() { monitor.startListening() }

    // MARK: - Control

    /// A tap that controls the app's volume (below 100% or muted).
    func isControlling(_ id: String) -> Bool { engine.isControlling(id) }

    /// Whether the app's level can be measured: it has a tap, controlling or only listening.
    func canMeasure(_ id: String) -> Bool { engine.hasTap(id) }

    /// True while a meter is on screen: then apps at 100% get a tap that only listens.
    private var metering = false

    /// Taps that just went back to 100%, or lost their meter, are settled after a short pause.
    private var settleWork: [String: DispatchWorkItem] = [:]

    /// Whether each app was producing sound when last applied. Only those get a listening tap:
    /// an app that's quiet has no level to show.
    private var playing: [String: Bool] = [:]
    private func wantsMeter(_ id: String) -> Bool { metering && (playing[id] ?? false) }

    /// Applies a source's effective gain. An app at full volume plays untouched. With no meter on
    /// screen, that means no tap at all: no audio work and no purple recording dot. While a meter
    /// is on screen, a tap only listens, to measure the level. Below 100% (or muted), the tap
    /// controls the volume. Going back to 100%, it stays in control for 2 s, so a fader resting
    /// near the top doesn't hand over again and again, then listens or lets go.
    func apply(_ id: String, processObjects: [AudioObjectID], gain: Float, playing isPlaying: Bool) {
        playing[id] = isPlaying
        switch TapPolicy.need(gain: gain, wantsMeter: wantsMeter(id)) {
        case .control:
            settleWork.removeValue(forKey: id)?.cancel()
            engine.ensureTap(id: id, processObjects: processObjects, gain: gain)
        case .listen, .untouched:
            if engine.isControlling(id) {
                engine.ensureTap(id: id, processObjects: processObjects, gain: 1)
                scheduleSettle(id)
            } else {
                listen(id, processObjects: processObjects, playing: isPlaying)
            }
        }
    }

    /// For an app that needs no volume control: a tap that only listens while a meter is on screen
    /// and the app is playing.
    func listen(_ id: String, processObjects: [AudioObjectID], playing isPlaying: Bool) {
        playing[id] = isPlaying
        guard !engine.isControlling(id) else { return }
        if wantsMeter(id) {
            settleWork.removeValue(forKey: id)?.cancel()
            engine.ensureListening(id: id, processObjects: processObjects)
        } else if engine.hasTap(id) {
            scheduleSettle(id)
        }
    }

    func release(_ id: String) {
        settleWork.removeValue(forKey: id)?.cancel()
        playing[id] = nil
        engine.removeTap(id: id)
    }

    /// Level measurement in the taps, only while a meter is on screen. When the last meter goes,
    /// the listening taps follow 2 s later, so closing and reopening the panel doesn't stop and
    /// start them. (When a meter appears, MixerCore asks for the taps it needs.)
    func setMetering(_ on: Bool) {
        metering = on
        engine.setMetering(on)
        if !on {
            for id in engine.listeningIDs { scheduleSettle(id) }
        }
    }

    func level(_ id: String) -> Float { engine.level(id: id) }

    private func scheduleSettle(_ id: String) {
        guard settleWork[id] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.settle(id) }
        }
        settleWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func settle(_ id: String) {
        settleWork[id] = nil
        guard engine.hasTap(id) else { return }
        switch TapPolicy.settle(controlling: engine.isControlling(id), gain: engine.gain(id: id) ?? 1, wantsMeter: wantsMeter(id)) {
        case .keep: break
        case .listen: engine.handBack(id: id)
        case .remove: engine.removeTap(id: id)
        }
    }

    func releaseAll() {
        settleWork.values.forEach { $0.cancel() }
        settleWork.removeAll()
        playing.removeAll()
        engine.stopAll()
    }

    /// Brings the app owning one of these processes to the front.
    func focus(pids: [pid_t]) {
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.activate()
                return
            }
        }
    }
}
