import AudioToolbox
import CoreAudio
import Foundation
import os

/// Shared between the main thread (gain, level reads) and the real-time audio thread.
final class TapRenderState {
    let targetGain = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    let level = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Non-zero while levels are wanted (a meter is on screen); otherwise no level is computed.
    let metering = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Hand-over between the app's own sound and ours: 0 = ours silent, 1 = ours fully on.
    /// The audio thread moves towards this target over `handoverSeconds`, for a crossfade
    /// instead of a hard switch when a tap starts or ends.
    let handoverTarget = UnsafeMutablePointer<Float>.allocate(capacity: 1)
    /// Counts audio buffers processed, so the main thread knows our sound is flowing.
    let renders = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    /// Non-zero while the tap only listens: the app's own sound plays as it is and ours is silent,
    /// so the meter reads the app's sound before our gain and hand-over.
    let listening = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    var skipInputBuffers = 0
    var sampleRate: Float = 48000
    static let handoverSeconds: Float = 0.02
    private var currentGain: Float
    private var handover: Float = 0

    init(gain: Float) {
        targetGain.initialize(to: gain)
        level.initialize(to: 0)
        metering.initialize(to: 0)
        handoverTarget.initialize(to: 0)
        renders.initialize(to: 0)
        listening.initialize(to: 0)
        currentGain = gain
    }

    deinit {
        targetGain.deallocate()
        level.deallocate()
        metering.deallocate()
        handoverTarget.deallocate()
        renders.deallocate()
        listening.deallocate()
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
        let meterApp = listening.pointee != 0
        var peak: Float = 0

        // The hand-over fade for this buffer, combined with the gain ramp into one start→end ramp.
        let bufferFrames = outList.count > 0 && outList[0].mNumberChannels > 0
            ? Int(outList[0].mDataByteSize) / (MemoryLayout<Float>.size * Int(outList[0].mNumberChannels)) : 0
        let hTarget = handoverTarget.pointee
        let hStep = Float(bufferFrames) / max(1, TapRenderState.handoverSeconds * sampleRate)
        let hEnd = handover < hTarget ? min(hTarget, handover + hStep) : max(hTarget, handover - hStep)
        let startGain = currentGain * handover
        let endGain = target * hEnd

        if inChannels > 0 {
            for oc in 0..<outChannels {
                guard let out = TapRenderState.channel(outList, start: 0, channel: oc),
                      let inp = TapRenderState.channel(inList, start: skip, channel: oc % inChannels) else { continue }
                let frames = min(out.frames, inp.frames)
                guard frames > 0 else { continue }
                var gain = startGain
                let step = (endGain - startGain) / Float(frames)
                if measure {
                    for f in 0..<frames {
                        let raw = inp.ptr[f * inp.stride]
                        let sample = raw * gain
                        out.ptr[f * out.stride] = sample
                        let a = abs(meterApp ? raw : sample)
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
        handover = hEnd
        renders.pointee &+= 1
        if measure { level.pointee = max(peak, level.pointee * 0.8) } else { level.pointee = 0 }
    }
}

/// One process tap + private aggregate device that re-plays one app's audio at our gain.
///
/// It can also only listen: then the app's own sound plays as it is, ours stays silent, and the
/// tap just measures the level for a meter. `takeOver(outputDevice:)` and `handBack()` switch
/// between listening and controlling the volume, with the same crossfade as starting and stopping.
final class ProcessTap {
    let processObjects: [AudioObjectID]
    let state: TapRenderState
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    /// True while the app's own sound still plays (before the hand-in completes, or while listening).
    private var originalPlaying = false
    /// True while the tap only listens, for a meter.
    private(set) var isListening = false
    /// Whether this macOS lets a running tap change its mute, which every crossfade relies on.
    private var canSwitchMute = false
    private var outputDevice = AudioObjectID(kAudioObjectUnknown)

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

    /// Starts the tap. With `seamless`, the app's own sound keeps playing until ours flows, then
    /// the two crossfade; if macOS doesn't allow that, it falls back to switching straight over.
    /// With `listenOnly`, the app's own sound keeps playing and the tap only measures.
    func start(outputDevice: AudioObjectID, seamless: Bool = true, listenOnly: Bool = false) -> Bool {
        let marker = Signposts.poi.beginInterval("Tap start")
        defer { Signposts.poi.endInterval("Tap start", marker) }
        guard let outputUID = CA.deviceUID(outputDevice), !processObjects.isEmpty else { return false }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjects)
        description.uuid = UUID()
        description.name = "LCX Mixer tap"
        description.isPrivate = true
        description.muteBehavior = (seamless || listenOnly) ? .unmuted : .mutedWhenTapped
        self.description = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else {
            Log.audio.error("Create tap failed: \(status)")
            return false
        }
        tapID = tap
        canSwitchMute = canChangeMute()
        if seamless && !listenOnly && !canSwitchMute {
            // This macOS doesn't let a running tap change its mute: switch straight over instead.
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
            return start(outputDevice: outputDevice, seamless: false)
        }
        originalPlaying = seamless || listenOnly
        isListening = listenOnly
        // Until a hand-in completes, what you hear is the app's own sound: the meter reads that.
        state.listening.pointee = (seamless || listenOnly) ? 1 : 0
        state.handoverTarget.pointee = 0
        self.outputDevice = outputDevice
        state.sampleRate = Float(CA.get(outputDevice, kAudioDevicePropertyNominalSampleRate, default: Float64(48000)))

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
            Log.audio.error("Create aggregate failed: \(status)")
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
            Log.audio.error("Create IO proc failed: \(status)")
            stop()
            return false
        }

        // Don't open the output device's own inputs (e.g. the Scarlett's mic inputs).
        if inputBuffersOfOutputDevice > 0 {
            disableInputStreams(count: inputBuffersOfOutputDevice, procID: procID)
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            Log.audio.error("Start aggregate failed: \(status)")
            stop()
            return false
        }
        if listenOnly {
            // Nothing more: the app plays on, and our silent copy only feeds the meter.
        } else if seamless {
            handIn(attempt: 0)
        } else {
            state.handoverTarget.pointee = 1   // straight over, with a short fade-in
        }
        return true
    }

    /// From listening to controlling the volume: the app's own sound is muted as ours fades in.
    /// Returns false if the tap couldn't be restarted (only on a macOS that can't crossfade).
    func takeOver(outputDevice: AudioObjectID) -> Bool {
        guard isListening else { return true }
        isListening = false
        if canSwitchMute {
            handIn(attempt: 0)
            return true
        }
        // This macOS can't change a running tap's mute: start over as a controlling tap.
        stop()
        return start(outputDevice: outputDevice, seamless: false)
    }

    /// From controlling the volume back to listening: the app's own sound returns as ours fades
    /// out, and the tap stays to measure. Returns false if the sound couldn't be handed back; the
    /// caller then replaces the tap.
    func handBack() -> Bool {
        guard !isListening else { return true }
        if !originalPlaying {
            guard setMute(.unmuted) else { return false }
            originalPlaying = true
        }
        isListening = true
        state.listening.pointee = 1
        state.handoverTarget.pointee = 0
        return true
    }

    /// Once our sound is flowing, mutes the app's own sound and fades ours in at the same moment.
    private func handIn(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self, self.tapID != kAudioObjectUnknown, self.originalPlaying, !self.isListening else { return }
            if self.state.renders.pointee < 2 && attempt < 25 {
                self.handIn(attempt: attempt + 1)   // not flowing yet (up to ~0.5 s)
                return
            }
            if self.setMute(.mutedWhenTapped) {
                self.originalPlaying = false
                self.state.listening.pointee = 0
                self.state.handoverTarget.pointee = 1
            } else if self.setMute(.mutedWhenTapped) {
                Log.audio.info("Seamless hand-in needed a second try")
                self.originalPlaying = false
                self.state.listening.pointee = 0
                self.state.handoverTarget.pointee = 1
            } else {
                // The app's own sound can't be muted while the tap runs: never leave it doubled.
                // Start over as a tap that mutes it from the start.
                Log.audio.info("Seamless hand-in failed; switching over directly")
                self.stop()
                _ = self.start(outputDevice: self.outputDevice, seamless: false)
            }
        }
    }

    /// Hands the sound back to the app: un-mutes its own sound and fades ours out at the same
    /// moment, then removes the tap. Falls back to an immediate stop.
    func stopSeamlessly() {
        let marker = Signposts.poi.beginInterval("Tap stop")
        defer { Signposts.poi.endInterval("Tap stop", marker) }
        guard tapID != kAudioObjectUnknown, !originalPlaying, setMute(.unmuted) else {
            stop()
            return
        }
        originalPlaying = true
        state.handoverTarget.pointee = 0
        let delay = Double(TapRenderState.handoverSeconds) + 0.06
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.stop() }   // keeps self alive until then
    }

    private func canChangeMute() -> Bool {
        var addr = CA.address(kAudioTapPropertyDescription)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(tapID, &addr, &settable) == noErr && settable.boolValue
    }

    private func setMute(_ behavior: CATapMuteBehavior) -> Bool {
        guard let description, tapID != kAudioObjectUnknown else { return false }
        description.muteBehavior = behavior
        var addr = CA.address(kAudioTapPropertyDescription)
        var object: CATapDescription = description
        let status = withUnsafeMutablePointer(to: &object) { ptr in
            AudioObjectSetPropertyData(tapID, &addr, 0, nil, UInt32(MemoryLayout<CATapDescription>.size), ptr)
        }
        if status != noErr { Log.audio.error("Change tap mute failed: \(status)") }
        return status == noErr
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
        if status != noErr { Log.audio.error("Disable input streams failed: \(status)") }
    }
}
