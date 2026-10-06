import AppKit
import CoreAudio
import Darwin

/// A native app (or app group) that has audio clients registered with Core Audio.
struct NativeAppSnapshot {
    let key: String
    var name: String
    var icon: NSImage?
    var processObjects: [AudioObjectID]
    var bundleIDs: [String]
    var pids: [pid_t]
    var memberNames: [String]
    var isRunningOutput: Bool
}

private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t
private let responsibleForPid: ResponsibleFn? = {
    guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
        return nil
    }
    return unsafeBitCast(symbol, to: ResponsibleFn.self)
}()

/// Finds which apps are producing sound, attributes helper processes to their app and applies grouping.
@MainActor
final class AudioProcessMonitor {
    private let settings: AppSettings
    private var ownerCache: [pid_t: NSRunningApplication?] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(settings: AppSettings) { self.settings = settings }

    static func isChrome(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.google.Chrome")
    }

    /// Group key and display name for an app's bundle identifier.
    func group(for bundleID: String) -> (key: String, name: String?) {
        for rule in settings.groups where rule.isComplete && rule.prefixes.contains(where: { bundleID.hasPrefix($0) }) {
            let name = rule.name.trimmingCharacters(in: .whitespaces)
            return ("group:" + name, name)
        }
        return (bundleID, nil)
    }

    /// Group keys of all running apps (used to tell whether a source's app has quit).
    func runningKeys() -> Set<String> {
        var keys = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier { keys.insert(group(for: id).key) }
        }
        return keys
    }

    func snapshot() -> [String: NativeAppSnapshot] {
        var result: [String: NativeAppSnapshot] = [:]
        var livePIDs = Set<pid_t>()

        for object in CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList) {
            let pid: pid_t = CA.get(object, kAudioProcessPropertyPID, default: -1)
            guard pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let running: UInt32 = CA.get(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            let processBundle = CA.string(object, kAudioProcessPropertyBundleID) ?? ""

            guard let owner = owningApp(for: pid), let ownerBundle = owner.bundleIdentifier else { continue }
            if ownerBundle == AppPaths.bundleID || AudioProcessMonitor.isChrome(ownerBundle) || AudioProcessMonitor.isChrome(processBundle) {
                continue
            }
            let (key, groupName) = group(for: ownerBundle)
            if settings.isIgnored([key, ownerBundle, processBundle]) { continue }

            let appName = owner.localizedName ?? ownerBundle
            var entry = result[key] ?? NativeAppSnapshot(
                key: key,
                name: groupName ?? appName,
                icon: owner.icon,
                processObjects: [],
                bundleIDs: [],
                pids: [],
                memberNames: [],
                isRunningOutput: false
            )
            entry.processObjects.append(object)
            if !entry.bundleIDs.contains(ownerBundle) { entry.bundleIDs.append(ownerBundle) }
            if !entry.pids.contains(owner.processIdentifier) { entry.pids.append(owner.processIdentifier) }
            if !entry.memberNames.contains(appName) { entry.memberNames.append(appName) }
            if entry.icon == nil { entry.icon = owner.icon }
            entry.isRunningOutput = entry.isRunningOutput || running != 0
            result[key] = entry
        }

        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }
        return result
    }

    // MARK: - Owner resolution

    private func owningApp(for pid: pid_t) -> NSRunningApplication? {
        if let cached = ownerCache[pid] { return cached }
        var candidates: [pid_t] = []
        if let responsible = responsibleForPid?(pid), responsible > 0 { candidates.append(responsible) }
        candidates.append(pid)
        var p = pid
        for _ in 0..<6 {
            p = AudioProcessMonitor.parentPID(p)
            if p <= 1 { break }
            candidates.append(p)
        }
        var found: NSRunningApplication?
        for c in candidates {
            if let app = NSRunningApplication(processIdentifier: c), app.activationPolicy == .regular {
                found = app
                break
            }
        }
        if found == nil {
            for c in candidates {
                if let app = NSRunningApplication(processIdentifier: c), app.bundleIdentifier != nil, app.activationPolicy != .prohibited {
                    found = app
                    break
                }
            }
        }
        ownerCache[pid] = .some(found)
        return found
    }

    static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}
