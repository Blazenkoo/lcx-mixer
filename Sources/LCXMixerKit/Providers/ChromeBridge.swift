import Foundation
import os

/// Local socket server the native-messaging bridges connect to. Each browser (and each browser
/// profile) runs its own bridge process, so several connections can be open at once.
/// Messages are newline-delimited JSON. Callbacks arrive on the main thread.
final class ChromeBridgeServer {
    /// A connection's ID, the process ID of its bridge, and whether it just opened (true) or closed (false).
    var onClient: ((_ id: Int32, _ bridgePID: pid_t, _ connected: Bool) -> Void)?
    var onMessage: ((_ id: Int32, _ message: [String: Any]) -> Void)?

    private final class Client {
        let fd: Int32
        var buffer = Data()
        var source: DispatchSourceRead?
        init(fd: Int32) { self.fd = fd }
    }

    private let queue = DispatchQueue(label: "lcxmixer.bridge")
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    /// Keyed by connection ID, which only ever counts up (socket numbers get reused).
    private var clients: [Int32: Client] = [:]
    private var nextID: Int32 = 1

    func start() {
        queue.async { self.listen() }
    }

    func send(to id: Int32, _ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        queue.async {
            guard let client = self.clients[id] else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client.fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
        }
    }

    // MARK: - Private (bridge queue)

    private func listen() {
        let path = AppPaths.socketPath
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { Log.browser.error("socket() failed"); return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let count = min(pathBytes.count, raw.count - 1)
            for i in 0..<count { raw[i] = pathBytes[i] }
        }
        // Create the socket file readable/writable by this user only.
        let previousMask = umask(0o077)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        umask(previousMask)
        chmod(path, 0o600)
        guard bound == 0, Darwin.listen(fd, 8) == 0 else {
            let code = errno
            Log.browser.error("bind/listen failed: \(code)")
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
        Log.browser.info("Bridge listening at \(path)") // private: the path holds your user name
    }

    private func acceptClient() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // Only the app's own bridge process (same user, same code signature) may connect.
        guard PeerVerifier.isTrustedPeer(fd) else {
            close(fd)
            return
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        if getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) != 0 { pid = 0 }

        let id = nextID
        nextID += 1
        let client = Client(fd: fd)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient(id) }
        source.resume()
        client.source = source
        clients[id] = client
        DispatchQueue.main.async { self.onClient?(id, pid, true) }
    }

    private func readClient(_ id: Int32) {
        guard let client = clients[id] else { return }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(client.fd, &chunk, chunk.count)
        if n <= 0 {
            dropClient(id)
            return
        }
        client.buffer.append(contentsOf: chunk[0..<n])
        while let newline = client.buffer.firstIndex(of: 0x0A) {
            let line = client.buffer[client.buffer.startIndex..<newline]
            client.buffer.removeSubrange(client.buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { self.onMessage?(id, object) }
        }
    }

    private func dropClient(_ id: Int32) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.source?.cancel()
        close(client.fd)
        DispatchQueue.main.async { self.onClient?(id, 0, false) }
    }

    // MARK: - Browser registration

    /// Writes the native-messaging host manifest for every supported browser that has a data folder
    /// (Chrome always), and copies the extension to a stable folder.
    static func registerWithBrowsers() {
        let fm = FileManager.default
        guard let executable = Bundle.main.executablePath else { return }
        let manifest: [String: Any] = [
            "name": AppPaths.nativeHostName,
            "description": "LCX Mixer bridge",
            "path": executable,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(AppPaths.extensionID)/"],
        ]
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for info in Browsers.all {
            let browser = base.appendingPathComponent(info.dataFolder)
            guard info == Browsers.chrome || fm.fileExists(atPath: browser.path) else { continue }
            let hosts = browser.appendingPathComponent("NativeMessagingHosts")
            try? fm.createDirectory(at: hosts, withIntermediateDirectories: true)
            // Clean up manifests left by earlier versions of this app under a different host name.
            if let files = try? fm.contentsOfDirectory(at: hosts, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension == "json" && file.deletingPathExtension().lastPathComponent != AppPaths.nativeHostName {
                    if let data = try? Data(contentsOf: file),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let path = json["path"] as? String,
                       URL(fileURLWithPath: path).lastPathComponent == URL(fileURLWithPath: executable).lastPathComponent,
                       path.contains("LCX Mixer.app") {
                        try? fm.removeItem(at: file)
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]) {
                try? data.write(to: hosts.appendingPathComponent(AppPaths.nativeHostName + ".json"))
            }
        }

        if let bundled = Bundle.main.resourceURL?.appendingPathComponent("ChromeExtension"),
           fm.fileExists(atPath: bundled.path) {
            let target = AppPaths.extensionFolder
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            if let files = try? fm.contentsOfDirectory(atPath: bundled.path) {
                for file in files {
                    let dst = target.appendingPathComponent(file)
                    try? fm.removeItem(at: dst)
                    try? fm.copyItem(at: bundled.appendingPathComponent(file), to: dst)
                }
            }
        }
    }
}
