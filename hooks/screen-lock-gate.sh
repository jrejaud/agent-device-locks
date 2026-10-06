#!/usr/bin/env bash
# screen-lock-gate.sh — Claude Code PreToolUse hook. DENY driving the screen (peekaboo,
# cliclick, AppleScript System Events click/keystroke) unless THIS session holds the
# screen claim (`screen-claim start "<goal>"`). Two agents clicking at once is chaos, and
# an agent that drives without the overlay is driving where the human cannot stop it.
#
# Read-only peekaboo verbs stay free: image, capture, see, list, permissions, learn, config.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
STATE="${SCREEN_CLAIM_STATE:-$HOME/.local/state/screen-claim}"
LOCK="$STATE/lock.json"; PIDF="$STATE/watch.pid"

input="$(cat)"
[ "$(printf '%s' "$input" | jq -r '.tool_name // ""')" = "Bash" ] || exit 0
raw="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"
sid="$(printf '%s' "$input" | jq -r '.session_id // ""')"
# Judge only what would RUN: blank out quoted strings first.
cmd="$(printf '%s' "$raw" | tr '\n' ' ' | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")"

drives=""
if printf '%s' "$cmd" | grep -qE '(^|[;&|( /])cliclick([ ;&|)]|$)'; then drives="cliclick"; fi
if printf '%s' "$cmd" | grep -qE '(^|[;&|( /])peekaboo +' \
   && ! printf '%s' "$cmd" | grep -qE '(^|[;&|( /])peekaboo +(image|capture|see|list|permissions|learn|config|--help|-h|--version)([ ;&|)]|$)'; then
  drives="peekaboo"
fi
if printf '%s' "$cmd" | grep -q osascript && printf '%s' "$raw" | grep -qi 'System Events' \
   && printf '%s' "$raw" | grep -qiE '(^|[^a-z])(click|keystroke|key code|set value|perform action)([^a-z]|$)'; then
  drives="AppleScript UI scripting"
fi
[ -n "$drives" ] || exit 0

held=0
if [ -f "$LOCK" ] && [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  owner="$(jq -r '.session // ""' "$LOCK")"
  if [ -z "$owner" ] || [ -z "$sid" ] || [ "$owner" = "$sid" ]; then held=1; fi
fi
[ "$held" = 1 ] && exit 0

why="you do not hold the screen claim"
[ -f "$LOCK" ] && why="another agent holds the screen: $(jq -r '.who + " — " + .goal' "$LOCK")"
jq -n --arg r "Blocked $drives: $why. Run \`screen-claim start \"<what you are about to do>\"\` first (it shows the user a countdown and a control overlay), and \`screen-claim stop\` when done." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
