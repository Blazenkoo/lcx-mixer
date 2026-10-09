import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings.shared
    private lazy var core = MixerCore(settings: settings)
    private let osd = OSDController()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mixerWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var welcomeWindow: RoundedWindow?
    private var aboutWindow: RoundedWindow?
    private var launchedAtLogin = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The launch event is only available this early.
        launchedAtLogin = LaunchContext.isLoginLaunch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        core.onOSD = { [weak self] message in self?.osd.show(message) }
        core.onStatusChange = { [weak self] in self?.updateStatusIcon() }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        popover.behavior = .transient
        popover.animates = true
        let panel = NSHostingController(rootView: ScaledRoot(settings: settings) {
            PanelView(
                core: core,
                openMixer: { [weak self] in self?.showMixer() },
                openSettings: { [weak self] in self?.showSettings() },
                openAbout: { [weak self] in self?.showAbout() }
            )
        })
        panel.sizingOptions = [.preferredContentSize] // the popover follows the panel's size, including text size
        popover.contentViewController = panel

        core.start()
        updateStatusIcon()
        observeMuteAll()
        dockObservation = settings.$alwaysInDock.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockPresence() } }
        }
        updateDockPresence()
        textSizeObservation = settings.$textSize.dropFirst().sink { [weak self] _ in
            // Measure after SwiftUI has laid the windows out at the new size.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { MainActor.assumeIsolated { self?.fitWindowsToContent() } }
        }

        if settings.launchAtLogin { settings.applyLaunchAtLogin() }
        // Opening the app yourself (including after Quit) shows the mixer; starting at login stays in the menu bar.
        if !launchedAtLogin { showMixer() }
        // The welcome window, once: on the first launch of v2 (also for people coming from v1).
        // Shown a moment later, once the Dock icon and the mixer window have settled.
        if !UserDefaults.standard.bool(forKey: "welcomeShown.v2") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated {
                    UserDefaults.standard.set(true, forKey: "welcomeShown.v2")
                    self.showWelcome()
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        core.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMixer()
        return true
    }

    // MARK: - Dock

    private var dockObservation: Any?
    private var textSizeObservation: Any?
    /// After a text size change, sizes each window to its content's own preferred size, larger or
    /// smaller. That size comes from SwiftUI's layout of the content alone, never from the window's
    /// current size, so nothing can build up across changes.
    private func fitWindowsToContent() {
        for window in [mixerWindow, settingsWindow].compactMap({ $0 }) {
            guard let content = window.contentViewController else { continue }
            content.view.layoutSubtreeIfNeeded()
            let size = content.preferredContentSize
            guard size.width > 0, size.height > 0 else { continue }
            resize(window, toContent: size)
        }
    }

    /// Resizes keeping the window's top-left corner in place, and inside the screen it's on.
    private func resize(_ window: NSWindow, toContent size: NSSize) {
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let old = window.frame
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        if let visible = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        if frame != old { window.setFrame(frame, display: true, animate: true) }
    }

    /// Dock icon while the mixer window is open, or always if the setting says so.
    private func updateDockPresence() {
        let mixerOpen = mixerWindow?.isVisible ?? false
        let wanted: NSApplication.ActivationPolicy = (settings.alwaysInDock || mixerOpen) ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { NSApp.activate() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mixerWindow else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.updateDockPresence() } }
    }

    // MARK: - Status item

    private var muteAllObservation: Any?
    private var micObservation: Any?

    private func observeMuteAll() {
        muteAllObservation = core.$muteAll.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStatusIcon() } }
        }
        micObservation = core.$micMuted.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateStatusIcon() } }
        }
    }

    private func updateStatusIcon() {
        statusItem?.button?.image = StatusIcon.make(connected: core.controllerConnected, muteAll: core.muteAll, micMuted: core.micMuted)
        var tip = core.controllerConnected ? "LCX Mixer" : "LCX Mixer — controller not connected"
        if core.micMuted { tip += " · microphone muted" }
        statusItem?.button?.toolTip = tip
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Windows

    func showMixer() {
        popover.performClose(nil)
        if mixerWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 680),
                // Not resizable: the window always matches its content, at every text size.
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LCX Mixer"
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: ScaledRoot(settings: settings, shortcuts: true) {
                MixerWindowView(
                    core: core,
                    openSettings: { [weak self] in self?.showSettings() }
                )
            })
            content.sizingOptions = [.preferredContentSize] // the window follows the content's size
            window.contentViewController = content
            window.center()
            // Remembers where the window was; its size always comes from the content (below).
            window.setFrameAutosaveName("MixerWindow")
            window.delegate = self
            mixerWindow = window
        }
        if let window = mixerWindow, let content = window.contentViewController {
            content.view.layoutSubtreeIfNeeded()
            let size = content.preferredContentSize
            if size.width > 0, size.height > 0 { resize(window, toContent: size) }
        }
        mixerWindow?.makeKeyAndOrderFront(nil)
        updateDockPresence()
        NSApp.activate()
    }

    func showSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 680),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "LCX Mixer Settings"
            window.isReleasedWhenClosed = false
            let content = NSHostingController(rootView: ScaledRoot(settings: settings, shortcuts: true) {
                SettingsView(settings: settings, core: core, openAbout: { [weak self] in self?.showAbout() })
            })
            content.sizingOptions = [.preferredContentSize]
            window.contentViewController = content
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showWelcome() {
        popover.performClose(nil)
        if welcomeWindow == nil {
            welcomeWindow = RoundedWindow(content: ScaledRoot(settings: settings) {
                WelcomeView(core: core,
                            openSettings: { [weak self] in self?.showSettings() },
                            close: { [weak self] in self?.welcomeWindow?.close() })
            })
        }
        present(welcomeWindow)
    }

    func showAbout() {
        popover.performClose(nil)
        if aboutWindow == nil {
            aboutWindow = RoundedWindow(content: ScaledRoot(settings: settings) {
                AboutView(core: core,
                          showSetup: { [weak self] in self?.aboutWindow?.close(); self?.showWelcome() },
                          close: { [weak self] in self?.aboutWindow?.close() })
            })
        }
        present(aboutWindow)
    }

    private func present(_ window: RoundedWindow?) {
        guard let window else { return }
        if !window.isVisible {
            window.contentViewController?.view.layoutSubtreeIfNeeded()
            if let size = window.contentViewController?.preferredContentSize, size.width > 0 {
                window.setContentSize(size)
            }
            window.center()
        }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // The shadow follows the rounded corners once the content has drawn.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { window.invalidateShadow() }
    }
}

/// Monochrome template icon: three faders. Slash when disconnected, filled tile while mute-all is on.
enum StatusIcon {
    static func make(connected: Bool, muteAll: Bool, micMuted: Bool) -> NSImage {
        let mixer = make(connected: connected, muteAll: muteAll)
        guard micMuted,
              let mic = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")?
                .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) else { return mixer }
        // The mixer icon with a small mic-off badge beside it.
        let size = NSSize(width: 18 + 3 + mic.size.width, height: 18)
        let image = NSImage(size: size, flipped: false) { _ in
            mixer.draw(in: NSRect(x: 0, y: 0, width: 18, height: 18))
            mic.draw(in: NSRect(x: 21, y: (18 - mic.size.height) / 2, width: mic.size.width, height: mic.size.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "LCX Mixer, microphone muted"
        return image
    }

    static func make(connected: Bool, muteAll: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ink = NSColor.black
            if muteAll {
                ink.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4).fill()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
            }
            ink.setStroke()
            ink.setFill()
            let xs: [CGFloat] = [5, 9, 13]
            let knobs: [CGFloat] = [11, 6, 9]
            for (x, k) in zip(xs, knobs) {
                let line = NSBezierPath()
                line.move(to: NSPoint(x: x, y: 3.5))
                line.line(to: NSPoint(x: x, y: 14.5))
                line.lineWidth = 1.3
                line.lineCapStyle = .round
                line.stroke()
                NSBezierPath(roundedRect: NSRect(x: x - 2.2, y: k - 1.3, width: 4.4, height: 2.6), xRadius: 1, yRadius: 1).fill()
            }
            if !connected {
                NSGraphicsContext.current?.compositingOperation = .clear
                let gap = NSBezierPath()
                gap.move(to: NSPoint(x: 2, y: 16))
                gap.line(to: NSPoint(x: 16, y: 2))
                gap.lineWidth = 3.4
                gap.stroke()
                NSGraphicsContext.current?.compositingOperation = muteAll ? .destinationOut : .sourceOver
                let slash = NSBezierPath()
                slash.move(to: NSPoint(x: 2.5, y: 15.5))
                slash.line(to: NSPoint(x: 15.5, y: 2.5))
                slash.lineWidth = 1.3
                slash.lineCapStyle = .round
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// How the app was started.
enum LaunchContext {
    /// True when macOS started the app as a login item. Besides the launch event's own flag,
    /// a start within 60 seconds of logging in also counts, in case the flag is missing.
    static func isLoginLaunch() -> Bool {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventID == AEEventID(kAEOpenApplication),
           event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            return true
        }
        if let login = consoleLoginTime(), Date().timeIntervalSince(login) < 60 { return true }
        return false
    }

    /// When the current user last logged in at this Mac's screen.
    private static func consoleLoginTime() -> Date? {
        let user = NSUserName()
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            let e = entry.pointee
            guard Int32(e.ut_type) == USER_PROCESS else { continue }
            let line = withUnsafeBytes(of: e.ut_line) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            let name = withUnsafeBytes(of: e.ut_user) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            guard line == "console", name == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(e.ut_tv.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }
}
