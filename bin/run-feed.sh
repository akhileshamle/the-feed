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

# --- 0. one run at a time (launchd fires every missed job at once on wake) ---
LOCK="$REPO/.lock"
find "$LOCK" -maxdepth 0 -mmin +15 -exec rmdir {} \; 2>/dev/null || true   # stale lock from a killed run
for i in $(seq 1 60); do
  mkdir "$LOCK" 2>/dev/null && break
  [ "$i" = 60 ] && { log "lock busy for 5 minutes, giving up"; exit 1; }
  sleep 5
done
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# --- once per slot per day (FORCE=1 to run again) ---
if [ "${FORCE:-0}" != "1" ] && SLOT="$SLOT" python3 - <<'PY'
import json, os, sys, datetime
try:
    entries = json.load(open("feed.json")).get("entries", [])
except Exception:
    sys.exit(1)
today = datetime.date.today().isoformat()
sys.exit(0 if any(e.get("slot") == os.environ["SLOT"] and e.get("time", "")[:10] == today for e in entries) else 1)
PY
then log "already ran today (FORCE=1 to run again)"; exit 0; fi

# --- 1. notes from Calendar (recurring events keep the same notes on every occurrence) ---
NOTES="$(osascript - "$CALENDAR_NAME" "$KEYWORD" <<'APPLESCRIPT'
on run argv
  set calName to item 1 of argv
  set kw to item 2 of argv
  -- pick the most recently started matching event that has notes
  with timeout of 300 seconds
    tell application "Calendar"
      set evs to (every event of calendar calName whose summary contains kw)
      set best to ""
      set bestDate to missing value
      repeat with ev in evs
        set d to description of ev
        if d is not missing value and d is not "" then
          set s to start date of ev
          if bestDate is missing value or s > bestDate then
            set best to d
            set bestDate to s
          end if
        end if
      end repeat
      return best
    end tell
  end timeout
end run
APPLESCRIPT
)" || { log "osascript failed (Automation permission for Calendar?)"; exit 1; }

if [ -z "${NOTES// /}" ]; then log "no notes found for '$KEYWORD' in '$CALENDAR_NAME'"; exit 1; fi

# --- 2. Claude ---
TODAY="$(date '+%A %d %B %Y')"
PROMPT="Today is $TODAY. You are producing today's '$SLOT' micro-session for an iOS software engineer. Below are the notes from the calendar event; follow them exactly. Do not open links or use tools; rely on the notes and your own knowledge. If the notes ask for a daily item, pick today's item fresh. Reply in Markdown with only the content to publish: a short title line (##), then the session, under 300 words. Put any answer or check at the very end after a line that says 'Answer:'.

--- CALENDAR NOTES ---
$NOTES"

RESPONSE="$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p 2>>"$LOG")" || { log "claude failed"; exit 1; }
if [ -z "${RESPONSE// /}" ]; then log "empty response"; exit 1; fi
# a real session starts with a Markdown title; anything else (CLI error, login notice) must not go public
FIRST_LINE="$(printf '%s\n' "$RESPONSE" | grep -m1 -v '^[[:space:]]*$' || true)"
if ! printf '%s' "$FIRST_LINE" | grep -qE '^#{1,3} '; then log "bad response, not published: ${FIRST_LINE:0:80}"; exit 1; fi

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

# Kindle page: a failure here must never block the main feed
python3 "$REPO/bin/make-kindle.py" >> "$LOG" 2>&1 || log "kindle page failed"

# --- 4. publish ---
if [ "${SKIP_PUSH:-0}" = "1" ]; then log "done (push skipped)"; exit 0; fi
git add feed.json kindle.html
git commit -q -m "feed: $SLOT $(date '+%F %H:%M')" || { log "nothing to commit"; exit 0; }
if ! git pull -q --rebase origin main >> "$LOG" 2>&1; then
  git rebase --abort 2>/dev/null || true
  log "rebase failed (commit kept locally; next run will retry the push)"; exit 1
fi
git push -q origin main >> "$LOG" 2>&1 || { log "push failed"; exit 1; }
log "published"
