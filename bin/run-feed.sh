#!/bin/bash
# Usage: bin/run-feed.sh <physics|math|dsa>
# 1. syncs main
# 2. reads the notes of the matching event in the "claude-maxing" calendar
# 3. runs them through Claude (headless)
# 4. writes entries/<timestamp>-<slot>.json on a new branch feed/<slot>-<timestamp> and pushes it
#    GitHub Actions then checks the branch, opens a PR, merges it and redeploys the page.
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

# --- 1. start from an up-to-date main ---
if [ "${SKIP_PUSH:-0}" != "1" ]; then
  git switch -q main >> "$LOG" 2>&1 || { log "could not switch to main (uncommitted changes?)"; exit 1; }
  git pull -q --ff-only origin main >> "$LOG" 2>&1 || { log "could not update main"; exit 1; }
fi

# --- 2. notes from Calendar (recurring events keep the same notes on every occurrence) ---
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

# --- 3. Claude ---
TODAY="$(date '+%A %d %B %Y')"
PROMPT="Today is $TODAY. You are producing today's '$SLOT' micro-session for Akhilesh, an iOS software engineer. Below are the notes from his calendar event; follow them exactly. Do not open links or use tools; rely on the notes and your own knowledge. If the notes ask for a daily item, pick today's item fresh. Reply in Markdown with only the content to publish: a short title line (##), then the session, under 300 words. Put any answer or check at the very end after a line that says 'Answer:'. Do not include email addresses, file paths, links or personal details.

--- CALENDAR NOTES ---
$NOTES"

RESPONSE="$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p 2>>"$LOG")" || { log "claude failed"; exit 1; }
if [ -z "${RESPONSE// /}" ]; then log "empty response"; exit 1; fi

# --- 4. write one entry file ---
STAMP="$(date '+%Y-%m-%dT%H-%M-%S')"
mkdir -p entries
SLOT="$SLOT" STAMP="$STAMP" RESPONSE="$RESPONSE" python3 - <<'PY'
import json, os, datetime
slot, stamp = os.environ["SLOT"], os.environ["STAMP"]
entry = {
    "slot": slot,
    "time": datetime.datetime.now().astimezone().isoformat(timespec="seconds"),
    "text": os.environ["RESPONSE"].strip(),
}
path = os.path.join("entries", f"{stamp}-{slot}.json")
with open(path, "w", encoding="utf-8") as f:
    json.dump(entry, f, ensure_ascii=False, indent=1)
print(path)
PY

# --- 5. branch, push, back to main ---
if [ "${SKIP_PUSH:-0}" = "1" ]; then log "done (push skipped)"; exit 0; fi
BRANCH="feed/${SLOT}-${STAMP//[-:T]/}"
git switch -q -c "$BRANCH"
git add entries
git commit -q -m "feed: $SLOT $(date '+%F %H:%M')"
if git push -q -u origin "$BRANCH" >> "$LOG" 2>&1; then
  log "pushed $BRANCH (GitHub Actions will check and merge it)"
  git switch -q main
  git branch -q -D "$BRANCH"
else
  log "push failed (branch $BRANCH kept locally)"
  git switch -q main
  exit 1
fi