#!/usr/bin/env bash
# Contract for both hooks, against a throwaway state dir and lock root. Prints PASS/FAIL per case.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SCREEN_CLAIM_STATE="$(mktemp -d)"
export AGENT_LOCK_DIR="$SCREEN_CLAIM_STATE/locks"
unset AGENT_LOCK_HOLDER CLAUDE_CODE_SESSION_ID
trap 'rm -rf "$SCREEN_CLAIM_STATE"' EXIT
fails=0

call() {  # hook, command, session → "deny" | "allow"
  local out
  out="$(jq -n --arg c "$2" --arg s "${3:-S1}" '{tool_name:"Bash",tool_input:{command:$c},session_id:$s}' | "$ROOT/hooks/$1")"
  printf '%s' "$out" | grep -q '"deny"' && echo deny || echo allow
}
expect() {  # label, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fails=$((fails+1)); fi
}
lock() { CLAUDE_CODE_SESSION_ID="$1" node "$ROOT/bin/agent-lock.mjs" "${@:2}" >/dev/null 2>&1; }

# --- lock gate: no claim held
expect "lock: click without a claim is denied"        deny  "$(call screen-lock-gate.sh 'peekaboo click "OK"')"
expect "lock: screenshot without a claim is allowed"  allow "$(call screen-lock-gate.sh 'peekaboo image --app Finder --path x.png')"
expect "lock: quoted mention is not an invocation"    allow "$(call screen-lock-gate.sh "grep 'peekaboo click' notes.md")"
expect "lock: System Events click is denied"          deny  "$(call screen-lock-gate.sh "osascript -e 'tell application \"System Events\" to click button 1'")"

# --- lock gate: the mac-screen agent-lock held by session S1
lock S1 acquire mac-screen --ttl 60 --wait 0 --desc "g"
expect "lock: holder may click"                       allow "$(call screen-lock-gate.sh 'peekaboo click "OK"' S1)"
expect "lock: a different session may not"            deny  "$(call screen-lock-gate.sh 'peekaboo click "OK"' S2)"
lock S1 release mac-screen
expect "lock: after release the holder may not"       deny  "$(call screen-lock-gate.sh 'peekaboo click "OK"' S1)"
lock S1 acquire mac-screen --ttl 1 --wait 0; sleep 2
expect "lock: a stale claim (watcher died) is denied" deny  "$(call screen-lock-gate.sh 'peekaboo click "OK"' S1)"

# --- stop gate
expect "stop: not paused → allowed"                   allow "$(call screen-stop-gate.sh 'peekaboo click "OK"')"
jq -n '{kind:"pause",message:"paused",at:"now"}' > "$SCREEN_CLAIM_STATE/interrupt.json"
expect "stop: paused → click denied"                  deny  "$(call screen-stop-gate.sh 'cd x && peekaboo type "hi"')"
expect "stop: paused → cliclick denied"               deny  "$(call screen-stop-gate.sh 'cliclick c:10,10')"
expect "stop: paused → unrelated command allowed"     allow "$(call screen-stop-gate.sh 'ls -la')"
echo '{"at":"now","text":"use the other window"}' > "$SCREEN_CLAIM_STATE/inbox.jsonl"
reason="$(jq -n '{tool_name:"Bash",tool_input:{command:"peekaboo click OK"}}' | "$ROOT/hooks/screen-stop-gate.sh" | jq -r .hookSpecificOutput.permissionDecisionReason)"
expect "stop: Talk message reaches the agent"         yes   "$(printf '%s' "$reason" | grep -q 'use the other window' && echo yes || echo no)"

[ "$fails" = 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
