import Foundation
import Darwin

/// Lists listening ports and active connections by parsing `lsof`'s
/// machine-readable field output. Listing every socket needs no privilege, so
/// this runs as the current user with no password prompt.
///
/// We use `lsof -F` (one field per line, prefixed by a single-char selector)
/// instead of the default space-columned output: the COMMAND column can contain
/// spaces and lsof truncates/pads columns, so column parsing is fragile. `-F`
/// is stable and unambiguous.
///
/// Field selectors we request (`-FpcuLtPnT`):
///   p<pid>  c<command>  u<uid>  L<login>   — process-level, apply to all files
///   t<type:IPv4|IPv6>  P<protocol:TCP|UDP>  n<name:addr:port[->addr:port]>
///   TST=<state>  — file-level (one socket each)
enum PortScanner {

    private static let log = FileLog("PortScanner")

    static func scan() -> [Connection] {
        guard let output = runLsof() else { return [] }
        return parse(output)
    }

    // MARK: - lsof

    private static func runLsof() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -n no DNS, -P no port-name lookup (faster + raw numbers); both IP protos;
        // -F<chars> machine-readable fields. Field order in output: process set
        // (p,c,u,L) then one file set (f,t,P,n,T...) per socket.
        process.arguments = ["-nP", "-FpcuLtPnT", "-iTCP", "-iUDP"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            log.error("failed to launch lsof: \(error.localizedDescription)")
            return nil
        }
        // Drain stderr on a separate thread so it can't deadlock: lsof emits
        // warnings about inaccessible sockets, and if that fills the stderr pipe
        // buffer while we're blocked reading the (also large) stdout pipe, neither
        // side can make progress. Read both concurrently.
        let errReader = DispatchQueue(label: "me.xueshi.xtools.ports.lsof.err", qos: .utility)
        errReader.async { _ = errPipe.fileHandleForReading.readDataToEndOfFile() }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        errReader.sync {}   // ensure the stderr read finished (avoids a leaked fd)
        // lsof exits non-zero (1) when some sockets are inaccessible; that's normal
        // and it still prints everything it could read. Don't discard partial output.
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Parse

    static func parse(_ output: String) -> [Connection] {
        let me = getpid()

        // Current process-level fields, carried forward until the next `p` line.
        var pid: pid_t = 0
        var command = ""
        var uid: uid_t? = nil
        // Resolve the executable path + start time once per pid (cheap, but a pid
        // can own many sockets) — start time is the per-instance fingerprint that
        // makes the later kill pid-reuse-safe.
        var execPath: String? = nil
        var startTime: UInt64? = nil

        // Current file-level fields (one socket), reset on each `f` line.
        var ftype = ""      // IPv4 / IPv6
        var proto = ""      // TCP / UDP
        var name = ""       // addr:port[->addr:port]
        var state: String? = nil
        var haveFile = false

        var rows: [Connection] = []

        func flushFile() {
            guard haveFile, pid > 1, pid != me, !name.isEmpty else { return }
            guard proto == "TCP" || proto == "UDP" else { return }
            let (local, remote) = splitName(name)
            guard let local = local else { return }
            let isV6 = ftype == "IPv6"
            // A socket is "listening" if TCP LISTEN, or a bound UDP socket with no
            // peer (lsof shows just a local addr, no "->").
            let isListening = (state == "LISTEN") || (proto == "UDP" && remote == nil)
            let row = Connection(
                id: "\(pid)-\(proto)-\(name)",
                pid: pid, command: command, uid: uid, executablePath: execPath,
                startTime: startTime,
                proto: proto, isIPv6: isV6,
                localAddr: local.addr, localPort: local.port,
                remoteAddr: remote?.addr, remotePort: remote?.port,
                state: state, isListening: isListening)
            rows.append(row)
        }

        output.enumerateLines { line, _ in
            guard let sel = line.first else { return }
            let value = String(line.dropFirst())
            switch sel {
            case "p":
                flushFile(); haveFile = false
                pid = pid_t(value) ?? 0
                // Reset process-scoped fields; resolve path + start time after pid.
                command = ""; uid = nil
                execPath = pid > 0 ? ProcessScanner.currentExecutablePath(pid: pid) : nil
                startTime = pid > 0 ? ProcessScanner.processStartTime(pid: pid) : nil
            case "c":
                command = value
            case "u":
                uid = UInt32(value).map { uid_t($0) }
            case "L":
                break   // login name available but uid is authoritative; ignore
            case "f":
                flushFile()
                // New socket — reset file-level fields.
                ftype = ""; proto = ""; name = ""; state = nil; haveFile = true
            case "t":
                ftype = value
            case "P":
                proto = value
            case "n":
                name = value
            case "T":
                // e.g. "ST=ESTABLISHED" / "ST=LISTEN" (also TQR=/TQS= which we skip).
                if value.hasPrefix("ST=") { state = String(value.dropFirst(3)) }
            default:
                break
            }
        }
        flushFile()

        return sort(rows)
    }

    /// Split an lsof NAME into local and optional remote `addr:port`. Handles
    /// IPv4 (`127.0.0.1:443`), IPv6 (`[::1]:4321`), wildcard (`*:3000`), and the
    /// `local->remote` connection form.
    private static func splitName(_ name: String) -> (local: (addr: String, port: String)?,
                                                       remote: (addr: String, port: String)?) {
        if let range = name.range(of: "->") {
            let l = parseEndpoint(String(name[name.startIndex..<range.lowerBound]))
            let r = parseEndpoint(String(name[range.upperBound...]))
            return (l, r)
        }
        return (parseEndpoint(name), nil)
    }

    /// Parse one `addr:port` endpoint, splitting on the LAST colon so IPv6
    /// addresses (which contain colons) aren't mangled. IPv6 keeps its `[...]`.
    private static func parseEndpoint(_ s: String) -> (addr: String, port: String)? {
        let endpoint = s.trimmingCharacters(in: .whitespaces)
        guard !endpoint.isEmpty else { return nil }
        guard let lastColon = endpoint.lastIndex(of: ":") else {
            return (endpoint, "*")
        }
        let addr = String(endpoint[endpoint.startIndex..<lastColon])
        let port = String(endpoint[endpoint.index(after: lastColon)...])
        return (addr.isEmpty ? "*" : addr, port.isEmpty ? "*" : port)
    }

    /// Listeners first (the common "who's on :3000" question), then established
    /// and other connections. Within each, sort by command then numeric local port.
    private static func sort(_ rows: [Connection]) -> [Connection] {
        rows.sorted { a, b in
            if a.isListening != b.isListening { return a.isListening }
            if a.command.lowercased() != b.command.lowercased() {
                return a.command.lowercased() < b.command.lowercased()
            }
            return (Int(a.localPort) ?? 0) < (Int(b.localPort) ?? 0)
        }
    }
}
