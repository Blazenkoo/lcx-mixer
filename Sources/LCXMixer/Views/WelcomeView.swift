import AppKit
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }
    static let repository = URL(string: "https://github.com/Blazenkoo/lcx-mixer")!
    static let licence = URL(string: "https://github.com/Blazenkoo/lcx-mixer/blob/main/LICENSE")!
    static let credit = "Designed and specified by Blaženko Davidović. Built with Claude."
}

/// A borderless window with much rounder corners than macOS's own, for the welcome window and About.
final class RoundedWindow: NSWindow {
    static let cornerRadius: CGFloat = 32

    init<Content: View>(content: Content) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
                   styleMask: [.borderless, .fullSizeContentView], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        contentViewController = host
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// Esc closes it, like a sheet.
    override func cancelOperation(_ sender: Any?) { close() }
}

/// The shape and frame every rounded window shares.
private struct RoundedPanel<Content: View>: View {
    let close: () -> Void
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: RoundedWindow.cornerRadius, style: .continuous)
        content
            .background(TowerPalette(dark: scheme == .dark).background)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close")
                .accessibilityLabel("Close")
                .padding(16)
            }
    }
}

// MARK: - Welcome

/// Shown on the first launch: the visual, then the three setup steps with their live state.
struct WelcomeView: View {
    @ObservedObject var core: MixerCore
    let openSettings: () -> Void
    let close: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        RoundedPanel(close: close) {
            VStack(spacing: 0) {
                TowerVisual(icons: TowerIcons.collect(from: core))
                    .frame(width: 520, height: 300)

                VStack(alignment: .leading, spacing: 14 * scale) {
                    Text("Three things to set up")
                        .scaledFont(AppText.headline, weight: .semibold)
                    step(1, done: core.permissionStatus == .authorized,
                         title: "Allow system audio recording",
                         detail: "Needed to set the volume of apps such as games, Discord or Music. The app never listens to your microphone.",
                         doneLabel: "Allowed") {
                        Button(core.permissionStatus == .denied ? "Open System Settings" : "Allow…") { core.requestAudioPermission() }
                    }
                    step(2, done: core.browserConnected,
                         title: "Add the browser extension",
                         detail: "For a channel per tab in Chrome, Edge, Brave, Arc, Vivaldi or Chromium. On the browser's extensions page, turn on Developer mode, choose Load unpacked and pick the extension folder.",
                         doneLabel: "Connected") {
                        Button("Show folder") { NSWorkspace.shared.activateFileViewerSelecting([AppPaths.extensionFolder]) }
                    }
                    step(3, done: core.controllerConnected,
                         title: "Connect your controller",
                         detail: core.controllerConnected
                            ? "\(core.controllerName) is ready."
                            : "Plug in \(core.controllerName), or pick another controller in Settings.",
                         doneLabel: "Connected") {
                        Button("Settings…", action: openSettings)
                    }
                    HStack {
                        Text("To see these steps again, choose About in the menu-bar panel.")
                            .scaledFont(AppText.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Get started", action: close)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.large)
                    }
                    .padding(.top, 4 * scale)
                }
                .padding(.horizontal, 28)
                .padding(.bottom, 26)
                .padding(.top, 4)
                .frame(width: 520, alignment: .leading)
            }
        }
    }

    private func step<Action: View>(_ n: Int, done: Bool, title: String, detail: String, doneLabel: String,
                                    @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .top, spacing: 12 * scale) {
            ZStack {
                Circle().fill(done ? Color.green.opacity(0.2) : Color.primary.opacity(0.08))
                if done {
                    Image(systemName: "checkmark").font(.system(size: 11 * scale, weight: .bold)).foregroundStyle(.green)
                } else {
                    Text("\(n)").scaledFont(AppText.callout, weight: .semibold)
                }
            }
            .frame(width: 24 * scale, height: 24 * scale)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2 * scale) {
                Text(title).scaledFont(AppText.body, weight: .medium)
                Text(detail)
                    .scaledFont(AppText.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if done {
                Text(doneLabel).scaledFont(AppText.status, weight: .medium).foregroundStyle(.secondary)
            } else {
                action().scaledFont(AppText.callout)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(done ? doneLabel : "Not done")
    }
}

// MARK: - About

struct AboutView: View {
    @ObservedObject var core: MixerCore
    let showSetup: () -> Void
    let close: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        RoundedPanel(close: close) {
            VStack(spacing: 0) {
                TowerVisual(icons: TowerIcons.collect(from: core))
                    .frame(width: 520, height: 300)
                VStack(spacing: 6 * scale) {
                    Text("Version \(AppInfo.version)").scaledFont(AppText.callout).foregroundStyle(.secondary)
                    Text(AppInfo.credit).scaledFont(AppText.callout).foregroundStyle(.secondary)
                    HStack(spacing: 16 * scale) {
                        Link("Source code on GitHub", destination: AppInfo.repository)
                        Link("MIT licence", destination: AppInfo.licence)
                        Button("Setup steps", action: showSetup).buttonStyle(.link)
                    }
                    .scaledFont(AppText.callout)
                }
                .multilineTextAlignment(.center)
                .padding(.bottom, 24)
                .frame(width: 520)
            }
        }
    }
}

/// Bottom of Settings: a small live copy of the visual beside the credits and links.
struct SettingsCredits: View {
    @ObservedObject var core: MixerCore
    let openAbout: () -> Void
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(alignment: .center, spacing: 14 * scale) {
            Button(action: openAbout) {
                TowerVisual(icons: TowerIcons.collect(from: core), showsTitle: false)
                    .frame(width: 132 * scale, height: 88 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12 * scale, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("About LCX Mixer")
            .accessibilityLabel("About LCX Mixer")
            VStack(alignment: .leading, spacing: 4 * scale) {
                Text("LCX Mixer \(AppInfo.version)").scaledFont(AppText.body, weight: .semibold)
                Text(AppInfo.credit)
                    .scaledFont(AppText.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12 * scale) {
                    Link("GitHub", destination: AppInfo.repository)
                    Link("MIT licence", destination: AppInfo.licence)
                }
                .scaledFont(AppText.callout)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4 * scale)
    }
}
