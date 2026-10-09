import CoreMIDI
import Foundation

enum ControllerEvent {
    case fader(index: Int, value: Int)
    case topButton(index: Int, pressed: Bool)
    case bottomButton(index: Int, pressed: Bool)
    case sideMute(pressed: Bool)
    case sideSolo(pressed: Bool)
    case seekKnob(index: Int, value: Int)
    case speedKnob(index: Int, value: Int)
}

/// Talks to the Launch Control XL over Core MIDI. Callbacks arrive on the main thread.
final class MIDIController {
    var onEvent: ((ControllerEvent) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private var client = MIDIClientRef()
    private var inPort = MIDIPortRef()
    private var outPort = MIDIPortRef()
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private(set) var isConnected = false

    func start() {
        var status = MIDIClientCreateWithBlock("LCX Mixer" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.rescan() }
        }
        if status != noErr { log("MIDIClientCreate failed", status) }
        status = MIDIInputPortCreateWithBlock(client, "LCX Mixer In" as CFString, &inPort) { [weak self] list, _ in
            self?.handle(list)
        }
        if status != noErr { log("MIDIInputPortCreate failed", status) }
        status = MIDIOutputPortCreate(client, "LCX Mixer Out" as CFString, &outPort)
        if status != noErr { log("MIDIOutputPortCreate failed", status) }
        rescan()
    }

    func rescan() {
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
        isConnected = source != 0 && destination != 0
        if isConnected != wasConnected || (isConnected && destChanged) {
            log("Controller", isConnected ? "connected" : "disconnected")
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
            if let name = displayName(endpoint), name.localizedCaseInsensitiveContains("Launch Control XL") {
                return endpoint
            }
        }
        return 0
    }

    private func displayName(_ object: MIDIObjectRef) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, kMIDIPropertyDisplayName, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    private func handle(_ list: UnsafePointer<MIDIPacketList>) {
        var events: [ControllerEvent] = []
        for packet in list.unsafeSequence() {
            let length = Int(packet.pointee.length)
            let bytes: [UInt8] = withUnsafeBytes(of: packet.pointee.data) { Array($0.prefix(length)) }
            parse(bytes, into: &events)
        }
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            for event in events { self?.onEvent?(event) }
        }
    }

    private func parse(_ bytes: [UInt8], into events: inout [ControllerEvent]) {
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
            let d1 = bytes[i + 1]
            let d2 = bytes[i + 2]
            i += 3
            switch type {
            case 0xB0:
                if let idx = LCXL.faderCCs.firstIndex(of: d1) {
                    events.append(.fader(index: idx, value: Int(d2)))
                } else if let idx = LCXL.seekKnobCCs.firstIndex(of: d1) {
                    events.append(.seekKnob(index: idx, value: Int(d2)))
                } else if let idx = LCXL.speedKnobCCs.firstIndex(of: d1) {
                    events.append(.speedKnob(index: idx, value: Int(d2)))
                }
            case 0x90, 0x80:
                let pressed = type == 0x90 && d2 > 0
                if let idx = LCXL.topButtonNotes.firstIndex(of: d1) {
                    events.append(.topButton(index: idx, pressed: pressed))
                } else if let idx = LCXL.bottomButtonNotes.firstIndex(of: d1) {
                    events.append(.bottomButton(index: idx, pressed: pressed))
                } else if d1 == LCXL.muteNote {
                    events.append(.sideMute(pressed: pressed))
                } else if d1 == LCXL.soloNote {
                    events.append(.sideSolo(pressed: pressed))
                }
            default:
                break
            }
        }
    }
}
