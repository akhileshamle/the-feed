#!/bin/bash
# Usage: bin/run-feed.sh <physics|math|dsa>
# 1. reads the notes of the matching event in the "claude-maxing" calendar
# 2. runs them through Claude (headless)
# 3. appends the answer to feed.json, commits and pushes
set -euo pipefail

SLOT="${1:?usage: run-feed.sh <physics|math|dsa>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

# launchd starts with a bare PATH
export PATH="/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/.npm-global/bin:$HOME/.claude/local:$PATH"
[ -f "$REPO/bin/feed.env" ] && . "$REPO/bin/feed.env"      # may set CLAUDE_BIN, CALENDAR_NAME
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
CALENDAR_NAME="${CALENDAR_NAME:-claude-maxing}"
LOG="$REPO/logs/run.log"; mkdir -p "$REPO/logs"
log() { echo "$(date '+%F %T') [$SLOT] $*" >> "$LOG"; }

case "$SLOT" in
  physics) KEYWORD="physics/maxing" ;;
  math)    KEYWORD="math/maxing" ;;
  dsa)     KEYWORD="dsa/maxing" ;;
  *) echo "unknown slot: $SLOT" >&2; exit 2 ;;
esac

# --- 1. notes from Calendar (recurring events keep the same notes on every occurrence) ---
NOTES="$(osascript - "$CALENDAR_NAME" "$KEYWORD" <<'APPLESCRIPT'
on run argv
  set calName to item 1 of argv
  set kw to item 2 of argv
  tell application "Calendar"
    set evs to (every event of calendar calName whose summary contains kw)
    if (count of evs) is 0 then return ""
    set d to description of (item 1 of evs)
    if d is missing value then return ""
    return d
  end tell
end run
APPLESCRIPT
)" || { log "osascript failed (Automation permission for Calendar?)"; exit 1; }

if [ -z "${NOTES// /}" ]; then log "no notes found for '$KEYWORD' in '$CALENDAR_NAME'"; exit 1; fi

# --- 2. Claude ---
TODAY="$(date '+%A %d %B %Y')"
PROMPT="Today is $TODAY. You are producing today's '$SLOT' micro-session for Akhilesh, an iOS software engineer. Below are the notes from his calendar event; follow them exactly. Do not open links or use tools; rely on the notes and your own knowledge. If the notes ask for a daily item, pick today's item fresh. Reply in Markdown with only the content to publish: a short title line (##), then the session, under 300 words. Put any answer or check at the very end after a line that says 'Answer:'.

--- CALENDAR NOTES ---
$NOTES"

RESPONSE="$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p 2>>"$LOG")" || { log "claude failed"; exit 1; }
if [ -z "${RESPONSE// /}" ]; then log "empty response"; exit 1; fi

# --- 3. append to feed.json ---
SLOT="$SLOT" RESPONSE="$RESPONSE" python3 - <<'PY'
import json, os, datetime
p = "feed.json"
try:
    data = json.load(open(p))
except Exception:
    data = {"entries": []}
tz = datetime.datetime.now().astimezone()
data["entries"].append({"slot": os.environ["SLOT"], "time": tz.isoformat(timespec="seconds"), "text": os.environ["RESPONSE"].strip()})
data["entries"] = data["entries"][-200:]
tmp = p + ".tmp"
json.dump(data, open(tmp, "w"), ensure_ascii=False, indent=1)
os.replace(tmp, p)
PY

# --- 4. publish ---
if [ "${SKIP_PUSH:-0}" = "1" ]; then log "done (push skipped)"; exit 0; fi
git add feed.json
git commit -q -m "feed: $SLOT $(date '+%F %H:%M')" || { log "nothing to commit"; exit 0; }
git pull -q --rebase origin main >> "$LOG" 2>&1 || true
git push -q origin main >> "$LOG" 2>&1 || { log "push failed"; exit 1; }
log "published"
