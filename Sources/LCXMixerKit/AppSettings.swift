import Foundation
import ServiceManagement

struct GroupRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// What the user typed, kept as-is so commas and spaces can be typed freely.
    var prefixesText: String

    /// Bundle identifier prefixes that belong to this group.
    var prefixes: [String] {
        prefixesText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A rule only takes effect once it has both a name and at least one prefix.
    var isComplete: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && !prefixes.isEmpty }

    init(name: String, prefixes: [String]) {
        self.name = name
        self.prefixesText = prefixes.joined(separator: ", ")
    }

    private enum CodingKeys: String, CodingKey { case id, name, prefixesText, prefixes }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        if let text = try c.decodeIfPresent(String.self, forKey: .prefixesText) {
            prefixesText = text
        } else {
            prefixesText = (try c.decodeIfPresent([String].self, forKey: .prefixes) ?? []).joined(separator: ", ")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(prefixesText, forKey: .prefixesText)
    }
}

enum ControllerKind: String, CaseIterable, Identifiable {
    case launchControlXL, mackieControl, midiLearn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .launchControlXL: return "Novation Launch Control XL mk2"
        case .mackieControl: return "Mackie Control (experimental)"
        case .midiLearn: return "Any MIDI controller (MIDI learn)"
        }
    }
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let defaults: UserDefaults

    @Published var masterMode: Bool { didSet { defaults.set(masterMode, forKey: "masterMode") } }
    @Published var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: "launchAtLogin"); applyLaunchAtLogin() } }
    @Published var showOSD: Bool { didSet { defaults.set(showOSD, forKey: "showOSD") } }
    @Published var rememberVolumes: Bool { didSet { defaults.set(rememberVolumes, forKey: "rememberVolumes") } }
    @Published var naturalCurve: Bool { didSet { defaults.set(naturalCurve, forKey: "naturalCurve") } }
    @Published var alwaysInDock: Bool { didSet { defaults.set(alwaysInDock, forKey: "alwaysInDock") } }
    /// Which controller the mixer listens to.
    @Published var controllerKind: ControllerKind { didSet { defaults.set(controllerKind.rawValue, forKey: "controllerKind") } }
    /// The MIDI device used with MIDI learn, by its display name.
    @Published var midiDevice: String { didSet { defaults.set(midiDevice, forKey: "midiDevice") } }
    /// MIDI learn assignments, keyed by `LearnTarget.key`.
    @Published var midiBindings: [String: MIDIBinding] { didSet { save(midiBindings, "midiBindings") } }
    /// Text and layout size for the app's windows, panel and pop-up.
    @Published var textSize: TextSize { didSet { defaults.set(textSize.rawValue, forKey: "textSize") } }
    @Published var groups: [GroupRule] { didSet { save(groups, "groups") } }
    /// Apps (bundle or group IDs) and websites the mixer leaves completely alone.
    /// An entry lives on one list only: adding it here takes it off the mute list.
    @Published var ignoreList: [String] {
        didSet {
            save(ignoreList, "ignoreList")
            let overlap = Set(ignoreList).intersection(muteList)
            if !overlap.isEmpty { muteList.removeAll { overlap.contains($0) } }
        }
    }
    /// Apps (bundle or group IDs) and websites that are always silenced and never take a channel.
    /// An entry lives on one list only: adding it here takes it off the ignore list.
    @Published var muteList: [String] {
        didSet {
            save(muteList, "muteList")
            let overlap = Set(muteList).intersection(ignoreList)
            if !overlap.isEmpty { ignoreList.removeAll { overlap.contains($0) } }
        }
    }
    /// Browsers whose extension has connected at least once; from then on they're controlled tab by tab.
    @Published var extensionBrowsers: [String] { didSet { save(extensionBrowsers, "extensionBrowsers") } }
    private(set) var rememberedVolumes: [String: Float]

    static let defaultGroups = [GroupRule(name: "League", prefixes: ["com.riotgames."])]
    static let defaultIgnore = [
        "com.apple.systemsoundserverd",
        "com.apple.UserNotificationCenter",
        "com.apple.notificationcenterui",
    ]

    /// The app uses `shared`; tests pass a throwaway store.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "masterMode": false,
            "launchAtLogin": true,
            "showOSD": true,
            "rememberVolumes": true,
            "naturalCurve": true,
            "alwaysInDock": false,
        ])
        masterMode = defaults.bool(forKey: "masterMode")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        showOSD = defaults.bool(forKey: "showOSD")
        rememberVolumes = defaults.bool(forKey: "rememberVolumes")
        naturalCurve = defaults.bool(forKey: "naturalCurve")
        alwaysInDock = defaults.bool(forKey: "alwaysInDock")
        textSize = TextSize(rawValue: defaults.integer(forKey: "textSize")) ?? .standard
        controllerKind = ControllerKind(rawValue: defaults.string(forKey: "controllerKind") ?? "") ?? .launchControlXL
        midiDevice = defaults.string(forKey: "midiDevice") ?? ""
        midiBindings = AppSettings.load("midiBindings", defaults) ?? [:]
        groups = AppSettings.load("groups", defaults) ?? AppSettings.defaultGroups
        ignoreList = AppSettings.load("ignoreList", defaults) ?? AppSettings.defaultIgnore
        muteList = AppSettings.load("muteList", defaults) ?? []
        extensionBrowsers = AppSettings.load("extensionBrowsers", defaults) ?? []
        rememberedVolumes = (defaults.dictionary(forKey: "rememberedVolumes") as? [String: Float]) ?? [:]

        // Entries saved on both lists by earlier builds stay on the mute list only.
        if !Set(ignoreList).isDisjoint(with: muteList) {
            let muted = Set(muteList)
            ignoreList.removeAll { muted.contains($0) }
            save(ignoreList, "ignoreList")
        }
    }

    /// One step larger (+1) or smaller (−1), stopping at the ends.
    func stepTextSize(_ delta: Int) {
        let next = max(TextSize.smaller.rawValue, min(TextSize.largest.rawValue, textSize.rawValue + delta))
        if let size = TextSize(rawValue: next) { textSize = size }
    }

    func remember(volume: Float, for key: String) {
        guard rememberVolumes, !key.isEmpty else { return }
        rememberedVolumes[key] = volume
        defaults.set(rememberedVolumes, forKey: "rememberedVolumes")
    }

    func rememberedVolume(for key: String) -> Float? {
        rememberVolumes ? rememberedVolumes[key] : nil
    }

    func isIgnored(_ keys: [String]) -> Bool {
        keys.contains { key in ignoreList.contains(where: { !$0.isEmpty && $0 == key }) }
    }

    /// Chrome is always handled tab by tab; another browser once its extension has connected.
    /// Until then it shows up as one whole app, like Safari or Firefox.
    func isPerTabBrowser(_ bundleID: String) -> Bool {
        guard let browser = Browsers.info(forBundleID: bundleID) else { return false }
        return browser.bundleID.hasPrefix(Browsers.chrome.bundleID) || extensionBrowsers.contains(browser.bundleID)
    }

    func isMuteListed(_ keys: [String]) -> Bool {
        keys.contains { key in muteList.contains(where: { !$0.isEmpty && $0 == key }) }
    }

    /// Fader position (0…1) → gain (0…1).
    func gain(forPosition p: Float) -> Float {
        let x = max(0, min(1, p))
        return naturalCurve ? x * x : x
    }

    /// Gain (0…1) → fader position (0…1).
    func position(forGain g: Float) -> Float {
        let x = max(0, min(1, g))
        return naturalCurve ? sqrt(x) : x
    }

    func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log("Launch at login change failed:", error.localizedDescription)
        }
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }

    private static func load<T: Decodable>(_ key: String, _ defaults: UserDefaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
