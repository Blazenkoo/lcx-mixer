import AudioToolbox
import CoreAudio
import Foundation
import os

/// Owns one ProcessTap per native source that has one: to control its volume, or only to
/// listen for a meter.
@MainActor
final class AudioEngine {
    private var taps: [String: ProcessTap] = [:]
    private(set) var outputDevice: AudioObjectID = CA.defaultOutputDevice()
    var onOutputDeviceChange: (() -> Void)?
    var onTapFailure: ((String) -> Void)?

    init() {
        var addr = CA.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(CA.system, &addr, DispatchQueue.main) { [weak self] _, _ in
            onMain { self?.defaultOutputChanged() }
        }
    }

    var outputName: String { CA.deviceName(outputDevice) }
    var masterSupported: Bool { CA.masterVolumeSupported(outputDevice) }
    var masterVolume: Float? { CA.masterVolume(outputDevice) }
    func setMasterVolume(_ value: Float) { CA.setMasterVolume(outputDevice, value) }

    /// Any tap: controlling the volume or only listening.
    func hasTap(_ id: String) -> Bool { taps[id] != nil }
    /// A tap that controls the volume (not one that only listens).
    func isControlling(_ id: String) -> Bool { taps[id].map { !$0.isListening } ?? false }
    var listeningIDs: [String] { taps.filter { $0.value.isListening }.map(\.key) }
    func gain(id: String) -> Float? { taps[id]?.gain }

    /// Whether taps measure levels (only while a meter is visible).
    private var metering = false
    func setMetering(_ on: Bool) {
        metering = on
        for tap in taps.values { tap.metering = on }
    }

    /// Creates or updates the tap that controls a source's volume. A listening tap takes over,
    /// with a crossfade. Rebuilds the tap when the set of processes changed.
    func ensureTap(id: String, processObjects: [AudioObjectID], gain: Float) {
        let objects = Array(Set(processObjects)).sorted()
        if let existing = taps[id] {
            if existing.processObjects == objects {
                existing.gain = gain
                if existing.isListening && !existing.takeOver(outputDevice: outputDevice) {
                    taps[id] = nil
                    onTapFailure?(id)
                }
                return
            }
            existing.stopSeamlessly()
            taps[id] = nil
        }
        guard !objects.isEmpty else { return }
        let tap = ProcessTap(processObjects: objects, gain: gain)
        tap.metering = metering
        if tap.start(outputDevice: outputDevice) {
            taps[id] = tap
        } else {
            onTapFailure?(id)
        }
    }

    /// Processes a listening tap couldn't be started for, so it isn't tried again and again.
    private var listenFailed: [String: [AudioObjectID]] = [:]

    /// A tap that only listens, for a meter: the app keeps playing as it is. Rebuilds the tap
    /// when the set of processes changed. A controlling tap is left as it is.
    func ensureListening(id: String, processObjects: [AudioObjectID]) {
        let objects = Array(Set(processObjects)).sorted()
        if let existing = taps[id] {
            guard existing.isListening, existing.processObjects != objects else { return }
            existing.stopSeamlessly()
            taps[id] = nil
        }
        guard !objects.isEmpty, listenFailed[id] != objects else { return }
        let tap = ProcessTap(processObjects: objects, gain: 1)
        tap.metering = metering
        if tap.start(outputDevice: outputDevice, listenOnly: true) {
            taps[id] = tap
            listenFailed[id] = nil
        } else {
            listenFailed[id] = objects
            Log.audio.info("Could not measure the level of \(id, privacy: .public)")
        }
    }

    /// From controlling back to listening: the app's own sound returns and the tap stays for the meter.
    func handBack(id: String) {
        guard let tap = taps[id] else { return }
        tap.gain = 1
        if !tap.handBack() {
            // The sound couldn't be handed back while running: listen with a fresh tap instead.
            let objects = tap.processObjects
            tap.stop()
            taps[id] = nil
            ensureListening(id: id, processObjects: objects)
        }
    }

    func setGain(id: String, _ gain: Float) {
        taps[id]?.gain = gain
    }

    /// Hands the app's sound back to it with a short crossfade, then removes the tap.
    func removeTap(id: String) {
        taps[id]?.stopSeamlessly()
        taps[id] = nil
        listenFailed[id] = nil
    }

    func level(id: String) -> Float { taps[id]?.level ?? 0 }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
        listenFailed.removeAll()
    }

    private func defaultOutputChanged() {
        let device = CA.defaultOutputDevice()
        guard device != outputDevice else { return }
        outputDevice = device
        let name = outputName
        Log.audio.info("Output device changed to \(name, privacy: .public)")
        // Restart every tap on the new device, keeping its gain, and listening if it was.
        listenFailed.removeAll()
        for (id, tap) in taps {
            let gain = tap.gain
            let objects = tap.processObjects
            let listening = tap.isListening
            tap.stop()
            let fresh = ProcessTap(processObjects: objects, gain: gain)
            fresh.metering = metering
            if fresh.start(outputDevice: device, listenOnly: listening) {
                taps[id] = fresh
            } else {
                taps[id] = nil
                if !listening { onTapFailure?(id) }
            }
        }
        onOutputDeviceChange?()
    }
}
