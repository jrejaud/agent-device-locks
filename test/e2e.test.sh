#!/usr/bin/env bash
# End to end with the fake overlay: start → granted → paused → message → resumed → cancelled → stop.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SCREEN_CLAIM_STATE="$(mktemp -d)" SCREEN_CLAIM_OVERLAY="$ROOT/test/fake-overlay.sh"
export AGENT_LOCK_DIR="$SCREEN_CLAIM_STATE/locks" AGENT_LOCK_HOLDER="agent-one" SCREEN_CLAIM_TTL=6
trap '"$ROOT/bin/screen-claim" stop >/dev/null; rm -rf "$SCREEN_CLAIM_STATE"' EXIT
S="$SCREEN_CLAIM_STATE"; fails=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }
lockstate() { node "$ROOT/bin/agent-lock.mjs" status mac-screen --json | jq -r "$1"; }
# Wait (up to 5 s) for a condition instead of sleeping a guessed amount.
until_ok() { local i=0; while ! eval "$1" 2>/dev/null && [ $i -lt 100 ]; do sleep 0.05; i=$((i+1)); done; }
press() { touch "$S/press-$1"; }

"$ROOT/bin/screen-claim" start "e2e test" --consent 0 >/dev/null
check "start is granted"                    '[ "$(cat $S/decision)" = grant ]'
check "the mac-screen agent-lock is ours"   '[ "$(lockstate .state)" = held-by-me ] && [ "$(lockstate .desc)" = "e2e test" ]'
check "status shows the claim"              '"$ROOT/bin/screen-claim" status | grep -q "held: agent-one — e2e test"'
check "a second agent is refused (exit 4)"  'AGENT_LOCK_HOLDER=agent-two "$ROOT/bin/screen-claim" start "other" --consent 0 2>/dev/null; [ $? = 4 ]'
press 1; until_ok '[ -f $S/interrupt.json ]'
check "Pause writes interrupt (pause)"      '[ "$(jq -r .kind $S/interrupt.json)" = pause ]'
check "stopped reports it"                  '"$ROOT/bin/screen-claim" stopped >/dev/null'
check "start refuses while paused"          '! "$ROOT/bin/screen-claim" start "again" --consent 0 2>/dev/null'
press 2; until_ok 'grep -q "left monitor" $S/inbox.jsonl'
check "Talk lands in the inbox"             'grep -q "use the left monitor" $S/inbox.jsonl'
press 3; until_ok '[ ! -f $S/interrupt.json ]'
check "Resume clears the interrupt"         '[ ! -f $S/interrupt.json ]'
press 4; until_ok '[ -f $S/interrupt.json ]'
check "Cancel writes interrupt (cancel)"    '[ "$(jq -r .kind $S/interrupt.json)" = cancel ]'
check "inbox prints the message"            '"$ROOT/bin/screen-claim" inbox | grep -q "left monitor"'
sleep 2
check "the watcher renews the lock past its TTL" '[ "$(lockstate .state)" = held-by-me ]'
"$ROOT/bin/screen-claim" stop >/dev/null; until_ok '! pgrep -f "watch.mjs --state $S" >/dev/null'
check "stop releases the screen"            '"$ROOT/bin/screen-claim" status | grep -q "^free"'
check "stop releases the agent-lock"        '[ "$(lockstate .state)" = free ]'
check "stop clears the cancel"              '[ ! -f $S/interrupt.json ]'
check "watcher is gone"                     '! pgrep -f "watch.mjs --state $S" >/dev/null'
[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
