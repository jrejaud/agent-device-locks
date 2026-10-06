#!/usr/bin/env bash
# End to end with the fake overlay: start → granted → paused → message → resumed → cancelled → stop.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SCREEN_CLAIM_STATE="$(mktemp -d)" SCREEN_CLAIM_OVERLAY="$ROOT/test/fake-overlay.sh"
trap '"$ROOT/bin/screen-claim" stop >/dev/null; rm -rf "$SCREEN_CLAIM_STATE"' EXIT
S="$SCREEN_CLAIM_STATE"; fails=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }

"$ROOT/bin/screen-claim" start "e2e test" --consent 0 >/dev/null
check "start is granted"                    '[ "$(cat $S/decision)" = grant ]'
check "status shows the claim"              '"$ROOT/bin/screen-claim" status | grep -q "held: .*e2e test"'
sleep 1.8
check "Pause writes interrupt (pause)"      '[ "$(jq -r .kind $S/interrupt.json)" = pause ]'
check "stopped reports it"                  '"$ROOT/bin/screen-claim" stopped >/dev/null'
check "start refuses while paused"          '! "$ROOT/bin/screen-claim" start "again" --consent 0 2>/dev/null'
sleep 1
check "Talk lands in the inbox"             'grep -q "use the left monitor" $S/inbox.jsonl'
sleep 1
check "Resume clears the interrupt"         '[ ! -f $S/interrupt.json ]'
sleep 1.2
check "Cancel writes interrupt (cancel)"    '[ "$(jq -r .kind $S/interrupt.json)" = cancel ]'
check "inbox prints the message"            '"$ROOT/bin/screen-claim" inbox | grep -q "left monitor"'
"$ROOT/bin/screen-claim" stop >/dev/null; sleep 0.5
check "stop releases the screen"            '"$ROOT/bin/screen-claim" status | grep -q "^free"'
check "stop clears the cancel"              '[ ! -f $S/interrupt.json ]'
check "watcher is gone"                     '! pgrep -f "watch.mjs --state $S" >/dev/null'
[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
