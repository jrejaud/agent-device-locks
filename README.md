# screen-claim

**A Pause button for an AI agent driving your Mac.**

Before the agent touches anything, a small panel in the corner says what it wants to do
and counts down. While it drives, the panel stays up with **Pause**, **Talk** and
**Cancel**, and those buttons actually stop it: Pause kills the click or keystroke in
flight, and a Claude Code hook refuses every further screen action until you press Resume.

| Asking | Driving | Paused |
|---|---|---|
| ![consent countdown](docs/consent.png) | ![control banner](docs/banner.png) | ![paused](docs/paused.png) |

The hands are [peekaboo](https://github.com/openclaw/Peekaboo). This repo is the layer
around them: consent, control, one agent at a time, and the [rules](PLAYBOOK.md) that keep
keystrokes out of the wrong app.

> **Reference code, not a maintained product.** It is small on purpose. Read it, copy it,
> or point your agent at the write-up and have it build its own.

## What's in it

| Path | |
|---|---|
| `overlay/main.swift` | The panel. A non-activating `NSPanel` (never steals focus, floats over every Space). Speaks a line protocol: prints `GRANT` `DENY` `STOP` `RESUME` `CANCEL` `MSG <text>`, reads `DOING <text>` `PAUSED` `RESUMED` `HIDE`. |
| `bin/screen-claim` | What the agent runs: `start "<goal>"`, `doing`, `stop`, `status`, `stopped`, `inbox`, `resume`. |
| `bin/watch.mjs` | Runs the panel for one claim and turns presses into state: `interrupt.json` on Pause/Cancel (plus `pkill` of peekaboo/cliclick), `inbox.jsonl` for Talk. Keeps the Mac awake while the claim is held. |
| `hooks/screen-stop-gate.sh` | PreToolUse hook: while paused or cancelled, deny every screen-driving call. The deny reason carries the user's Talk messages, so the agent hears them on its next attempt. |
| `hooks/screen-lock-gate.sh` | PreToolUse hook: deny screen driving unless this session holds the claim. One driver at a time, never one the user can't see. |
| `tools/type-to-pid.swift` | Send keystrokes to one process by pid, so they cannot land in whatever happens to have focus. |
| `PLAYBOOK.md` | The rules for the agent. |

## Install

Needs macOS 14+, Xcode command-line tools, Node 18+, `jq`, and peekaboo
(`brew install openclaw/tap/peekaboo`) with Accessibility + Screen Recording granted.

```bash
git clone https://github.com/jrejaud/screen-claim ~/screen-claim
~/screen-claim/overlay/build.sh
ln -s ~/screen-claim/bin/screen-claim /usr/local/bin/screen-claim
```

Wire both hooks in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|mcp__peekaboo__.*|mcp__computer-use__.*",
        "hooks": [
          { "type": "command", "command": "~/screen-claim/hooks/screen-stop-gate.sh" },
          { "type": "command", "command": "~/screen-claim/hooks/screen-lock-gate.sh" }
        ] }
    ]
  }
}
```

Then add [PLAYBOOK.md](PLAYBOOK.md) to your agent's instructions.

### Optional

- `SCREEN_CLAIM_NOTIFY_CMD` — a command run with each button press as its argument (type it
  into the agent's terminal, push it to your phone). Without it the agent learns on its
  next screen action, through the hook.
- `SCREEN_CLAIM_FOCUS_CMD` — shows a **Go to session** button that runs this command, e.g.
  `open -a Terminal`.
- `SCREEN_CONSENT_SECS` (default 15), `SCREEN_CLAIM_WHO` (the label on the panel),
  `SCREEN_CLAIM_STATE` (default `~/.local/state/screen-claim`).

## Tests

```bash
test/hooks.test.sh   # both hooks, against a throwaway state dir
test/e2e.test.sh     # start → pause → talk → resume → cancel → stop, with a fake overlay
```

MIT.
