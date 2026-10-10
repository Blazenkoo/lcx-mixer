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

    /// Twice the 2.3 pace: waves spread in 0.8 s (was 1.6 s) and drops land twice as often.
    func testDropsAreQuick() {
        XCTAssertEqual(RainField.life(calm: false), 0.8, accuracy: 0.0001)
        XCTAssertEqual(RainField.life(calm: true), 1.2, accuracy: 0.0001)
        let perSecond = Double(landings(zone: 1, seconds: 300).count) / 300
        XCTAssertEqual(perSecond, 2.6, accuracy: 0.3)
    }

    /// The pace is the same at every volume: a drop at 30% spreads as fast as one at 100%.
    func testWavesSpreadAsFastAtLowVolume() {
        for zone in [1.0, 0.3] {
            let field = RainField()
            let start = Date(timeIntervalSinceReferenceDate: 10_000)
            let first = field.drops(at: start, active: true, calm: false, zone: zone)
            XCTAssertEqual(first.count, 1)
            let landed = first[0].bands[0].position
            // Half its life later, its waves are halfway out.
            let later = field.drops(at: start.addingTimeInterval(0.4), active: false, calm: false, zone: zone)
            let drop = later.first { $0.bands[0].position == landed }
            XCTAssertNotNil(drop)
            if let drop {
                XCTAssertEqual(drop.bands[1].position - landed, RainField.waveTravel / 2, accuracy: 0.0001)
            }
            // And gone once its life is over.
            let gone = field.drops(at: start.addingTimeInterval(0.81), active: false, calm: false, zone: zone)
            XCTAssertFalse(gone.contains { $0.bands[0].position == landed })
        }
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
