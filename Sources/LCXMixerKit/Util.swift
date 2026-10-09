import Foundation
import os

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

/// A 0…1 level as a whole percentage, e.g. "71%".
func percent(_ p: Float) -> String { "\(Int((p * 100).rounded()))%" }

/// Where the app logs: Apple's unified log, one category per area. Nothing is written to files of
/// the app's own. Failures are errors; connections and device changes are info, which macOS keeps
/// in memory only. Words that could say something about you (paths, page titles) stay private,
/// so macOS hides them in logs you share. Follow it live with:
///     log stream --level info --predicate 'subsystem == "org.lcxmixer.app"'
enum Log {
    static let subsystem = "org.lcxmixer.app"
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let midi = Logger(subsystem: subsystem, category: "midi")
    static let browser = Logger(subsystem: subsystem, category: "browser")
    static let ui = Logger(subsystem: subsystem, category: "ui")
}

/// Performance markers: named intervals that show up in Instruments under Points of Interest,
/// so a slowdown points at one part. They cost next to nothing while nobody is recording.
enum Signposts {
    static let poi = OSSignposter(subsystem: Log.subsystem, category: .pointsOfInterest)
}
