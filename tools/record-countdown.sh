#!/usr/bin/env bash
# record-countdown.sh <out.webp> [consent-secs] [width-pt] [text-scale]
# Records the REAL overlay running its consent countdown and morphing into the banner, by
# recording that one window with ScreenCaptureKit (tools/window-frames, never the screen), then assembles the frames into
# a looping animated WebP with each frame's true duration. Needs peekaboo, jq, ImageMagick and tools/window-frames (build: swiftc -O tools/window-frames.swift -o tools/window-frames).
set -euo pipefail
OUT="${1:?out.webp}"; SECS="${2:-6}"; W="${3:-400}"; TS="${4:-1}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/overlay/agent-overlay-mac"
WHO="Claude Code · session 4f2a91c3"; GOAL="Open System Settings → Displays and turn on Night Shift"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
HOLD=$((SECS + 4))

{ sleep "$HOLD"; echo HIDE; } | "$BIN" --who "$WHO" --desc "$GOAL" --consent "$SECS" --width "$W" --text-scale "$TS" >/dev/null &
pid=$!
id=""
for _ in $(seq 1 40); do
  id="$(peekaboo list windows --app "PID:$pid" --json 2>/dev/null | jq -r '[.data.windows[] | select(.title=="Agent Control")][0].window_id // empty')"
  [ -n "$id" ] && break; sleep 0.1
done
[ -n "$id" ] || { echo "no Agent Control window" >&2; exit 1; }

# Record that one window at ~20 fps until the panel has been a banner for ~2.5 s.
"$(dirname "$0")/window-frames" "$id" 20 "$((SECS + 3))" "$TMP" >/dev/null
n=$(ls "$TMP"/*.png | wc -l | tr -d " ")
wait "$pid" 2>/dev/null || true

# Every frame onto one canvas (the banner is shorter than the countdown), top-aligned,
# with its real on-screen duration; the last frame holds 2 s before the loop restarts.
maxw=0; maxh=0
for f in "$TMP"/*.png; do read -r w h < <(magick identify -format '%w %h\n' "$f"); [ "$w" -gt "$maxw" ] && maxw=$w; [ "$h" -gt "$maxh" ] && maxh=$h; done
args=(); T=(); while read -r t; do T+=("$t"); done < "$TMP/times"; i=0
for f in "$TMP"/*.png; do
  if [ $((i+1)) -lt ${#T[@]} ]; then d=$(perl -e "printf '%d', (${T[$((i+1))]} - ${T[$i]}) * 100 + 0.5"); else d=200; fi
  [ "$d" -lt 2 ] && d=2
  magick "$f" -background none -gravity north -extent "${maxw}x${maxh}" +repage "$f"
  args+=( -delay "$d" "$f" )
  i=$((i+1))
done
magick -dispose background "${args[@]}" -loop 0 -quality 90 "$OUT"
echo "$OUT: $n frames, ${maxw}x${maxh}"
