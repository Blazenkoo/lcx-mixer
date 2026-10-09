import AppKit
import SwiftUI

/// Reports whether the window a view sits in can actually be seen: open, not minimised, and not
/// fully covered or on another Space. Animations use it to stop drawing when nobody can see them.
/// (Closed windows keep their views alive, and SwiftUI's animation timelines keep running there.)
struct WindowVisibilityProbe: NSViewRepresentable {
    @Binding var visible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onChange = { [binding = $visible] isVisible in
            if binding.wrappedValue != isVisible { binding.wrappedValue = isVisible }
        }
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { report(false); return }
            let names: [Notification.Name] = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.update(closing: note.name == NSWindow.willCloseNotification) }
                })
            }
            update(closing: false)
        }

        private func update(closing: Bool) {
            guard let window else { report(false); return }
            report(!closing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        private func report(_ visible: Bool) {
            // After the current layout pass, so SwiftUI state isn't changed mid-update.
            DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.onChange?(visible) } }
        }

        private func stopObserving() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
        }

        deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }
    }
}
