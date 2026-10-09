import AppKit
import Combine
import CoreAudio

/// Live meter values, kept apart from MixerCore so 15 Hz updates only redraw the meters.
@MainActor
final class LevelStore: ObservableObject {
    @Published var values: [String: Float] = [:]
}

/// The single source of truth: sources, channels, soft takeover, master mode, controller and Chrome.
@MainActor
final class MixerCore: ObservableObject {
    static let channelCount = 8

    @Published private(set) var channels: [String?] = Array(repeating: nil, count: MixerCore.channelCount) {
        didSet {
            for i in 0..<MixerCore.channelCount where oldValue[i] != channels[i] { resetKnobs(i) }
            // A channel that gets any source is no longer held for the one that sat there before the restart.
            if !restore.isEmpty { restore = restore.filter { channels[$0.key] == nil } }
            scheduleRefresh()
            saveLayout()
        }
    }
    @Published private(set) var sources: [String: Source] = [:] { didSet { scheduleRefresh(); saveLayout() } }
    @Published private(set) var waiting: [String] = []
    @Published private(set) var manual: [String] = []
    /// Sources silenced by the mute list: shown in Unassigned, never on a channel.
    @Published private(set) var listMuted: [String] = []
    @Published private(set) var muteAll = false { didSet { scheduleRefresh() } }
    /// The Mac's current microphone is muted (Solo button).
    @Published private(set) var micMuted = false { didSet { scheduleRefresh() } }
    @Published private(set) var faders: [FaderState] = Array(repeating: FaderState(), count: MixerCore.channelCount)
    @Published private(set) var controllerConnected = false { didSet { onStatusChange?() } }
    /// At least one browser's extension is connected.
    @Published private(set) var browserConnected = false
    /// Every open extension connection (one per browser profile).
    @Published private(set) var browserConnections: [BrowserConnection] = []
    @Published private(set) var chromeProblem = false
    /// Chrome loaded the extension from the project folder instead of the app's copy, so it never self-updates.
    @Published private(set) var wrongExtensionFolder = false
    @Published private(set) var outputName = ""
    @Published private(set) var masterSupported = false
    @Published private(set) var masterVolume: Float = 0
    @Published private(set) var permissionStatus: AudioCapturePermission.Status = .unknown

    let settings: AppSettings
    let levels = LevelStore()
    var onOSD: ((OSDMessage) -> Void)?
    var onStatusChange: (() -> Void)?

    /// The hardware the mixer is controlled from.
    private let controller: ControllerDriver = LaunchControlXLDriver()
    /// Output device and master volume (and the process taps the native provider uses).
    private let engine: AudioEngine
    /// Source providers: native apps and browser tabs.
    private let native: NativeAppProvider
    private let chrome = ChromeProvider()
    private let microphone = Microphone()
    private let icons = IconLoader()
    private let launchedAt = Date()

    // Knobs: speed (bottom row) and seek shuttle (middle row)
    private var speedAttached = Array(repeating: false, count: MixerCore.channelCount)
    private var speedPrev: [Float?] = Array(repeating: nil, count: MixerCore.channelCount)
    private var speedSentAt: [String: Date] = [:]
    private var seekDeflection = Array(repeating: Float(0), count: MixerCore.channelCount)
    private var seekArmed = Array(repeating: false, count: MixerCore.channelCount)
    private var seekTimers: [Int: Timer] = [:]
    private var notAvailableShownAt: [Int: Date] = [:]
    private var refreshScheduled = false
    private var blinkUntil: [Date?] = Array(repeating: nil, count: MixerCore.channelCount)
    private var holdTimers: [Int: DispatchWorkItem] = [:]
    private var holdFired = Set<Int>()
    private var lastTopPress: [Int: Date] = [:]
    private var volumeSentAt: [String: Date] = [:]
    private var muteSentAt: [String: Date] = [:]
    private var pendingTabVolume = Set<String>()
    private var masterSetAt = Date.distantPast
    private var permissionRequested = false
    private var cancellables = Set<AnyCancellable>()
    private var pollCount = 0

    // Restoring the channel layout after a restart
    private struct SavedSlot: Codable, Equatable { var id: String; var host: String }
    private static let layoutKey = "channelLayout"
    /// How long a channel is held for the source that sat on it before the restart.
    private static let restoreWindow: TimeInterval = 10
    /// Channels held for sources from the saved layout, until they return or the window ends.
    private var restore: [Int: SavedSlot] = [:]
    private var lastSavedLayout: Data?

    init(settings: AppSettings) {
        self.settings = settings
        let engine = AudioEngine()
        self.engine = engine
        self.native = NativeAppProvider(settings: settings, engine: engine)
    }

    // MARK: - Derived state

    var masterActive: Bool { settings.masterMode && masterSupported }
    var firstSourceChannel: Int { masterActive ? 1 : 0 }
    var hasFreeChannel: Bool { firstFreeChannel(includingHeld: true) != nil }

    var unassigned: [Source] {
        (waiting + manual + listMuted).compactMap { sources[$0] }
    }

    func isManuallyUnassigned(_ id: String) -> Bool { manual.contains(id) }

    func isListMuted(_ id: String) -> Bool { listMuted.contains(id) }

    func channel(of id: String) -> Int? { channels.firstIndex(of: id) }

    func source(onChannel ch: Int) -> Source? {
        guard ch >= 0, ch < channels.count, let id = channels[ch] else { return nil }
        return sources[id]
    }

    func status(ofChannel ch: Int) -> ChannelStatus {
        if masterActive && ch == 0 { return .master }
        guard let s = source(onChannel: ch) else { return .empty }
        return status(of: s, onChannel: true)
    }

    func status(of s: Source, onChannel: Bool) -> ChannelStatus {
        if s.isMuted || (muteAll && onChannel) { return .muted }
        return unmutedStatus(of: s)
    }

    private func unmutedStatus(of s: Source) -> ChannelStatus {
        if s.kind == .app { return .appActive }
        if s.canPlayPause { return s.isPlaying ? .playing : .paused }
        return s.isAudible ? .playing : .paused
    }

    func position(of s: Source) -> Float { settings.position(forGain: s.volume) }

    /// Hint shown while a fader waits for soft takeover, nil when attached.
    func takeoverHint(channel ch: Int) -> String? {
        let f = faders[ch]
        guard !f.attached, let p = f.position else { return nil }
        let target: Float
        if masterActive && ch == 0 {
            target = masterVolume
        } else if let s = source(onChannel: ch) {
            target = position(of: s)
        } else {
            return nil
        }
        // Below the current level the next touch takes over immediately, so only "above" needs a hint.
        if p <= target + 0.03 { return nil }
        return "Move fader down"
    }

    // MARK: - Start

    func start() {
        loadLayout()

        chrome.onTabs = { [weak self] connection, tabs in MainActor.assumeIsolated { self?.handleTabs(tabs, from: connection) } }
        chrome.onConnectionsChange = { [weak self] connections in MainActor.assumeIsolated { self?.browsersChanged(connections) } }
        chrome.start()

        controller.onAction = { [weak self] action in MainActor.assumeIsolated { self?.handle(action) } }
        controller.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.controllerConnectionChanged(connected) } }
        controller.onNeedsLights = { [weak self] in MainActor.assumeIsolated { self?.refreshLEDs() } }
        controller.start()

        engine.onOutputDeviceChange = { [weak self] in self?.outputChanged() }
        engine.onTapFailure = { id in log("Could not control audio of", id) }

        permissionStatus = AudioCapturePermission.status()
        outputChanged()

        mainTimer(every: 0.5) { [weak self] in self?.poll() }
        mainTimer(every: 1.0 / 30.0) { [weak self] in self?.updateLevels() }

        settings.$masterMode.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.masterModeChanged() } }
        }.store(in: &cancellables)
        settings.$naturalCurve.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.detachAllFaders() } }
        }.store(in: &cancellables)
        settings.$ignoreList.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyIgnoreList() } }
        }.store(in: &cancellables)
        settings.$muteList.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyMuteList() } }
        }.store(in: &cancellables)
    }

    func shutdown() {
        native.releaseAll()
        microphone.restore()
        controller.clearLights()
    }

    // MARK: - Polling

    private func poll() {
        pollCount += 1
        pollNativeApps()

        // Follows mute changes made elsewhere, and a switch to another microphone.
        let mic = microphone.isMuted
        if mic != micMuted { micMuted = mic }

        if masterSupported, let v = engine.masterVolume, abs(v - masterVolume) > 0.01,
           Date().timeIntervalSince(masterSetAt) > 1 {
            masterVolume = v
            if masterActive { faders[0].attached = false }
        }

        let browserRunning = !ChromeProvider.runningBrowsers.isEmpty
        let problem = browserRunning && !browserConnected && Date().timeIntervalSince(launchedAt) > 10
        if problem != chromeProblem { chromeProblem = problem }

        if pollCount % 4 == 0 && permissionStatus != .authorized {
            let status = AudioCapturePermission.status()
            if status != permissionStatus {
                permissionStatus = status
                if status == .authorized { permissionGranted() }
            }
        }
    }

    private func pollNativeApps() {
        let snapshot = native.snapshot()
        let running = native.runningKeys()

        for (key, app) in snapshot {
            let id = "app:" + key
            let detail = app.memberNames.count > 1 ? app.memberNames.joined(separator: " + ") : ""
            if var s = sources[id] {
                s.name = app.name
                if let icon = app.icon { s.icon = icon }
                s.isPlaying = app.isRunningOutput
                s.isAudible = app.isRunningOutput
                s.processObjects = app.processObjects
                s.pids = app.pids
                s.bundleIDs = app.bundleIDs
                s.detail = detail
                if s != sources[id] { sources[id] = s }
                if native.isControlling(id) {
                    native.control(id, processObjects: app.processObjects, gain: effectiveGain(s))
                }
            } else if app.isRunningOutput || isHeld(id, host: "") {
                var s = Source(
                    id: id, kind: .app, name: app.name, detail: detail, icon: app.icon,
                    rememberKey: key, isPlaying: true, isAudible: true, isMuted: false, volume: 1,
                    canPlayPause: false, canSetVolume: true
                )
                s.processObjects = app.processObjects
                s.pids = app.pids
                s.bundleIDs = app.bundleIDs
                addSource(s)
            }
        }

        for (id, s) in sources where s.kind == .app {
            let key = String(id.dropFirst(4))
            if !running.contains(key) { removeSource(id) }
        }
    }

    private func updateLevels() {
        var values: [String: Float] = [:]
        // Keep the phase small: a Float of the full timestamp only changes about once a minute.
        let t = Float(Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1000))
        for (id, s) in sources {
            switch s.kind {
            case .app:
                values[id] = min(1, native.level(id))
            case .tab:
                values[id] = s.isAudible && !s.isMuted ? 0.45 + 0.2 * sin(t * 9) + 0.1 * sin(t * 23) : 0
            }
        }
        if values != levels.values { levels.values = values }
    }

    // MARK: - Assignment

    /// Automatic placement skips channels held for a returning source; your own actions (Assign, drag) may use them.
    private func firstFreeChannel(includingHeld: Bool = false) -> Int? {
        (firstSourceChannel..<MixerCore.channelCount).first { channels[$0] == nil && (includingHeld || restore[$0] == nil) }
    }

    private func addSource(_ source: Source) {
        var s = source
        if settings.isMuteListed(listKeys(s)) {
            sources[s.id] = s
            listMuted.append(s.id)
            silenceListed(s.id)
            return
        }
        if s.kind == .app && permissionStatus == .denied {
            s.permissionNeeded = true
            sources[s.id] = s
            manual.append(s.id)
            return
        }
        sources[s.id] = s
        if let ch = heldChannel(for: s) {
            place(s.id, on: ch)
        } else if let ch = firstFreeChannel() {
            place(s.id, on: ch)
        } else {
            waiting.append(s.id)
            osd("–", title: s.displayName, value: "Waiting for a channel", icon: s.icon, duration: 3, source: s)
        }
    }

    private func place(_ id: String, on ch: Int) {
        channels[ch] = id
        if let s = sources[id] {
            osd("\(ch + 1)", title: s.displayName, value: "On channel \(ch + 1)", icon: s.icon, duration: 3, source: s)
        }
        waiting.removeAll { $0 == id }
        manual.removeAll { $0 == id }
        faders[ch].attached = false
        blinkUntil[ch] = Date().addingTimeInterval(0.8)
        after(0.85) { [weak self] in self?.scheduleRefresh() }
        activate(id)
    }

    /// Applies remembered volume and starts controlling the source's audio.
    private func activate(_ id: String) {
        guard var s = sources[id] else { return }
        let remembered = settings.rememberedVolume(for: s.rememberKey)
        if let remembered { s.volume = remembered }
        sources[id] = s
        switch s.kind {
        case .app:
            tapIfPossible(id)
        case .tab:
            if remembered != nil {
                if s.canSetVolume { sendTabVolume(s) } else { pendingTabVolume.insert(id) }
            }
            if muteAll { sendTabMute(s) }
        }
    }

    private func tapIfPossible(_ id: String) {
        guard var s = sources[id], s.kind == .app else { return }
        let status = AudioCapturePermission.status()
        if status != permissionStatus { permissionStatus = status }
        switch status {
        case .denied:
            s.permissionNeeded = true
            sources[id] = s
            if let ch = channel(of: id) {
                channels[ch] = nil
                manual.append(id)
                fillFromWaiting(ch)
            }
        case .unknown where !permissionRequested:
            permissionRequested = true
            AudioCapturePermission.request { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.permissionStatus = granted ? .authorized : (AudioCapturePermission.status() == .unknown ? .unknown : .denied)
                    if granted { self.permissionGranted() } else {
                        for (sid, src) in self.sources where src.kind == .app && self.channel(of: sid) != nil {
                            self.tapIfPossible(sid)
                        }
                    }
                }
            }
        case .unknown:
            break // request pending
        case .authorized:
            if s.permissionNeeded {
                s.permissionNeeded = false
                sources[id] = s
            }
            native.control(id, processObjects: s.processObjects, gain: effectiveGain(s))
        }
    }

    private func permissionGranted() {
        for (id, s) in sources where s.kind == .app {
            if s.permissionNeeded {
                var updated = s
                updated.permissionNeeded = false
                sources[id] = updated
                if listMuted.contains(id) {
                    tapIfPossible(id) // now it can actually be silenced
                    continue
                }
                manual.removeAll { $0 == id }
                if let ch = firstFreeChannel() { place(id, on: ch) } else { waiting.append(id) }
            } else if channel(of: id) != nil {
                tapIfPossible(id)
            }
        }
    }

    private func removeSource(_ id: String) {
        let ch = channel(of: id)
        waiting.removeAll { $0 == id }
        manual.removeAll { $0 == id }
        listMuted.removeAll { $0 == id }
        native.release(id)
        pendingTabVolume.remove(id)
        sources[id] = nil
        if let ch {
            channels[ch] = nil
            faders[ch].attached = false
            fillFromWaiting(ch)
        }
    }

    private func fillFromWaiting(_ ch: Int) {
        guard ch >= firstSourceChannel, channels[ch] == nil, restore[ch] == nil, let next = waiting.first else { return }
        place(next, on: ch)
    }

    // MARK: - Channel layout across restarts

    /// Loads the layout saved before the app last quit, and holds those channels for a short while.
    private func loadLayout() {
        guard let data = UserDefaults.standard.data(forKey: Self.layoutKey),
              let slots = try? JSONDecoder().decode([SavedSlot?].self, from: data) else { return }
        lastSavedLayout = data
        for (ch, slot) in slots.enumerated() where ch < Self.channelCount {
            if let slot { restore[ch] = slot }
        }
        if !restore.isEmpty {
            after(Self.restoreWindow) { [weak self] in self?.endRestore() }
        }
    }

    /// Saves which source sits on which channel: only the source's ID (tab number or app) and, for tabs, the website.
    private func saveLayout() {
        var slots: [SavedSlot?] = Array(repeating: nil, count: Self.channelCount)
        for ch in 0..<Self.channelCount {
            if let id = channels[ch], let s = sources[id] {
                slots[ch] = SavedSlot(id: id, host: s.kind == .tab ? s.host : "")
            } else if let held = restore[ch] {
                slots[ch] = held // keep it saved while it's still being held
            }
        }
        guard let data = try? JSONEncoder().encode(slots), data != lastSavedLayout else { return }
        lastSavedLayout = data
        UserDefaults.standard.set(data, forKey: Self.layoutKey)
    }

    /// A tab must also be on the same website, so a reused tab number can't take another site's channel.
    private func isHeld(_ id: String, host: String) -> Bool {
        restore.values.contains { $0.id == id && (id.hasPrefix("app:") || $0.host == host) }
    }

    private func heldChannel(for s: Source) -> Int? {
        restore.first { entry in
            entry.value.id == s.id && (s.kind == .app || entry.value.host == s.host)
                && entry.key >= firstSourceChannel && channels[entry.key] == nil
        }?.key
    }

    /// Sources that didn't come back in time give up their channels; waiting sources fill them.
    private func endRestore() {
        guard !restore.isEmpty else { return }
        restore.removeAll()
        for ch in firstSourceChannel..<Self.channelCount where channels[ch] == nil { fillFromWaiting(ch) }
        saveLayout()
    }

    // MARK: - User actions (UI and controller)

    func unassign(channel ch: Int) {
        guard let id = channels[ch] else { return }
        if let s = sources[id] {
            osd("\(ch + 1)", title: s.displayName, value: "Unassigned", icon: s.icon, duration: 3, source: s)
        }
        channels[ch] = nil
        faders[ch].attached = false
        manual.append(id)
        applyGainAndMute(id)
        fillFromWaiting(ch)
    }

    func unassign(source id: String) {
        if let ch = channel(of: id) { unassign(channel: ch) }
    }

    func assign(_ id: String) {
        guard sources[id] != nil, channel(of: id) == nil, !listMuted.contains(id), let ch = firstFreeChannel(includingHeld: true) else { return }
        if sources[id]?.permissionNeeded == true {
            AudioCapturePermission.openSystemSettings()
            return
        }
        place(id, on: ch)
    }

    /// Drag and drop: move a source onto a channel, swapping with an occupant.
    func move(_ id: String, to ch: Int) {
        guard ch >= firstSourceChannel, ch < MixerCore.channelCount, let s = sources[id], !s.permissionNeeded,
              !listMuted.contains(id) else { return }
        let occupant = channels[ch]
        if occupant == id { return }
        if let from = channel(of: id) {
            channels[from] = occupant
            channels[ch] = id
            faders[from].attached = false
            faders[ch].attached = false
            if occupant == nil { fillFromWaiting(from) }
        } else {
            if let occupant {
                manual.append(occupant)
                applyGainAndMute(occupant)
            }
            place(id, on: ch)
        }
    }

    func ignore(_ id: String) {
        guard let s = sources[id] else { return }
        let key = primaryKey(s)
        if !key.isEmpty && !settings.ignoreList.contains(key) { settings.ignoreList.append(key) }
        removeSource(id)
    }

    /// Adds the source's app or website to the mute list; it leaves its channel and goes silent.
    func alwaysMute(_ id: String) {
        guard let s = sources[id] else { return }
        let key = primaryKey(s)
        if !key.isEmpty && !settings.muteList.contains(key) { settings.muteList.append(key) }
    }

    /// Takes the source's app or website off the mute list; it plays again and takes a channel.
    func removeFromMuteList(_ id: String) {
        guard let s = sources[id] else { return }
        let keys = Set(listKeys(s))
        settings.muteList.removeAll { keys.contains($0) }
    }

    func setVolumeFromUI(_ id: String, position: Float) {
        setVolume(id, gain: settings.gain(forPosition: position))
        if let ch = channel(of: id) { faders[ch].attached = false }
    }

    func setMasterFromUI(_ position: Float) {
        masterVolume = position
        masterSetAt = Date()
        engine.setMasterVolume(position)
        faders[0].attached = false
    }

    func toggleMute(_ id: String) {
        guard var s = sources[id] else { return }
        s.isMuted.toggle()
        sources[id] = s
        applyGainAndMute(id)
    }

    func togglePlay(_ id: String) {
        guard var s = sources[id], s.kind == .tab, let tabId = s.tabId, let conn = s.browserConnection else { return }
        chrome.togglePlay(conn, tabId: tabId)
        if s.canPlayPause {
            s.isPlaying.toggle()
            sources[id] = s
        }
    }

    /// Side Mute button: silences all media playback (what you hear).
    func toggleMuteAll() {
        muteAll.toggle()
        for id in channels.compactMap({ $0 }) { applyGainAndMute(id) }
        osd("All", title: "All media", value: muteAll ? "Muted" : "Unmuted")
    }

    /// Side Solo button: silences the Mac's current microphone (what others hear from you).
    func toggleMicrophone() {
        let name = microphone.deviceName
        switch microphone.toggle() {
        case .muted:
            micMuted = true
            osd("Mic", title: "Microphone · \(name)", value: "Muted")
        case .unmuted:
            micMuted = false
            osd("Mic", title: "Microphone · \(name)", value: "Unmuted")
        case .unsupported:
            osd("Mic", title: "Microphone · \(name)", value: "Can't be muted by apps")
        }
    }

    func focus(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app:
            native.focus(pids: s.pids)
        case .tab:
            if let tabId = s.tabId, let conn = s.browserConnection { chrome.focus(conn, tabId: tabId, windowId: s.windowId) }
        }
    }

    // MARK: - Volume and mute plumbing

    private func effectiveGain(_ s: Source) -> Float {
        if listMuted.contains(s.id) { return 0 }
        let mutedByAll = muteAll && channel(of: s.id) != nil
        return (s.isMuted || mutedByAll) ? 0 : s.volume
    }

    private func setVolume(_ id: String, gain: Float) {
        guard var s = sources[id] else { return }
        s.volume = max(0, min(1, gain))
        sources[id] = s
        settings.remember(volume: s.volume, for: s.rememberKey)
        switch s.kind {
        case .app: native.setGain(id, effectiveGain(s))
        case .tab: sendTabVolume(s)
        }
    }

    private func applyGainAndMute(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app: native.setGain(id, effectiveGain(s))
        case .tab: sendTabMute(s)
        }
    }

    private func sendTabVolume(_ s: Source) {
        guard let tabId = s.tabId, let conn = s.browserConnection else { return }
        volumeSentAt[s.id] = Date()
        chrome.setVolume(conn, tabId: tabId, gain: s.volume, position: position(of: s))
    }

    private func sendTabMute(_ s: Source) {
        guard let tabId = s.tabId, let conn = s.browserConnection else { return }
        muteSentAt[s.id] = Date()
        let muted = s.isMuted || (muteAll && channel(of: s.id) != nil) || listMuted.contains(s.id)
        chrome.setMute(conn, tabId: tabId, muted: muted)
    }

    // MARK: - Controller

    private func controllerConnectionChanged(_ connected: Bool) {
        // The driver initialises the device itself, then asks for the lights through onNeedsLights.
        controllerConnected = connected
        detachAllFaders()
        for i in 0..<MixerCore.channelCount { faders[i].position = nil }
    }

    private func handle(_ action: ControllerAction) {
        switch action {
        case let .fader(ch, p):
            guard ch < MixerCore.channelCount else { return }
            faderMoved(ch, position: p)
        case let .playPause(ch):
            guard ch < MixerCore.channelCount else { return }
            topPressed(ch)
        case let .muteButton(ch, pressed):
            guard ch < MixerCore.channelCount else { return }
            bottomButton(ch, pressed: pressed)
        case .muteAll:
            toggleMuteAll()
        case .micMute:
            toggleMicrophone()
        case let .speedKnob(ch, p):
            guard ch < MixerCore.channelCount else { return }
            speedKnob(ch, position: p)
        case let .seekKnob(ch, p):
            guard ch < MixerCore.channelCount else { return }
            seekKnob(ch, position: p)
        }
    }

    // MARK: - Knobs

    static let speedSteps: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// Centre = 1×, left end = 0.5×, right end = 2×, in fixed steps.
    static func speed(forKnob p: Float) -> Float {
        if p <= 0.5 {
            let i = Int((p / 0.5 * 2).rounded())            // 0…2 → 0.5, 0.75, 1
            return speedSteps[max(0, min(2, i))]
        }
        let i = Int(((p - 0.5) / 0.5 * 4).rounded())        // 0…4 → 1 … 2
        return speedSteps[2 + max(0, min(4, i))]
    }

    private func speedLabel(_ speed: Float) -> String {
        let text = String(format: "%.2f", speed)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
        return text + "×"
    }

    private func resetKnobs(_ ch: Int) {
        speedAttached[ch] = false
        speedPrev[ch] = nil
        stopSeek(ch)
        seekArmed[ch] = false
        seekDeflection[ch] = 0
    }

    private func notAvailable(_ ch: Int, _ s: Source, _ what: String) {
        let now = Date()
        if let last = notAvailableShownAt[ch], now.timeIntervalSince(last) < 1.5 { return }
        notAvailableShownAt[ch] = now
        osd("\(ch + 1)", title: s.displayName, value: "\(what) not available", source: s)
    }

    private func speedKnob(_ ch: Int, position p: Float) {
        guard !(masterActive && ch == 0), let s = source(onChannel: ch) else { return }
        guard s.canSpeed, let tabId = s.tabId, let conn = s.browserConnection else {
            notAvailable(ch, s, "Speed")
            return
        }
        let speed = MixerCore.speed(forKnob: p)
        if !speedAttached[ch] {
            if abs(speed - s.speed) < 0.01 {
                speedAttached[ch] = true
            } else if let prev = speedPrev[ch], (prev - s.speed) * (speed - s.speed) <= 0 {
                speedAttached[ch] = true
            }
        }
        let previous = speedPrev[ch]
        speedPrev[ch] = speed
        guard speedAttached[ch] else {
            if previous != speed {
                osd("\(ch + 1)", title: s.displayName, value: "Turn to \(speedLabel(s.speed)) to take over", source: s)
            }
            return
        }
        guard abs(speed - s.speed) > 0.001 else { return }
        var updated = s
        updated.speed = speed
        sources[s.id] = updated
        speedSentAt[s.id] = Date()
        chrome.setSpeed(conn, tabId: tabId, rate: speed)
        osd("\(ch + 1)", title: s.displayName, value: "Speed \(speedLabel(speed))", source: s)
        scheduleRefresh()
    }

    private func seekKnob(_ ch: Int, position p: Float) {
        guard !(masterActive && ch == 0), let s = source(onChannel: ch) else { return }
        let d = (p - 0.5) * 2
        let centred = abs(d) < 0.12
        if !seekArmed[ch] {
            // Safety: a knob that wasn't centred when the source arrived does nothing until it passes centre.
            if centred {
                seekArmed[ch] = true
            } else {
                if s.canSeek { osd("\(ch + 1)", title: s.displayName, value: "Return knob to centre to seek", source: s) }
                return
            }
        }
        seekDeflection[ch] = centred ? 0 : d
        if centred {
            stopSeek(ch)
            scheduleRefresh()
            return
        }
        guard s.canSeek, s.tabId != nil else {
            notAvailable(ch, s, "Seek")
            return
        }
        if seekTimers[ch] == nil {
            seekTick(ch)
            seekTimers[ch] = mainTimer(every: 0.5) { [weak self] in self?.seekTick(ch) }
        }
        scheduleRefresh()
    }

    private func seekTick(_ ch: Int) {
        let d = seekDeflection[ch]
        guard d != 0, let s = source(onChannel: ch), s.canSeek, let tabId = s.tabId, let conn = s.browserConnection else {
            stopSeek(ch)
            return
        }
        let magnitude = abs(d)
        let step: Float = magnitude < 0.45 ? 5 : (magnitude < 0.8 ? 15 : 30)
        let seconds = d > 0 ? step : -step
        chrome.seekBy(conn, tabId: tabId, seconds: seconds)
        osd("\(ch + 1)", title: s.displayName, value: d > 0 ? "⏩ +\(Int(step)) s" : "⏪ −\(Int(step)) s", source: s)
    }

    private func stopSeek(_ ch: Int) {
        seekTimers[ch]?.invalidate()
        seekTimers[ch] = nil
    }

    private func softTakeover(_ ch: Int, _ p: Float, target: Float) -> Bool {
        var f = faders[ch]
        if !f.attached {
            if p < target {
                // Fader is below the current level: jumping down is always safe, take over at once.
                f.attached = true
            } else if abs(p - target) < 0.03 {
                f.attached = true
            } else if let prev = f.position, (prev - target) * (p - target) <= 0 {
                f.attached = true
            }
        }
        f.position = p
        faders[ch] = f
        return f.attached
    }

    private func faderMoved(_ ch: Int, position p: Float) {
        if masterActive && ch == 0 {
            if softTakeover(ch, p, target: masterVolume) {
                masterVolume = p
                masterSetAt = Date()
                engine.setMasterVolume(p)
                osd("Master", title: outputName, value: percent(p))
            } else {
                osd("Master", title: outputName, value: takeoverHint(channel: ch) ?? percent(masterVolume))
            }
            return
        }
        guard let s = source(onChannel: ch) else {
            faders[ch].position = p
            return
        }
        if softTakeover(ch, p, target: position(of: s)) {
            setVolume(s.id, gain: settings.gain(forPosition: p))
            osd("\(ch + 1)", title: s.displayName, value: percent(p), source: s)
        } else {
            osd("\(ch + 1)", title: s.displayName, value: (takeoverHint(channel: ch).map { $0 + " · " } ?? "") + percent(position(of: s)), source: s)
        }
    }

    private func topPressed(_ ch: Int) {
        guard let s = source(onChannel: ch), s.kind == .tab else { return }
        let now = Date()
        if s.isTwitch, let last = lastTopPress[ch], now.timeIntervalSince(last) < 0.4 {
            lastTopPress[ch] = nil
            togglePlay(s.id)
            if let tabId = s.tabId, let conn = s.browserConnection { chrome.jumpLive(conn, tabId: tabId) }
            osd("\(ch + 1)", title: s.displayName, value: "Jump to live", source: s)
            return
        }
        lastTopPress[ch] = now
        togglePlay(s.id)
        let playing = sources[s.id]?.isPlaying ?? false
        osd("\(ch + 1)", title: s.displayName, value: s.canPlayPause ? (playing ? "Playing" : "Paused") : "Play/pause", source: s)
    }

    private func bottomButton(_ ch: Int, pressed: Bool) {
        if pressed {
            guard channels[ch] != nil else { return }
            holdFired.remove(ch)
            holdTimers[ch]?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let s = self.source(onChannel: ch) else { return }
                    self.holdFired.insert(ch)
                    self.holdTimers[ch] = nil
                    _ = s
                    self.unassign(channel: ch)
                }
            }
            holdTimers[ch] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        } else {
            holdTimers[ch]?.cancel()
            holdTimers[ch] = nil
            if holdFired.remove(ch) != nil { return }
            guard let s = source(onChannel: ch) else { return }
            toggleMute(s.id)
            let muted = sources[s.id]?.isMuted ?? false
            osd("\(ch + 1)", title: s.displayName, value: muted ? "Muted" : "Unmuted", source: s)
        }
    }

    private func detachAllFaders() {
        for i in 0..<MixerCore.channelCount { faders[i].attached = false }
    }

    // MARK: - LEDs

    private func scheduleRefresh() {
        guard !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshScheduled = false
                self?.refreshLEDs()
            }
        }
    }

    /// Works out what every light should show and hands it to the controller driver.
    private func refreshLEDs() {
        guard controllerConnected else { return }
        let now = Date()
        var lights = ControllerLights(channels: [])
        for ch in 0..<MixerCore.channelCount {
            var c = ChannelLights()
            if !(masterActive && ch == 0), let s = source(onChannel: ch) {
                if s.canSpeed {
                    if s.speed > 1.001 { c.speedKnob = .green } else if s.speed < 0.999 { c.speedKnob = .red }
                }
                if s.canSeek && seekTimers[ch] != nil {
                    c.seekKnob = seekDeflection[ch] > 0 ? .green : .red
                }
                if s.kind == .tab {
                    c.playButton = unmutedStatus(of: s) == .playing ? .green : .amber
                } else {
                    // Native apps have no play/pause; dim green says "in use" without promising one.
                    c.playButton = .greenDim
                }
                if let until = blinkUntil[ch], until > now { c.playButton = .greenBlink }
                if muteAll {
                    c.muteButton = .redBlink
                } else if s.isMuted {
                    c.muteButton = .red
                } else if s.kind == .tab && !s.canSetVolume {
                    c.muteButton = .redDim
                }
            }
            lights.channels.append(c)
        }
        lights.muteAll = muteAll ? .yellow : .off
        lights.micMute = micMuted ? .red : .off
        controller.show(lights)
    }

    // MARK: - Output device and master mode

    private func outputChanged() {
        outputName = engine.outputName
        masterSupported = engine.masterSupported
        masterVolume = engine.masterVolume ?? 0
        masterModeChanged()
        onStatusChange?()
    }

    private func masterModeChanged() {
        if masterActive, let id = channels[0] {
            channels[0] = nil
            if let ch = firstFreeChannel() { place(id, on: ch) } else { waiting.insert(id, at: 0) }
        } else if !masterActive {
            fillFromWaiting(0)
        }
        detachAllFaders()
        scheduleRefresh()
    }

    private func applyIgnoreList() {
        for (id, s) in sources where settings.isIgnored(listKeys(s)) {
            // Moved here from the mute list: give the sound back before letting go of it.
            if listMuted.contains(id) {
                listMuted.removeAll { $0 == id }
                if s.kind == .tab { sendTabMute(s) }
            }
            removeSource(id)
        }
    }

    // MARK: - Mute list

    /// Keys a list entry can match: the app's group key and bundle IDs, or the tab's website.
    private func listKeys(_ s: Source) -> [String] {
        s.kind == .app ? [String(s.id.dropFirst(4))] + s.bundleIDs : [s.host]
    }

    /// The key written to a list when the user picks "Always ignore" or "Always mute".
    private func primaryKey(_ s: Source) -> String {
        s.kind == .app ? String(s.id.dropFirst(4)) : s.host
    }

    private func silenceListed(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app: tapIfPossible(id)   // gain 0 through the tap
        case .tab: sendTabMute(s)      // Chrome's tab mute
        }
    }

    /// Applies a changed mute list to sources that are already playing.
    private func applyMuteList() {
        for (id, s) in sources where !settings.isIgnored(listKeys(s)) {
            let listed = settings.isMuteListed(listKeys(s))
            let muted = listMuted.contains(id)
            if listed && !muted {
                if let ch = channel(of: id) {
                    channels[ch] = nil
                    faders[ch].attached = false
                }
                waiting.removeAll { $0 == id }
                manual.removeAll { $0 == id }
                listMuted.append(id)
                silenceListed(id)
                osd("–", title: s.displayName, value: "Muted by list", icon: s.icon, duration: 3, source: s)
            } else if !listed && muted {
                listMuted.removeAll { $0 == id }
                applyGainAndMute(id) // sound back first
                if let ch = firstFreeChannel() { place(id, on: ch) } else { waiting.append(id) }
            }
        }
        for ch in firstSourceChannel..<MixerCore.channelCount where channels[ch] == nil { fillFromWaiting(ch) }
    }

    // MARK: - Browsers

    private func browsersChanged(_ connections: [BrowserConnection]) {
        let before = Set(browserConnections.map(\.id))
        browserConnections = connections.sorted { $0.id < $1.id }
        browserConnected = !connections.isEmpty
        if browserConnected { chromeProblem = false }
        let wrong = connections.contains { !$0.extensionOK }
        if wrong != wrongExtensionFolder { wrongExtensionFolder = wrong }

        // A browser whose extension has connected is controlled tab by tab from now on, never as a whole app.
        for c in connections {
            guard let browser = c.browser, !settings.extensionBrowsers.contains(browser.bundleID) else { continue }
            settings.extensionBrowsers.append(browser.bundleID)
            for (id, s) in sources where s.kind == .app && s.bundleIDs.contains(where: { Browsers.info(forBundleID: $0) == browser }) {
                removeSource(id)
            }
        }

        // Tabs of a closed connection leave after a grace period, unless a reconnect reports them again.
        let gone = before.subtracting(connections.map(\.id))
        for connection in gone {
            after(6) { [weak self] in
                guard let self else { return }
                for (id, s) in self.sources where s.kind == .tab && s.browserConnection == connection {
                    self.removeSource(id)
                }
                self.updateBrowserLabels()
            }
        }
    }

    /// Tabs show their browser's name only while tabs from more than one browser are in the mixer.
    private func updateBrowserLabels() {
        let keys = Set(sources.values.filter { $0.kind == .tab }.map(\.browserKey))
        let several = keys.count > 1
        for (id, s) in sources where s.kind == .tab {
            let label = several ? (Browsers.info(forBundleID: s.browserKey)?.name ?? "Browser") : nil
            if s.browserLabel != label {
                var updated = s
                updated.browserLabel = label
                sources[id] = updated
            }
        }
    }

    /// Merges one browser connection's tab list into the mixer's sources.
    private func handleTabs(_ tabs: [TabReport], from connection: BrowserConnection) {
        var seen = Set<String>()
        let now = Date()
        for t in tabs {
            let tabId = t.tabId
            // Tab numbers are only unique within one browser, so the browser is part of the ID.
            let id = "tab:\(connection.key):\(tabId)"
            let host = t.host
            let title = t.title
            let audible = t.audible
            let muted = t.muted
            let hasMedia = t.hasMedia
            let playing = t.playing
            let canVolume = t.canVolume
            let canSpeed = t.canSpeed
            let canSeek = t.canSeek
            let speed = t.speed
            // Spotify reports its slider position; convert it to gain with the app's curve.
            let volume = t.reportedVolume.map { t.volumeIsPosition ? settings.gain(forPosition: $0) : $0 }
            let favicon = t.favicon
            let windowId = t.windowId
            let windowBounds = t.windowBounds

            if sources[id] == nil {
                // A paused tab that held a channel before the restart takes it back too.
                guard audible || (hasMedia && isHeld(id, host: host)), !settings.isIgnored([host]) else { continue }
                seen.insert(id)
                var s = Source(
                    id: id, kind: .tab, name: SiteNames.name(forHost: host),
                    detail: SiteNames.cleanTitle(title, host: host), icon: nil, rememberKey: host,
                    isPlaying: playing || !hasMedia, isAudible: audible, isMuted: muted,
                    volume: canVolume ? (volume ?? 1) : 1, canPlayPause: hasMedia, canSetVolume: canVolume
                )
                s.tabId = tabId
                s.windowId = windowId
                s.browserConnection = connection.id
                s.browserKey = connection.key
                s.windowBounds = windowBounds
                s.canSpeed = canSpeed
                s.canSeek = canSeek
                if let speed { s.speed = speed }
                s.host = host
                s.icon = icons.icon(for: favicon) { [weak self] image in self?.setIcon(id, image) }
                addSource(s)
                continue
            }

            seen.insert(id)
            guard var s = sources[id] else { continue }
            if s.host != host {
                s.icon = nil
                s.rememberKey = host
            }
            s.host = host
            s.name = SiteNames.name(forHost: host)
            s.detail = SiteNames.cleanTitle(title, host: host)
            s.isAudible = audible
            s.isPlaying = hasMedia ? playing : audible
            s.canPlayPause = hasMedia
            s.canSetVolume = canVolume
            s.windowId = windowId
            s.browserConnection = connection.id
            if let windowBounds { s.windowBounds = windowBounds }
            s.canSpeed = canSpeed
            s.canSeek = canSeek
            if let speed, abs(speed - s.speed) > 0.01, now.timeIntervalSince(speedSentAt[id] ?? .distantPast) > 1.5 {
                s.speed = speed // changed in the page itself (e.g. YouTube's own menu)
                if let ch = channel(of: id) { speedAttached[ch] = false }
            }
            let onChannel = channel(of: id) != nil
            if now.timeIntervalSince(muteSentAt[id] ?? .distantPast) > 1.0 && !(muteAll && onChannel) && !listMuted.contains(id) {
                s.isMuted = muted
            }
            if canVolume, pendingTabVolume.contains(id) {
                pendingTabVolume.remove(id)
                sources[id] = s
                sendTabVolume(s)
            } else if canVolume, let v = volume, abs(v - s.volume) > 0.01,
                      now.timeIntervalSince(volumeSentAt[id] ?? .distantPast) > 1.5 {
                s.volume = v
                if let ch = channel(of: id) { faders[ch].attached = false }
            }
            if let icon = icons.icon(for: favicon, completion: { [weak self] image in self?.setIcon(id, image) }) {
                s.icon = icon
            }
            if s != sources[id] { sources[id] = s }
        }
        for (id, s) in sources where s.kind == .tab && s.browserConnection == connection.id && !seen.contains(id) {
            removeSource(id)
        }
        updateBrowserLabels()
    }

    private func setIcon(_ id: String, _ image: NSImage) {
        guard var s = sources[id] else { return }
        s.icon = image
        sources[id] = s
    }

    // MARK: - OSD

    private func osd(_ channel: String, title: String, value: String, icon: NSImage? = nil, duration: TimeInterval = 2, source: Source? = nil) {
        guard settings.showOSD else { return }
        let point = source.flatMap { screenPoint(for: $0) }
        onOSD?(OSDMessage(channel: channel, title: title, value: value, icon: icon, duration: duration, screenPoint: point))
    }

    /// Centre of the window the source plays in, in Cocoa screen coordinates, so the pop-up appears on that screen.
    private func screenPoint(for s: Source) -> CGPoint? {
        // Chrome and Core Graphics use a top-left origin on the primary screen; Cocoa uses bottom-left.
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return nil }
        func cocoa(_ r: CGRect) -> CGPoint { CGPoint(x: r.midX, y: primaryHeight - r.midY) }
        switch s.kind {
        case .tab:
            return s.windowBounds.map(cocoa)
        case .app:
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
            var best: CGRect?
            for info in list {
                guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, s.pids.contains(pid),
                      (info[kCGWindowLayer as String] as? Int) == 0,
                      let dict = info[kCGWindowBounds as String] as? NSDictionary,
                      let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) else { continue }
                if best == nil || rect.width * rect.height > best!.width * best!.height { best = rect }
            }
            return best.map(cocoa)
        }
    }

    private func percent(_ p: Float) -> String { "\(Int((p * 100).rounded()))%" }
}
