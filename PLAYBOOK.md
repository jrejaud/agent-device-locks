# Driving a Mac: the agent playbook

Paste this into your agent's instructions (`CLAUDE.md`, a skill, a system prompt). It is
the part that makes screen control reliable, and it costs nothing to install.

## The tool: peekaboo, not computer-use

Use [peekaboo](https://github.com/openclaw/Peekaboo) for the hands. It drives macOS
accessibility directly: no read-only tier for browsers, no per-app grant negotiated
mid-task. It needs Accessibility and Screen Recording granted once in System Settings.

```bash
peekaboo see --app Safari --json          # UI elements with ids + a snapshot id
peekaboo image --app Safari --path s.png  # look
peekaboo click "Sign In"                  # by label (or --on <elem-id>, or coordinates)
peekaboo type "hello"                     # into the FOCUSED element of the FRONTMOST app
peekaboo press return ; peekaboo hotkey cmd,shift,g
peekaboo menu --app Safari --item "New Window"
peekaboo dialog click --button "OK" --app Safari
peekaboo learn                            # its own full agent guide
```

## Rules

1. **Claim the screen before the first click, release it after — including on failure.**
   `screen-claim start "<what you are about to do, in plain words>"`, then drive, then
   `screen-claim stop`. The goal text is what the human reads before deciding to let you.
   Update it as you go: `screen-claim doing "Filling in the shipping form"`.

2. **If a call is denied because the user paused or cancelled, stop.** Do not retry, do not
   switch to another GUI tool. Read the reason (it carries any message they typed), tell
   them what state the screen is in, and wait. Pause = keep your place, they may resume.
   Cancel = drop the task and `screen-claim stop`.

3. **Accessibility first, mouse and keyboard last.** Pressing a button or setting a field
   through the accessibility tree does not move the cursor or take focus, so the human can
   keep working, and it cannot land in the wrong app.
   ```bash
   osascript -e 'tell application "System Events" to tell process "Safari" to click button "Sign In" of window 1'
   osascript -e 'tell application "System Events" to tell process "Safari" to set value of text field 1 of window 1 to "me@example.com"'
   ```
   Fall back to real clicks and keystrokes only when the element is not exposed (games,
   canvases) or refuses (secure password fields often reject `set value`).

4. **Never type without proving where the keys will land.** `type` goes to the focused
   element of the frontmost app, not the app you named. Before typing: pick the target
   window by its real title and size (apps own invisible windows, often listed first),
   bring it forward, confirm `lsappinfo info -only name $(lsappinfo front)` names it, type a
   few characters, screenshot the window, and only then continue.
   Better: when you know the pid, `type-to-pid <pid> text "…"` sends keys straight to that
   process and cannot hit anything else.

5. **Submit by clicking the button, not by pressing Return.** Many apps do not bind Return
   to their default button.

6. **Capture feedback as a burst.** An error shake or a toast lasts about a second. After a
   submit, screenshot the window every ~150 ms for ~2 s and look across the frames. The
   app's own state (an AX value, a log line, its API) beats pixels when available.

7. **Screenshot the window, not the screen.** `screencapture -l <windowid>` captures one
   window regardless of what is in front of it. A full-screen or region capture catches
   whatever else is open, including private things in other apps.

8. **System dialogs** ("X quit unexpectedly" and friends) belong to the
   `UserNotificationCenter` process; press their buttons through AppleScript:
   `tell application "System Events" to tell process "UserNotificationCenter" to click button "Ignore" of window 1`.
