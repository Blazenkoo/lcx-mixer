import AudioToolbox
import CoreAudio
import Foundation

/// Shared between the main thread (gain, level reads) and the real-time audio thread.
final class TapRenderState {
    let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Non-zero while levels are wanted (a meter is on screen); otherwise no level is computed.
    let metering = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var skipInputBuffers = 0
    private var currentGain: Float

    init(gain: Float) {
        targetGain.initialize(to: gain)
        level.initialize(to: 0)
        metering.initialize(to: 0)
        // Starts silent and ramps to the target over the first buffer (a few milliseconds):
        // a short fade-in rather than a click when the app's sound moves into the tap.
        currentGain = 0
    }

    deinit {
        targetGain.deallocate()
        level.deallocate()
        metering.deallocate()
    }

    /// Finds logical channel `channel` in a buffer list, starting at buffer `start`.
    @inline(__always)
    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, start: Int, channel: Int)
        -> (ptr: UnsafeMutablePointer<Float>, stride: Int, frames: Int)? {
        var c = channel
        var b = start
        while b < list.count {
            let buffer = list[b]
            let n = Int(buffer.mNumberChannels)
            if n > 0 && c < n {
                guard let data = buffer.mData else { return nil }
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * n)
                return (data.assumingMemoryBound(to: Float.self).advanced(by: c), n, frames)
            }
            c -= n
            b += 1
        }
        return nil
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer, start: Int) -> Int {
        var total = 0
        var b = start
        while b < list.count { total += Int(list[b].mNumberChannels); b += 1 }
        return total
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outList = UnsafeMutableAudioBufferListPointer(output)

        for buffer in outList {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        var skip = skipInputBuffers
        var inChannels = TapRenderState.channelCount(inList, start: skip)
        if inChannels == 0 {
            skip = 0
            inChannels = TapRenderState.channelCount(inList, start: 0)
        }
        let outChannels = min(2, TapRenderState.channelCount(outList, start: 0))
        let target = targetGain.pointee
        let measure = metering.pointee != 0
        var peak: Float = 0

        if inChannels > 0 {
            for oc in 0..<outChannels {
                guard let out = TapRenderState.channel(outList, start: 0, channel: oc),
                      let inp = TapRenderState.channel(inList, start: skip, channel: oc % inChannels) else { continue }
                let frames = min(out.frames, inp.frames)
                guard frames > 0 else { continue }
                var gain = currentGain
                let step = (target - currentGain) / Float(frames)
                if measure {
                    for f in 0..<frames {
                        let sample = inp.ptr[f * inp.stride] * gain
                        out.ptr[f * out.stride] = sample
                        let a = abs(sample)
                        if a > peak { peak = a }
                        gain += step
                    }
                } else {
                    for f in 0..<frames {
                        out.ptr[f * out.stride] = inp.ptr[f * inp.stride] * gain
                        gain += step
                    }
                }
            }
        }
        currentGain = target
        if measure { level.pointee = max(peak, level.pointee * 0.8) } else { level.pointee = 0 }
    }
}

/// One process tap + private aggregate device that re-plays one app's audio at our gain.
final class ProcessTap {
    let processObjects: [AudioObjectID]
    let state: TapRenderState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?

    init(processObjects: [AudioObjectID], gain: Float) {
        self.processObjects = processObjects
        self.state = TapRenderState(gain: gain)
    }

    deinit { stop() }

    var gain: Float {
        get { state.targetGain.pointee }
        set { state.targetGain.pointee = max(0, min(1, newValue)) }
    }

    var level: Float { state.level.pointee }

    var metering: Bool {
        get { state.metering.pointee != 0 }
        set { state.metering.pointee = newValue ? 1 : 0 }
    }

    func start(outputDevice: AudioObjectID) -> Bool {
        guard let outputUID = CA.deviceUID(outputDevice), !processObjects.isEmpty else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "LCX Mixer tap"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            log("Create tap failed", status)
            return false
        }
        tapID = tap

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LCX Mixer",
            kAudioAggregateDeviceUIDKey: "lcxmixer-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg)
        guard status == noErr else {
            log("Create aggregate failed", status)
            stop()
            return false
        }
        aggregateID = agg

        let inputBuffersOfOutputDevice = CA.inputBufferCount(outputDevice)
        state.skipInputBuffers = inputBuffersOfOutputDevice

        let renderState = state
        // No dispatch queue: the block runs directly on the device's real-time audio thread, which is
        // already part of the device's audio workgroup. (A queue would add a thread hop per buffer.)
        // The render code is real-time safe: no memory allocation, no locks.
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, nil) { _, input, _, output, _ in
            renderState.render(input: input, output: output)
        }
        guard status == noErr, let procID else {
            log("Create IO proc failed", status)
            stop()
            return false
        }

        // Don't open the output device's own inputs (e.g. the Scarlett's mic inputs).
        if inputBuffersOfOutputDevice > 0 {
            disableInputStreams(count: inputBuffersOfOutputDevice, procID: procID)
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            log("Start aggregate failed", status)
            stop()
            return false
        }
        return true
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    /// Turns off the first `count` input streams for our IO proc (layout of AudioHardwareIOProcStreamUsage:
    /// pointer mIOProc, UInt32 mNumberStreams, UInt32 mStreamIsOn[]).
    private func disableInputStreams(count: Int, procID: AudioDeviceIOProcID) {
        var addr = CA.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(aggregateID, &addr, 0, nil, &size) == noErr, size >= 16 else { return }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 8)
        defer { raw.deallocate() }
        memset(raw, 0, Int(size))
        raw.storeBytes(of: unsafeBitCast(procID, to: UnsafeMutableRawPointer.self), as: UnsafeMutableRawPointer.self)
        guard AudioObjectGetPropertyData(aggregateID, &addr, 0, nil, &size, raw) == noErr else { return }
        let streams = Int(raw.load(fromByteOffset: 8, as: UInt32.self))
        guard streams > count else { return } // never switch off the tap itself
        for i in 0..<count {
            raw.storeBytes(of: UInt32(0), toByteOffset: 12 + 4 * i, as: UInt32.self)
        }
        let status = AudioObjectSetPropertyData(aggregateID, &addr, 0, nil, size, raw)
        if status != noErr { log("Disable input streams failed", status) }
    }
}
