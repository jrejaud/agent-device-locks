#!/usr/bin/env bash
# Contract for bin/agent-lock.mjs, local storage only, against a throwaway lock root.
# (The --device <serial> backend runs the same logic through `adb shell`; not tested here.)
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export AGENT_LOCK_DIR="$(mktemp -d)"
unset AGENT_LOCK_HOLDER AGENT_LOCK_DEVICE
trap 'rm -rf "$AGENT_LOCK_DIR"' EXIT
fails=0
al() { local who="$1"; shift; AGENT_LOCK_HOLDER="$who" node "$ROOT/bin/agent-lock.mjs" "$@"; }
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; fails=$((fails+1)); fi; }
code() { "$@" >/dev/null 2>&1; echo $?; }
json() { al "$1" status "$2" --json | jq -r "$3"; }

# --- acquire / refuse / release
check "A acquires"                         '[ "$(code al A acquire r1 --ttl 60 --wait 0)" = 0 ]'
check "status says held-by-me for A"       '[ "$(json A r1 .state)" = held-by-me ]'
check "status says held for B"             '[ "$(json B r1 .state)" = held ]'
check "B is refused (exit 4) with --wait 0" '[ "$(code al B acquire r1 --wait 0)" = 4 ]'
check "B cannot release the lock of A (exit 5)" '[ "$(code al B release r1)" = 5 ]'
check "A re-acquire is a renew"            'al A acquire r1 --wait 0 | grep -q "already mine"'
check "A releases"                         '[ "$(code al A release r1)" = 0 ] && [ "$(json A r1 .state)" = free ]'

# --- steal: a live lock never, a stale one yes
al A acquire r2 --ttl 60 --wait 0 >/dev/null
check "steal of a live lock is refused (5)" '[ "$(code al B steal r2)" = 5 ] && [ "$(json A r2 .holder)" = A ]'
al A release r2 >/dev/null
al A acquire r2 --ttl 1 --wait 0 >/dev/null; sleep 2
check "a past-TTL lock reads stale"        '[ "$(json B r2 .state)" = stale ]'
check "steal adopts the stale lock"        'al B steal r2 | grep -q stolen && [ "$(json B r2 .holder)" = B ]'
check "the fence token moved on (3rd claim)"          '[ "$(json B r2 .fence)" = 3 ]'
check "A (frozen past its TTL) cannot renew" '[ "$(code al A renew r2)" = 5 ]'

# --- interrupt / resume: anyone raises it, it does not release, a fresh claim clears it
al A acquire r3 --ttl 60 --wait 0 >/dev/null
al U interrupt r3 --message "stop now" >/dev/null
check "interrupt is visible to the holder" '[ "$(json A r3 .interrupted)" = true ] && [ "$(json A r3 .interrupt.message)" = "stop now" ]'
check "interrupt does not release"         '[ "$(json A r3 .state)" = held-by-me ]'
check "re-acquire does not clear it"       'al A acquire r3 --wait 0 >/dev/null; [ "$(json A r3 .interrupted)" = true ]'
al U resume r3 >/dev/null
check "resume clears it"                   '[ "$(json A r3 .interrupted)" = false ]'
al U interrupt r3 >/dev/null; al A release r3 >/dev/null
check "release wipes the flag"             '[ "$(json B r3 .interrupted)" = false ]'

# --- disable / enable (master switch)
al U disable r4 --message "hands off" >/dev/null
check "acquire refuses while disabled (6)" '[ "$(code al A acquire r4 --wait 0)" = 6 ]'
al U enable r4 >/dev/null
check "acquire works after enable"         '[ "$(code al A acquire r4 --wait 0)" = 0 ]'
al A release r4 >/dev/null

# --- queue: waiters are served in arrival order, or in the order the user set
ORDER="$AGENT_LOCK_DIR/served"
waiter() {  # holder, resource: wait, record the turn, hold 1 s, release
  al "$1" acquire "$2" --wait 30 --poll 1 >/dev/null && echo "$1" >> "$ORDER.$2" && sleep 1 && al "$1" release "$2" >/dev/null
}
al A acquire q1 --ttl 60 --wait 0 >/dev/null
waiter B q1 & W1=$!; sleep 1.5
waiter C q1 & W2=$!; sleep 1.5
check "queue lists both waiters, B first"  '[ "$(al A queue q1 --json | jq -r "[.waiters[].holder]|join(\",\")")" = "B,C" ]'
al A release q1 >/dev/null; wait "$W1" "$W2"
check "served in arrival order: B then C"  '[ "$(paste -sd, "$ORDER.q1")" = "B,C" ]'

al A acquire q2 --ttl 60 --wait 0 >/dev/null
waiter B q2 & W1=$!; sleep 1.5
waiter C q2 & W2=$!; sleep 1.5
al U reorder q2 --order C,B >/dev/null
al A release q2 >/dev/null; wait "$W1" "$W2"
check "reorder wins over arrival: C then B" '[ "$(paste -sd, "$ORDER.q2")" = "C,B" ]'
check "queue is empty afterwards"          '[ "$(al A queue q2 --json | jq ".waiters|length")" = 0 ]'

# --- holder identity falls back to the session id
check "session id names the holder"        'CLAUDE_CODE_SESSION_ID=S9 node "$ROOT/bin/agent-lock.mjs" acquire r5 --wait 0 >/dev/null; json X r5 .holder | grep -q "^S9@."'

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
