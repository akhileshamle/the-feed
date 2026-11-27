#!/bin/bash
# Usage: bin/archive-prompt.sh <physics|math|dsa|ios>
# Saves the slot's current Calendar note (the recurring event) to prompts/archive/<date>-<slot>.md.
# Run it before editing a note in Calendar, so the old text is kept. Never overwrites an existing file.
# claude.ai artifact links are replaced by a placeholder, because the repo is public.
set -euo pipefail

SLOT="${1:?usage: archive-prompt.sh <physics|math|dsa|ios>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ -f "$REPO/bin/feed.env" ] && . "$REPO/bin/feed.env"
CALENDAR_NAME="${CALENDAR_NAME:-claude-maxing}"

case "$SLOT" in
  physics) KEYWORD="physics/maxing" ;;
  math)    KEYWORD="math/maxing" ;;
  dsa)     KEYWORD="dsa/maxing" ;;
  ios)     KEYWORD="ios/maxing" ;;
  *) echo "unknown slot: $SLOT" >&2; exit 2 ;;
esac

OUT="$REPO/prompts/archive/$(date +%F)-$SLOT.md"
if [ -e "$OUT" ]; then echo "already exists, not overwriting: $OUT" >&2; exit 1; fi

# the recurring event is the one that carries the "all events" notes (same rule as run-feed.sh)
NOTES="$(osascript - "$CALENDAR_NAME" "$KEYWORD" <<'APPLESCRIPT'
on run argv
  set calName to item 1 of argv
  set kw to item 2 of argv
  set dayEnd to (current date)
  set time of dayEnd to 0
  set dayEnd to dayEnd + 1 * days
  with timeout of 300 seconds
    tell application "Calendar"
      set evs to (every event of calendar calName whose summary contains kw)
      set best to ""
      set bestDate to missing value
      repeat with ev in evs
        set d to description of ev
        if (recurrence of ev) is not missing value and d is not missing value and d is not "" then
          set s to start date of ev
          -- a series split by "this and future events": the newest one that has started wins
          if s < dayEnd and (bestDate is missing value or s > bestDate) then
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
)" || { echo "osascript failed (Automation permission for Calendar?)" >&2; exit 1; }

if [ -z "${NOTES// /}" ]; then echo "no notes found for '$KEYWORD' in '$CALENDAR_NAME'" >&2; exit 1; fi

# the repo is public: claude.ai artifact links are not kept in the archive
NOTES="$(printf '%s' "$NOTES" | sed -E 's#https://claude\.ai/artifact/[A-Za-z0-9_-]+#<artifact link removed>#g')"

mkdir -p "$(dirname "$OUT")"
printf '%s\n' "$NOTES" > "$OUT"
echo "saved $OUT ($(printf '%s' "$NOTES" | wc -m | tr -d ' ') characters)"
