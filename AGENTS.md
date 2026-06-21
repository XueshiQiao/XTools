# XTools

A macOS menu-bar app that hosts a growing collection of small system utilities, one per tab. Each tool is isolated in its own folder; the shell (menu bar + settings-style window) is shared. The visual language is lifted from the sibling app **AnyDrag** so the two read as one family.

## Tech Stack
- Swift 5.9, macOS 13.0+. AppKit shell (menu bar, window controller); the UI is SwiftUI hosted in an `NSHostingController`.
- XcodeGen (`project.yml`) generates the Xcode project.
- Sparkle (auto-update) + Aptabase (anonymous analytics) — both wired up but **inert/placeholder** until real keys/feed are configured (see below).
- Not sandboxed (`com.apple.security.app-sandbox = false`) — required to enumerate and signal other processes and read LaunchAgent/Daemon plists.
- Localized: English + Simplified Chinese (`Localizable.strings` + `LocalizationOverride`; SwiftUI reads them through the `L(_:)` helper).

## Architecture
```
XTools/Sources/
├─ App/        main.swift · AppDelegate · MenuBarController · UpdateController
├─ Core/       FileLog · LocalizationOverride · Preferences · Analytics      (shared infra)
├─ UI/         AppChrome (visual language) · MainWindowController + MainView ·
│              GeneralPage · AboutPage · XTool (protocol) · ToolRegistry · AppState
└─ Tools/
   └─ LaunchManager/   ← the first tool, fully self-contained
```

### The tool abstraction (how to add a tool)
1. Create `Sources/Tools/<Name>/`.
2. Implement `XToolModule` on a `<Name>Tool` class (id, title, symbol, color, optional `activate()`/`shutdown()` for app-lifetime background work, and `makeRootView()`).
3. Add one line to `ToolRegistry.makeAllTools()`.

The sidebar, routing, and lifecycle are all driven by the registry — the shell never hard-codes a tool. `AppState` owns the tool instances (created at launch, so background services start immediately) and the current `SidebarItem` selection. The built-in **General** and **About** pages sit below the tools.

### Launch Manager (first tool)
Finds and cleans up "ghost" background processes left running after an app is quit (e.g. Baidu Netdisk's `netdisk_service`), manages LaunchAgents/Daemons, and runs user-defined **Guardian** rules.

- `ProcessScanner` — `sysctl(KERN_PROC_ALL)` + `proc_pidpath` (paths normalized to symlink-resolved real paths so every comparison is canonical).
- `LaunchInventory` — parses the three launchd dirs' plists directly (world-readable, so root daemons are inventoried too).
- `ResidualDetector` + `KnownApps` — groups helpers by owning `.app` bundle whose main app isn't running; classifies offender/benign/unknown (Apple system bundles and known updaters are marked benign, never auto-suggested).
- `GuardianReaper` — app-lifetime enforcer. Event trigger (NSWorkspace app-terminated) + 10s poll. Reaps **user-level** helpers only (SIGTERM→SIGKILL); root helpers are surfaced/counted but need the on-demand privileged path. Rules are **opt-in**, persisted per-tool via `GuardianRuleStore`.
- `ProcessReaper` / `PrivilegedRunner` / `LaunchControl` — kill (user direct, root via one admin password prompt), bootout, and disable-by-moving-plist-aside (never deletes; backs up to `.bak`).

**Scope (v1):** user-level continuous guardian + on-demand root cleanup (password prompt). Continuous *root* reaping needs a separately-installed privileged helper — deferred to v2.

## Build & Run
```bash
brew install xcodegen
xcodegen generate
scripts/run.sh          # kill old → build → relaunch (Debug)
# or: open XTools.xcodeproj  then Cmd+R
```
- The Debug build is `XTools-Debug.app` (bundle id `me.xueshi.xtools.debug`).
- Logs: `~/Library/Logs/XTools/XTools.log` (`tail -F` it).
- `XTOOLS_AUTOOPEN=1` opens the window on launch (dev/screenshot affordance; inert otherwise).

## Placeholders to fill before shipping
- `XTools/Info.plist`: `SUPublicEDKey` (Sparkle EdDSA public key) and set `SUEnableAutomaticChecks` to `<true/>`; confirm `SUFeedURL` repo.
- `XTools/Sources/Core/Analytics.swift`: real Aptabase `appKey` (currently `A-XX-…` → inert).
- A distinct app icon (currently borrows AnyDrag's as a placeholder).

## Conventions
- Truthfulness: only claim "works" for paths actually run & observed. Root continuous-reap is explicitly NOT implemented (v2).
- Data safety: never delete a plist — move it to `.bak`. Never auto-kill without an opt-in Guardian rule.
- Keep tools isolated: a tool owns its models/services/store/view + persistence inside its folder; `Core`/`UI` hold only shared infra.
