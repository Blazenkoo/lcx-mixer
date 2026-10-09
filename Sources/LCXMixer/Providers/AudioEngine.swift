import AudioToolbox
import CoreAudio
import Foundation

/// Owns one ProcessTap per native source that has been put on a channel.
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

    func hasTap(_ id: String) -> Bool { taps[id] != nil }
    func gain(id: String) -> Float? { taps[id]?.gain }

    /// Whether taps measure levels (only while a meter is visible).
    private var metering = false
    func setMetering(_ on: Bool) {
        metering = on
        for tap in taps.values { tap.metering = on }
    }

    /// Creates or updates the tap for a source. Rebuilds it when the set of processes changed.
    func ensureTap(id: String, processObjects: [AudioObjectID], gain: Float) {
        let objects = Array(Set(processObjects)).sorted()
        if let existing = taps[id] {
            if existing.processObjects == objects {
                existing.gain = gain
                return
            }
            existing.stop()
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

    func setGain(id: String, _ gain: Float) {
        taps[id]?.gain = gain
    }

    func removeTap(id: String) {
        taps[id]?.stop()
        taps[id] = nil
    }

    func level(id: String) -> Float { taps[id]?.level ?? 0 }

    func stopAll() {
        for tap in taps.values { tap.stop() }
        taps.removeAll()
    }

    private func defaultOutputChanged() {
        let device = CA.defaultOutputDevice()
        guard device != outputDevice else { return }
        outputDevice = device
        log("Output device changed to", outputName)
        // Restart every tap on the new device, keeping its gain.
        for (id, tap) in taps {
            let gain = tap.gain
            let objects = tap.processObjects
            tap.stop()
            let fresh = ProcessTap(processObjects: objects, gain: gain)
            fresh.metering = metering
            if fresh.start(outputDevice: device) {
                taps[id] = fresh
            } else {
                taps[id] = nil
                onTapFailure?(id)
            }
        }
        onOutputDeviceChange?()
    }
}
