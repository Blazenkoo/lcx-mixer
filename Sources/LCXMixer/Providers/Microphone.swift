import CoreAudio
import Foundation

/// Mutes the Mac's current microphone (default input device) for every app at once.
/// Uses the device's own mute where it has one; otherwise turns its input volume to zero and back.
/// It never reads or records the microphone.
@MainActor
final class Microphone {
    enum ToggleResult { case muted, unmuted, unsupported }

    /// Input volumes saved by the zero-volume fallback, per device UID, to put back on unmute.
    private var savedVolumes: [String: [UInt32: Float32]] = [:]
    /// Devices this app muted, so quitting can unmute them again.
    private var mutedByApp = Set<String>()
    /// After a change, the device can take a moment to report it; until then the app's own state counts.
    private var changedAt = Date.distantPast
    private var lastSet: (uid: String, muted: Bool)?

    var device: AudioObjectID { CA.get(CA.system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(kAudioObjectUnknown)) }
    var deviceName: String { CA.deviceName(device) }

    /// Whether the current microphone is muted (by this app or anything else).
    var isMuted: Bool {
        let d = device
        guard d != kAudioObjectUnknown else { return false }
        let uid = CA.deviceUID(d) ?? "\(d)"
        if let lastSet, lastSet.uid == uid, Date().timeIntervalSince(changedAt) < 2 { return lastSet.muted }
        let mutable = Self.elements(d).filter { Self.isSettable(d, kAudioDevicePropertyMute, $0) }
        if !mutable.isEmpty {
            // Muted if any element reports it: some devices mute through the main element, others per channel.
            return mutable.contains { Self.get(d, kAudioDevicePropertyMute, $0, UInt32(0)) != 0 }
        }
        return savedVolumes[uid] != nil
    }

    var isSupported: Bool {
        let d = device
        guard d != kAudioObjectUnknown else { return false }
        return Self.elements(d).contains {
            Self.isSettable(d, kAudioDevicePropertyMute, $0) || Self.isSettable(d, kAudioDevicePropertyVolumeScalar, $0)
        }
    }

    func toggle() -> ToggleResult {
        let d = device
        guard d != kAudioObjectUnknown, isSupported else { return .unsupported }
        let mute = !isMuted
        set(d, muted: mute)
        return mute ? .muted : .unmuted
    }

    /// Unmutes any microphone this app muted, so quitting never leaves a silent mic behind.
    func restore() {
        let d = device
        if let uid = CA.deviceUID(d), mutedByApp.contains(uid) { set(d, muted: false) }
    }

    // MARK: - Private

    private func set(_ d: AudioObjectID, muted: Bool) {
        let uid = CA.deviceUID(d) ?? "\(d)"
        let elements = Self.elements(d)
        let mutable = elements.filter { Self.isSettable(d, kAudioDevicePropertyMute, $0) }
        if muted { mutedByApp.insert(uid) } else { mutedByApp.remove(uid) }
        lastSet = (uid, muted)
        changedAt = Date()
        log("Microphone", muted ? "muted" : "unmuted", "via", mutable.isEmpty ? "input volume" : "mute (\(mutable.count) elements)")

        if !mutable.isEmpty {
            for e in mutable { Self.set(d, kAudioDevicePropertyMute, e, UInt32(muted ? 1 : 0)) }
            return
        }
        // Fallback: input volume to zero, and back to what it was.
        let adjustable = elements.filter { Self.isSettable(d, kAudioDevicePropertyVolumeScalar, $0) }
        if muted {
            var saved: [UInt32: Float32] = [:]
            for e in adjustable {
                saved[e] = Self.get(d, kAudioDevicePropertyVolumeScalar, e, Float32(1))
                Self.set(d, kAudioDevicePropertyVolumeScalar, e, Float32(0))
            }
            savedVolumes[uid] = saved
        } else {
            let saved = savedVolumes.removeValue(forKey: uid) ?? [:]
            for e in adjustable { Self.set(d, kAudioDevicePropertyVolumeScalar, e, saved[e] ?? Float32(1)) }
        }
    }

    /// The main element, then one per input channel.
    private static func elements(_ d: AudioObjectID) -> [UInt32] {
        [kAudioObjectPropertyElementMain] + (1...max(1, UInt32(inputChannelCount(d)))).map { $0 }
    }

    private static func inputChannelCount(_ d: AudioObjectID) -> Int {
        var addr = CA.address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(d, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func isSettable(_ d: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        guard AudioObjectHasProperty(d, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(d, &addr, &settable) == noErr && settable.boolValue
    }

    private static func get<T>(_ d: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ fallback: T) -> T {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        var value = fallback
        var size = UInt32(MemoryLayout<T>.size)
        return AudioObjectGetPropertyData(d, &addr, 0, nil, &size, &value) == noErr ? value : fallback
    }

    private static func set<T>(_ d: AudioObjectID, _ selector: AudioObjectPropertySelector, _ element: UInt32, _ value: T) {
        var addr = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeInput, mElement: element)
        var v = value
        let status = AudioObjectSetPropertyData(d, &addr, 0, nil, UInt32(MemoryLayout<T>.size), &v)
        if status != noErr { log("Microphone property change failed", status) }
    }
}
