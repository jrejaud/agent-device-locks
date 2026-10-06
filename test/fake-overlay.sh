#!/usr/bin/env bash
# Stands in for the Swift overlay: grants, then presses Pause, sends a Talk message,
# presses Resume, then Cancel — so watch.mjs can be tested with no window.
# Each press waits for the test to `touch $SCREEN_CLAIM_STATE/press-<n>`, so the test drives
# the timing instead of racing fixed sleeps (a timer version failed ~1 run in 7).
press() {  # n line
  local f="$SCREEN_CLAIM_STATE/press-$1" i=0
  while [ ! -e "$f" ] && [ $i -lt 400 ]; do sleep 0.05; i=$((i+1)); done
  echo "$2"
}
echo "GRANT 1"
press 1 "STOP 2"
press 2 "MSG use the left monitor"
press 3 "RESUME 3"
press 4 "CANCEL 4"
while read -r line; do [ "$line" = HIDE ] && exit 0; done
