import Foundation

/// Chrome native-messaging host: relays Chrome's length-prefixed stdio messages to the app's socket and back.
enum BridgeHost {
    private static let lock = NSLock()
    private static var socketFD: Int32 = -1

    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        Thread.detachNewThread { stdinLoop() }
        Thread.detachNewThread { socketLoop() }
        while true { sleep(3600) }
    }

    // Chrome → app
    private static func stdinLoop() {
        while true {
            guard let header = readExactly(fd: 0, count: 4) else { exit(0) }
            let length = Int(header[0]) | Int(header[1]) << 8 | Int(header[2]) << 16 | Int(header[3]) << 24
            guard length > 0, length < 64 * 1024 * 1024, var body = readExactly(fd: 0, count: length) else { exit(0) }
            body.append(0x0A)
            lock.lock()
            let fd = socketFD
            lock.unlock()
            if fd >= 0 { _ = writeAll(fd: fd, bytes: body) }
        }
    }

    // app → Chrome
    private static func socketLoop() {
        var reportedDown = false
        while true {
            let fd = connectSocket()
            if fd < 0 {
                if !reportedDown {
                    sendToChrome(#"{"type":"appStatus","connected":false}"#)
                    reportedDown = true
                }
                sleep(2)
                continue
            }
            lock.lock(); socketFD = fd; lock.unlock()
            reportedDown = false
            sendToChrome(#"{"type":"appStatus","connected":true}"#)

            var pending = [UInt8]()
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = read(fd, &chunk, chunk.count)
                if n <= 0 { break }
                pending.append(contentsOf: chunk[0..<n])
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Array(pending[0..<newline])
                    pending.removeSubrange(0...newline)
                    if !line.isEmpty { sendToChrome(bytes: line) }
                }
            }
            lock.lock(); socketFD = -1; lock.unlock()
            close(fd)
            sendToChrome(#"{"type":"appStatus","connected":false}"#)
            reportedDown = true
            sleep(1)
        }
    }

    private static func connectSocket() -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let pathBytes = Array(AppPaths.socketPath.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let count = min(pathBytes.count, raw.count - 1)
            for i in 0..<count { raw[i] = pathBytes[i] }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            close(fd)
            return -1
        }
        // Make sure the listener really is the LCX Mixer app before relaying Chrome's messages.
        guard PeerVerifier.isTrustedPeer(fd) else {
            close(fd)
            return -1
        }
        return fd
    }

    private static let stdoutLock = NSLock()

    private static func sendToChrome(_ json: String) {
        sendToChrome(bytes: Array(json.utf8))
    }

    private static func sendToChrome(bytes: [UInt8]) {
        let n = UInt32(bytes.count)
        let header: [UInt8] = [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)]
        stdoutLock.lock()
        defer { stdoutLock.unlock() }
        if !writeAll(fd: 1, bytes: header + bytes) { exit(0) }
    }

    private static func readExactly(fd: Int32, count: Int) -> [UInt8]? {
        var result = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = result.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress!.advanced(by: offset), count - offset)
            }
            if n <= 0 { return nil }
            offset += n
        }
        return result
    }

    @discardableResult
    private static func writeAll(fd: Int32, bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { raw in
                write(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset)
            }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }
}
