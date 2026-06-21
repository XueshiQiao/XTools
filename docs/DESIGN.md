# XTools — Design & Decisions

> Record of what XTools is, the decisions taken, and what's deliberately deferred.
> Companion to `AGENTS.md` (which is the day-to-day architecture reference).

## 1. What it is
A macOS menu-bar app that hosts many small system utilities — one per sidebar tab.
The shell (menu bar + a settings-style window) and visual language are shared and
lifted from the sibling app **AnyDrag**. Each tool lives in its own isolated folder.

First tool: **Launch Manager** — find & clean up "ghost" background processes left
running after an app is quit (motivating case: Baidu Netdisk's `netdisk_service`),
manage LaunchAgents/Daemons, and run opt-in **Guardian** rules.

## 2. Extensibility model (the key requirement)
- `XToolModule` protocol = the contract: `id`, `title`, `symbol`, `color`,
  `activate()`/`shutdown()` (app-lifetime background work), `makeRootView()`.
- `ToolRegistry.makeAllTools()` = the single list of tools. Adding a tool is a
  one-line change there + a new `Sources/Tools/<Name>/` folder.
- `AppState` owns the tool instances and the sidebar selection; the sidebar,
  routing, and lifecycle are registry-driven — the shell never hard-codes a tool.
- Isolation rule: a tool owns its models/services/store/view **and its persistence**
  inside its folder. `Core/` and `UI/` hold only shared infrastructure.

## 3. Launch Manager design
Three layers:
1. **Inventory** — `LaunchInventory` parses `~/Library/LaunchAgents`,
   `/Library/LaunchAgents`, `/Library/LaunchDaemons` plists directly (world-readable,
   so root daemons are listed too). `ProcessScanner` enumerates processes via
   `sysctl(KERN_PROC_ALL)` + `proc_pidpath`.
2. **Residual detection** — `ResidualDetector` groups processes by their owning
   `.app` bundle whose **main app isn't running**. `KnownApps` classifies each group
   offender / benign / unknown (Apple system bundles + known updaters → benign, never
   suggested). Detection is informational only.
3. **Guardian (the root-cause mechanism)** — `GuardianReaper` runs for the whole app
   lifetime. Two triggers: an `NSWorkspace` app-terminated event (instant when you
   quit the app) and a 10 s poll (catches helpers launchd re-spawns). When a rule's
   app isn't running, it reaps that bundle's leftover helpers.

### Why Guardian instead of deleting the LaunchAgent plist
The vendor (e.g. Baidu) re-adds its LaunchAgent on next launch/login, so deleting the
plist doesn't hold. Guardian leaves the plist alone and simply reaps the orphaned
helpers whenever the owning app isn't up — treating the cause, surviving re-adds, and
fully reversible (toggle the rule off). This was the user's idea; adopted as the core.

### Path canonicalization (a real correctness point)
`proc_pidpath` may return either the launch path (`/tmp/…`) or the real path
(`/private/tmp/…`). All executable paths are normalized to the symlink-resolved real
path at snapshot time so bundle-grouping, rule matching, and main-app detection all
use one canonical form. (Found and fixed during verification.)

## 4. Decisions & scope
| Decision | Choice | Note |
|---|---|---|
| Kill scope | User-level continuous + root on-demand | Root continuous reap deferred (§5) |
| Guardian default | Detect + **opt-in** rules only | Never auto-kills; known offenders are suggestions, not active |
| Reap signal | SIGTERM, then SIGKILL after 2 s grace | User-owned, `uid==getuid()`, never our own pid |
| Disable a plist | Move to `.bak` (never delete) | Backs up; `/Library` plists via one admin prompt |
| Update + analytics | Sparkle + Aptabase scaffolding, placeholders | Inert until keys/feed configured |
| Cleaning the user's real machine | Not done by the tool's author | Tool built + verified against a throwaway test process only |

## 5. Capability boundaries (honest)
- ✅ **Verified (run & observed):** process enumeration, residual detection + UI,
  Guardian poll reaping a user-level helper (SIGTERM confirmed, incl. a process that
  ignores SIGTERM → forced via SIGKILL with the pid-recycle guard), the root-helper
  flag-not-kill path in the continuous loop, "disable completely" (bootout + move
  plist aside) on a KeepAlive launch item, build + launch + window UI.
- ❓ **Unverified (built, not exercised this session):** the root on-demand path
  (`PrivilegedRunner` admin password prompt) and `LaunchControl` bootout/disable — they
  trigger an interactive password dialog, intentionally not run unattended.
- ⛔ **Not implemented (v2):** continuous *root-daemon* reaping. A background loop can't
  prompt for a password; doing it needs a separately-installed privileged helper
  (`SMAppService` daemon), which can't be reliably validated under local dev signing.

## 6. v2 / follow-ups
- Privileged helper (`SMAppService` daemon) for continuous root reaping.
- Per-rule grace period + helper-match override in the Guardian rule model.
- Richer inventory: load/enable state via `launchctl print`, search across all fields.
- Replace the placeholder app icon; fill Sparkle key + Aptabase appKey; flip
  `SUEnableAutomaticChecks` to true.
