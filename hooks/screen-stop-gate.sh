#!/usr/bin/env bash
# screen-stop-gate.sh — Claude Code PreToolUse hook. While the user has pressed Pause,
# Cancel or "I'm busy" on the screen-claim overlay, DENY every screen-driving tool call.
# The deny reason carries what the user pressed and any message they typed into Talk,
# so the agent learns it was stopped on its very next attempt.
#
# Covered: Bash commands that run peekaboo or cliclick, AppleScript UI scripting
# (System Events click/keystroke), and the peekaboo / computer-use MCP tools.
set -uo pipefail
STATE="${SCREEN_CLAIM_STATE:-$HOME/.local/state/screen-claim}"
INTR="$STATE/interrupt.json"; INBOX="$STATE/inbox.jsonl"
[ -f "$INTR" ] || exit 0

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""')"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""')"

deny() {
  local msg kind msgs=""
  kind="$(jq -r .kind "$INTR" 2>/dev/null)"; msg="$(jq -r .message "$INTR" 2>/dev/null)"
  [ -s "$INBOX" ] && msgs=" Messages from the user: $(jq -r '"\"" + .text + "\""' "$INBOX" | paste -sd' ' -)."
  jq -n --arg r "Screen driving is halted ($kind) — blocked: $1. $msg$msgs Do not retry or route around it with another GUI tool." \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  mcp__computer-use__request_access|mcp__computer-use__list_granted_applications) exit 0 ;;
  mcp__computer-use__*) deny "computer-use ($tool)" ;;
  mcp__peekaboo__list|mcp__peekaboo__image) exit 0 ;;   # read-only
  mcp__peekaboo__*) deny "peekaboo MCP ($tool)" ;;
esac

if [ "$tool" = "Bash" ]; then
  # Judge only what would RUN: blank out quoted strings so a mention inside quotes
  # (a grep pattern, a commit message) is not an invocation.
  raw="$cmd"
  cmd="$(printf '%s' "$cmd" | tr '\n' ' ' | sed -E "s/'[^']*'/''/g; s/\"[^\"]*\"/\"\"/g")"
  if printf '%s' "$cmd" | grep -qE '(^|[;&|( /])(peekaboo|cliclick)([ ;&|)]|$)'; then
    deny "peekaboo/cliclick"
  fi
  if printf '%s' "$cmd" | grep -qE 'osascript' \
     && printf '%s' "$raw" | grep -qiE 'System Events' \
     && printf '%s' "$raw" | grep -qiE '(^|[^a-z])(click|keystroke|key code|set value|perform action)([^a-z]|$)'; then
    deny "AppleScript UI scripting (System Events click/keystroke)"
  fi
fi
exit 0
