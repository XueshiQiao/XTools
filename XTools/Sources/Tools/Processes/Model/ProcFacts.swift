import Foundation
import AppKit

/// Everything XTools can establish about a process WITHOUT asking a model.
///
/// This is the top half of the detail pane and the trusted half of the AI prompt.
/// Assembling it is slow (a code-signature check on a big Electron bundle takes
/// seconds, `LaunchInventory` parses every plist in three directories), so it is
/// built off the main thread, on demand, for ONE selected process — never per row.
struct ProcFacts: Equatable {

    let row: ProcRow

    /// Proven identity. nil while still being computed.
    let signature: CodeSignature?
    /// `Info.plist` bundle id of the owning `.app`, if it lives in one.
    let bundleID: String?
    /// Raw, UNREDACTED argv. Never leaves the machine in this form.
    let argv: ProcArguments.Argv?
    /// The LaunchAgent/Daemon that starts this program, if one does. Nobody else
    /// can tell a model *why the process exists* — only that it is running.
    let launchdLabel: String?
    let launchdPlistPath: String?
    /// Ancestors, nearest first, at most three deep.
    let parents: [(pid: pid_t, name: String)]

    static func == (a: ProcFacts, b: ProcFacts) -> Bool {
        a.row == b.row && a.signature == b.signature && a.bundleID == b.bundleID
            && a.argv?.values == b.argv?.values && a.launchdLabel == b.launchdLabel
            && a.parents.map(\.pid) == b.parents.map(\.pid)
    }

    var hasMeaningfulArguments: Bool { argv?.hasMeaningfulArguments ?? false }

    /// The same facts wearing a fresher row snapshot (metrics move every sweep;
    /// signature/argv/launchd do not — no reason to recompute them).
    func updating(row newRow: ProcRow) -> ProcFacts {
        ProcFacts(row: newRow, signature: signature, bundleID: bundleID, argv: argv,
                  launchdLabel: launchdLabel, launchdPlistPath: launchdPlistPath,
                  parents: parents)
    }
}

/// Builds `ProcFacts`. Call OFF the main thread.
enum ProcFactsBuilder {

    /// `roster` is the current process list — the parent chain is walked through it
    /// rather than re-querying the kernel per ancestor.
    static func build(for row: ProcRow, roster: [ProcRow]) -> ProcFacts {
        let signature = row.executablePath.map(CodeSignInspector.inspect)
        let bundleID = row.owningAppBundlePath.flatMap { Bundle(path: $0)?.bundleIdentifier }
        let argv = row.isKernelTask ? nil : ProcArguments.arguments(pid: row.pid)
        let launchd = matchLaunchd(path: row.executablePath)

        // Walk up at most three ancestors. The guard against a cycle is not
        // paranoia — a corrupt ppid would otherwise spin forever.
        var parents: [(pid: pid_t, name: String)] = []
        var seen: Set<pid_t> = [row.pid]
        var cursor = row.ppid
        let byPid = Dictionary(roster.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        while parents.count < 3, cursor > 0, !seen.contains(cursor), let p = byPid[cursor] {
            parents.append((pid: p.pid, name: p.name))
            seen.insert(cursor)
            cursor = p.ppid
        }

        return ProcFacts(row: row, signature: signature, bundleID: bundleID, argv: argv,
                         launchdLabel: launchd?.label, launchdPlistPath: launchd?.plistPath,
                         parents: parents)
    }

    /// The launchd job whose program IS this executable.
    private static func matchLaunchd(path: String?) -> LaunchItem? {
        guard let path, !path.isEmpty else { return nil }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return LaunchInventory.scan().first { item in
            guard let program = item.programPath else { return false }
            return URL(fileURLWithPath: program).resolvingSymlinksInPath().path == resolved
        }
    }
}
