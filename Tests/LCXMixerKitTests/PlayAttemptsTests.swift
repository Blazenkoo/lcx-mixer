import XCTest
@testable import LCXMixerKit

/// Telling when a muted source keeps trying to make sound, and not for short pings.
final class PlayAttemptsTests: XCTestCase {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000)
    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testAShortSoundIsNotTryingToPlay() {
        var a = PlayAttempts()
        var r = a.update(sounding: ["wa": true], now: at(0))
        XCTAssertEqual(r.popUps, [])
        XCTAssertEqual(r.recheck ?? -1, PlayAttempts.sustained, accuracy: 0.001)
        r = a.update(sounding: ["wa": false], now: at(1.5))   // a notification ping
        XCTAssertTrue(a.trying.isEmpty)
        XCTAssertNil(r.recheck)
        r = a.update(sounding: ["wa": false], now: at(10))
        XCTAssertTrue(a.trying.isEmpty)
        XCTAssertEqual(r.popUps, [])
    }

    func testSustainedSoundIsTryingToPlayWithOnePopUp() {
        var a = PlayAttempts()
        _ = a.update(sounding: ["wa": true], now: at(0))
        let r = a.update(sounding: ["wa": true], now: at(3))
        XCTAssertEqual(a.trying, ["wa"])
        XCTAssertEqual(r.popUps, ["wa"])
        XCTAssertEqual(a.update(sounding: ["wa": true], now: at(30)).popUps, [], "one pop-up per stretch")
    }

    func testTheStateClearsAFewSecondsAfterTheSoundStops() {
        var a = PlayAttempts()
        _ = a.update(sounding: ["wa": true], now: at(0))
        _ = a.update(sounding: ["wa": true], now: at(4))
        var r = a.update(sounding: ["wa": false], now: at(5))
        XCTAssertEqual(a.trying, ["wa"])
        XCTAssertEqual(r.recheck ?? -1, PlayAttempts.settle, accuracy: 0.001)
        r = a.update(sounding: ["wa": false], now: at(5 + PlayAttempts.settle))
        XCTAssertTrue(a.trying.isEmpty)
        XCTAssertNil(r.recheck)
    }

    func testThePopUpRepeatsAtMostEveryTenMinutes() {
        var a = PlayAttempts()
        _ = a.update(sounding: ["wa": true], now: at(0))
        XCTAssertEqual(a.update(sounding: ["wa": true], now: at(3)).popUps, ["wa"])
        _ = a.update(sounding: ["wa": false], now: at(10))
        _ = a.update(sounding: ["wa": false], now: at(20))
        // Plays again two minutes later: the state comes back, the pop-up doesn't.
        _ = a.update(sounding: ["wa": true], now: at(120))
        XCTAssertEqual(a.update(sounding: ["wa": true], now: at(124)).popUps, [])
        XCTAssertEqual(a.trying, ["wa"])
        _ = a.update(sounding: ["wa": false], now: at(130))
        _ = a.update(sounding: ["wa": false], now: at(140))
        // Eleven minutes after the first pop-up: it shows again.
        _ = a.update(sounding: ["wa": true], now: at(660))
        XCTAssertEqual(a.update(sounding: ["wa": true], now: at(664)).popUps, ["wa"])
    }

    func testASourceTakenOffTheMuteListIsForgotten() {
        var a = PlayAttempts()
        _ = a.update(sounding: ["wa": true], now: at(0))
        _ = a.update(sounding: ["wa": true], now: at(4))
        let r = a.update(sounding: [:], now: at(5))
        XCTAssertTrue(a.trying.isEmpty)
        XCTAssertNil(r.recheck)
    }

    func testSourcesAreTrackedSeparately() {
        var a = PlayAttempts()
        _ = a.update(sounding: ["wa": true, "slack": false], now: at(0))
        let r = a.update(sounding: ["wa": true, "slack": true], now: at(3))
        XCTAssertEqual(a.trying, ["wa"])
        XCTAssertEqual(r.popUps, ["wa"])
        XCTAssertEqual(r.recheck ?? -1, PlayAttempts.sustained, accuracy: 0.001)
    }
}
