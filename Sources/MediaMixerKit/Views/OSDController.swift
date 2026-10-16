import AppKit
import SwiftUI

/// Small translucent pill near the top of the screen shown when a hardware control is touched.
@MainActor
final class OSDController {
    private var panel: NSPanel?
    private let model = OSDModel()
    private var hideWork: DispatchWorkItem?

    func show(_ message: OSDMessage) {
        model.message = message
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let scale = AppSettings.shared.textSize.scale
        panel.setContentSize(NSSize(width: OSDView.width * scale, height: OSDView.height * scale))
        position(panel, near: message.screenPoint)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + message.duration, execute: work)
    }

    private func hide() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                if panel.alphaValue < 0.05 { panel.orderOut(nil) }
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: OSDView.width, height: OSDView.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let host = NSHostingView(rootView: ScaledRoot(settings: AppSettings.shared) { OSDView(model: self.model) })
        host.frame = panel.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    private func position(_ panel: NSPanel, near point: CGPoint?) {
        let target = point.flatMap { p in NSScreen.screens.first { $0.frame.contains(p) } }
        guard let screen = target ?? NSScreen.main else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 16))
    }
}

final class OSDModel: ObservableObject {
    @Published var message = OSDMessage(channel: "", title: "", value: "")
}

private struct OSDView: View {
    static let width: CGFloat = 460
    static let height: CGFloat = 56
    @ObservedObject var model: OSDModel
    @Environment(\.uiScale) private var scale

    var body: some View {
        HStack(spacing: 10 * scale) {
            if let icon = model.message.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24 * scale, height: 24 * scale)
                    .clipShape(RoundedRectangle(cornerRadius: 5 * scale))
            }
            Text(model.message.channel)
                .scaledFont(13, weight: .bold, design: .rounded)
                .padding(.horizontal, 8 * scale)
                .padding(.vertical, 3 * scale)
                .background(Capsule().fill(Color.primary.opacity(0.12)))
            Text(model.message.title)
                .scaledFont(14, weight: .semibold)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8 * scale)
            Text(model.message.value)
                .scaledFont(14, weight: .medium, monospacedDigit: true)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 16 * scale)
        .frame(width: Self.width * scale, height: Self.height * scale)
        .background(.regularMaterial, in: Capsule())
    }
}
