import XCTest
@testable import LCXMixerKit

/// When a native app gets a tap, and what kind: control its volume, only listen for a meter, or none.
final class TapPolicyTests: XCTestCase {

    func testBelowFullVolumeTheTapControls() {
        XCTAssertEqual(TapPolicy.need(gain: 0.5, wantsMeter: false), .control)
        XCTAssertEqual(TapPolicy.need(gain: 0.5, wantsMeter: true), .control)
        XCTAssertEqual(TapPolicy.need(gain: 0, wantsMeter: true), .control)   // muted
    }

    func testAtFullVolumeTheTapOnlyListensWhileAMeterIsOnScreen() {
        XCTAssertEqual(TapPolicy.need(gain: 1, wantsMeter: true), .listen)
        XCTAssertEqual(TapPolicy.need(gain: 0.9995, wantsMeter: true), .listen)
    }

    func testAtFullVolumeWithNoMeterThereIsNoTap() {
        XCTAssertEqual(TapPolicy.need(gain: 1, wantsMeter: false), .untouched)
    }

    func testBackAtFullVolumeTheTapListensOrGoes() {
        XCTAssertEqual(TapPolicy.settle(controlling: true, gain: 1, wantsMeter: true), .listen)
        XCTAssertEqual(TapPolicy.settle(controlling: true, gain: 1, wantsMeter: false), .remove)
    }

    func testTurnedDownAgainBeforeSettlingKeepsControl() {
        XCTAssertEqual(TapPolicy.settle(controlling: true, gain: 0.7, wantsMeter: true), .keep)
        XCTAssertEqual(TapPolicy.settle(controlling: true, gain: 0.7, wantsMeter: false), .keep)
    }

    func testListeningTapGoesWhenTheLastMeterDoes() {
        XCTAssertEqual(TapPolicy.settle(controlling: false, gain: 1, wantsMeter: false), .remove)
        XCTAssertEqual(TapPolicy.settle(controlling: false, gain: 1, wantsMeter: true), .keep)
    }
}
