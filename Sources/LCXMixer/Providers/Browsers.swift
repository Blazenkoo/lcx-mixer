import AppKit

/// A Chromium-based browser the extension can run in.
struct BrowserInfo: Hashable {
    let bundleID: String
    let name: String
    /// The browser's data folder under ~/Library/Application Support. Chromium browsers read
    /// native-messaging setup from its "NativeMessagingHosts" subfolder.
    let dataFolder: String
}

enum Browsers {
    static let chrome = BrowserInfo(bundleID: "com.google.Chrome", name: "Chrome", dataFolder: "Google/Chrome")

    static let all: [BrowserInfo] = [
        chrome,
        BrowserInfo(bundleID: "com.google.Chrome.beta", name: "Chrome Beta", dataFolder: "Google/Chrome Beta"),
        BrowserInfo(bundleID: "com.google.Chrome.canary", name: "Chrome Canary", dataFolder: "Google/Chrome Canary"),
        BrowserInfo(bundleID: "com.microsoft.edgemac", name: "Edge", dataFolder: "Microsoft Edge"),
        BrowserInfo(bundleID: "com.brave.Browser", name: "Brave", dataFolder: "BraveSoftware/Brave-Browser"),
        BrowserInfo(bundleID: "company.thebrowser.Browser", name: "Arc", dataFolder: "Arc/User Data"),
        BrowserInfo(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", dataFolder: "Vivaldi"),
        BrowserInfo(bundleID: "org.chromium.Chromium", name: "Chromium", dataFolder: "Chromium"),
    ]

    /// The browser a bundle ID belongs to, including its helper processes ("com.brave.Browser.helper").
    static func info(forBundleID id: String) -> BrowserInfo? {
        let lower = id.lowercased()
        if let exact = all.first(where: { $0.bundleID.lowercased() == lower }) { return exact }
        return all
            .filter { lower.hasPrefix($0.bundleID.lowercased() + ".") }
            .max { $0.bundleID.count < $1.bundleID.count }
    }

    /// Supported browsers that are open right now.
    static var running: [BrowserInfo] {
        let open = Set(NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier?.lowercased() })
        return all.filter { open.contains($0.bundleID.lowercased()) }
    }

    /// The browser that launched a bridge process: macOS attributes the process to the app
    /// "responsible" for it; failing that, the parent process chain is followed.
    @MainActor
    static func identify(bridgePID pid: pid_t) -> (BrowserInfo, pid_t)? {
        var candidates: [pid_t] = []
        if let responsible = responsibleForPid?(pid), responsible > 0 { candidates.append(responsible) }
        var p = pid
        for _ in 0..<6 {
            p = AudioProcessMonitor.parentPID(p)
            guard p > 1 else { break }
            candidates.append(p)
        }
        for c in candidates {
            if let id = NSRunningApplication(processIdentifier: c)?.bundleIdentifier, let info = info(forBundleID: id) {
                return (info, c)
            }
        }
        return nil
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
    private static let responsibleForPid: ResponsibleFn? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleFn.self)
    }()
}
