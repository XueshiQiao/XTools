# XTools

A macOS menu-bar toolbox — a growing set of small system utilities, one per tab,
sharing one settings-style window. Visual language matches the sibling app AnyDrag.

## First tool: Launch Manager
Find and clean up the background processes some apps leave running after you quit them
(the classic case: Baidu Netdisk's `netdisk_service` lingering after you've "quit").

- **Residual processes** — lists background helpers whose owning app isn't running.
  Known repeat offenders are highlighted; legitimate background services / Apple system
  bundles are de-emphasized. One-tap **Reap**.
- **Guardian rules** — opt in per app: whenever that app isn't running, XTools reaps
  its leftover helpers automatically (instantly when you quit it, plus a short poll to
  catch helpers the system re-spawns). It leaves the app's LaunchAgent alone, so it
  keeps working even when the vendor re-adds it on next launch.
- **LaunchAgents / Daemons inventory** — browse all three launchd directories, spot
  orphans pointing at deleted apps, and stop / disable items (system items prompt once
  for your password; plists are moved to `.bak`, never deleted).

User-level cleanup is automatic and needs no privileges; root daemons are handled
on-demand with an admin password prompt.

## Build
```bash
brew install xcodegen
xcodegen generate
scripts/run.sh          # kill → build → relaunch (Debug)
```
macOS 13+. Logs at `~/Library/Logs/XTools/XTools.log`.

See `AGENTS.md` for architecture and `docs/DESIGN.md` for decisions & scope.

---
By [@XueshiQiao](https://x.com/XueshiQiao) · [xueshi.dev](https://xueshi.dev)
