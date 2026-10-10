import XCTest
@testable import LCXMixerKit

/// Saved settings: the version that lets later releases upgrade them safely.
final class SettingsTests: XCTestCase {

    func testFreshSettingsSaveTheCurrentVersion() {
        let store = TestStore.fresh(for: self)
        _ = AppSettings(defaults: store)
        XCTAssertEqual(store.integer(forKey: AppSettings.settingsVersionKey), AppSettings.settingsVersion)
    }

    func testSettingsFromOlderReleasesAreKeptAndGetTheVersion() {
        let store = TestStore.fresh(for: self)
        // As 2.1.1 saved them: no version, some choices of yours.
        store.set(false, forKey: "naturalCurve")
        store.set(try! JSONEncoder().encode(["www.youtube.com"]), forKey: "muteList")
        let settings = AppSettings(defaults: store)
        XCTAssertFalse(settings.naturalCurve)
        XCTAssertEqual(settings.muteList, ["www.youtube.com"])
        XCTAssertEqual(store.integer(forKey: AppSettings.settingsVersionKey), AppSettings.settingsVersion)
    }

    func testSettingsFromANewerBuildAreLeftAlone() {
        let store = TestStore.fresh(for: self)
        store.set(AppSettings.settingsVersion + 5, forKey: AppSettings.settingsVersionKey)
        _ = AppSettings(defaults: store)
        XCTAssertEqual(store.integer(forKey: AppSettings.settingsVersionKey), AppSettings.settingsVersion + 5)
    }
}
