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
    /// Facts that never change for a running process, looked up once instead of on every poll.
    /// Asking macOS for an app's bundle ID or name is a round trip to another process each time.
    private var bundleIDCache: [pid_t: String] = [:]
    private var nameCache: [pid_t: String] = [:]
    private var iconCache: [pid_t: NSImage] = [:]
    private var processInfoCache: [AudioObjectID: (pid: pid_t, bundle: String)] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init(settings: AppSettings) { self.settings = settings }

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
        var live = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            live.insert(pid)
            let id: String
            if let cached = bundleIDCache[pid] {
                id = cached
            } else {
                id = app.bundleIdentifier ?? ""
                bundleIDCache[pid] = id
            }
            if !id.isEmpty { keys.insert(group(for: id).key) }
        }
        bundleIDCache = bundleIDCache.filter { live.contains($0.key) }
        return keys
    }

    private func bundleID(of app: NSRunningApplication) -> String? {
        let pid = app.processIdentifier
        if let cached = bundleIDCache[pid] { return cached.isEmpty ? nil : cached }
        let id = app.bundleIdentifier
        bundleIDCache[pid] = id ?? ""
        return id
    }

    private func icon(of app: NSRunningApplication) -> NSImage? {
        let pid = app.processIdentifier
        if let cached = iconCache[pid] { return cached }
        let icon = app.icon
        if let icon { iconCache[pid] = icon }
        return icon
    }

    private func name(of app: NSRunningApplication, fallback: String) -> String {
        let pid = app.processIdentifier
        if let cached = nameCache[pid] { return cached }
        let name = app.localizedName ?? fallback
        nameCache[pid] = name
        return name
    }

    func snapshot() -> [String: NativeAppSnapshot] {
        var result: [String: NativeAppSnapshot] = [:]
        var livePIDs = Set<pid_t>()

        let objects = CA.objectIDs(CA.system, kAudioHardwarePropertyProcessObjectList)
        for object in objects {
            // A process object's PID and bundle never change: read them once. Only "is it playing" is live.
            let info: (pid: pid_t, bundle: String)
            if let cached = processInfoCache[object] {
                info = cached
            } else {
                info = (CA.get(object, kAudioProcessPropertyPID, default: -1), CA.string(object, kAudioProcessPropertyBundleID) ?? "")
                processInfoCache[object] = info
            }
            let pid = info.pid
            guard pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let running: UInt32 = CA.get(object, kAudioProcessPropertyIsRunningOutput, default: 0)
            let processBundle = info.bundle

            guard let owner = owningApp(for: pid), let ownerBundle = bundleID(of: owner) else { continue }
            // Browsers controlled tab by tab through the extension are never also a native source.
            if ownerBundle == AppPaths.bundleID || settings.isPerTabBrowser(ownerBundle) || settings.isPerTabBrowser(processBundle) {
                continue
            }
            let (key, groupName) = group(for: ownerBundle)
            if settings.isIgnored([key, ownerBundle, processBundle]) { continue }

            let appName = name(of: owner, fallback: ownerBundle)
            var entry = result[key] ?? NativeAppSnapshot(
                key: key,
                name: groupName ?? appName,
                icon: icon(of: owner),
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
            if entry.icon == nil { entry.icon = icon(of: owner) }
            entry.isRunningOutput = entry.isRunningOutput || running != 0
            result[key] = entry
        }

        ownerCache = ownerCache.filter { livePIDs.contains($0.key) }
        let liveObjects = Set(objects)
        processInfoCache = processInfoCache.filter { liveObjects.contains($0.key) }
        let owners = Set(ownerCache.values.compactMap { $0?.processIdentifier })
        nameCache = nameCache.filter { owners.contains($0.key) }
        iconCache = iconCache.filter { owners.contains($0.key) }
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

    nonisolated static func parentPID(_ pid: pid_t) -> pid_t {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return -1 }
        return info.kp_eproc.e_ppid
    }
}
