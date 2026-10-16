import AudioToolbox
import CoreAudio
import Foundation
import os

/// Small wrappers around the CoreAudio property API.
enum CA {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector,
                        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func get<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                       default fallback: T) -> T {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<T>.size)
        var value = fallback
        let status = AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value)
        return status == noErr ? value : fallback
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> String? {
        var addr = address(selector, scope)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(object, &addr, 0, nil, &size, ptr)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func objectIDs(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func defaultOutputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultOutputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    static func deviceUID(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func deviceName(_ device: AudioObjectID) -> String {
        string(device, kAudioObjectPropertyName) ?? "Unknown output"
    }

    /// Number of input stream buffers a device exposes (these come first in an aggregate's input).
    static func inputBufferCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        return Int(raw.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers)
    }

    // MARK: Master (system output) volume

    static func masterVolumeSupported(_ device: AudioObjectID) -> Bool {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr else { return false }
        return settable.boolValue
    }

    static func masterVolume(_ device: AudioObjectID) -> Float? {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Listens for changes to the device's master volume.
    static func masterVolumeListener(_ device: AudioObjectID, _ handler: @escaping @MainActor () -> Void) -> CAPropertyListener? {
        CAPropertyListener(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: kAudioDevicePropertyScopeOutput, handler: handler)
    }

    static func setMasterVolume(_ device: AudioObjectID, _ volume: Float) {
        var addr = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput)
        var value = Float32(max(0, min(1, volume)))
        AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }
}

// MARK: - Device lists (the header's Output and Input pickers)

/// A device as the Output and Input pickers list it.
struct AudioDeviceChoice: Identifiable, Equatable {
    let id: AudioObjectID
    let name: String
}

/// What the pickers need to know about one Core Audio device.
struct RawAudioDevice {
    let id: AudioObjectID
    let uid: String
    let name: String
    let hidden: Bool
    let inputStreams: Int
    let outputStreams: Int
}

extension CA {
    /// Output or input devices as Sound settings shows them, by name. Leaves out hidden devices
    /// and the private devices this app makes for its own audio taps.
    static func deviceChoices(input: Bool) -> [AudioDeviceChoice] {
        visibleDevices(objectIDs(system, kAudioHardwarePropertyDevices).map(rawDevice), input: input)
    }

    static func visibleDevices(_ raw: [RawAudioDevice], input: Bool) -> [AudioDeviceChoice] {
        raw.filter { (input ? $0.inputStreams : $0.outputStreams) > 0 && !$0.hidden && !$0.uid.hasPrefix("lcxmixer-") }
            .map { AudioDeviceChoice(id: $0.id, name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private static func rawDevice(_ d: AudioObjectID) -> RawAudioDevice {
        RawAudioDevice(id: d, uid: deviceUID(d) ?? "", name: deviceName(d),
                       hidden: get(d, kAudioDevicePropertyIsHidden, default: UInt32(0)) != 0,
                       inputStreams: streamCount(d, scope: kAudioObjectPropertyScopeInput),
                       outputStreams: streamCount(d, scope: kAudioObjectPropertyScopeOutput))
    }

    private static func streamCount(_ d: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var addr = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(d, &addr, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    static func defaultInputDevice() -> AudioObjectID {
        get(system, kAudioHardwarePropertyDefaultInputDevice, default: AudioObjectID(kAudioObjectUnknown))
    }

    /// Switches the Mac's output or input, the same as choosing it in Sound settings.
    static func setDefaultDevice(_ d: AudioObjectID, input: Bool) {
        var addr = address(input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice)
        var value = d
        let status = AudioObjectSetPropertyData(system, &addr, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &value)
        if status != noErr { Log.audio.error("Could not switch the default \(input ? "input" : "output", privacy: .public) device: \(status)") }
    }
}

/// Calls `handler` on the main thread whenever a Core Audio property changes, until released.
/// Lets the app sleep until something actually happens, instead of asking on a timer.
final class CAPropertyListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock

    init?(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
          handler: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
        guard object != kAudioObjectUnknown, AudioObjectHasProperty(object, &address) else { return nil }
        self.block = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
    }

    deinit { AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block) }
}
