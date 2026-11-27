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

# --- 1. notes from Calendar ---
# Which event wins: a one-day event that starts today (an override for today) first, otherwise the
# recurring event ("all events" notes; if the series was split, the newest one that has started). One-day events on other days are ignored.
# FEED_DAY_OFFSET=1 pretends it is tomorrow (for testing only).
RAW="$(osascript - "$CALENDAR_NAME" "$KEYWORD" "${FEED_DAY_OFFSET:-0}" <<'APPLESCRIPT'
on run argv
  set calName to item 1 of argv
  set kw to item 2 of argv
  set dayStart to (current date)
  set time of dayStart to 0
  set dayStart to dayStart + ((item 3 of argv) as integer) * days
  set dayEnd to dayStart + 1 * days
  with timeout of 300 seconds
    tell application "Calendar"
      set evs to (every event of calendar calName whose summary contains kw)
      set ovNotes to ""
      set ovDate to missing value
      set recNotes to ""
      set recDate to missing value
      repeat with ev in evs
        set d to description of ev
        if d is not missing value and d is not "" then
          set s to start date of ev
          if (recurrence of ev) is not missing value then
            -- editing "this and future events" splits a series in two: the newest one that has begun wins
            if s < dayEnd and (recDate is missing value or s > recDate) then
              set recNotes to d
              set recDate to s
            end if
          else if s ≥ dayStart and s < dayEnd then
            if ovDate is missing value or s > ovDate then
              set ovNotes to d
              set ovDate to s
            end if
          end if
        end if
      end repeat
      if ovDate is not missing value then return "one-day event of " & (ovDate as string) & linefeed & ovNotes
      if recDate is not missing value then return "recurring event" & linefeed & recNotes
      return ""
    end tell
  end timeout
end run
APPLESCRIPT
)" || { log "osascript failed (Automation permission for Calendar?)"; exit 1; }

NOTES="${RAW#*$'\n'}"
if [ -z "${RAW// /}" ] || [ -z "${NOTES// /}" ]; then log "no notes found for '$KEYWORD' in '$CALENDAR_NAME'"; exit 1; fi
log "notes from ${RAW%%$'\n'*}"

# --- 2. Claude ---
TODAY="$(date '+%A %d %B %Y')"
PROMPT="Today is $TODAY. You are producing today's '$SLOT' micro-session for a curious generalist who wants to think more clearly about engineering, finance, business and everyday decisions. Below are the notes from the calendar event; follow them exactly. Do not open links or use tools; rely on the notes and your own knowledge. If the notes ask for a daily item, pick today's item fresh. Reply in Markdown with only the content to publish: a short title line (##), then the session, under 300 words. Put any answer or check at the very end after a line that says 'Answer:'.

--- CALENDAR NOTES ---
$NOTES"

RESPONSE="$(printf '%s' "$PROMPT" | "$CLAUDE_BIN" -p --tools "" 2>>"$LOG")" || { log "claude failed"; exit 1; }
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
KEEP = 200
old, data["entries"] = data["entries"][:-KEEP], data["entries"][-KEEP:]

def write(path, obj):
    tmp = path + ".tmp"
    json.dump(obj, open(tmp, "w"), ensure_ascii=False, indent=1)
    os.replace(tmp, path)

# Entries that fall off the page are filed by month in archive/ instead of being deleted.
# Archive first, then trim, so a crash in between can only duplicate, never lose.
by_month = {}
for e in old:
    by_month.setdefault(e["time"][:7], []).append(e)
for month, items in by_month.items():
    ap = os.path.join("archive", month + ".json")
    os.makedirs("archive", exist_ok=True)
    try:
        have = json.load(open(ap)).get("entries", [])
    except Exception:
        have = []
    seen = {(e["time"], e["slot"]) for e in have}
    have += [e for e in items if (e["time"], e["slot"]) not in seen]
    have.sort(key=lambda e: e["time"])
    write(ap, {"entries": have})
write(p, data)
PY

# Kindle page: a failure here must never block the main feed
python3 "$REPO/bin/make-kindle.py" >> "$LOG" 2>&1 || log "kindle page failed"

# --- 4. publish ---
if [ "${SKIP_PUSH:-0}" = "1" ]; then log "done (push skipped)"; exit 0; fi
git add feed.json kindle.html
[ -d archive ] && git add archive
git commit -q -m "feed: $SLOT $(date '+%F %H:%M')" || { log "nothing to commit"; exit 0; }
if ! git pull -q --rebase origin main >> "$LOG" 2>&1; then
  git rebase --abort 2>/dev/null || true
  log "rebase failed (commit kept locally; next run will retry the push)"; exit 1
fi
git push -q origin main >> "$LOG" 2>&1 || { log "push failed"; exit 1; }
log "published"
