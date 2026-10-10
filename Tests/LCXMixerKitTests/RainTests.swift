import XCTest
@testable import LCXMixerKit

/// Activity drops follow the channel's volume: they land only below it, and fewer of them at a
/// lower volume.
final class RainTests: XCTestCase {

    /// Runs a field for `seconds` at 30 frames a second; returns every drop's landing spot.
    private func landings(zone: Double, seconds: Double = 600, calm: Bool = false) -> [Double] {
        let field = RainField()
        var spots: [Double] = []
        var known = Set<Double>()
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        for frame in 0..<Int(seconds * 30) {
            let drops = field.drops(at: start.addingTimeInterval(Double(frame) / 30), active: true, calm: calm, zone: zone)
            for drop in drops {
                let spot = drop.bands[0].position
                if known.insert(spot).inserted { spots.append(spot) }
            }
        }
        return spots
    }

    func testDropsLandOnlyBelowTheVolume() {
        let spots = landings(zone: 0.5)
        XCTAssertFalse(spots.isEmpty)
        XCTAssertTrue(spots.allSatisfy { $0 > 0 && $0 < 0.5 }, "highest: \(spots.max() ?? 0)")
    }

    func testFewerDropsAtLowerVolume() {
        let full = Double(landings(zone: 1).count)
        let third = Double(landings(zone: 0.3).count)
        XCTAssertEqual(third / full, 0.3, accuracy: 0.08)
    }

    func testAQuietChannelStillShowsSignsOfLife() {
        let full = Double(landings(zone: 1).count)
        let tiny = Double(landings(zone: 0.05).count)
        XCTAssertEqual(tiny / full, 0.2, accuracy: 0.06)
    }

    func testNoDropsAtZeroVolume() {
        XCTAssertTrue(landings(zone: 0, seconds: 60).isEmpty)
    }

    func testWavesSpreadHalfAsFarAsBefore() {
        XCTAssertEqual(RainField.waveTravel, 0.225, accuracy: 0.0001)
    }

    func testMetersUseTheFadersScale() {
        let store = TestStore.fresh(for: self)
        let settings = AppSettings(defaults: store)
        settings.naturalCurve = true
        // Fader at 50% plays at 25% strength: a sound at full strength peaks at the fader.
        XCTAssertEqual(settings.position(forGain: settings.gain(forPosition: 0.5)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(settings.position(forGain: 0.25), 0.5, accuracy: 0.0001)
    }
}
