import Foundation

/// Local socket server the native-messaging bridge connects to. Messages are newline-delimited JSON.
final class ChromeBridgeServer {
    var onMessage: (([String: Any]) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?

    private let queue = DispatchQueue(label: "lcxmixer.bridge")
    private var listenFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var readSource: DispatchSourceRead?
    private var buffer = Data()

    func start() {
        queue.async { self.listen() }
    }

    func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(0x0A)
        queue.async {
            guard self.clientFD >= 0 else { return }
            data.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(self.clientFD, raw.baseAddress!.advanced(by: offset), raw.count - offset)
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
        guard fd >= 0 else { log("socket() failed"); return }

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
        guard bound == 0, Darwin.listen(fd, 4) == 0 else {
            log("bind/listen failed", errno)
            close(fd)
            return
        }
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClient() }
        source.resume()
        acceptSource = source
        log("Bridge listening at", path)
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
        dropClient(notify: false)
        clientFD = fd
        buffer.removeAll()
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.readClient() }
        source.resume()
        readSource = source
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    private func readClient() {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(clientFD, &chunk, chunk.count)
        if n <= 0 {
            dropClient(notify: true)
            return
        }
        buffer.append(contentsOf: chunk[0..<n])
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            DispatchQueue.main.async { self.onMessage?(object) }
        }
    }

    private func dropClient(notify: Bool) {
        readSource?.cancel()
        readSource = nil
        if clientFD >= 0 { close(clientFD) }
        clientFD = -1
        if notify { DispatchQueue.main.async { self.onConnectionChange?(false) } }
    }

    // MARK: - Chrome registration

    /// Writes Chrome's native-messaging host manifest and copies the extension to a stable folder.
    static func registerWithChrome() {
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
        for browserDir in ["Google/Chrome", "Google/Chrome Beta", "Google/Chrome Canary"] {
            let browser = base.appendingPathComponent(browserDir)
            guard browserDir == "Google/Chrome" || fm.fileExists(atPath: browser.path) else { continue }
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
