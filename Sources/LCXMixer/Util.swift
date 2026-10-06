import Foundation

/// Runs `work` on the main thread, as main-actor code.
func onMain(_ work: @escaping @MainActor () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }
}

/// Repeating main-thread timer whose block runs as main-actor code.
@discardableResult
func mainTimer(every interval: TimeInterval, _ work: @escaping @MainActor () -> Void) -> Timer {
    let timer = Timer(timeInterval: interval, repeats: true) { _ in
        MainActor.assumeIsolated { work() }
    }
    RunLoop.main.add(timer, forMode: .common)
    return timer
}

func after(_ seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated { work() } }
}

enum AppPaths {
    static let bundleID = "org.lcxmixer.app"
    static let nativeHostName = "org.lcxmixer.app"
    static let extensionID = "olbpfdodnajmnkbbibehghjleehbooll"

    static var support: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LCXMixer", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Only this user account may look inside (the bridge socket lives here).
        chmod(dir.path, 0o700)
        return dir
    }
    static var socketPath: String { support.appendingPathComponent("bridge.sock").path }
    static var extensionFolder: URL { support.appendingPathComponent("ChromeExtension", isDirectory: true) }
}

func log(_ items: Any...) {
    let line = items.map { "\($0)" }.joined(separator: " ")
    NSLog("[LCXMixer] %@", line)
}
