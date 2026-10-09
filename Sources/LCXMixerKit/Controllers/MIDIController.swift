import CoreMIDI
import Foundation
import os

/// One incoming MIDI message, already split into its parts.
struct MIDIMessage {
    enum Kind { case controlChange, noteOn, noteOff, pitchBend }
    let kind: Kind
    /// Zero-based MIDI channel (0 = channel 1).
    let channel: UInt8
    /// Controller or note number; 0 for pitch bend.
    let number: UInt8
    /// 0…127, or 0…16383 for pitch bend.
    let value: Int
}

/// Connects to one MIDI device over Core MIDI and passes on its messages. Device-neutral: drivers
/// decide what the messages mean. Callbacks arrive on the main thread.
final class MIDIController {
    var onMessage: ((MIDIMessage) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    /// Picks the device by its display name.
    private let matches: (String) -> Bool
    /// Devices that need lights sent back count as connected only with an output too.
    private let needsOutput: Bool

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private(set) var isConnected = false
    private var started = false

    init(needsOutput: Bool, matching matches: @escaping (String) -> Bool) {
        self.needsOutput = needsOutput
        self.matches = matches
    }

    /// Display names of every MIDI input device currently available.
    static func sourceNames() -> [String] {
        (0..<MIDIGetNumberOfSources()).compactMap { i in
            let endpoint = MIDIGetSource(i)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            return offline == 0 ? displayName(endpoint) : nil
        }
    }

    func start() {
        guard !started else { return }
        started = true
        var status = MIDIClientCreateWithBlock("LCX Mixer" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.rescan() }
        }
        if status != noErr { Log.midi.error("MIDIClientCreate failed: \(status)") }
        status = MIDIInputPortCreateWithBlock(client, "LCX Mixer In" as CFString, &inPort) { [weak self] list, _ in
            self?.handle(list)
        }
        if status != noErr { Log.midi.error("MIDIInputPortCreate failed: \(status)") }
        status = MIDIOutputPortCreate(client, "LCX Mixer Out" as CFString, &outPort)
        if status != noErr { Log.midi.error("MIDIOutputPortCreate failed: \(status)") }
        rescan()
    }

    /// Disconnects and releases the MIDI ports (used when switching controllers).
    func stop() {
        guard started else { return }
        started = false
        onMessage = nil
        onConnectionChange = nil
        if source != 0 { MIDIPortDisconnectSource(inPort, source) }
        source = 0
        destination = 0
        isConnected = false
        MIDIPortDispose(inPort)
        MIDIPortDispose(outPort)
        MIDIClientDispose(client)
    }

    func rescan() {
        guard started else { return }
        let newSource = findEndpoint(count: MIDIGetNumberOfSources(), get: MIDIGetSource)
        let newDest = findEndpoint(count: MIDIGetNumberOfDestinations(), get: MIDIGetDestination)
        let wasConnected = isConnected
        if newSource != source {
            if source != 0 { MIDIPortDisconnectSource(inPort, source) }
            source = newSource
            if source != 0 { MIDIPortConnectSource(inPort, source, nil) }
        }
        let destChanged = newDest != destination
        destination = newDest
        isConnected = source != 0 && (!needsOutput || destination != 0)
        if isConnected != wasConnected || (isConnected && destChanged) {
            let state = isConnected ? "connected" : "disconnected"
            Log.midi.info("Controller \(state, privacy: .public)")
            onConnectionChange?(isConnected)
        }
    }

    func send(_ bytes: [UInt8]) {
        guard destination != 0, !bytes.isEmpty else { return }
        var list = MIDIPacketList()
        withUnsafeMutablePointer(to: &list) { ptr in
            let packet = MIDIPacketListInit(ptr)
            _ = MIDIPacketListAdd(ptr, MemoryLayout<MIDIPacketList>.size, packet, 0, bytes.count, bytes)
            MIDISend(outPort, destination, ptr)
        }
    }

    // MARK: - Private

    private func findEndpoint(count: Int, get: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef {
        for i in 0..<count {
            let endpoint = get(i)
            var offline: Int32 = 0
            MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            if offline != 0 { continue }
            if let name = Self.displayName(endpoint), matches(name) {
                return endpoint
            }
        }
        return 0
    }

    private static func displayName(_ object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var messages: [MIDIMessage] = []
        for packet in list.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes: [UInt8] = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
            Self.parse(bytes, into: &messages)
        }
        guard !messages.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for message in messages { self?.onMessage?(message) }
        }
    }

    /// Splits raw MIDI bytes into messages; SysEx and anything unknown is skipped.
    static func parse(_ bytes: [UInt8], into messages: inout [MIDIMessage]) {
        var i = 0
        while i < bytes.count {
            let status = bytes[i]
            if status == 0xF0 {
                while i < bytes.count && bytes[i] != 0xF7 { i += 1 }
                i += 1
                continue
            }
            guard status & 0x80 != 0, i + 2 < bytes.count else { i += 1; continue }
            let type = status & 0xF0
            let channel = status & 0x0F
            let d1 = bytes[i + 1]
            let d2 = bytes[i + 2]
            i += 3
            switch type {
            case 0xB0:
                messages.append(MIDIMessage(kind: .controlChange, channel: channel, number: d1, value: Int(d2)))
            case 0x90:
                messages.append(MIDIMessage(kind: d2 > 0 ? .noteOn : .noteOff, channel: channel, number: d1, value: Int(d2)))
            case 0x80:
                messages.append(MIDIMessage(kind: .noteOff, channel: channel, number: d1, value: Int(d2)))
            case 0xE0:
                messages.append(MIDIMessage(kind: .pitchBend, channel: channel, number: 0, value: Int(d1) | Int(d2) << 7))
            default:
                break
            }
        }
    }
}
