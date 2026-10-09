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

    func isControlling(_ id: String) -> Bool { engine.hasTap(id) }

    /// Pending releases of taps that went back to full volume.
    private var releaseWork: [String: DispatchWorkItem] = [:]

    /// Applies a source's effective gain. An app at full volume plays untouched: no tap, no audio
    /// work, no purple recording dot. The tap starts only when the gain is below 100% (or muted),
    /// and is released again 2 s after the gain returns to 100%, so a fader resting near the top
    /// doesn't start and stop it over and over.
    func apply(_ id: String, processObjects: [AudioObjectID], gain: Float) {
        if gain < 0.999 {
            releaseWork.removeValue(forKey: id)?.cancel()
            engine.ensureTap(id: id, processObjects: processObjects, gain: gain)
        } else if engine.hasTap(id) {
            engine.ensureTap(id: id, processObjects: processObjects, gain: 1)
            guard releaseWork[id] == nil else { return }
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.releaseWork[id] = nil
                    if (self.engine.gain(id: id) ?? 1) >= 0.999 { self.engine.removeTap(id: id) }
                }
            }
            releaseWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Stops controlling a source; its audio returns to normal.
    func release(_ id: String) {
        releaseWork.removeValue(forKey: id)?.cancel()
        engine.removeTap(id: id)
    }

    /// Level measurement in the taps, only while a meter is on screen.
    func setMetering(_ on: Bool) { engine.setMetering(on) }

    func level(_ id: String) -> Float { engine.level(id: id) }

    func releaseAll() {
        releaseWork.values.forEach { $0.cancel() }
        releaseWork.removeAll()
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
