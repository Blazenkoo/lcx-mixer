import Foundation

/// MIDI map of the Novation Launch Control XL mk2 on Factory Template 1 (MIDI channel 9).
enum LCXL {
    static let channel: UInt8 = 8 // zero-based → MIDI channel 9

    static let faderCCs: [UInt8] = [77, 78, 79, 80, 81, 82, 83, 84]
    /// Top button row ("Track Focus").
    static let topButtonNotes: [UInt8] = [41, 42, 43, 44, 57, 58, 59, 60]
    /// Bottom button row ("Track Control").
    static let bottomButtonNotes: [UInt8] = [73, 74, 75, 76, 89, 90, 91, 92]
    /// Middle knob row ("Send B"): seek shuttle.
    static let seekKnobCCs: [UInt8] = [29, 30, 31, 32, 33, 34, 35, 36]
    /// Bottom knob row ("Pan/Device"): playback speed.
    static let speedKnobCCs: [UInt8] = [49, 50, 51, 52, 53, 54, 55, 56]
    static let deviceNote: UInt8 = 105
    static let muteNote: UInt8 = 106
    static let soloNote: UInt8 = 107
    static let armNote: UInt8 = 108

    /// LED velocity = 16 × green + red + flags (12 = normal, 8 = flashing).
    enum Color: UInt8 {
        case off = 12
        case redLow = 13
        case red = 15
        case amberLow = 29
        case amber = 63
        case yellow = 62
        case greenLow = 28
        case green = 60
        case redFlash = 11
        case amberFlash = 59
        case greenFlash = 56
    }

    /// SysEx: switch the controller to Factory Template 1 (template index 8).
    static let selectFactoryTemplate1: [UInt8] = [0xF0, 0x00, 0x20, 0x29, 0x02, 0x11, 0x77, 0x08, 0xF7]
    static var resetLEDs: [UInt8] { [0xB0 | channel, 0x00, 0x00] }
    static var enableFlashing: [UInt8] { [0xB0 | channel, 0x00, 0x28] }

    /// Knob LED via SysEx: index 0–7 top row, 8–15 middle row, 16–23 bottom row (Factory Template 1).
    static func knobLED(index: UInt8, _ color: Color) -> [UInt8] {
        [0xF0, 0x00, 0x20, 0x29, 0x02, 0x11, 0x78, 0x08, index, color.rawValue, 0xF7]
    }

    static func led(note: UInt8, _ color: Color) -> [UInt8] {
        [0x90 | channel, note, color.rawValue]
    }
}
