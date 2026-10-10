import AppKit
import Combine
import CoreAudio
import os

/// Live meter values, kept apart from MixerCore so 15 Hz updates only redraw the meters.
@MainActor
final class LevelStore: ObservableObject {
    @Published var values: [String: Float] = [:]
    /// Sources without a measurable level, shown as activity instead of a meter: browser tabs,
    /// and native apps that play untouched at full volume (no tap, so nothing to measure).
    @Published var activity: Set<String> = []
}

/// The single source of truth: sources, channels, soft takeover, master mode, controller and Chrome.
/// Tests drive it through a few entry points that are internal rather than private: `handleTabs`,
/// `handle(_:)`, `loadLayout`, `applyMuteList`, `startController` and `refreshLEDs`.
@MainActor
final class MixerCore: ObservableObject {
    static let channelCount = 8

    /// Who sits on which channel, who waits, who is unassigned (ChannelAssignment keeps the books).
    @Published private(set) var assignment = ChannelAssignment(channels: MixerCore.channelCount) {
        didSet {
            guard assignment.channels != oldValue.channels else { return }
            for i in 0..<MixerCore.channelCount where oldValue.channels[i] != assignment.channels[i] { resetKnobs(i) }
            scheduleRefresh()
            saveLayout()
        }
    }
    @Published private(set) var sources: [String: Source] = [:] { didSet { scheduleRefresh(); saveLayout() } }
    var channels: [String?] { assignment.channels }
    var waiting: [String] { assignment.waiting }
    var manual: [String] { assignment.manual }
    /// Sources silenced by the mute list: shown in Unassigned, never on a channel.
    var listMuted: [String] { assignment.listMuted }
    @Published private(set) var muteAll = false { didSet { scheduleRefresh() } }
    /// The Mac's current microphone is muted (Solo button).
    @Published private(set) var micMuted = false { didSet { scheduleRefresh() } }
    @Published private(set) var faders: [FaderState] = Array(repeating: FaderState(), count: MixerCore.channelCount)
    @Published private(set) var controllerConnected = false { didSet { onStatusChange?() } }
    /// The current controller's name, e.g. "Launch Control XL".
    @Published private(set) var controllerName = ""
    /// The MIDI learn target waiting for a control to be moved, if any.
    @Published private(set) var learning: LearnTarget?
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

    /// The hardware the mixer is controlled from; replaced when Settings picks another controller.
    private var controller: ControllerDriver
    /// Output device and master volume (and the process taps the native provider uses).
    private let engine: AudioEngine
    /// Source providers: native apps and browser tabs.
    private let native: NativeAppProvider
    private let chrome = ChromeProvider()
    private let microphone = Microphone()
    private let icons = IconLoader()
    private let launchedAt = Date()

    // Knobs and buttons: what a move means is ControlInput's; the timers stay here.
    private var controls = ControlInput(channels: MixerCore.channelCount)
    /// Seek shuttle (middle row): jumps every 0.5 s while a knob is turned.
    private var seekTimers: [Int: Timer] = [:]
    /// Holding a channel's play button for 3 s reloads its tab.
    private let playHold = ButtonHold()
    /// Holding a channel's mute button for 1 s unassigns it.
    private let muteHold = ButtonHold()
    private var speedSentAt: [String: Date] = [:]
    private var notAvailableShownAt: [Int: Date] = [:]
    private var refreshScheduled = false
    private var blinkUntil: [Date?] = Array(repeating: nil, count: MixerCore.channelCount)
    private var volumeSentAt: [String: Date] = [:]
    private var muteSentAt: [String: Date] = [:]
    private var pendingTabVolume = Set<String>()
    private var masterSetAt = Date.distantPast
    private var permissionRequested = false
    private var cancellables = Set<AnyCancellable>()
    private var pollCount = 0

    // Restoring the channel layout after a restart
    private static let layoutKey = "channelLayout"
    /// How long a channel is held for the source that sat on it before the restart.
    private static let restoreWindow: TimeInterval = 10
    private var lastSavedLayout: Data?

    /// Where the channel layout is saved between launches.
    private let layoutStore: UserDefaults

    /// The app passes only `settings`; tests also pass a stand-in controller and a throwaway store.
    init(settings: AppSettings, controller: ControllerDriver? = nil, layoutStore: UserDefaults = .standard) {
        self.settings = settings
        self.layoutStore = layoutStore
        let engine = AudioEngine()
        self.engine = engine
        self.controller = controller ?? MixerCore.makeController(settings)
        self.native = NativeAppProvider(settings: settings, engine: engine)
    }

    // MARK: - Derived state

    var masterActive: Bool { settings.masterMode && masterSupported }
    var firstSourceChannel: Int { masterActive ? 1 : 0 }
    var hasFreeChannel: Bool { firstFreeChannel(includingHeld: true) != nil }

    /// Sources waiting for a channel, or unassigned by you. Sources the mute list silences aren't
    /// among them: nothing is waiting there, so they get their own quiet line (`listMutedSources`).
    var unassigned: [Source] {
        (waiting + manual).compactMap { sources[$0] }
    }

    /// Sources the mute list is silencing right now.
    var listMutedSources: [Source] { listMuted.compactMap { sources[$0] } }

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
        return s.unmutedStatus
    }

    func position(of s: Source) -> Float { settings.position(forGain: s.volume) }

    /// Hint shown while a fader waits for soft takeover, nil when attached.
    func takeoverHint(channel ch: Int) -> String? {
        let target: Float
        if masterActive && ch == 0 {
            target = masterVolume
        } else if let s = source(onChannel: ch) {
            target = position(of: s)
        } else {
            return nil
        }
        return ControlInput.takeoverHint(faders[ch], target: target)
    }

    // MARK: - Start

    func start() {
        loadLayout()

        chrome.onTabs = { [weak self] connection, tabs in MainActor.assumeIsolated { self?.handleTabs(tabs, from: connection) } }
        chrome.onConnectionsChange = { [weak self] connections in MainActor.assumeIsolated { self?.browsersChanged(connections) } }
        chrome.start()

        startController()

        engine.onOutputDeviceChange = { [weak self] in self?.outputChanged() }
        engine.onTapFailure = { id in Log.audio.error("Could not control audio of \(id, privacy: .public)") }

        permissionStatus = AudioCapturePermission.status()
        outputChanged()

        // Changes arrive as notifications; this slow check is only a safety net.
        native.onChange = { [weak self] in self?.scheduleNativeCheck() }
        native.startListening()
        microphone.onChange = { [weak self] in self?.microphoneChanged() }
        microphone.startListening()
        listenToMasterVolume()
        let safety = mainTimer(every: 10) { [weak self] in self?.poll() }
        safety.tolerance = 2
        poll()

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
        settings.$controllerKind.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.switchController() } }
        }.store(in: &cancellables)
        settings.$midiDevice.removeDuplicates().dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.switchController() } }
        }.store(in: &cancellables)
    }

    func shutdown() {
        native.releaseAll()
        microphone.restore()
        controller.clearLights()
    }

    // MARK: - Polling

    /// Safety net, every 10 s: everything below also arrives as notifications.
    private func poll() {
        pollCount += 1
        pollNativeApps()
        microphoneChanged()
        masterVolumeChanged()

        let browserRunning = !ChromeProvider.runningBrowsers.isEmpty
        let problem = browserRunning && !browserConnected && Date().timeIntervalSince(launchedAt) > 10
        if problem != chromeProblem { chromeProblem = problem }

        if permissionStatus != .authorized {
            let status = AudioCapturePermission.status()
            if status != permissionStatus {
                permissionStatus = status
                if status == .authorized { permissionGranted() }
            }
        }
    }

    private func pollNativeApps() {
        let marker = Signposts.poi.beginInterval("Native check")
        defer { Signposts.poi.endInterval("Native check", marker) }
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
                updateTap(s)
            } else if app.isRunningOutput || assignment.isHeld(id, host: "") {
                var s = Source(
                    id: id, kind: .app, name: app.name, detail: detail, icon: app.icon,
                    rememberKey: key, isPlaying: true, isAudible: true, isMuted: false, volume: 1,
                    canPlayPause: false, canSetVolume: true
                )
                s.processObjects = app.processObjects
                s.pids = app.pids
                s.bundleIDs = app.bundleIDs
                addSource(s)
                if let added = sources[id] { updateTap(added) }
            }
        }

        for (id, s) in sources where s.kind == .app {
            let key = String(id.dropFirst(4))
            if !running.contains(key) { removeSource(id) }
        }
    }

    /// Brings a native app's tap up to date. On a channel, silenced by the mute list, or turned down
    /// before: the tap follows its volume. Otherwise it plays untouched, with a tap that only
    /// listens while a meter is on screen.
    private func updateTap(_ s: Source) {
        guard s.kind == .app, permissionStatus == .authorized else { return }
        if native.isControlling(s.id) || channel(of: s.id) != nil || listMuted.contains(s.id) {
            native.apply(s.id, processObjects: s.processObjects, gain: effectiveGain(s), playing: s.isPlaying)
        } else {
            native.listen(s.id, processObjects: s.processObjects, playing: s.isPlaying)
        }
    }

    /// Set by the app: true while a window or panel showing meters is on screen. The meter timer
    /// and the taps' level measurement run only then.
    var metersWanted = false {
        didSet {
            guard metersWanted != oldValue else { return }
            native.setMetering(metersWanted)
            if metersWanted {
                // Just after the window or panel has drawn, so starting taps doesn't delay it.
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.metersWanted else { return }
                        for s in self.sources.values where s.kind == .app { self.updateTap(s) }
                    }
                }
            }
            meterTimer?.invalidate()
            meterTimer = nil
            if metersWanted {
                meterTimer = mainTimer(every: 1.0 / 30.0) { [weak self] in self?.updateLevels() }
                updateLevels()
            } else {
                if !levels.values.isEmpty { levels.values = [:] }
                if !levels.activity.isEmpty { levels.activity = [] }
            }
        }
    }
    private var meterTimer: Timer?

    private func updateLevels() {
        var values: [String: Float] = [:]
        var activity = Set<String>()
        for (id, s) in sources {
            let audible = s.isAudible && !s.isMuted && !muteAll && !listMuted.contains(id)
            switch s.kind {
            case .app where native.canMeasure(id):
                values[id] = min(1, native.level(id))
            case .app, .tab:
                // No measurable level: just "audible", shown as activity drops.
                values[id] = audible ? 1 : 0
                activity.insert(id)
            }
        }
        if values != levels.values { levels.values = values }
        if activity != levels.activity { levels.activity = activity }
    }

    // MARK: - Change notifications

    private var nativeCheckScheduled = false

    /// Bursts of notifications (an app opening several audio processes) become one check.
    private func scheduleNativeCheck() {
        guard !nativeCheckScheduled else { return }
        nativeCheckScheduled = true
        after(0.1) { [weak self] in
            guard let self else { return }
            self.nativeCheckScheduled = false
            self.pollNativeApps()
        }
    }

    private func microphoneChanged() {
        let mic = microphone.isMuted
        if mic != micMuted { micMuted = mic }
    }

    private var masterListener: CAPropertyListener?

    /// Follows the output device's volume (master mode), on change rather than on a timer.
    private func listenToMasterVolume() {
        masterListener = CA.masterVolumeListener(engine.outputDevice) { [weak self] in
            self?.masterVolumeChanged()
        }
    }

    private func masterVolumeChanged() {
        if masterSupported, let v = engine.masterVolume, abs(v - masterVolume) > 0.01,
           Date().timeIntervalSince(masterSetAt) > 1 {
            masterVolume = v
            if masterActive { faders[0].attached = false }
        }
    }

    // MARK: - Assignment

    /// Automatic placement skips channels held for a returning source; your own actions (Assign, drag) may use them.
    private func firstFreeChannel(includingHeld: Bool = false) -> Int? {
        assignment.firstFreeChannel(from: firstSourceChannel, includingHeld: includingHeld)
    }

    private func addSource(_ source: Source) {
        var s = source
        if lists.isMuted(s) {
            sources[s.id] = s
            assignment.addListMuted(s.id)
            silenceListed(s.id)
            return
        }
        if s.kind == .app && permissionStatus == .denied {
            s.permissionNeeded = true
            sources[s.id] = s
            assignment.addManual(s.id)
            return
        }
        sources[s.id] = s
        if let ch = assignment.heldChannel(for: s, from: firstSourceChannel) {
            place(s.id, on: ch)
        } else if let ch = firstFreeChannel() {
            place(s.id, on: ch)
        } else {
            assignment.addWaiting(s.id)
            osd("–", title: s.displayName, value: "Waiting for a channel", icon: s.icon, duration: 3, source: s)
        }
    }

    private func place(_ id: String, on ch: Int) {
        assignment.place(id, on: ch)
        if let s = sources[id] {
            osd("\(ch + 1)", title: s.displayName, value: "On channel \(ch + 1)", icon: s.icon, duration: 3, source: s)
        }
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

    /// From the welcome window: asks for the audio permission, or opens System Settings if it was refused.
    func requestAudioPermission() {
        switch AudioCapturePermission.status() {
        case .authorized:
            permissionStatus = .authorized
        case .denied:
            AudioCapturePermission.openSystemSettings()
        case .unknown:
            permissionRequested = true
            AudioCapturePermission.request { [weak self] granted in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.permissionStatus = granted ? .authorized : (AudioCapturePermission.status() == .unknown ? .unknown : .denied)
                    if granted { self.permissionGranted() }
                }
            }
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
                assignment.clear(ch)
                assignment.addManual(id)
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
            native.apply(id, processObjects: s.processObjects, gain: effectiveGain(s), playing: s.isPlaying)
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
                assignment.removeManual(id)
                if let ch = firstFreeChannel() { place(id, on: ch) } else { assignment.addWaiting(id) }
            } else if channel(of: id) != nil {
                tapIfPossible(id)
            }
        }
        if metersWanted {
            for s in sources.values where s.kind == .app { updateTap(s) }
        }
    }

    private func removeSource(_ id: String) {
        let ch = channel(of: id)
        assignment.forget(id)
        native.release(id)
        pendingTabVolume.remove(id)
        sources[id] = nil
        if let ch {
            assignment.clear(ch)
            faders[ch].attached = false
            fillFromWaiting(ch)
        }
    }

    private func fillFromWaiting(_ ch: Int) {
        guard let next = assignment.nextToFill(ch, from: firstSourceChannel) else { return }
        place(next, on: ch)
    }

    // MARK: - Channel layout across restarts

    /// Loads the layout saved before the app last quit, and holds those channels for a short while.
    func loadLayout() {
        guard let data = layoutStore.data(forKey: Self.layoutKey),
              let slots = try? JSONDecoder().decode([ChannelAssignment.SavedSlot?].self, from: data) else { return }
        lastSavedLayout = data
        assignment.hold(slots)
        if !assignment.held.isEmpty {
            after(Self.restoreWindow) { [weak self] in self?.endRestore() }
        }
    }

    /// Saves which source sits on which channel: only the source's ID (tab number or app) and, for tabs, the website.
    private func saveLayout() {
        guard let data = try? JSONEncoder().encode(assignment.layout(sources)), data != lastSavedLayout else { return }
        lastSavedLayout = data
        layoutStore.set(data, forKey: Self.layoutKey)
    }

    /// Sources that didn't come back in time give up their channels; waiting sources fill them.
    private func endRestore() {
        guard !assignment.held.isEmpty else { return }
        assignment.endHolding()
        for ch in firstSourceChannel..<Self.channelCount where channels[ch] == nil { fillFromWaiting(ch) }
        saveLayout()
    }

    // MARK: - User actions (UI and controller)

    func unassign(channel ch: Int) {
        guard let id = channels[ch] else { return }
        if let s = sources[id] {
            osd("\(ch + 1)", title: s.displayName, value: "Unassigned", icon: s.icon, duration: 3, source: s)
        }
        assignment.clear(ch)
        faders[ch].attached = false
        assignment.addManual(id)
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
            assignment.swap(from, ch)
            faders[from].attached = false
            faders[ch].attached = false
            if occupant == nil { fillFromWaiting(from) }
        } else {
            if let occupant {
                assignment.addManual(occupant)
                applyGainAndMute(occupant)
            }
            place(id, on: ch)
        }
    }

    func ignore(_ id: String) {
        guard let s = sources[id] else { return }
        let key = MuteLists.primaryKey(of: s)
        if !key.isEmpty && !settings.ignoreList.contains(key) { settings.ignoreList.append(key) }
        removeSource(id)
    }

    /// Adds the source's app or website to the mute list; it leaves its channel and goes silent.
    func alwaysMute(_ id: String) {
        guard let s = sources[id] else { return }
        let key = MuteLists.primaryKey(of: s)
        if !key.isEmpty && !settings.muteList.contains(key) { settings.muteList.append(key) }
    }

    /// Takes the source's app or website off the mute list; it plays again and takes a channel.
    func removeFromMuteList(_ id: String) {
        guard let s = sources[id] else { return }
        let keys = Set(MuteLists.keys(of: s))
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
        case .app: native.apply(id, processObjects: s.processObjects, gain: effectiveGain(s), playing: s.isPlaying)
        case .tab: sendTabVolume(s)
        }
    }

    private func applyGainAndMute(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app: native.apply(id, processObjects: s.processObjects, gain: effectiveGain(s), playing: s.isPlaying)
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

    private static func makeController(_ settings: AppSettings) -> ControllerDriver {
        switch settings.controllerKind {
        case .launchControlXL: return LaunchControlXLDriver()
        case .midiLearn: return MIDILearnDriver(settings: settings)
        case .mackieControl: return MackieControlDriver(settings: settings)
        }
    }

    func startController() {
        controllerName = controller.displayName
        controller.onAction = { [weak self] action in MainActor.assumeIsolated { self?.handle(action) } }
        controller.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.controllerConnectionChanged(connected) } }
        controller.onNeedsLights = { [weak self] in MainActor.assumeIsolated { self?.refreshLEDs() } }
        if let learner = controller as? MIDILearnDriver {
            learner.onLearned = { [weak self] target, binding in MainActor.assumeIsolated { self?.learned(target, binding) } }
        }
        controller.start()
        controllerConnectionChanged(controller.isConnected)
        // Devices without a setup sequence of their own get their lights straight away.
        if controller.isConnected { refreshLEDs() }
    }

    /// Settings picked another controller or MIDI device: let go of the old one and start the new one.
    private func switchController() {
        cancelLearning()
        controller.stop()
        controller = MixerCore.makeController(settings)
        startController()
    }

    // MARK: MIDI learn

    /// The next control moved on the device is assigned to `target`.
    func startLearning(_ target: LearnTarget) {
        guard let learner = controller as? MIDILearnDriver else { return }
        learner.learning = target
        learning = target
    }

    func cancelLearning() {
        (controller as? MIDILearnDriver)?.learning = nil
        learning = nil
    }

    func clearBinding(_ target: LearnTarget) {
        settings.midiBindings[target.key] = nil
    }

    func clearAllBindings() {
        cancelLearning()
        settings.midiBindings = [:]
    }

    private func learned(_ target: LearnTarget, _ binding: MIDIBinding) {
        // One control does one thing: drop any other assignment of the same control.
        for (key, existing) in settings.midiBindings where existing == binding && key != target.key {
            settings.midiBindings[key] = nil
        }
        settings.midiBindings[target.key] = binding
        learning = nil
        osd("MIDI", title: target.label, value: binding.summary)
    }

    private func controllerConnectionChanged(_ connected: Bool) {
        // The driver initialises the device itself, then asks for the lights through onNeedsLights.
        controllerConnected = connected
        detachAllFaders()
        for i in 0..<MixerCore.channelCount { faders[i].position = nil }
    }

    func handle(_ action: ControllerAction) {
        switch action {
        case let .fader(ch, p):
            guard ch < MixerCore.channelCount else { return }
            faderMoved(ch, position: p)
        case let .playButton(ch, pressed):
            guard ch < MixerCore.channelCount else { return }
            topButton(ch, pressed: pressed)
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

    // MARK: - Knobs, faders and buttons

    private func resetKnobs(_ ch: Int) {
        controls.reset(ch)
        stopSeek(ch)
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
        switch controls.speedKnob(ch, at: p, current: s.speed) {
        case let .waiting(hint):
            if hint {
                osd("\(ch + 1)", title: s.displayName, value: "Turn to \(ControlInput.speedLabel(s.speed)) to take over", source: s)
            }
        case .unchanged:
            break
        case let .set(speed):
            var updated = s
            updated.speed = speed
            sources[s.id] = updated
            speedSentAt[s.id] = Date()
            chrome.setSpeed(conn, tabId: tabId, rate: speed)
            osd("\(ch + 1)", title: s.displayName, value: "Speed \(ControlInput.speedLabel(speed))", source: s)
            scheduleRefresh()
        }
    }

    private func seekKnob(_ ch: Int, position p: Float) {
        guard !(masterActive && ch == 0), let s = source(onChannel: ch) else { return }
        switch controls.seekKnob(ch, at: p) {
        case .notArmed:
            if s.canSeek { osd("\(ch + 1)", title: s.displayName, value: "Return knob to centre to seek", source: s) }
        case .centred:
            stopSeek(ch)
            scheduleRefresh()
        case .turned:
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
    }

    private func seekTick(_ ch: Int) {
        let d = controls.seekDeflection[ch]
        guard d != 0, let s = source(onChannel: ch), s.canSeek, let tabId = s.tabId, let conn = s.browserConnection else {
            stopSeek(ch)
            return
        }
        let seconds = ControlInput.seekStep(d)
        let step = Int(abs(seconds))
        chrome.seekBy(conn, tabId: tabId, seconds: seconds)
        osd("\(ch + 1)", title: s.displayName, value: d > 0 ? "⏩ +\(step) s" : "⏪ −\(step) s", source: s)
    }

    private func stopSeek(_ ch: Int) {
        seekTimers[ch]?.invalidate()
        seekTimers[ch] = nil
    }

    /// Soft takeover (ControlInput decides); true when the fader now drives the level.
    private func softTakeover(_ ch: Int, _ p: Float, target: Float) -> Bool {
        faders[ch] = ControlInput.takeover(faders[ch], movedTo: p, target: target, motorised: controller.hasMotorisedFaders)
        return faders[ch].attached
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

    /// Play acts on release, so a 3-second hold can reload the tab instead.
    private func topButton(_ ch: Int, pressed: Bool) {
        if pressed {
            playHold.reset(ch)
            guard source(onChannel: ch)?.kind == .tab else { return }
            playHold.press(ch, holdAfter: 3, hintAfter: 1, hint: { [weak self] in
                guard let self, let s = self.source(onChannel: ch) else { return }
                self.osd("\(ch + 1)", title: s.displayName, value: "Keep holding to reload the tab", source: s)
            }, onHold: { [weak self] in
                guard let self, let s = self.source(onChannel: ch) else { return false }
                self.reloadTab(s.id)
                return true
            })
        } else {
            guard playHold.release(ch) else { return }
            topPressed(ch)
        }
    }

    /// Reloads a tab, e.g. one that lost its connection to the extension after an update.
    func reloadTab(_ id: String) {
        guard let s = sources[id], let tabId = s.tabId, let conn = s.browserConnection else { return }
        chrome.reloadTab(conn, tabId: tabId)
        if let ch = channel(of: id) { osd("\(ch + 1)", title: s.displayName, value: "Reloading tab", source: s) }
    }

    private func topPressed(_ ch: Int) {
        guard let s = source(onChannel: ch), s.kind == .tab else { return }
        if controls.playPressIsDouble(ch, at: Date(), counting: s.isTwitch) {
            togglePlay(s.id)
            if let tabId = s.tabId, let conn = s.browserConnection { chrome.jumpLive(conn, tabId: tabId) }
            osd("\(ch + 1)", title: s.displayName, value: "Jump to live", source: s)
            return
        }
        togglePlay(s.id)
        let playing = sources[s.id]?.isPlaying ?? false
        osd("\(ch + 1)", title: s.displayName, value: s.canPlayPause ? (playing ? "Playing" : "Paused") : "Play/pause", source: s)
    }

    /// Mute acts on release, so a 1-second hold can unassign the channel instead.
    private func bottomButton(_ ch: Int, pressed: Bool) {
        if pressed {
            guard channels[ch] != nil else { return }
            muteHold.press(ch, holdAfter: 1) { [weak self] in
                guard let self, self.source(onChannel: ch) != nil else { return false }
                self.unassign(channel: ch)
                return true
            }
        } else {
            guard muteHold.release(ch), let s = source(onChannel: ch) else { return }
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

    /// Gathers what sits on each channel; LightComposer works out the lights for the driver.
    func refreshLEDs() {
        guard controllerConnected else { return }
        let marker = Signposts.poi.beginInterval("LED refresh")
        defer { Signposts.poi.endInterval("LED refresh", marker) }
        let now = Date()
        let channels = (0..<MixerCore.channelCount).map { ch -> LightComposer.Channel in
            if masterActive && ch == 0 { return .master(volume: masterVolume) }
            guard let s = source(onChannel: ch) else { return .empty }
            return .source(s, position: position(of: s), blinking: blinkUntil[ch].map { $0 > now } ?? false,
                           seeking: seekTimers[ch] != nil ? controls.seekDeflection[ch] : nil)
        }
        controller.show(LightComposer.lights(for: channels, muteAll: muteAll, micMuted: micMuted))
    }

    // MARK: - Output device and master mode

    private func outputChanged() {
        listenToMasterVolume()
        outputName = engine.outputName
        masterSupported = engine.masterSupported
        masterVolume = engine.masterVolume ?? 0
        masterModeChanged()
        onStatusChange?()
    }

    private func masterModeChanged() {
        if masterActive, let id = channels[0] {
            assignment.clear(0)
            if let ch = firstFreeChannel() { place(id, on: ch) } else { assignment.addWaiting(id, first: true) }
        } else if !masterActive {
            fillFromWaiting(0)
        }
        detachAllFaders()
        scheduleRefresh()
    }

    private func applyIgnoreList() {
        for id in lists.ignored(in: sources) {
            // Moved here from the mute list: give the sound back before letting go of it.
            if listMuted.contains(id) {
                assignment.removeListMuted(id)
                if let s = sources[id], s.kind == .tab { sendTabMute(s) }
            }
            removeSource(id)
        }
    }

    // MARK: - Mute list

    /// The mute and ignore lists as they stand in Settings.
    private var lists: MuteLists { MuteLists(muteList: settings.muteList, ignoreList: settings.ignoreList) }

    private func silenceListed(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app: tapIfPossible(id)   // gain 0 through the tap
        case .tab: sendTabMute(s)      // Chrome's tab mute
        }
    }

    /// Applies a changed mute list to sources that are already playing.
    func applyMuteList() {
        for change in lists.changes(in: sources, listMuted: listMuted) {
            switch change {
            case let .silence(id):
                guard let s = sources[id] else { continue }
                if let ch = channel(of: id) {
                    assignment.clear(ch)
                    faders[ch].attached = false
                }
                assignment.forget(id)
                assignment.addListMuted(id)
                silenceListed(id)
                osd("–", title: s.displayName, value: "Muted by list", icon: s.icon, duration: 3, source: s)
            case let .release(id):
                assignment.removeListMuted(id)
                applyGainAndMute(id) // sound back first
                if let ch = firstFreeChannel() { place(id, on: ch) } else { assignment.addWaiting(id) }
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
        for (id, label) in TabMerger.browserLabels(for: sources) {
            guard var s = sources[id], s.browserLabel != label else { continue }
            s.browserLabel = label
            sources[id] = s
        }
    }

    /// Merges one browser connection's tab list into the mixer's sources. TabMerger works out the
    /// values; this adds, updates and removes the sources and sends what needs sending.
    func handleTabs(_ tabs: [TabReport], from connection: BrowserConnection) {
        let marker = Signposts.poi.beginInterval("Tab merge")
        defer { Signposts.poi.endInterval("Tab merge", marker) }
        var seen = Set<String>()
        let now = Date()
        for t in tabs {
            let id = TabMerger.sourceID(of: t, from: connection)
            let gain = TabMerger.reportedGain(t, gainForPosition: settings.gain(forPosition:))

            guard let old = sources[id] else {
                guard TabMerger.joins(t, held: assignment.isHeld(id, host: t.host), ignored: settings.isIgnored([t.host])) else { continue }
                seen.insert(id)
                var s = TabMerger.newSource(t, id: id, from: connection, gain: gain)
                s.icon = icons.icon(for: t.favicon) { [weak self] image in self?.setIcon(id, image) }
                addSource(s)
                continue
            }

            seen.insert(id)
            let onChannel = channel(of: id) != nil
            let recent = TabMerger.Recent(
                now: now, volumeSentAt: volumeSentAt[id], speedSentAt: speedSentAt[id], muteSentAt: muteSentAt[id],
                volumePending: pendingTabVolume.contains(id), muteHeld: (muteAll && onChannel) || listMuted.contains(id)
            )
            var update = TabMerger.update(old, with: t, from: connection, gain: gain, recent: recent)
            if update.speedChangedInPage, let ch = channel(of: id) { controls.detachSpeedKnob(ch) }
            if update.volumeChangedInPage, let ch = channel(of: id) { faders[ch].attached = false }
            if update.sendPendingVolume {
                pendingTabVolume.remove(id)
                sources[id] = update.source
                sendTabVolume(update.source)
            }
            if let icon = icons.icon(for: t.favicon, completion: { [weak self] image in self?.setIcon(id, image) }) {
                update.source.icon = icon
            }
            if update.source != sources[id] { sources[id] = update.source }
        }
        for id in TabMerger.closed(in: sources, connection: connection, seen: seen) {
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
}
