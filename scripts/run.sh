#!/usr/bin/env bash
#
# Kill any running XTools, (re)generate the project, build Debug, and relaunch.
# ALWAYS launches via `open` so LaunchServices registers/activates the app
# normally (a raw-binary launch comes up behind other windows and won't
# foreground cleanly — that's why there is no `nohup` direct-exec path here).
#
# Usage: scripts/run.sh [--tab <tool-id>]
#   --tab <id>   pre-select a tool tab on launch, e.g. `--tab now-playing`
#                (dev/screenshot affordance; passed through as `open --args`).
#                The window opens on launch regardless — no env var needed.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/dd/Build/Products/Debug/XTools-Debug.app"

TAB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tab)  TAB="${2:-}"; shift 2 ;;
    --open) shift ;;   # deprecated no-op: the window always opens on launch now.
    *) echo "unknown arg: $1 (usage: scripts/run.sh [--tab <tool-id>])" >&2; exit 2 ;;
  esac
done

echo "› killing any running instance…"
pkill -f "XTools-Debug" 2>/dev/null || true
sleep 1

echo "› xcodegen generate…"
xcodegen generate >/dev/null

echo "› building (Debug)…"
xcodebuild -project XTools.xcodeproj -scheme XTools -configuration Debug \
  -derivedDataPath build/dd -destination 'platform=macOS' build \
  2>&1 | grep -E "(error:|warning: .*Sources/XTools|BUILD SUCCEEDED|BUILD FAILED)" || true

[ -d "$APP" ] || { echo "build did not produce $APP" >&2; exit 1; }

echo "› launching via open…"
if [ -n "$TAB" ]; then
  # `open --args` passes argv on a fresh launch; the app reads `--tab`.
  open "$APP" --args --tab "$TAB"
else
  open "$APP"
fi
echo "› done. logs: tail -F ~/Library/Logs/XTools/XTools.log"
