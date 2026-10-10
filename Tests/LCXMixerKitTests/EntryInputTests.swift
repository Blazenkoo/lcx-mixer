import XCTest
@testable import LCXMixerKit

/// What a typed list entry becomes, and when Settings refuses it.
final class EntryInputTests: XCTestCase {

    func testAPastedAddressBecomesItsWebsite() {
        XCTAssertEqual(EntryInput.normalize("  https://web.whatsapp.com/send?x=1 "), "web.whatsapp.com")
        XCTAssertEqual(EntryInput.normalize("slack.com"), "slack.com")
        XCTAssertEqual(EntryInput.normalize("com.apple.Music"), "com.apple.Music")
    }

    func testEmptyHasNoMessage() {
        XCTAssertNil(EntryInput.problem("", list: [], listName: "mute list"))
    }

    func testSpacesDuplicatesAndTheOtherListAreRefused() {
        XCTAssertNotNil(EntryInput.problem("web whatsapp", list: [], listName: "mute list"))
        XCTAssertEqual(EntryInput.problem("slack.com", list: ["slack.com"], listName: "mute list"),
                       "It's already on the mute list.")
        XCTAssertEqual(EntryInput.problem("zoom.us", list: [], listName: "mute list", other: ["zoom.us"], otherName: "ignore list"),
                       "It's on the ignore list. Select it there and use Move instead.")
        XCTAssertNil(EntryInput.problem("discord.com", list: ["slack.com"], listName: "mute list"))
    }

    func testPrefixesAreSplitOnCommas() {
        XCTAssertEqual(EntryInput.prefixes(" com.riotgames., com.example. ,, "), ["com.riotgames.", "com.example."])
    }

    func testAGroupNameCanOnlyBeUsedOnce() {
        let existing = [GroupRule(name: "League", prefixes: ["com.riotgames."])]
        XCTAssertEqual(EntryInput.groupProblem(name: " league ", prefixes: "com.x.", existing: existing),
                       "There's already a group called league.")
        XCTAssertNil(EntryInput.groupProblem(name: "Games", prefixes: "com.x., com.y.", existing: existing))
        XCTAssertNotNil(EntryInput.groupProblem(name: "Games", prefixes: "com.x y.", existing: existing))
    }

    func testSettingsSectionsAreInSidebarOrder() {
        XCTAssertEqual(SettingsSection.mixer + SettingsSection.sources + [.about], SettingsSection.allCases)
        XCTAssertEqual(SettingsSection.muteList.title, "Mute list")
    }
}
