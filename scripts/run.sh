#!/usr/bin/env bash
#
# Kill any running XTools, (re)generate the project, build Debug, and relaunch.
# Mirrors the "kill → rebuild → re-sign → relaunch, never a no-op" cycle.
#
# Usage: scripts/run.sh [--open]   (--open opens the settings window on launch)
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/dd/Build/Products/Debug/XTools-Debug.app"

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

echo "› launching…"
if [ "${1:-}" = "--open" ]; then
  # `open` can't pass env vars; exec the binary directly so XTOOLS_AUTOOPEN reaches it.
  XTOOLS_AUTOOPEN=1 nohup "$APP/Contents/MacOS/XTools-Debug" >/dev/null 2>&1 &
  disown 2>/dev/null || true
else
  open "$APP"
fi
echo "› done. logs: tail -F ~/Library/Logs/XTools/XTools.log"
