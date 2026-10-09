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
        popover.contentViewController = NSHostingController(rootView: PanelView(
            core: core,
            openMixer: { [weak self] in self?.showMixer() },
            openSettings: { [weak self] in self?.showSettings() }
        ))

        core.start()
        updateStatusIcon()
        observeMuteAll()
        dockObservation = settings.$alwaysInDock.sink { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockPresence() } }
        }
        updateDockPresence()

        if settings.launchAtLogin { settings.applyLaunchAtLogin() }
        if !UserDefaults.standard.bool(forKey: "hasLaunchedBefore") {
            UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            showMixer()
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
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "LCX Mixer"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: MixerWindowView(
                core: core,
                openSettings: { [weak self] in self?.showSettings() }
            ))
            window.center()
            window.setFrameAutosaveName("MixerWindow")
            window.delegate = self
            mixerWindow = window
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
            window.contentViewController = NSHostingController(rootView: SettingsView(settings: settings, core: core))
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
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
