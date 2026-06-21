import Foundation

/// Flushes the macOS DNS cache. This requires root, so it runs through
/// `PrivilegedRunner` (one admin password prompt — the same mechanism the Launch
/// Manager uses). It runs the documented two-step Apple recommends:
///
///     dscacheutil -flushcache; killall -HUP mDNSResponder
///
/// Blocks on the password prompt, so call off the main thread.
enum DNSFlusher {

    private static let log = FileLog("DNSFlusher")

    enum FlushError: LocalizedError {
        case cancelled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:        return L("dns.flush.cancelled")
            case .failed(let m):    return String(format: L("dns.flush.failed"), m)
            }
        }
    }

    static func flush() -> Result<Void, FlushError> {
        let inner = "/usr/bin/dscacheutil -flushcache; /usr/bin/killall -HUP mDNSResponder"
        switch PrivilegedRunner.run("/bin/sh", ["-c", inner]) {
        case .success:
            log.info("flushed DNS cache")
            return .success(())
        case .failure(.cancelled):
            return .failure(.cancelled)
        case .failure(.failed(_, let message)):
            return .failure(.failed(message))
        }
    }
}
