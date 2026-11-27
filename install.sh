#!/bin/bash
# Installs the daily launchd jobs (one per slot). Run once from the repo folder:  bash install.sh
# Remove them later with:  bash install.sh --uninstall
set -euo pipefail
REPO="$(cd "$(dirname "$0")" && pwd)"
AGENTS="$HOME/Library/LaunchAgents"
UIDN="$(id -u)"

# slot  hour  minute  (IST, your Mac's local time)
JOBS="ios 6 5
physics 11 15
math 11 25
dsa 14 0"

if [ "${1:-}" = "--uninstall" ]; then
  echo "$JOBS" | while read -r slot h m; do
    launchctl bootout "gui/$UIDN/com.thefeed.$slot" 2>/dev/null || true
    rm -f "$AGENTS/com.thefeed.$slot.plist"
  done
  echo "Removed."; exit 0
fi

chmod +x "$REPO/bin/run-feed.sh"
mkdir -p "$AGENTS" "$REPO/logs"

# remember where claude lives so launchd can find it
CLAUDE_PATH="$(command -v claude || true)"
if [ -z "$CLAUDE_PATH" ]; then echo "claude CLI not found on PATH. Install it first, then re-run."; exit 1; fi
printf 'CLAUDE_BIN=%q\n' "$CLAUDE_PATH" > "$REPO/bin/feed.env"

echo "$JOBS" | while read -r slot h m; do
  PLIST="$AGENTS/com.thefeed.$slot.plist"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.thefeed.$slot</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$REPO/bin/run-feed.sh</string><string>$slot</string>
  </array>
  <key>StartCalendarInterval</key><dict>
    <key>Hour</key><integer>$h</integer><key>Minute</key><integer>$m</integer>
  </dict>
  <key>StandardOutPath</key><string>$REPO/logs/launchd-$slot.out</string>
  <key>StandardErrorPath</key><string>$REPO/logs/launchd-$slot.err</string>
</dict></plist>
EOF
  launchctl bootout "gui/$UIDN/com.thefeed.$slot" 2>/dev/null || true
  launchctl bootstrap "gui/$UIDN" "$PLIST"
  echo "Installed $slot at $(printf '%02d:%02d' "$h" "$m")"
done
echo "Done. Test one now with:  bash bin/run-feed.sh physics"
