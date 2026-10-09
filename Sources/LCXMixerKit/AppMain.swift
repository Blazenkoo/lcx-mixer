import AppKit

/// The app's entry point. The executable's main.swift only calls `run()`, so everything else
/// lives in this library, where the tests can reach it.
public enum AppMain {
    public static func run() {
        // Chrome launches this same executable as its native-messaging host and passes the
        // extension origin as an argument. In that case run the small stdio <-> socket bridge only.
        if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("chrome-extension://") }) {
            BridgeHost.run()
        }

        signal(SIGPIPE, SIG_IGN)

        MainActor.assumeIsolated {
            let app = NSApplication.shared
            let appDelegate = AppDelegate()
            app.delegate = appDelegate
            app.setActivationPolicy(.accessory)
            withExtendedLifetime(appDelegate) {
                app.run()
            }
        }
    }
}
