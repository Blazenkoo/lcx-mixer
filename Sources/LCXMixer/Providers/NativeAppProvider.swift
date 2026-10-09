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

    // MARK: - Control

    func isControlling(_ id: String) -> Bool { engine.hasTap(id) }

    /// Starts or updates control of a source's processes at the given gain.
    func control(_ id: String, processObjects: [AudioObjectID], gain: Float) {
        engine.ensureTap(id: id, processObjects: processObjects, gain: gain)
    }

    func setGain(_ id: String, _ gain: Float) { engine.setGain(id: id, gain) }

    /// Stops controlling a source; its audio returns to normal.
    func release(_ id: String) { engine.removeTap(id: id) }

    func level(_ id: String) -> Float { engine.level(id: id) }

    func releaseAll() { engine.stopAll() }

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
