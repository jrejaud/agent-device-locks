#!/usr/bin/env bash
# capture-panels.sh <out-dir> [width-pt] [text-scale] [suffix]
# Screenshots the real overlay in each state (asking, driving, paused, talk) by window id,
# for docs and blog posts. Desktop size: defaults. Phone-friendly: 320 1.3 -mobile.
# Needs peekaboo, jq and Screen Recording permission for the terminal. Captures ONE window, never the screen.
set -euo pipefail
OUT="${1:?out dir}"; W="${2:-400}"; TS="${3:-1}"; SUF="${4:-}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/overlay/agent-overlay-mac"
WHO="Claude Code · session 4f2a91c3"; GOAL="Open System Settings → Displays and turn on Night Shift"
mkdir -p "$OUT"

shot() {  # state-name consent-secs stdin-script...
  local name="$1" consent="$2"; shift 2
  { sleep 1.5; for l in "$@"; do echo "$l"; sleep 0.6; done; sleep 4; echo HIDE; } |
    "$BIN" --who "$WHO" --desc "$GOAL" --consent "$consent" --width "$W" --text-scale "$TS" >/dev/null &
  local pid=$!
  sleep 3.5
  local id
  id="$(peekaboo list windows --app "PID:$pid" --json 2>/dev/null | jq -r '[.data.windows[] | select(.title=="Agent Control")][0].window_id // empty')"
  [ -n "$id" ] || id="$(peekaboo list windows --app agent-overlay-mac --json 2>/dev/null | jq -r '[.data.windows[] | select(.title=="Agent Control")][0].window_id // empty')"
  [ -n "$id" ] || { echo "no Agent Control window for $name" >&2; wait "$pid" || true; return 1; }
  screencapture -x -o -l "$id" "$OUT/$name$SUF.png"
  echo "$OUT/$name$SUF.png"
  wait "$pid" || true
}

shot consent 20
shot banner 0
shot paused 0 PAUSED
shot talk 0 "TALK use the left monitor instead"
