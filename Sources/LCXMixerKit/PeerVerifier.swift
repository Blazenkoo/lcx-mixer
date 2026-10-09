import Darwin
import Foundation
import Security
import os

/// Checks that the process on the other end of a local socket is this same app
/// (same user, and code-signed with this app's own designated requirement).
enum PeerVerifier {
    private static let ownRequirement: SecRequirement? = {
        var selfCode: SecCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(selfCode, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }()

    static func isTrustedPeer(_ fd: Int32) -> Bool {
        // 1. Same user account.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
            Log.browser.error("Rejected socket peer: different user")
            return false
        }

        // 2. Same code signature (audit token avoids PID-reuse races).
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0 else {
            Log.browser.error("Rejected socket peer: no audit token")
            return false
        }
        guard let requirement = ownRequirement else {
            Log.browser.error("Rejected socket peer: own signature unavailable")
            return false
        }
        let tokenData = withUnsafeBytes(of: &token) { Data($0) } as CFData
        let attributes = [kSecGuestAttributeAudit as String: tokenData] as CFDictionary
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else {
            Log.browser.error("Rejected socket peer: unknown process")
            return false
        }
        let status = SecCodeCheckValidity(code, [], requirement)
        if status != errSecSuccess {
            Log.browser.error("Rejected socket peer: signature mismatch: \(status)")
            return false
        }
        return true
    }
}
