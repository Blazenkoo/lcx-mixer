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
            scheduleRefresh()
        }
    }
    @Published private(set) var sources: [String: Source] = [:] { didSet { scheduleRefresh() } }
    @Published private(set) var waiting: [String] = []
    @Published private(set) var manual: [String] = []
    @Published private(set) var muteAll = false { didSet { scheduleRefresh() } }
    @Published private(set) var faders: [FaderState] = Array(repeating: FaderState(), count: MixerCore.channelCount)
    @Published private(set) var controllerConnected = false { didSet { onStatusChange?() } }
    @Published private(set) var chromeConnected = false
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

    private let midi = MIDIController()
    private let engine = AudioEngine()
    private let monitor: AudioProcessMonitor
    private let bridge = ChromeBridgeServer()
    private let icons = IconLoader()
    private let launchedAt = Date()

    private var lastLEDs: [Int: UInt8] = [:]

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
    private var chromeGrace: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()
    private var pollCount = 0

    init(settings: AppSettings) {
        self.settings = settings
        self.monitor = AudioProcessMonitor(settings: settings)
    }

    // MARK: - Derived state

    var masterActive: Bool { settings.masterMode && masterSupported }
    var firstSourceChannel: Int { masterActive ? 1 : 0 }
    var hasFreeChannel: Bool { firstFreeChannel() != nil }

    var unassigned: [Source] {
        (waiting + manual).compactMap { sources[$0] }
    }

    func isManuallyUnassigned(_ id: String) -> Bool { manual.contains(id) }

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
        ChromeBridgeServer.registerWithChrome()

        midi.onEvent = { [weak self] event in MainActor.assumeIsolated { self?.handle(event) } }
        midi.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.controllerConnectionChanged(connected) } }
        midi.start()

        bridge.onMessage = { [weak self] message in MainActor.assumeIsolated { self?.handleBridge(message) } }
        bridge.onConnectionChange = { [weak self] connected in MainActor.assumeIsolated { self?.bridgeConnectionChanged(connected) } }
        bridge.start()

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
    }

    func shutdown() {
        engine.stopAll()
        if controllerConnected { midi.send(LCXL.resetLEDs) }
    }

    // MARK: - Polling

    private func poll() {
        pollCount += 1
        pollNativeApps()

        if masterSupported, let v = engine.masterVolume, abs(v - masterVolume) > 0.01,
           Date().timeIntervalSince(masterSetAt) > 1 {
            masterVolume = v
            if masterActive { faders[0].attached = false }
        }

        let chromeRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").isEmpty
        let problem = chromeRunning && !chromeConnected && Date().timeIntervalSince(launchedAt) > 10
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
        let snapshot = monitor.snapshot()
        let running = monitor.runningKeys()

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
                if engine.hasTap(id) {
                    engine.ensureTap(id: id, processObjects: app.processObjects, gain: effectiveGain(s))
                }
            } else if app.isRunningOutput {
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
                values[id] = min(1, engine.level(id: id))
            case .tab:
                values[id] = s.isAudible && !s.isMuted ? 0.45 + 0.2 * sin(t * 9) + 0.1 * sin(t * 23) : 0
            }
        }
        if values != levels.values { levels.values = values }
    }

    // MARK: - Assignment

    private func firstFreeChannel() -> Int? {
        (firstSourceChannel..<MixerCore.channelCount).first { channels[$0] == nil }
    }

    private func addSource(_ source: Source) {
        var s = source
        if s.kind == .app && permissionStatus == .denied {
            s.permissionNeeded = true
            sources[s.id] = s
            manual.append(s.id)
            return
        }
        sources[s.id] = s
        if let ch = firstFreeChannel() {
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
            engine.ensureTap(id: id, processObjects: s.processObjects, gain: effectiveGain(s))
        }
    }

    private func permissionGranted() {
        for (id, s) in sources where s.kind == .app {
            if s.permissionNeeded {
                var updated = s
                updated.permissionNeeded = false
                sources[id] = updated
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
        engine.removeTap(id: id)
        pendingTabVolume.remove(id)
        sources[id] = nil
        if let ch {
            channels[ch] = nil
            faders[ch].attached = false
            fillFromWaiting(ch)
        }
    }

    private func fillFromWaiting(_ ch: Int) {
        guard ch >= firstSourceChannel, channels[ch] == nil, let next = waiting.first else { return }
        place(next, on: ch)
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
        guard sources[id] != nil, channel(of: id) == nil, let ch = firstFreeChannel() else { return }
        if sources[id]?.permissionNeeded == true {
            AudioCapturePermission.openSystemSettings()
            return
        }
        place(id, on: ch)
    }

    /// Drag and drop: move a source onto a channel, swapping with an occupant.
    func move(_ id: String, to ch: Int) {
        guard ch >= firstSourceChannel, ch < MixerCore.channelCount, let s = sources[id], !s.permissionNeeded else { return }
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
        let key = s.kind == .app ? String(id.dropFirst(4)) : s.host
        if !key.isEmpty && !settings.ignoreList.contains(key) { settings.ignoreList.append(key) }
        removeSource(id)
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
        guard var s = sources[id], s.kind == .tab, let tabId = s.tabId else { return }
        bridge.send(["type": "togglePlay", "tabId": tabId])
        if s.canPlayPause {
            s.isPlaying.toggle()
            sources[id] = s
        }
    }

    func toggleMuteAll() {
        muteAll.toggle()
        for id in channels.compactMap({ $0 }) { applyGainAndMute(id) }
        osd("All", title: "Mute all", value: muteAll ? "On" : "Off")
    }

    func focus(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app:
            for pid in s.pids {
                if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                    app.activate()
                    return
                }
            }
        case .tab:
            if let tabId = s.tabId {
                bridge.send(["type": "focus", "tabId": tabId, "windowId": s.windowId ?? -1])
                NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.activate()
            }
        }
    }

    // MARK: - Volume and mute plumbing

    private func effectiveGain(_ s: Source) -> Float {
        let mutedByAll = muteAll && channel(of: s.id) != nil
        return (s.isMuted || mutedByAll) ? 0 : s.volume
    }

    private func setVolume(_ id: String, gain: Float) {
        guard var s = sources[id] else { return }
        s.volume = max(0, min(1, gain))
        sources[id] = s
        settings.remember(volume: s.volume, for: s.rememberKey)
        switch s.kind {
        case .app: engine.setGain(id: id, effectiveGain(s))
        case .tab: sendTabVolume(s)
        }
    }

    private func applyGainAndMute(_ id: String) {
        guard let s = sources[id] else { return }
        switch s.kind {
        case .app: engine.setGain(id: id, effectiveGain(s))
        case .tab: sendTabMute(s)
        }
    }

    private func sendTabVolume(_ s: Source) {
        guard let tabId = s.tabId else { return }
        volumeSentAt[s.id] = Date()
        bridge.send(["type": "setVolume", "tabId": tabId, "value": s.volume, "position": position(of: s)])
    }

    private func sendTabMute(_ s: Source) {
        guard let tabId = s.tabId else { return }
        muteSentAt[s.id] = Date()
        let muted = s.isMuted || (muteAll && channel(of: s.id) != nil)
        bridge.send(["type": "setMute", "tabId": tabId, "muted": muted])
    }

    // MARK: - Controller

    private func controllerConnectionChanged(_ connected: Bool) {
        controllerConnected = connected
        lastLEDs.removeAll()
        detachAllFaders()
        for i in 0..<MixerCore.channelCount { faders[i].position = nil }
        guard connected else { return }
        midi.send(LCXL.selectFactoryTemplate1)
        after(0.15) { [weak self] in
            guard let self else { return }
            self.midi.send(LCXL.resetLEDs)
            self.midi.send(LCXL.enableFlashing)
            self.lastLEDs.removeAll()
            self.refreshLEDs()
        }
    }

    private func handle(_ event: ControllerEvent) {
        switch event {
        case let .fader(index, value):
            faderMoved(index, position: Float(value) / 127)
        case let .topButton(index, pressed):
            if pressed { topPressed(index) }
        case let .bottomButton(index, pressed):
            bottomButton(index, pressed: pressed)
        case let .sideMute(pressed):
            if pressed { toggleMuteAll() }
        case let .speedKnob(index, value):
            speedKnob(index, position: Float(value) / 127)
        case let .seekKnob(index, value):
            seekKnob(index, position: Float(value) / 127)
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
        guard s.canSpeed, let tabId = s.tabId else {
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
        bridge.send(["type": "setSpeed", "tabId": tabId, "rate": speed])
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
        guard d != 0, let s = source(onChannel: ch), s.canSeek, let tabId = s.tabId else {
            stopSeek(ch)
            return
        }
        let magnitude = abs(d)
        let step: Float = magnitude < 0.45 ? 5 : (magnitude < 0.8 ? 15 : 30)
        let seconds = d > 0 ? step : -step
        bridge.send(["type": "seekBy", "tabId": tabId, "seconds": seconds])
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
            if let tabId = s.tabId { bridge.send(["type": "jumpLive", "tabId": tabId]) }
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

    private func refreshLEDs() {
        guard controllerConnected else { return }
        let now = Date()
        var desired: [(UInt8, LCXL.Color)] = []
        var knobs: [(UInt8, LCXL.Color)] = []
        for ch in 0..<MixerCore.channelCount {
            var top = LCXL.Color.off
            var bottom = LCXL.Color.off
            var speedLED = LCXL.Color.off
            var seekLED = LCXL.Color.off
            if !(masterActive && ch == 0), let s = source(onChannel: ch) {
                if s.canSpeed {
                    if s.speed > 1.001 { speedLED = .green } else if s.speed < 0.999 { speedLED = .red }
                }
                if s.canSeek && seekTimers[ch] != nil {
                    seekLED = seekDeflection[ch] > 0 ? .green : .red
                }
            }
            knobs.append((UInt8(8 + ch), seekLED))
            knobs.append((UInt8(16 + ch), speedLED))
            if !(masterActive && ch == 0), let s = source(onChannel: ch) {
                if s.kind == .tab {
                    top = unmutedStatus(of: s) == .playing ? .green : .amber
                }
                if let until = blinkUntil[ch], until > now { top = .greenFlash }
                if muteAll {
                    bottom = .redFlash
                } else if s.isMuted {
                    bottom = .red
                } else if s.kind == .tab && !s.canSetVolume {
                    bottom = .redLow
                }
            }
            desired.append((LCXL.topButtonNotes[ch], top))
            desired.append((LCXL.bottomButtonNotes[ch], bottom))
        }
        desired.append((LCXL.muteNote, muteAll ? .yellow : .off))
        for (note, color) in desired where lastLEDs[Int(note)] != color.rawValue {
            midi.send(LCXL.led(note: note, color))
            lastLEDs[Int(note)] = color.rawValue
        }
        for (index, color) in knobs where lastLEDs[1000 + Int(index)] != color.rawValue {
            midi.send(LCXL.knobLED(index: index, color))
            lastLEDs[1000 + Int(index)] = color.rawValue
        }
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
        for (id, s) in sources {
            let keys = s.kind == .app ? [String(id.dropFirst(4))] + s.bundleIDs : [s.host]
            if settings.isIgnored(keys) { removeSource(id) }
        }
    }

    // MARK: - Chrome

    private func bridgeConnectionChanged(_ connected: Bool) {
        chromeConnected = connected
        chromeGrace?.cancel()
        chromeGrace = nil
        if connected {
            chromeProblem = false
            bridge.send(["type": "requestSnapshot"])
        } else {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.chromeConnected else { return }
                    for (id, s) in self.sources where s.kind == .tab { self.removeSource(id) }
                }
            }
            chromeGrace = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
        }
    }

    private func handleBridge(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        if type == "tabs", let tabs = message["tabs"] as? [[String: Any]] {
            let build = message["extensionBuild"] as? String ?? ""
            let wrong = build.isEmpty || build == "__BUILD_ID__"
            if wrong != wrongExtensionFolder { wrongExtensionFolder = wrong }
            handleTabs(tabs)
        }
    }

    private func handleTabs(_ tabs: [[String: Any]]) {
        var seen = Set<String>()
        let now = Date()
        for t in tabs {
            guard let tabId = (t["id"] as? NSNumber)?.intValue else { continue }
            let id = "tab:\(tabId)"
            let url = t["url"] as? String ?? ""
            let host = URL(string: url)?.host ?? ""
            let title = t["title"] as? String ?? ""
            let audible = t["audible"] as? Bool ?? false
            let muted = t["muted"] as? Bool ?? false
            let hasMedia = t["hasMedia"] as? Bool ?? false
            let playing = t["playing"] as? Bool ?? false
            let canVolume = t["canVolume"] as? Bool ?? false
            let canSpeed = t["canSpeed"] as? Bool ?? false
            let canSeek = t["canSeek"] as? Bool ?? false
            let speed = (t["speed"] as? NSNumber)?.floatValue
            let volumeIsPosition = t["volumeIsPosition"] as? Bool ?? false
            let reported = (t["volume"] as? NSNumber)?.floatValue
            // Spotify reports its slider position; convert it to gain with the app's curve.
            let volume = reported.map { volumeIsPosition ? settings.gain(forPosition: $0) : $0 }
            let favicon = t["favIconUrl"] as? String ?? ""
            let windowId = (t["windowId"] as? NSNumber)?.intValue
            var windowBounds: CGRect?
            if let b = t["windowBounds"] as? [String: Any],
               let l = (b["left"] as? NSNumber)?.doubleValue, let tp = (b["top"] as? NSNumber)?.doubleValue,
               let w = (b["width"] as? NSNumber)?.doubleValue, let h = (b["height"] as? NSNumber)?.doubleValue {
                windowBounds = CGRect(x: l, y: tp, width: w, height: h)
            }

            if sources[id] == nil {
                guard audible, !settings.isIgnored([host]) else { continue }
                seen.insert(id)
                var s = Source(
                    id: id, kind: .tab, name: SiteNames.name(forHost: host),
                    detail: SiteNames.cleanTitle(title, host: host), icon: nil, rememberKey: host,
                    isPlaying: playing || !hasMedia, isAudible: audible, isMuted: muted,
                    volume: canVolume ? (volume ?? 1) : 1, canPlayPause: hasMedia, canSetVolume: canVolume
                )
                s.tabId = tabId
                s.windowId = windowId
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
            if let windowBounds { s.windowBounds = windowBounds }
            s.canSpeed = canSpeed
            s.canSeek = canSeek
            if let speed, abs(speed - s.speed) > 0.01, now.timeIntervalSince(speedSentAt[id] ?? .distantPast) > 1.5 {
                s.speed = speed // changed in the page itself (e.g. YouTube's own menu)
                if let ch = channel(of: id) { speedAttached[ch] = false }
            }
            let onChannel = channel(of: id) != nil
            if now.timeIntervalSince(muteSentAt[id] ?? .distantPast) > 1.0 && !(muteAll && onChannel) {
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
        for (id, s) in sources where s.kind == .tab && !seen.contains(id) {
            removeSource(id)
        }
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
