#!/usr/bin/env bash
# screen-lock-gate.sh — Claude Code PreToolUse hook. DENY driving the screen (peekaboo,
# cliclick, AppleScript System Events click/keystroke) unless THIS session holds the
# screen claim (`screen-claim start "<goal>"`). Two agents clicking at once is chaos, and
# an agent that drives without the overlay is driving where the human cannot stop it.
#
# Read-only peekaboo verbs stay free: image, capture, see, list, permissions, learn, config.
set -uo pipefail
command -v jq >/dev/null 2>&1 || exit 0
HERE="$(cd "$(dirname "$(realpath "${BASH_SOURCE[0]}")")" && pwd)"

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

# The claim is the agent-lock `mac-screen` (taken by `screen-claim start`, renewed by its
# watcher, stale within a TTL if the watcher dies). Ask it whether THIS session holds it:
# agent-lock names a Claude Code holder after its session id, so pass the hook's in.
command -v node >/dev/null 2>&1 || exit 0
st="$(CLAUDE_CODE_SESSION_ID="$sid" node "$HERE/../bin/agent-lock.mjs" status mac-screen --json 2>/dev/null)"
state="$(printf '%s' "$st" | jq -r '.state // "free"' 2>/dev/null)"
if [ "$state" = held ] || [ "$state" = held-by-me ]; then
  if [ -z "$sid" ] || [ "$(printf '%s' "$st" | jq -r .mine)" = true ]; then exit 0; fi
  why="another agent holds the screen: $(printf '%s' "$st" | jq -r '.holder + " — " + .desc')"
else
  why="you do not hold the screen claim"
fi
jq -n --arg r "Blocked $drives: $why. Run \`screen-claim start \"<what you are about to do>\"\` first (it shows the user a countdown and a control overlay), and \`screen-claim stop\` when done." \
  '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
