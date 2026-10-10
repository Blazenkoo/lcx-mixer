import XCTest
@testable import LCXMixerKit

/// MuteLists on its own: which entries match which sources, and what a changed list means.
final class MuteListsTests: XCTestCase {

    private func app(_ key: String, bundles: [String] = []) -> Source {
        var s = Source(id: "app:" + key, kind: .app, name: key, detail: "", icon: nil, rememberKey: key,
                       isPlaying: true, isAudible: true, isMuted: false, volume: 1, canPlayPause: false, canSetVolume: true)
        s.bundleIDs = bundles
        return s
    }

    private func site(_ host: String, id: String) -> Source {
        var s = Source(id: id, kind: .tab, name: host, detail: "", icon: nil, rememberKey: host,
                       isPlaying: true, isAudible: true, isMuted: false, volume: 1, canPlayPause: true, canSetVolume: true)
        s.host = host
        return s
    }

    func testAnAppMatchesByGroupKeyOrAnyOfItsBundles() {
        let league = app("League", bundles: ["com.riotgames.LeagueofLegends.LeagueClientUx"])
        XCTAssertEqual(MuteLists.keys(of: league), ["League", "com.riotgames.LeagueofLegends.LeagueClientUx"])
        XCTAssertEqual(MuteLists.primaryKey(of: league), "League")
        XCTAssertTrue(MuteLists(muteList: ["com.riotgames.LeagueofLegends.LeagueClientUx"], ignoreList: []).isMuted(league))
    }

    func testTheMatchingEntryIsReportedAsWritten() {
        let league = app("League", bundles: ["com.riotgames.LeagueofLegends.LeagueClientUx"])
        let lists = MuteLists(muteList: ["web.whatsapp.com", "com.riotgames.LeagueofLegends.LeagueClientUx"], ignoreList: [])
        XCTAssertEqual(lists.muteEntry(for: league), "com.riotgames.LeagueofLegends.LeagueClientUx")
        XCTAssertEqual(lists.muteEntry(for: site("web.whatsapp.com", id: "tab:browser:1")), "web.whatsapp.com")
        XCTAssertNil(lists.muteEntry(for: site("www.youtube.com", id: "tab:browser:2")))
    }

    func testATabMatchesByWebsite() {
        let tab = site("www.youtube.com", id: "tab:browser:1")
        XCTAssertEqual(MuteLists.keys(of: tab), ["www.youtube.com"])
        XCTAssertTrue(MuteLists(muteList: [], ignoreList: ["www.youtube.com"]).isIgnored(tab))
        XCTAssertFalse(MuteLists(muteList: ["youtube.com"], ignoreList: []).isMuted(tab), "entries match whole keys only")
    }

    func testEmptyEntriesNeverMatch() {
        XCTAssertFalse(MuteLists.list([""], contains: [""]))
    }

    func testChangesSilenceNewlyListedAndReleaseUnlisted() {
        let sources = [
            "tab:browser:1": site("www.youtube.com", id: "tab:browser:1"),
            "tab:browser:2": site("www.twitch.tv", id: "tab:browser:2"),
            "tab:browser:3": site("open.spotify.com", id: "tab:browser:3"),
        ]
        let lists = MuteLists(muteList: ["www.youtube.com"], ignoreList: ["open.spotify.com"])
        let changes = lists.changes(in: sources, listMuted: ["tab:browser:2", "tab:browser:3"])
        XCTAssertEqual(Set(changes), [.silence("tab:browser:1"), .release("tab:browser:2")],
                       "the ignored Spotify tab is left out")
        XCTAssertEqual(lists.ignored(in: sources), ["tab:browser:3"])
    }
}
