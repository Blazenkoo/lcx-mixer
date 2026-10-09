import XCTest
@testable import LCXMixerKit

/// LightComposer on its own: plain values in, lights out.
final class LightComposerTests: XCTestCase {

    private func app(muted: Bool = false) -> Source {
        Source(id: "app:com.apple.Music", kind: .app, name: "Music", detail: "", icon: nil, rememberKey: "com.apple.Music",
               isPlaying: true, isAudible: true, isMuted: muted, volume: 1, canPlayPause: false, canSetVolume: true)
    }

    private func video(speed: Float = 1) -> Source {
        var s = Source(id: "tab:browser:1", kind: .tab, name: "YouTube", detail: "Video", icon: nil, rememberKey: "www.youtube.com",
                       isPlaying: true, isAudible: true, isMuted: false, volume: 1, canPlayPause: true, canSetVolume: true)
        s.canSpeed = true
        s.canSeek = true
        s.speed = speed
        return s
    }

    func testMasterChannelShowsTheOutputVolume() {
        let c = LightComposer.light(for: .master(volume: 0.5), muteAll: false)
        XCTAssertEqual(c.name, "Master")
        XCTAssertEqual(c.detail, "50%")
        XCTAssertEqual(c.fader, 0.5)
        XCTAssertEqual(c.playButton, .off)
    }

    func testNativeAppIsDimGreenAndRedWhenMuted() {
        XCTAssertEqual(LightComposer.light(for: .source(app(), position: 1, blinking: false, seeking: nil), muteAll: false).playButton, .greenDim)
        XCTAssertEqual(LightComposer.light(for: .source(app(muted: true), position: 1, blinking: false, seeking: nil), muteAll: false).muteButton, .red)
    }

    func testSeekKnobLightsOnlyWhileSeeking() {
        XCTAssertEqual(LightComposer.light(for: .source(video(), position: 1, blinking: false, seeking: nil), muteAll: false).seekKnob, .off)
        XCTAssertEqual(LightComposer.light(for: .source(video(), position: 1, blinking: false, seeking: 0.6), muteAll: false).seekKnob, .green)
        XCTAssertEqual(LightComposer.light(for: .source(video(), position: 1, blinking: false, seeking: -0.6), muteAll: false).seekKnob, .red)
    }

    func testBlinkingNewChannelGivesWayToAReloadWarning() {
        var s = video()
        XCTAssertEqual(LightComposer.light(for: .source(s, position: 1, blinking: true, seeking: nil), muteAll: false).playButton, .greenBlink)
        s.needsReload = true
        XCTAssertEqual(LightComposer.light(for: .source(s, position: 1, blinking: true, seeking: nil), muteAll: false).playButton, .amberBlink)
    }

    func testSideButtons() {
        let l = LightComposer.lights(for: [.empty], muteAll: true, micMuted: true)
        XCTAssertEqual(l.muteAll, .yellow)
        XCTAssertEqual(l.micMute, .red)
        XCTAssertEqual(l.channels, [ChannelLights()])
    }
}
